import AppKit
import Foundation
import SwiftUI
import WidgetKit

@main
struct UsageBarApp: App {
    @StateObject private var store = UsageStore()

    var body: some Scene {
        MenuBarExtra {
            UsagePanel(store: store)
                .onAppear {
                    store.start()
                }
        } label: {
            Label(store.menuTitle, systemImage: "chart.bar.fill")
        }
        .menuBarExtraStyle(.window)
    }
}

@MainActor
final class UsageStore: ObservableObject {
    @Published private(set) var codexState: UsageState = .loading {
        didSet { scheduleWidgetSnapshotPersistence() }
    }
    @Published private(set) var claudeState: UsageState = .loading {
        didSet { scheduleWidgetSnapshotPersistence() }
    }
    @Published var selectedProvider: UsageProvider = .codex

    private var timer: Timer?
    private var activityToken: NSObjectProtocol?
    private var codexRefreshTask: Task<Void, Never>?
    private var claudeRefreshTask: Task<Void, Never>?
    private var widgetSnapshotPersistTask: Task<Void, Never>?
    private var claudeLive: UsageSnapshot?            // 最近一次成功的实时快照
    private var lastClaudeAttempt: Date = .distantPast
    private var claudeBackoffUntil: Date = .distantPast
    private var lastPersistedWidgetSnapshot: UsageWidgetSnapshot?

    var menuTitle: String {
        let codex = compactRemainingText(provider: .codex, state: codexState)
        let claude = compactRemainingText(provider: .claude, state: claudeState)

        if let codex, let claude {
            return "\(codex) · \(claude)"
        }

        return codex ?? claude ?? "UsageMonitor"
    }

    private func compactRemainingText(provider: UsageProvider, state: UsageState) -> String? {
        guard case .loaded(let snapshot) = state else { return nil }
        let prefix = provider == .codex ? "C" : "Cl"
        return "\(prefix) \(Int(snapshot.primaryRemaining.rounded()))%"
    }

    func state(for provider: UsageProvider) -> UsageState {
        switch provider {
        case .codex:
            return codexState
        case .claude:
            return claudeState
        }
    }

    init() {
        start()
    }

    func start() {
        guard timer == nil else { return }

        // 菜单栏 app 是后台进程，闲置后 App Nap 会把 NSTimer 大幅节流甚至挂起。
        // 退出 App Nap（但仍允许 Mac 正常休眠），保证定时刷新稳定触发。
        activityToken = ProcessInfo.processInfo.beginActivity(
            options: .userInitiatedAllowingIdleSystemSleep,
            reason: "UsageMonitor periodic usage refresh"
        )

        let timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refresh()
            }
        }
        // 加到 .common 模式，弹窗打开（事件跟踪模式）时计时器也能继续触发。
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        refresh()
    }

    func refresh() {
        refreshCodex()
        refreshClaude()
    }

    private func scheduleWidgetSnapshotPersistence() {
        widgetSnapshotPersistTask?.cancel()
        widgetSnapshotPersistTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard !Task.isCancelled else { return }
            self?.persistWidgetSnapshotIfNeeded()
        }
    }

    private func persistWidgetSnapshotIfNeeded() {
        var rows = UsageWidgetSnapshot.defaultRows
        updateWidgetRow(id: "claude", state: claudeState, rows: &rows)
        updateWidgetRow(id: "codex", state: codexState, rows: &rows)
        let snapshot = UsageWidgetSnapshot(updatedAt: Date(), rows: rows)

        guard snapshot != lastPersistedWidgetSnapshot else {
            return
        }

        do {
            try UsageWidgetStore.save(snapshot)
            lastPersistedWidgetSnapshot = snapshot
            WidgetCenter.shared.reloadTimelines(ofKind: "UsageBarWidget")
        } catch {
            // The widget can still render its built-in placeholder if the shared
            // container is unavailable, so the menu bar app should stay quiet.
        }
    }

    private func updateWidgetRow(id: String, state: UsageState, rows: inout [UsageWidgetRow]) {
        guard let index = rows.firstIndex(where: { $0.id == id }) else { return }
        var row = rows[index]

        switch state {
        case .loading:
            row.percent = 0
            row.detail = "加载中"
            row.isUnavailable = true

        case .unavailable:
            row.percent = 0
            row.detail = "不可用"
            row.isUnavailable = true

        case .loaded(let snapshot):
            let remainingPercent = snapshot.primaryRemaining
            row.percent = max(0, min(remainingPercent, 100))
            row.detail = UsageWidgetResetText.text(for: snapshot.primary?.resetDate)
            row.isCritical = remainingPercent <= 10
            row.isUnavailable = snapshot.primary == nil
            row.fillsRemaining = true
        }

        rows[index] = row
    }

    private func refreshCodex() {
        codexRefreshTask?.cancel()
        codexRefreshTask = Task { @MainActor in
            do {
                let snapshot = try await Task.detached {
                    try CodexUsageReader().latestSnapshot()
                }.value

                guard !Task.isCancelled else { return }
                codexState = .loaded(snapshot)
            } catch {
                guard !Task.isCancelled else { return }
                codexState = .unavailable(error.localizedDescription)
            }
        }
    }

    private func refreshClaude() {
        let now = Date()
        // 429 退避期内直接跳过，让端点冷却。
        if now < claudeBackoffUntil { return }
        // 节流：任意来源（手点/计时器）最短 30s 才真正发一次请求，避免打爆端点触发 429。
        if now.timeIntervalSince(lastClaudeAttempt) < 30 { return }
        lastClaudeAttempt = now

        claudeRefreshTask?.cancel()
        claudeRefreshTask = Task { @MainActor in
            do {
                let snapshot = try await Task.detached {
                    try ClaudeOAuthUsageReader().latestSnapshot()
                }.value

                guard !Task.isCancelled else { return }
                claudeLive = snapshot          // 记住最近一次成功的实时结果
                claudeState = .loaded(snapshot)
            } catch {
                guard !Task.isCancelled else { return }

                if case ClaudeUsageError.httpStatus(429) = error {
                    claudeBackoffUntil = Date().addingTimeInterval(180)
                }

                // 失败时优先保留上次实时结果（时间会变旧但不会倒退到很久前的磁盘缓存）；
                // 完全没有实时结果时才退到 Stop hook 写的本地缓存。
                if let live = claudeLive {
                    claudeState = .loaded(live)
                } else if let cache = try? ClaudeCacheUsageReader().latestSnapshot() {
                    claudeState = .loaded(cache)
                } else {
                    claudeState = .unavailable(error.localizedDescription)
                }
            }
        }
    }

    func openUsagePage(for provider: UsageProvider) {
        if let url = URL(string: provider.usageURLString) {
            NSWorkspace.shared.open(url)
        }
    }
}

