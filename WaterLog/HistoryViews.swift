import SwiftUI

struct HistoryView: View {
    @EnvironmentObject private var model: AppModel
    @State private var sharing = SharePresentation()
    @State private var exporting = false
    var openDay: (String) -> Void
    var report: () -> Void

    var body: some View {
        List {
            if model.snapshot?.days.isEmpty != false {
                Text(L.t("还没有饮水记录")).foregroundStyle(Palette.muted)
            }
            Section {
                ForEach(model.snapshot?.days ?? []) { day in
                    Button { openDay(day.id) } label: {
                        HStack {
                            Text(ContextDate.day(day.id, zone: model.zone)).foregroundStyle(Palette.ink)
                            Spacer(minLength: 6)
                            Text(model.preferences.unit.label(day.total)).font(.subheadline.weight(.semibold)).foregroundStyle(Palette.darkBlue)
                            Image(systemName: "chevron.right").font(.caption2).foregroundStyle(Palette.muted)
                        }
                        .frame(minHeight: 44).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("history.day.\(day.id)")
                }
            }
        }
        .navigationTitle(L.t("历史"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button(action: report) {
                    Label(L.t("近 7 天周报"), systemImage: model.hasPro ? "chart.bar" : "lock")
                }.accessibilityIdentifier("history.report")
                Menu {
                    Button(action: exportCSV) {
                        Label(L.t("导出 CSV"), systemImage: "square.and.arrow.up")
                    }
                    .disabled(exporting)
                    .accessibilityIdentifier("history.exportCSV")
                } label: {
                    Label(L.t("更多"), systemImage: "ellipsis.circle")
                }
                .accessibilityIdentifier("history.menu")
            }
        }
        .sharePresentation($sharing)
    }

    private func exportCSV() {
        guard !exporting, let days = model.snapshot?.days else { return }
        exporting = true
        Task {
            defer { exporting = false }
            do {
                let file = try await Task.detached {
                    try ExportFiles.write(CSV.export(days), filename: "waterlog.csv")
                }.value
                try sharing.present(SharedItems(values: [file], temporaryFile: file),
                                    type: "CSV", uiTesting: model.config.uiTesting)
            } catch {
                model.error = L.t("无法导出文件，请重试。")
            }
        }
    }
}

struct HistoryDayView: View {
    @EnvironmentObject private var model: AppModel
    let key: String
    var edit: (DrinkEntry) -> Void

    var body: some View {
        let day = model.snapshot?.day(key)
        let unit = model.preferences.unit
        List {
            Section {
                Text(unit.label(day?.total ?? 0)).font(.largeTitle.weight(.bold)).foregroundStyle(Palette.darkBlue)
                    .accessibilityIdentifier("day.total")
            }
            Section(L.t("饮水明细")) {
                if day?.entries.isEmpty != false { Text(L.t("这天没有记录")).foregroundStyle(Palette.muted) }
                ForEach(Array((day?.entries ?? []).enumerated()), id: \.element.id) { index, entry in
                    EntryRow(entry: entry, unit: unit) { edit(entry) }
                        .accessibilityIdentifier("day.entry.\(index)")
                }
            }
        }
        .navigationTitle(ContextDate.day(key, zone: model.zone))
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct ReportView: View {
    @EnvironmentObject private var model: AppModel
    var paywall: () -> Void

    var body: some View {
        List {
            if model.hasPro {
                let week = model.week
                Text(L.daysLogged(week.filter(\.recorded).count))
                    .font(.title2.weight(.semibold))
                    .accessibilityIdentifier("report.count")
                ForEach(week) { day in
                    LabeledContent(ContextDate.label(day.date, zone: model.zone, format: "MMMdEEE"),
                                   value: model.preferences.unit.label(day.total))
                }
            } else {
                Button(L.t("一次买断"), action: paywall).accessibilityIdentifier("report.unlock")
            }
        }
        .navigationTitle(L.t("近 7 天周报"))
        .navigationBarTitleDisplayMode(.inline)
    }
}
