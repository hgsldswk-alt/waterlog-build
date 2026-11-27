import SwiftUI
import StoreKit
import UIKit

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.openURL) private var openURL
    @Environment(\.requestReview) private var requestReview
    var goal: () -> Void
    var reminder: () -> Void
    var paywall: () -> Void

    private var reminderOn: Bool { model.preferences.reminder.enabled && model.permission == .allowed }

    var body: some View {
        List {
            Section(L.t("单位")) {
                ForEach(VolumeUnit.allCases) { unit in
                    Button {
                        Task { await model.update({ $0.unit = unit }, widget: true) }
                    } label: {
                        HStack {
                            Text(unit.title)
                            Spacer()
                            if model.preferences.unit == unit { Image(systemName: "checkmark").foregroundStyle(Palette.blue) }
                        }
                        .foregroundStyle(Palette.ink)
                        .frame(minHeight: 44).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(model.preferences.unit == unit ? .isSelected : [])
                    .accessibilityIdentifier("settings.unit.\(unit.rawValue)")
                }
            }

            Section {
                Button(action: goal) {
                    LabeledContent(L.t("每日目标"), value: model.preferences.goal.map(model.preferences.unit.label) ?? L.t("未设置"))
                        .frame(minHeight: 44)
                }.accessibilityIdentifier("settings.goal")
            }

            Section {
                Toggle(L.t("每日提醒"), isOn: Binding(get: { reminderOn }, set: { enabled in
                    var next = model.preferences.reminder
                    next.enabled = enabled
                    Task { await model.configureReminder(next, ask: enabled) }
                }))
                .disabled(model.reminderBusy)
                .accessibilityIdentifier("settings.reminder")
                if reminderOn {
                    Button(action: reminder) {
                        LabeledContent(L.t("提醒时间"), value: ContextDate.label(
                            ReminderTimeView.date(model.preferences.reminder, zone: model.zone), zone: model.zone, format: "jm"))
                            .frame(minHeight: 44)
                    }
                    .accessibilityIdentifier("settings.reminderTime")
                }
                if model.permission == .denied {
                    Text(L.t("提醒尚未开启。可在系统设置中允许通知。"))
                        .font(.footnote).foregroundStyle(Palette.muted)
                        .accessibilityIdentifier("settings.notificationsDenied")
                    Button(L.t("打开系统设置")) {
                        if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                    }
                    .accessibilityIdentifier("settings.system")
                }
            }

            if !model.config.free {
                Section(L.t("高级版")) {
                    Button(action: paywall) {
                        LabeledContent(L.t("一次买断"), value: model.purchaseStatus)
                            .frame(minHeight: 44)
                    }
                    .accessibilityIdentifier("settings.paywall")
                    Button(L.t("恢复购买")) {
                        Task { await model.restorePurchases() }
                    }
                    .disabled(model.purchaseBusy)
                    .accessibilityIdentifier("settings.restore")
                    if let message = model.purchaseMessage {
                        Text(message).font(.footnote).foregroundStyle(Palette.muted)
                    }
                }
            }
            Section {
                Button(L.t("给 App 评分")) {
                    if let url = model.config.storeURL,
                       var components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
                        components.queryItems = [URLQueryItem(name: "action", value: "write-review")]
                        if let reviewURL = components.url {
                            openURL(reviewURL)
                            return
                        }
                    }
                    requestReview()
                }.accessibilityIdentifier("settings.rate")
            }
        }
        .navigationTitle(L.t("设置"))
        .navigationBarTitleDisplayMode(.inline)
    }

}

struct GoalView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focused: Bool
    let unit: VolumeUnit
    private let goal: Int?
    private let originalText: String
    @State private var amount: String
    @State private var validation: String?
    @State private var busy = false

    init(goal: Int?, unit: VolumeUnit) {
        self.goal = goal
        self.unit = unit
        let text = goal.map { unit.number($0, grouping: false) } ?? ""
        originalText = text
        _amount = State(initialValue: text)
    }

    var body: some View {
        Form {
            HStack {
                TextField(L.t("每日目标"), text: $amount)
                    .keyboardType(.decimalPad).focused($focused)
                    .accessibilityIdentifier("goal.amount")
                Text(unit.symbol).foregroundStyle(Palette.muted)
            }
            Text(L.t("留空即可关闭每日目标。")).font(.footnote).foregroundStyle(Palette.muted)
            FieldError(message: validation ?? model.error)
        }
        .navigationTitle(L.t("每日目标"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(L.t("取消")) { dismiss() }.accessibilityIdentifier("goal.cancel")
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(L.t("保存"), action: save).disabled(busy).accessibilityIdentifier("goal.save")
            }
        }
        .task { await Task.yield(); focused = true }
        .onChange(of: amount) { _, _ in validation = nil }
        .onDisappear { model.error = nil }
    }

    private func save() {
        let text = amount.trimmingCharacters(in: .whitespacesAndNewlines)
        let volume = text == originalText ? goal : unit.parse(text, maxML: 20_000)
        guard text.isEmpty || volume != nil else {
            validation = L.t("请输入相当于 1–20,000 mL 的目标。")
            return
        }
        busy = true
        model.error = nil
        Task {
            let saved = await model.update { $0.goal = volume }
            busy = false
            if saved { dismiss() }
        }
    }
}

struct ReminderTimeView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let settings: ReminderSettings
    @State private var choice: Date?

    static func date(_ settings: ReminderSettings, zone: TimeZone) -> Date {
        Days.calendar(in: zone).date(from: DateComponents(
            year: 2026, month: 1, day: 15, hour: settings.hour, minute: settings.minute
        )) ?? Date()
    }

    var body: some View {
        Form {
            DatePicker(L.t("提醒时间"), selection: Binding(
                get: { choice ?? Self.date(settings, zone: model.zone) }, set: { choice = $0 }
            ), displayedComponents: .hourAndMinute)
            .accessibilityIdentifier("reminder.time")
            FieldError(message: model.error)
        }
        .navigationTitle(L.t("提醒时间"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(L.t("取消")) { dismiss() }.accessibilityIdentifier("reminder.cancel")
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(L.t("完成"), action: save).disabled(model.reminderBusy).accessibilityIdentifier("reminder.save")
            }
        }
        .onDisappear { model.error = nil }
    }

    private func save() {
        var next = settings
        if let choice {
            let time = Days.calendar(in: model.zone).dateComponents([.hour, .minute], from: choice)
            next.hour = time.hour ?? settings.hour
            next.minute = time.minute ?? settings.minute
        }
        model.error = nil
        Task { if await model.configureReminder(next) { dismiss() } }
    }
}