enum UsageProvider: String, CaseIterable, Identifiable {
    case codex
    case claude

    var id: String { rawValue }

    var title: String {
        switch self {
        case .codex:
            return "Codex"
        case .claude:
            return "Claude"
        }
    }

    var systemImage: String {
        switch self {
        case .codex:
            return "atom"
        case .claude:
            return "sparkle"
        }
    }

    var tint: Color {
        switch self {
        case .codex:
            return Color(red: 0.56, green: 0.79, blue: 0.93)
        case .claude:
            return Color(red: 0.95, green: 0.55, blue: 0.38)
        }
    }

    var usageURLString: String {
        switch self {
        case .codex:
            return "https://chatgpt.com/codex/settings/usage"
        case .claude:
            return "https://claude.ai/settings/usage"
        }
    }
}

enum UsageState {
    case loading
    case loaded(UsageSnapshot)
    case unavailable(String)
}

struct UsageSnapshot {
    let provider: UsageProvider
    let updatedAt: Date
    let sourcePath: String
    let planType: String?
    let primary: RateLimitWindow?
    let secondary: RateLimitWindow?
    let credits: CreditsSnapshot?

    var primaryUsed: Double {
        primary?.usedPercent ?? 0
    }

    var primaryRemaining: Double {
        max(0, 100 - primaryUsed)
    }

    init(
        provider: UsageProvider = .codex,
        updatedAt: Date,
        sourcePath: String,
        planType: String?,
        primary: RateLimitWindow?,
        secondary: RateLimitWindow?,
        credits: CreditsSnapshot?
    ) {
        self.provider = provider
        self.updatedAt = updatedAt
        self.sourcePath = sourcePath
        self.planType = planType
        self.primary = primary
        self.secondary = secondary
        self.credits = credits
    }
}

typealias CodexUsageSnapshot = UsageSnapshot

struct RateLimitWindow: Decodable {
    let usedPercent: Double
    let windowMinutes: Double?
    let resetsAt: Double?

    var resetDate: Date? {
        guard let resetsAt else { return nil }
        return Date(timeIntervalSince1970: resetsAt)
    }

    enum CodingKeys: String, CodingKey {
        case usedPercent
        case usedPercentSnake = "used_percent"
        case usedPercentageSnake = "used_percentage"
        case windowDurationMins
        case windowMinutesSnake = "window_minutes"
        case resetsAt
        case resetsAtSnake = "resets_at"
    }

    init(usedPercent: Double, windowMinutes: Double? = nil, resetsAt: Double? = nil) {
        self.usedPercent = usedPercent
        self.windowMinutes = windowMinutes
        self.resetsAt = resetsAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        usedPercent = try container.decodeFlexibleDouble(forKeys: [.usedPercent, .usedPercentSnake, .usedPercentageSnake])
        windowMinutes = try container.decodeFlexibleOptionalDouble(forKeys: [.windowDurationMins, .windowMinutesSnake])
        resetsAt = try container.decodeFlexibleOptionalDouble(forKeys: [.resetsAt, .resetsAtSnake])
    }
}

struct CreditsSnapshot: Decodable {
    let hasCredits: Bool?
    let unlimited: Bool?
    let balance: Double?

    enum CodingKeys: String, CodingKey {
        case hasCredits
        case hasCreditsSnake = "has_credits"
        case unlimited
        case balance
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        hasCredits = try container.decodeFlexibleOptionalBool(forKeys: [.hasCredits, .hasCreditsSnake])
        unlimited = try container.decodeFlexibleOptionalBool(forKey: .unlimited)
        balance = try container.decodeFlexibleOptionalDouble(forKey: .balance)
    }
}

