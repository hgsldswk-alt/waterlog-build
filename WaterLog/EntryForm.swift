import SwiftUI

struct EntryForm: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @FocusState private var amountFocused: Bool
    let entry: DrinkEntry?
    let unit: VolumeUnit
    private let draftID = UUID()
    private let originalText: String

    @State private var amount: String
    @State private var drink: Drink
    @State private var date: Date?
    @State private var showTime = false
    @State private var busy = false
    @State private var confirmDelete = false
    @State private var validation: String?

    init(entry: DrinkEntry?, unit: VolumeUnit) {
        self.entry = entry
        self.unit = unit
        let initialAmount = entry.map { unit.number($0.volume, grouping: false) } ?? ""
        originalText = initialAmount
        _amount = State(initialValue: initialAmount)
        _drink = State(initialValue: entry?.drink ?? .water)
        _date = State(initialValue: entry?.consumedAt)
    }

    private var zone: TimeZone { entry?.zone ?? model.zone }
    private var when: Date { date ?? model.now }

    var body: some View {
        Form {
            Section {
                HStack {
                    TextField(L.t("饮用量"), text: $amount)
                        .keyboardType(.decimalPad)
                        .focused($amountFocused)
                        .font(.title.monospacedDigit())
                        .accessibilityIdentifier("entry.amount")
                    Text(unit.symbol).foregroundStyle(Palette.muted)
                }
                FieldError(message: validation ?? model.error)
            }

            Section(L.t("饮品")) {
                ForEach(Drink.allCases) { option in
                    Button { drink = option } label: {
                        HStack {
                            Text(option.title)
                            Spacer()
                            if drink == option { Image(systemName: "checkmark").foregroundStyle(Palette.blue) }
                        }
                        .foregroundStyle(Palette.ink)
                        .frame(minHeight: 44).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(drink == option ? .isSelected : [])
                    .accessibilityIdentifier("entry.drink.\(option.rawValue)")
                }
            }

            Section {
                Button {
                    amountFocused = false
                    showTime.toggle()
                } label: {
                    HStack {
                        Text(L.t("时间")).foregroundStyle(Palette.ink)
                        Spacer(minLength: 6)
                        Text(date == nil ? L.t("现在") : ContextDate.label(when, zone: zone, format: "MMMdjm"))
                            .foregroundStyle(Palette.muted)
                        Image(systemName: showTime ? "chevron.up" : "chevron.down").font(.caption)
                    }
                    .frame(minHeight: 44).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("entry.time")
                if showTime {
                    DatePicker(L.t("饮用时间"), selection: Binding(get: { when }, set: { date = $0 }),
                               in: ...max(model.now, entry?.consumedAt ?? model.now), displayedComponents: [.date, .hourAndMinute])
                        .environment(\.timeZone, zone)
                        .accessibilityIdentifier("entry.date")
                    Button(L.t("昨天")) {
                        date = Days.calendar(in: zone).date(byAdding: .day, value: -1, to: model.now)
                    }
                    .accessibilityIdentifier("entry.yesterday")
                    if entry == nil {
                        Button(L.t("现在")) { date = nil }
                            .accessibilityIdentifier("entry.now")
                    }
                }
            }

            if entry != nil {
                Button(L.t("删除记录"), role: .destructive) { confirmDelete = true }
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("entry.delete")
            }
        }
        .scrollDismissesKeyboard(.interactively)
        .navigationTitle(entry == nil ? L.t("自填") : L.t("编辑记录"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(L.t("取消")) { dismiss() }.accessibilityIdentifier("entry.cancel")
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(entry == nil ? L.t("记入") : L.t("保存"), action: save)
                    .disabled(busy).accessibilityIdentifier("entry.save")
            }
        }
        .confirmationDialog(L.t("删除这笔记录？"), isPresented: $confirmDelete, titleVisibility: .visible) {
            Button(L.t("删除记录"), role: .destructive) {
                guard let entry else { return }
                busy = true
                Task {
                    let deleted = await model.delete(entry.id)
                    busy = false
                    if deleted { dismiss() }
                }
            }
            Button(L.t("取消"), role: .cancel) {}
        }
        .task {
            guard entry == nil else { return }
            try? await Task.sleep(for: .milliseconds(160))
            if !Task.isCancelled { amountFocused = true }
        }
        .onChange(of: amount) { _, _ in validation = nil }
        .onDisappear { model.error = nil }
    }

    private func save() {
        let unchanged = amount.trimmingCharacters(in: .whitespacesAndNewlines) == originalText
        guard let volume = (unchanged ? entry?.volume : nil) ?? unit.parse(amount) else {
            validation = L.t("请输入相当于 1–5,000 mL 的饮用量。")
            return
        }
        busy = true
        validation = nil
        model.error = nil
        Task {
            let saved = await model.save(entry, draftID: draftID, amount: volume, drink: drink, date: date)
            busy = false
            if saved { dismiss() }
        }
    }
}
