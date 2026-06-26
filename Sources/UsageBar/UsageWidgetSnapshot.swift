import Foundation

struct UsageWidgetSnapshot: Codable, Equatable {
    var updatedAt: Date
    var rows: [UsageWidgetRow]

    static func defaults(updatedAt: Date = Date()) -> UsageWidgetSnapshot {
        UsageWidgetSnapshot(updatedAt: updatedAt, rows: defaultRows)
    }

    static var defaultRows: [UsageWidgetRow] {
        [
            UsageWidgetRow(
                id: "codex",
                title: "Codex",
                systemImage: "atom",
                tintName: "mint",
                percent: 0,
                detail: "等待刷新",
                fillsRemaining: true,
                isUnavailable: true
            ),
            UsageWidgetRow(
                id: "claude",
                title: "Claude",
                systemImage: "sparkle",
                tintName: "coral",
                percent: 0,
                detail: "等待刷新",
                fillsRemaining: true,
                isUnavailable: true
            )
        ]
    }
}

struct UsageWidgetRow: Codable, Identifiable, Equatable {
    var id: String
    var title: String
    var systemImage: String
    var tintName: String
    var percent: Double
    var detail: String
    var fillsRemaining: Bool
    var isCritical: Bool
    var isUnavailable: Bool

    init(
        id: String,
        title: String,
        systemImage: String,
        tintName: String,
        percent: Double,
        detail: String,
        fillsRemaining: Bool = false,
        isCritical: Bool = false,
        isUnavailable: Bool = false
    ) {
        self.id = id
        self.title = title
        self.systemImage = systemImage
        self.tintName = tintName
        self.percent = max(0, min(percent, 100))
        self.detail = detail
        self.fillsRemaining = fillsRemaining
        self.isCritical = isCritical
        self.isUnavailable = isUnavailable
    }

    enum CodingKeys: String, CodingKey {
        case id
        case title
        case systemImage
        case tintName
        case percent
        case detail
        case fillsRemaining
        case isCritical
        case isUnavailable
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        systemImage = try container.decode(String.self, forKey: .systemImage)
        tintName = try container.decode(String.self, forKey: .tintName)
        percent = max(0, min(try container.decode(Double.self, forKey: .percent), 100))
        detail = try container.decode(String.self, forKey: .detail)
        fillsRemaining = try container.decodeIfPresent(Bool.self, forKey: .fillsRemaining) ?? false
        isCritical = try container.decodeIfPresent(Bool.self, forKey: .isCritical) ?? false
        isUnavailable = try container.decodeIfPresent(Bool.self, forKey: .isUnavailable) ?? false
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(title, forKey: .title)
        try container.encode(systemImage, forKey: .systemImage)
        try container.encode(tintName, forKey: .tintName)
        try container.encode(percent, forKey: .percent)
        try container.encode(detail, forKey: .detail)
        try container.encode(fillsRemaining, forKey: .fillsRemaining)
        try container.encode(isCritical, forKey: .isCritical)
        try container.encode(isUnavailable, forKey: .isUnavailable)
    }
}

enum UsageWidgetStore {
    static let appGroupIdentifier = "group.local.usagebar.codex"

    private static let fileName = "usagebar-widget.json"
    private static let applicationSupportDirectoryName = "UsageMonitor"
    private static let legacyApplicationSupportDirectoryName = "UsageBar"

    static func load() -> UsageWidgetSnapshot {
        let decoder = JSONDecoder()
        var latest: UsageWidgetSnapshot?

        for url in snapshotURLs() {
            guard let data = try? Data(contentsOf: url),
                  let snapshot = try? decoder.decode(UsageWidgetSnapshot.self, from: data) else {
                continue
            }

            if latest == nil || snapshot.updatedAt > latest!.updatedAt {
                latest = snapshot
            }
        }

        return latest ?? .defaults()
    }

    static func save(_ snapshot: UsageWidgetSnapshot) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(snapshot)
        let fileManager = FileManager.default
        var lastError: Error?
        var didWrite = false

        for url in snapshotURLs() {
            do {
                try fileManager.createDirectory(
                    at: url.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try data.write(to: url, options: .atomic)
                didWrite = true
            } catch {
                lastError = error
            }
        }

        if didWrite {
            return
        }

        if let lastError {
            throw lastError
        }
    }

    private static func snapshotURLs() -> [URL] {
        var urls: [URL] = []
        let fileManager = FileManager.default
        func appendUnique(_ url: URL) {
            guard !urls.contains(url) else { return }
            urls.append(url)
        }

        let applicationSupportURL = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library")
            .appendingPathComponent("Application Support")
            .appendingPathComponent(applicationSupportDirectoryName)
            .appendingPathComponent(fileName)
        let legacyApplicationSupportURL = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library")
            .appendingPathComponent("Application Support")
            .appendingPathComponent(legacyApplicationSupportDirectoryName)
            .appendingPathComponent(fileName)

        if let containerURL = fileManager.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupIdentifier
        ) {
            appendUnique(containerURL.appendingPathComponent(fileName))
        }

        appendUnique(
            fileManager.homeDirectoryForCurrentUser
                .appendingPathComponent("Library")
                .appendingPathComponent("Group Containers")
                .appendingPathComponent(appGroupIdentifier)
                .appendingPathComponent(fileName)
        )

        appendUnique(applicationSupportURL)
        appendUnique(legacyApplicationSupportURL)

        appendUnique(
            fileManager.homeDirectoryForCurrentUser
                .appendingPathComponent("Library")
                .appendingPathComponent("Containers")
                .appendingPathComponent("local.usagebar.codex.widget")
                .appendingPathComponent("Data")
                .appendingPathComponent("Library")
                .appendingPathComponent("Application Support")
                .appendingPathComponent(applicationSupportDirectoryName)
                .appendingPathComponent(fileName)
        )

        appendUnique(
            fileManager.homeDirectoryForCurrentUser
                .appendingPathComponent("Library")
                .appendingPathComponent("Containers")
                .appendingPathComponent("local.usagebar.codex.widget")
                .appendingPathComponent("Data")
                .appendingPathComponent("Library")
                .appendingPathComponent("Application Support")
                .appendingPathComponent(legacyApplicationSupportDirectoryName)
                .appendingPathComponent(fileName)
        )

        return urls
    }
}

enum UsageWidgetResetText {
    static func text(for date: Date?) -> String {
        guard let date else { return "--" }

        let seconds = Int(date.timeIntervalSinceNow)
        guard seconds > 0 else { return "已重置" }

        let minutes = max(1, seconds / 60)
        let hours = minutes / 60
        let days = hours / 24

        if days > 0 {
            return "\(days)天后"
        }

        if hours > 0 {
            return "\(hours):\(String(format: "%02d", minutes % 60))"
        }

        return "\(minutes)分钟"
    }
}