private struct RolloutLine: Decodable {
    let timestamp: String?
    let payload: RolloutPayload?
}

private struct RolloutPayload: Decodable {
    let type: String?
    let rateLimits: CodexRateLimits?

    enum CodingKeys: String, CodingKey {
        case type
        case rateLimits = "rate_limits"
    }
}

private struct CodexRateLimits: Decodable {
    let primary: RateLimitWindow?
    let secondary: RateLimitWindow?
    let credits: CreditsSnapshot?
    let planType: String?

    enum CodingKeys: String, CodingKey {
        case primary
        case secondary
        case credits
        case planType
        case planTypeSnake = "plan_type"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        primary = try container.decodeIfPresent(RateLimitWindow.self, forKey: .primary)
        secondary = try container.decodeIfPresent(RateLimitWindow.self, forKey: .secondary)
        credits = try container.decodeIfPresent(CreditsSnapshot.self, forKey: .credits)
        planType = try container.decodeFlexibleOptionalString(forKeys: [.planType, .planTypeSnake])
    }
}

private final class CodexUsageReader {
    func latestSnapshot() throws -> CodexUsageSnapshot {
        do {
            return try CodexAppServerUsageReader().latestSnapshot()
        } catch {
            return try RolloutUsageReader().latestSnapshot()
        }
    }
}

private final class ClaudeUsageReader {
    func latestSnapshot() throws -> UsageSnapshot {
        // 优先走零 token 的只读端点，与 Codex 的 account/rateLimits/read 对称。
        do {
            return try ClaudeOAuthUsageReader().latestSnapshot()
        } catch {
            // 端点不可用（离线 / token 过期）时回退到 Stop hook 写的本地缓存。
            return try ClaudeCacheUsageReader().latestSnapshot()
        }
    }
}

/// 直接查询 Claude 账户用量端点。不发 /v1/messages、不触碰模型，零 token。
private final class ClaudeOAuthUsageReader {
    private let decoder = JSONDecoder()

    func latestSnapshot() throws -> UsageSnapshot {
        let token = try keychainToken()
        let usageData = try syncGet("https://api.anthropic.com/api/oauth/usage", token: token)
        let usage = try decoder.decode(OAuthUsageResponse.self, from: usageData)

        guard usage.fiveHour != nil || usage.sevenDay != nil else {
            throw ClaudeUsageError.invalidResponse
        }

        return UsageSnapshot(
            provider: .claude,
            updatedAt: Date(),
            sourcePath: "api.anthropic.com/api/oauth/usage",
            planType: planType(token: token),
            primary: window(usage.fiveHour, windowMinutes: 5 * 60),
            secondary: window(usage.sevenDay, windowMinutes: 7 * 24 * 60),
            credits: nil
        )
    }

    private func window(_ window: OAuthUsageResponse.Window?, windowMinutes: Double) -> RateLimitWindow? {
        guard let window else { return nil }
        return RateLimitWindow(
            usedPercent: window.utilization,
            windowMinutes: windowMinutes,
            resetsAt: parseDate(window.resetsAt)?.timeIntervalSince1970
        )
    }

    /// profile 端点同样零 token，用来补上代码里一直为空的 plan_type；失败就忽略。
    private func planType(token: String) -> String? {
        guard let data = try? syncGet("https://api.anthropic.com/api/oauth/profile", token: token),
              let profile = try? decoder.decode(OAuthProfileResponse.self, from: data) else {
            return nil
        }

        if profile.account?.hasClaudeMax == true { return "max" }
        if profile.account?.hasClaudePro == true { return "pro" }
        return profile.organization?.organizationType?.replacingOccurrences(of: "claude_", with: "")
    }

    private func keychainToken() throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", "Claude Code-credentials", "-w"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()

        do {
            try process.run()
        } catch {
            throw ClaudeUsageError.noToken
        }
        process.waitUntilExit()

        let data = output.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0,
              let creds = try? decoder.decode(KeychainCredentials.self, from: data) else {
            throw ClaudeUsageError.noToken
        }

        let oauth = creds.claudeAiOauth
        if let expiresAt = oauth.expiresAt, Date().timeIntervalSince1970 > expiresAt / 1000 {
            throw ClaudeUsageError.tokenExpired
        }

        guard !oauth.accessToken.isEmpty else { throw ClaudeUsageError.noToken }
        return oauth.accessToken
    }

    private func syncGet(_ urlString: String, token: String) throws -> Data {
        guard let url = URL(string: urlString) else { throw ClaudeUsageError.invalidResponse }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 10
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")

        let semaphore = DispatchSemaphore(value: 0)
        let result = SyncRequestResult()

        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            result.fulfill(data: data, status: (response as? HTTPURLResponse)?.statusCode ?? 0, error: error)
            semaphore.signal()
        }
        task.resume()

        if semaphore.wait(timeout: .now() + 12) == .timedOut {
            task.cancel()
            throw ClaudeUsageError.requestTimedOut
        }

        if let error = result.error { throw error }
        guard result.status == 200, let payload = result.data else {
            throw ClaudeUsageError.httpStatus(result.status)
        }
        return payload
    }

    private func parseDate(_ value: String?) -> Date? {
        guard let value else { return nil }

        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) {
            return date
        }

        let standard = ISO8601DateFormatter()
        standard.formatOptions = [.withInternetDateTime]
        return standard.date(from: value)
    }
}

