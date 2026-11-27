import SwiftUI
import WidgetKit

private struct ReadingEntry: TimelineEntry {
    let date: Date
    let reading: WidgetReading?
}

private struct Provider: TimelineProvider {
    func placeholder(in context: Context) -> ReadingEntry {
        let now = Date()
        return ReadingEntry(date: now, reading: WidgetReading(total: 750_000, unit: .ml, groupID: nil,
                                                             amount: nil, refresh: Days.nextMidnight(after: now)))
    }

    func getSnapshot(in context: Context, completion: @escaping (ReadingEntry) -> Void) {
        if context.isPreview {
            completion(placeholder(in: context))
        } else {
            Task { completion(await current()) }
        }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<ReadingEntry>) -> Void) {
        Task {
            let entry = await current()
            completion(Timeline(entries: [entry], policy: .after(entry.reading?.refresh ?? entry.date.addingTimeInterval(900))))
        }
    }

    private func current() async -> ReadingEntry {
        let now = Date()
        let reading = try? await LogStore().widgetReading(at: now, zone: .current)
        return ReadingEntry(date: now, reading: reading)
    }
}

private struct ReadingView: View {
    let entry: ReadingEntry
    private let blue = Color(red: 18/255, green: 82/255, blue: 186/255)
    private let ink = Color(red: 21/255, green: 36/255, blue: 58/255)

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L.t("今日已记录")).font(.caption.weight(.semibold))
            Group {
                if let reading = entry.reading {
                    Text(reading.unit.label(reading.total))
                        .font(.title2.weight(.bold).monospacedDigit())
                } else {
                    Text(L.t("读数暂不可用")).font(.headline)
                }
            }
            .lineLimit(1).minimumScaleFactor(0.6)
            Spacer(minLength: 2)
            if let reading = entry.reading, let group = reading.groupID, let amount = reading.amount {
                Button(intent: LogCupIntent(group: group, amount: amount)) {
                    Label(reading.unit.label(amount), systemImage: "plus")
                        .font(.footnote.weight(.semibold))
                        .lineLimit(1).minimumScaleFactor(0.7)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .background(blue, in: RoundedRectangle(cornerRadius: 9))
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L.f("记一杯，%@", reading.unit.label(amount)))
                .accessibilityIdentifier("widget.log")
            } else {
                Link(L.t("打开 App 记录"), destination: Launch.homeURL)
                    .font(.caption.weight(.semibold))
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("widget.open")
            }
        }
        .foregroundStyle(ink)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .widgetURL(Launch.homeURL)
        .containerBackground(for: .widget) { Color(red: 232/255, green: 240/255, blue: 1) }
    }
}

@main
struct WaterLogWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: Launch.widgetKind, provider: Provider()) { ReadingView(entry: $0) }
            .configurationDisplayName(L.t("饮水记录"))
            .description(L.t("查看今日合计，也可快捷记下常用杯量。"))
            .supportedFamilies([.systemSmall])
    }
}
