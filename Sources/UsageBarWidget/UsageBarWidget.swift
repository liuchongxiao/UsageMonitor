import SwiftUI
import WidgetKit

struct UsageBarWidgetEntry: TimelineEntry {
    let date: Date
    let snapshot: UsageWidgetSnapshot
}

struct UsageBarWidgetProvider: TimelineProvider {
    func placeholder(in context: Context) -> UsageBarWidgetEntry {
        UsageBarWidgetEntry(date: Date(), snapshot: .defaults())
    }

    func getSnapshot(in context: Context, completion: @escaping (UsageBarWidgetEntry) -> Void) {
        completion(UsageBarWidgetEntry(date: Date(), snapshot: UsageWidgetStore.load()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<UsageBarWidgetEntry>) -> Void) {
        let entry = UsageBarWidgetEntry(date: Date(), snapshot: UsageWidgetStore.load())
        let nextRefresh = Calendar.current.date(byAdding: .minute, value: 5, to: entry.date) ?? entry.date.addingTimeInterval(300)
        completion(Timeline(entries: [entry], policy: .after(nextRefresh)))
    }
}

struct UsageBarWidgetView: View {
    let entry: UsageBarWidgetEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(entry.snapshot.rows.prefix(5)) { row in
                UsageBarWidgetRowView(row: row)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .containerBackground(for: .widget) {
            LinearGradient(
                colors: [
                    Color(red: 0.10, green: 0.10, blue: 0.10),
                    Color(red: 0.04, green: 0.04, blue: 0.04)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
    }
}

private struct UsageBarWidgetRowView: View {
    let row: UsageWidgetRow

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 10) {
                Image(systemName: row.systemImage)
                    .font(.system(size: 13, weight: .bold))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(iconTint)
                    .frame(width: 26)

                Text(row.title)
                    .font(.system(size: 15, weight: .heavy))
                    .foregroundStyle(.white.opacity(row.isUnavailable ? 0.62 : 0.88))
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)

                Spacer(minLength: 0)
            }

            HStack(spacing: 8) {
                Text("剩余 \(Int(row.percent.rounded()))%")
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white.opacity(row.isUnavailable ? 0.48 : 0.58))
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)

                Spacer(minLength: 8)

                Text(row.detail)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(row.isUnavailable ? 0.60 : 0.88))
                    .lineLimit(1)
                    .minimumScaleFactor(0.76)
            }

            UsageBarWidgetMeter(
                value: row.percent,
                tint: meterTint,
                isUnavailable: row.isUnavailable,
                fillsRemaining: row.fillsRemaining
            )
                .frame(height: 6)
        }
        .frame(minHeight: 32)
    }

    private var iconTint: Color {
        switch row.tintName {
        case "coral":
            return Color(red: 0.95, green: 0.50, blue: 0.43)
        case "purple":
            return Color(red: 0.54, green: 0.30, blue: 0.96)
        case "mint":
            return Color(red: 0.15, green: 0.74, blue: 0.47)
        case "green":
            return Color(red: 0.24, green: 0.74, blue: 0.56)
        case "violet":
            return Color(red: 0.58, green: 0.25, blue: 0.95)
        default:
            return .white.opacity(0.70)
        }
    }

    private var meterTint: Color {
        if row.isCritical {
            return Color(red: 0.90, green: 0.12, blue: 0.16)
        }

        return Color(red: 0.56, green: 0.82, blue: 0.22)
    }
}

private struct UsageBarWidgetMeter: View {
    let value: Double
    let tint: Color
    let isUnavailable: Bool
    let fillsRemaining: Bool

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 5)
                    .fill(.white.opacity(0.08))

                RoundedRectangle(cornerRadius: 5)
                    .fill(isUnavailable ? .white.opacity(0.16) : tint)
                    .frame(width: proxy.size.width * max(0, min(fillsRemaining ? value : 100 - value, 100)) / 100)

                HStack(spacing: 0) {
                    ForEach(1..<4) { index in
                        Spacer()
                        Rectangle()
                            .fill(.white.opacity(0.24))
                            .frame(width: 2)
                        if index == 3 {
                            Spacer(minLength: 0)
                        }
                    }
                }
                .padding(.horizontal, 6)
            }
        }
    }
}

struct UsageBarWidget: Widget {
    let kind = "UsageBarWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: UsageBarWidgetProvider()) { entry in
            UsageBarWidgetView(entry: entry)
        }
        .configurationDisplayName("UsageMonitor")
        .description("查看 Claude、Codex 和常用服务的用量。")
        .supportedFamilies([.systemMedium, .systemLarge])
    }
}

@main
struct UsageBarWidgetBundle: WidgetBundle {
    var body: some Widget {
        UsageBarWidget()
    }
}