private final class SyncRequestResult: @unchecked Sendable {
    private let lock = NSLock()
    private var _data: Data?
    private var _status = 0
    private var _error: Error?

    func fulfill(data: Data?, status: Int, error: Error?) {
        lock.lock()
        defer { lock.unlock() }
        _data = data
        _status = status
        _error = error
    }

    var data: Data? { lock.lock(); defer { lock.unlock() }; return _data }
    var status: Int { lock.lock(); defer { lock.unlock() }; return _status }
    var error: Error? { lock.lock(); defer { lock.unlock() }; return _error }
}

private struct OAuthUsageResponse: Decodable {
    let fiveHour: Window?
    let sevenDay: Window?

    enum CodingKeys: String, CodingKey {
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
    }

    struct Window: Decodable {
        let utilization: Double
        let resetsAt: String?

        enum CodingKeys: String, CodingKey {
            case utilization
            case resetsAt = "resets_at"
        }
    }
}

private struct OAuthProfileResponse: Decodable {
    let account: Account?
    let organization: Organization?

    struct Account: Decodable {
        let hasClaudeMax: Bool?
        let hasClaudePro: Bool?

        enum CodingKeys: String, CodingKey {
            case hasClaudeMax = "has_claude_max"
            case hasClaudePro = "has_claude_pro"
        }
    }

    struct Organization: Decodable {
        let organizationType: String?

        enum CodingKeys: String, CodingKey {
            case organizationType = "organization_type"
        }
    }
}

private struct KeychainCredentials: Decodable {
    let claudeAiOauth: OAuth

    struct OAuth: Decodable {
        let accessToken: String
        let expiresAt: Double?
    }
}

private final class ClaudeCacheUsageReader {
    private let decoder = JSONDecoder()
    private let fileManager = FileManager.default

    func latestSnapshot() throws -> UsageSnapshot {
        let cacheURL = claudeHomeURL().appendingPathComponent("usagebar-rate-limits.json")
        guard fileManager.fileExists(atPath: cacheURL.path) else {
            throw ClaudeUsageError.noCache
        }

        let data = try Data(contentsOf: cacheURL)
        let cache: ClaudeUsageCache
        do {
            cache = try decoder.decode(ClaudeUsageCache.self, from: data)
        } catch {
            throw ClaudeUsageError.invalidCache
        }

        return UsageSnapshot(
            provider: .claude,
            updatedAt: Date(timeIntervalSince1970: cache.updatedAt),
            sourcePath: cacheURL.path,
            planType: cache.planType,
            primary: RateLimitWindow(
                usedPercent: cache.currentSession.usedPercent,
                windowMinutes: 5 * 60,
                resetsAt: cache.currentSession.resetsAt
            ),
            secondary: RateLimitWindow(
                usedPercent: cache.weekly.usedPercent,
                windowMinutes: 7 * 24 * 60,
                resetsAt: cache.weekly.resetsAt
            ),
            credits: nil
        )
    }

    private func claudeHomeURL() -> URL {
        if let envHome = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"], !envHome.isEmpty {
            return URL(fileURLWithPath: envHome)
        }

        return fileManager.homeDirectoryForCurrentUser.appendingPathComponent(".claude")
    }
}

private struct ClaudeUsageCache: Decodable {
    let updatedAt: Double
    let planType: String?
    let currentSession: ClaudeUsageLimit
    let weekly: ClaudeUsageLimit

    enum CodingKeys: String, CodingKey {
        case updatedAt = "updated_at"
        case planType = "plan_type"
        case currentSession = "current_session"
        case weekly
    }
}

private struct ClaudeUsageLimit: Decodable {
    let usedPercent: Double
    let resetsAt: Double

    enum CodingKeys: String, CodingKey {
        case usedPercent = "used_percent"
        case resetsAt = "resets_at"
    }
}

private final class CodexAppServerUsageReader {
    private let decoder = JSONDecoder()
    private let fileManager = FileManager.default

    func latestSnapshot() throws -> CodexUsageSnapshot {
        let cliURL = try codexCLIURL()
        let process = Process()
        let input = Pipe()
        let output = Pipe()

        process.executableURL = cliURL
        process.arguments = ["app-server"]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = output

        let semaphore = DispatchSemaphore(value: 0)
        let collector = AppServerResponseCollector(sourcePath: cliURL.path)

        output.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else {
                semaphore.signal()
                return
            }

            if collector.append(chunk) {
                semaphore.signal()
            }
        }

        try process.run()
        defer {
            output.fileHandleForReading.readabilityHandler = nil
            try? inputHandleClose(input.fileHandleForWriting)
            if process.isRunning {
                process.terminate()
            }
        }

        let inputHandle = input.fileHandleForWriting
        try writeJSONLine(
            ["id": 1, "method": "initialize", "params": [
                "clientInfo": ["name": "usagemonitor", "version": "0.1.0"],
                "capabilities": ["experimentalApi": true]
            ]],
            to: inputHandle
        )
        try writeJSONLine(["method": "initialized", "params": [:]], to: inputHandle)
        try writeJSONLine(["id": 2, "method": "account/rateLimits/read", "params": NSNull()], to: inputHandle)

        _ = semaphore.wait(timeout: .now() + 8)

        if let result = collector.snapshot {
            return result
        }

        throw CodexUsageError.appServerNoRateLimits
    }

    private func inputHandleClose(_ handle: FileHandle) throws {
        if #available(macOS 10.15.4, *) {
            try handle.close()
        } else {
            handle.closeFile()
        }
    }

    private func codexCLIURL() throws -> URL {
        let configURL = codexHomeURL().appendingPathComponent("config.toml")
        if let contents = try? String(contentsOf: configURL, encoding: .utf8),
           let path = parseCodexCLIPath(from: contents),
           fileManager.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }

        let appPath = "/Applications/Codex.app/Contents/Resources/codex"
        if fileManager.isExecutableFile(atPath: appPath) {
            return URL(fileURLWithPath: appPath)
        }

        throw CodexUsageError.codexCLINotFound
    }

    private func parseCodexCLIPath(from config: String) -> String? {
        for line in config.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("CODEX_CLI_PATH") else { continue }
            guard let equalsIndex = trimmed.firstIndex(of: "=") else { continue }

            let value = trimmed[trimmed.index(after: equalsIndex)...]
                .trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))

            return value.isEmpty ? nil : value
        }

        return nil
    }

    private func writeJSONLine(_ object: [String: Any], to handle: FileHandle) throws {
        let data = try JSONSerialization.data(withJSONObject: object)
        handle.write(data)
        handle.write(Data("\n".utf8))
    }

    fileprivate static func decodeAppServerSnapshot(from data: Data, sourcePath: String) -> CodexUsageSnapshot? {
        let decoder = JSONDecoder()
        guard let output = String(data: data, encoding: .utf8) else { return nil }

        for line in output.split(separator: "\n", omittingEmptySubsequences: true) {
            guard line.contains("\"id\":2"), line.contains("\"result\"") else { continue }
            guard let response = try? decoder.decode(AppServerRateLimitsResponse.self, from: Data(line.utf8)) else { continue }
            let limits = response.result.rateLimitsByLimitId?["codex"] ?? response.result.rateLimits

            return CodexUsageSnapshot(
                updatedAt: Date(),
                sourcePath: sourcePath,
                planType: limits.planType,
                primary: limits.primary,
                secondary: limits.secondary,
                credits: limits.credits
            )
        }

        return nil
    }

    private func codexHomeURL() -> URL {
        if let envHome = ProcessInfo.processInfo.environment["CODEX_HOME"], !envHome.isEmpty {
            return URL(fileURLWithPath: envHome)
        }

        return fileManager.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
    }
}

private final class AppServerResponseCollector: @unchecked Sendable {
    private let lock = NSLock()
    private let sourcePath: String
    private var buffer = Data()
    private var storedSnapshot: CodexUsageSnapshot?

    init(sourcePath: String) {
        self.sourcePath = sourcePath
    }

    var snapshot: CodexUsageSnapshot? {
        lock.lock()
        defer { lock.unlock() }
        return storedSnapshot
    }

    func append(_ data: Data) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        buffer.append(data)
        if storedSnapshot == nil {
            storedSnapshot = CodexAppServerUsageReader.decodeAppServerSnapshot(from: buffer, sourcePath: sourcePath)
        }

        return storedSnapshot != nil
    }
}

private struct AppServerRateLimitsResponse: Decodable {
    let id: Int
    let result: AppServerRateLimitsResult
}

private struct AppServerRateLimitsResult: Decodable {
    let rateLimits: CodexRateLimits
    let rateLimitsByLimitId: [String: CodexRateLimits]?
}

private final class RolloutUsageReader {
    private let decoder = JSONDecoder()
    private let fileManager = FileManager.default

    func latestSnapshot() throws -> CodexUsageSnapshot {
        let codexHome = codexHomeURL()
        let roots = [
            codexHome.appendingPathComponent("sessions"),
            codexHome.appendingPathComponent("archived_sessions")
        ]

        let files = roots.flatMap { jsonlFiles(in: $0) }
        var latest: CodexUsageSnapshot?

        for file in files {
            guard let contents = try? String(contentsOf: file, encoding: .utf8) else { continue }

            for line in contents.split(separator: "\n", omittingEmptySubsequences: true).reversed() {
                guard line.contains("\"rate_limits\"") else { continue }
                guard let snapshot = decodeSnapshot(from: line, sourcePath: file.path) else { continue }

                if latest == nil || snapshot.updatedAt > latest!.updatedAt {
                    latest = snapshot
                }

                break
            }
        }

        if let latest {
            return latest
        }

        throw CodexUsageError.noRateLimitsFound
    }

    private func codexHomeURL() -> URL {
        if let envHome = ProcessInfo.processInfo.environment["CODEX_HOME"], !envHome.isEmpty {
            return URL(fileURLWithPath: envHome)
        }

        return fileManager.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
    }

    private func jsonlFiles(in root: URL) -> [URL] {
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        return enumerator.compactMap { item in
            guard let url = item as? URL, url.pathExtension == "jsonl" else { return nil }
            return url
        }
    }

    private func decodeSnapshot(from line: Substring, sourcePath: String) -> CodexUsageSnapshot? {
        let data = Data(line.utf8)
        guard let rollout = try? decoder.decode(RolloutLine.self, from: data) else { return nil }
        guard rollout.payload?.type == "token_count" else { return nil }
        guard let rateLimits = rollout.payload?.rateLimits else { return nil }

        let updatedAt = parseDate(rollout.timestamp) ?? Date.distantPast
        return CodexUsageSnapshot(
            updatedAt: updatedAt,
            sourcePath: sourcePath,
            planType: rateLimits.planType,
            primary: rateLimits.primary,
            secondary: rateLimits.secondary,
            credits: rateLimits.credits
        )
    }

    private func parseDate(_ value: String?) -> Date? {
        guard let value else { return nil }

        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) {
            return date
        }

        let standard = ISO8601DateFormatter()
        standard.formatOptions = [.withInternetDateTime]
        return standard.date(from: value)
    }
}

private enum CodexUsageError: LocalizedError {
    case appServerNoRateLimits
    case codexCLINotFound
    case noRateLimitsFound

    var errorDescription: String? {
        switch self {
        case .appServerNoRateLimits:
            return "Codex app-server 没有返回账户限额，已尝试回退本地记录。"
        case .codexCLINotFound:
            return "没有找到 Codex.app 自带的 codex CLI。"
        case .noRateLimitsFound:
            return "没有在 ~/.codex/sessions 找到 Codex rate_limits 记录。先运行一次 Codex，或打开 Codex 用量页刷新。"
        }
    }
}

private enum ClaudeUsageError: LocalizedError {
    case noCache
    case invalidCache
    case noToken
    case tokenExpired
    case requestTimedOut
    case httpStatus(Int)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .noCache:
            return "没有找到 ~/.claude/usagebar-rate-limits.json，且 OAuth 用量端点不可用。"
        case .invalidCache:
            return "Claude usage 缓存格式不正确。请让 Claude Code 再结束一次对话回合刷新缓存。"
        case .noToken:
            return "没能从钥匙串读取 Claude Code OAuth token。请先在 Claude Code 登录。"
        case .tokenExpired:
            return "Claude Code OAuth token 已过期，请重新登录后再刷新。"
        case .requestTimedOut:
            return "查询 Claude 用量端点超时。"
        case .httpStatus(let code):
            return "Claude 用量端点返回 HTTP \(code)。"
        case .invalidResponse:
            return "Claude 用量端点返回了无法解析的内容。"
        }
    }
}

private extension KeyedDecodingContainer {
    func decodeFlexibleDouble(forKeys keys: [Key]) throws -> Double {
        for key in keys where contains(key) {
            if let value = try? decodeFlexibleDouble(forKey: key) {
                return value
            }
        }

        throw DecodingError.dataCorrupted(
            DecodingError.Context(codingPath: codingPath, debugDescription: "Expected numeric value for one of \(keys)")
        )
    }

    func decodeFlexibleDouble(forKey key: Key) throws -> Double {
        if let value = try? decode(Double.self, forKey: key) {
            return value
        }

        if let value = try? decode(Int.self, forKey: key) {
            return Double(value)
        }

        if let value = try? decode(String.self, forKey: key), let double = Double(value) {
            return double
        }

        throw DecodingError.dataCorruptedError(forKey: key, in: self, debugDescription: "Expected numeric value")
    }

    func decodeFlexibleOptionalDouble(forKeys keys: [Key]) throws -> Double? {
        for key in keys where contains(key) {
            return try decodeFlexibleOptionalDouble(forKey: key)
        }

        return nil
    }

    func decodeFlexibleOptionalDouble(forKey key: Key) throws -> Double? {
        guard contains(key) else { return nil }
        if try decodeNil(forKey: key) {
            return nil
        }

        return try decodeFlexibleDouble(forKey: key)
    }

    func decodeFlexibleOptionalBool(forKeys keys: [Key]) throws -> Bool? {
        for key in keys where contains(key) {
            return try decodeFlexibleOptionalBool(forKey: key)
        }

        return nil
    }

    func decodeFlexibleOptionalBool(forKey key: Key) throws -> Bool? {
        guard contains(key) else { return nil }
        if try decodeNil(forKey: key) {
            return nil
        }

        if let value = try? decode(Bool.self, forKey: key) {
            return value
        }

        if let value = try? decode(String.self, forKey: key) {
            return ["true", "1", "yes"].contains(value.lowercased())
        }

        return nil
    }

    func decodeFlexibleOptionalString(forKeys keys: [Key]) throws -> String? {
        for key in keys where contains(key) {
            if try decodeNil(forKey: key) {
                return nil
            }

            if let value = try? decode(String.self, forKey: key) {
                return value
            }
        }

        return nil
    }
}

struct UsagePanel: View {
    @ObservedObject var store: UsageStore

    private var provider: UsageProvider {
        store.selectedProvider
    }

    private var state: UsageState {
        store.state(for: provider)
    }

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.10, green: 0.11, blue: 0.16),
                    Color(red: 0.07, green: 0.08, blue: 0.11)
                ],
                startPoint: .top,
                endPoint: .bottom
            )

            content
                .padding(22)
        }
        .frame(width: 430)
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private var content: some View {
        VStack(alignment: .leading, spacing: 20) {
            ProviderTabs(
                selectedProvider: $store.selectedProvider,
                codexState: store.codexState,
                claudeState: store.claudeState
            )

            selectedContent
        }
    }

    @ViewBuilder
    private var selectedContent: some View {
        switch state {
        case .loading:
            ProgressView()
                .progressViewStyle(.circular)
                .frame(height: 180)

        case .unavailable(let message):
            VStack(alignment: .leading, spacing: 18) {
                HeaderView(
                    provider: provider,
                    title: provider.title,
                    subtitle: "未找到本地用量记录",
                    plan: nil
                )

                Text(message)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white.opacity(0.68))
                    .fixedSize(horizontal: false, vertical: true)

                ActionRow(
                    onRefresh: store.refresh,
                    onOpenUsage: { store.openUsagePage(for: provider) },
                    provider: provider
                )
            }

        case .loaded(let snapshot):
            VStack(alignment: .leading, spacing: 20) {
                HeaderView(
                    provider: snapshot.provider,
                    title: snapshot.provider.title,
                    subtitle: "更新于 \(RelativeTimeFormatter.text(since: snapshot.updatedAt))",
                    plan: snapshot.planType?.capitalized
                )

                if let primary = snapshot.primary {
                    UsageSection(
                        title: primaryTitle(for: snapshot.provider),
                        usedPercent: primary.usedPercent,
                        window: primary,
                        tint: primaryTint(for: snapshot.provider),
                        fillsRemaining: true
                    )
                }

                if let secondary = snapshot.secondary {
                    DashedDivider()

                    UsageSection(
                        title: secondaryTitle(for: snapshot.provider),
                        usedPercent: secondary.usedPercent,
                        window: secondary,
                        tint: Color(red: 0.80, green: 0.92, blue: 0.17),
                        fillsRemaining: true
                    )
                }

                if snapshot.provider == .codex {
                    CreditsRow(credits: snapshot.credits)
                }

                Divider()
                    .overlay(.white.opacity(0.12))

                ActionRow(
                    onRefresh: store.refresh,
                    onOpenUsage: { store.openUsagePage(for: snapshot.provider) },
                    provider: snapshot.provider
                )
            }
        }
    }

    private func primaryTitle(for provider: UsageProvider) -> String {
        switch provider {
        case .codex:
            return "5 小时用量"
        case .claude:
            return "当前会话"
        }
    }

    private func secondaryTitle(for provider: UsageProvider) -> String {
        switch provider {
        case .codex:
            return "每周用量"
        case .claude:
            return "当前周（全部模型）"
        }
    }

    private func primaryTint(for provider: UsageProvider) -> Color {
        switch provider {
        case .codex:
            return Color(red: 0.63, green: 0.92, blue: 0.20)
        case .claude:
            return Color(red: 0.95, green: 0.55, blue: 0.38)
        }
    }
}

private struct ProviderTabs: View {
    @Binding var selectedProvider: UsageProvider
    let codexState: UsageState
    let claudeState: UsageState

    var body: some View {
        HStack(spacing: 8) {
            ForEach(UsageProvider.allCases) { provider in
                Button {
                    selectedProvider = provider
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: provider.systemImage)
                            .font(.system(size: 13, weight: .semibold))

                        Text(provider.title)
                            .font(.system(size: 13, weight: .semibold))

                        if let text = percentText(for: provider) {
                            Text(text)
                                .font(.system(size: 12, weight: .bold))
                                .monospacedDigit()
                                .foregroundStyle(.white.opacity(0.72))
                        }
                    }
                    .foregroundStyle(selectedProvider == provider ? .white : .white.opacity(0.48))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(
                        selectedProvider == provider ? .white.opacity(0.13) : .white.opacity(0.04),
                        in: RoundedRectangle(cornerRadius: 8)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            Spacer(minLength: 0)
        }
        .padding(5)
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
    }

    private func percentText(for provider: UsageProvider) -> String? {
        let state = provider == .codex ? codexState : claudeState
        guard case .loaded(let snapshot) = state else { return nil }
        return PercentFormatter.text(snapshot.primaryRemaining)
    }
}

private struct HeaderView: View {
    let provider: UsageProvider
    let title: String
    let subtitle: String
    let plan: String?

    var body: some View {
        VStack(spacing: 14) {
            HStack(alignment: .top) {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: provider.systemImage)
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(provider.tint)
                        .frame(width: 26, height: 32)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(title)
                            .font(.system(size: 26, weight: .bold))
                            .foregroundStyle(.white)

                        Text(subtitle)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.48))
                    }
                }

                Spacer()

                if let plan {
                    Text(plan)
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(.white)
                }
            }
        }
    }
}

private struct UsageSection: View {
    let title: String
    let usedPercent: Double
    let window: RateLimitWindow
    let tint: Color
    let fillsRemaining: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(.white)

                Spacer()

                Text(ResetFormatter.shortText(for: window.resetDate))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.48))
            }

            HStack(alignment: .firstTextBaseline) {
                Text("剩余 \(PercentFormatter.text(100 - usedPercent))")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.78))

                Spacer()

                Text("已用 \(PercentFormatter.text(usedPercent))")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.62))
            }

            UsageMeter(value: fillsRemaining ? 100 - usedPercent : usedPercent, tint: tint)

            if let resetDate = window.resetDate {
                Text("重置于 \(DateFormatter.shortReset.string(from: resetDate))")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.36))
            }
        }
    }
}

private struct UsageMeter: View {
    let value: Double
    let tint: Color

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 5)
                    .fill(.white.opacity(0.10))

                RoundedRectangle(cornerRadius: 5)
                    .fill(tint)
                    .frame(width: proxy.size.width * max(0, min(value, 100)) / 100)

                HStack(spacing: 0) {
                    ForEach(1..<4) { index in
                        Spacer()
                        Rectangle()
                            .fill(.white.opacity(0.24))
                            .frame(width: 2)
                        if index == 3 {
                            Spacer()
                        }
                    }
                }
            }
        }
        .frame(height: 14)
    }
}

private struct CreditsRow: View {
    let credits: CreditsSnapshot?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("额外用量")
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(.white)

            HStack {
                Text(creditText)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.58))

                Spacer()
            }

            UsageMeter(value: creditPercent, tint: creditTint)
                .opacity(credits == nil ? 0.45 : 1)
        }
    }

    private var creditText: String {
        guard let credits else {
            return "当前记录未返回 credits"
        }

        if credits.unlimited == true {
            return "Unlimited"
        }

        if let balance = credits.balance {
            return "余额 \(balance.formatted(.number.precision(.fractionLength(0...2))))"
        }

        return credits.hasCredits == true ? "可用" : "不可用"
    }

    private var creditPercent: Double {
        guard let credits else { return 0 }
        if credits.unlimited == true { return 100 }
        return credits.hasCredits == true ? 35 : 100
    }

    private var creditTint: Color {
        guard let credits else { return .white.opacity(0.18) }
        return credits.hasCredits == true || credits.unlimited == true
            ? Color(red: 0.63, green: 0.92, blue: 0.20)
            : Color(red: 0.95, green: 0.16, blue: 0.18)
    }
}

private struct ActionRow: View {
    let onRefresh: () -> Void
    let onOpenUsage: () -> Void
    let provider: UsageProvider

    var body: some View {
        VStack(spacing: 4) {
            ActionButton(icon: "arrow.clockwise", title: "刷新", action: onRefresh)
            ActionButton(icon: "chart.bar.xaxis", title: "\(provider.title) 用量页", action: onOpenUsage)
            ActionButton(icon: "power", title: "退出", action: { NSApp.terminate(nil) })
        }
    }
}

private struct ActionButton: View {
    let icon: String
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .medium))
                    .frame(width: 22)

                Text(title)
                    .font(.system(size: 15, weight: .semibold))

                Spacer()
            }
            .foregroundStyle(.white.opacity(0.72))
            .frame(height: 36)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct DashedDivider: View {
    var body: some View {
        Rectangle()
            .fill(.clear)
            .frame(height: 1)
            .overlay(
                DashedLine()
                    .stroke(style: StrokeStyle(lineWidth: 1, dash: [6, 6]))
                    .foregroundStyle(.white.opacity(0.18))
            )
    }
}

private struct DashedLine: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        return path
    }
}

private enum PercentFormatter {
    static func text(_ value: Double) -> String {
        "\(Int(max(0, min(value, 100)).rounded()))%"
    }
}

private enum ResetFormatter {
    static func shortText(for date: Date?) -> String {
        guard let date else { return "未知重置时间" }

        let seconds = Int(date.timeIntervalSinceNow)
        guard seconds > 0 else { return "已到重置时间" }

        let minutes = max(1, seconds / 60)
        let hours = minutes / 60
        let days = hours / 24

        if days > 0 {
            return "\(days)天\(hours % 24)小时后重置"
        }

        if hours > 0 {
            return "\(hours):\(String(format: "%02d", minutes % 60)) 后重置"
        }

        return "\(minutes)分钟后重置"
    }
}

private enum RelativeTimeFormatter {
    static func text(since date: Date) -> String {
        let seconds = Int(Date().timeIntervalSince(date))

        if seconds < 60 {
            return "刚刚"
        }

        let minutes = seconds / 60
        if minutes < 60 {
            return "\(minutes)分钟前"
        }

        let hours = minutes / 60
        if hours < 24 {
            return "\(hours)小时前"
        }

        return DateFormatter.shortReset.string(from: date)
    }
}

private extension DateFormatter {
    static let shortReset: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "M月d日 HH:mm"
        return formatter
    }()
}
