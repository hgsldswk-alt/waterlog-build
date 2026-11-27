import SwiftUI
import UIKit
import UniformTypeIdentifiers

private struct CupDraft {
    let original: [Int]
    let displayed: [String]
    var fields: [String]
    var name: String

    init(_ group: CupPresetSet, unit: VolumeUnit) {
        original = group.amounts
        displayed = group.amounts.map { unit.number($0, grouping: false) }
        fields = displayed
        name = group.name ?? ""
    }

    func values(in unit: VolumeUnit) -> [Int]? {
        let parsed = fields.indices.compactMap { index in
            let field = fields[index].trimmingCharacters(in: .whitespacesAndNewlines)
            return field == displayed[index] ? original[index] : unit.parse(field)
        }
        return CupCode.valid(parsed) ? parsed : nil
    }
}

struct GroupsView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var overlay: Overlay?
    let unit: VolumeUnit

    private enum Overlay: Identifiable {
        case importer, code(CupPresetSet), add
        var id: String {
            switch self {
            case .importer: return "import"
            case .code(let group): return group.id.uuidString
            case .add: return "add"
            }
        }
    }

    var body: some View {
        let active = model.preferences.activeGroup
        GroupEditor(group: active, unit: unit, allowsName: model.hasPro || active.name != nil) { amounts, name in
            if await model.changeGroup(.edit(active.id, name: name, amounts: amounts)) { dismiss() }
        } extras: {
            Section {
                Button(L.t("导入")) { overlay = .importer }.accessibilityIdentifier("cups.import")
                Button(L.t("分享杯量组")) { overlay = .code(active) }.accessibilityIdentifier("cups.share")
            }
            if model.hasPro || model.preferences.groups.count > 1 {
                Section(L.t("杯量组")) {
                    ForEach(model.preferences.groups.filter { $0.id != active.id }) { item in
                        NavigationLink(value: item.id) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(item.title)
                                Text(item.amounts.map(unit.label).joined(separator: " · "))
                                    .font(.caption).foregroundStyle(Palette.muted)
                            }
                            .frame(minHeight: 44)
                        }
                        .accessibilityIdentifier("cups.otherGroup.\(item.id.uuidString)")
                    }
                    if model.hasPro {
                        Button(L.t("新增杯量组")) { overlay = .add }.accessibilityIdentifier("cups.addGroup")
                    }
                }
            }
        }
        .navigationTitle(L.t("编辑杯量"))
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(L.t("关闭")) { dismiss() }.accessibilityIdentifier("cups.close")
            }
        }
        .navigationDestination(for: UUID.self) { id in
            if let item = model.preferences.groups.first(where: { $0.id == id }) {
                StoredGroupView(group: item, unit: unit) { overlay = .code(item) }
            }
        }
        .sheet(item: $overlay) { item in
            NavigationStack {
                switch item {
                case .importer: ImportCupView(unit: unit)
                case .code(let group): CupCodeView(group: group, unit: unit)
                case .add:
                    GroupEditor(group: CupPresetSet(amounts: active.amounts), unit: unit, allowsName: true, requiresName: true) { amounts, name in
                        if let name, await model.changeGroup(.add(name, amounts)) { overlay = nil }
                    } extras: { EmptyView() }
                    .navigationTitle(L.t("新增杯量组"))
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button(L.t("取消")) { overlay = nil }.accessibilityIdentifier("cups.new.cancel")
                        }
                    }
                }
            }
        }
    }
}

private struct GroupEditor<Extras: View>: View {
    @EnvironmentObject private var model: AppModel
    let group: CupPresetSet
    let unit: VolumeUnit
    let allowsName: Bool
    let requiresName: Bool
    var commit: ([Int], String?) async -> Void
    @ViewBuilder var extras: () -> Extras

    @State private var draft: CupDraft
    @State private var busy = false
    @State private var validation: String?

    init(group: CupPresetSet, unit: VolumeUnit, allowsName: Bool, requiresName: Bool = false,
         commit: @escaping ([Int], String?) async -> Void, @ViewBuilder extras: @escaping () -> Extras) {
        self.group = group
        self.unit = unit
        self.allowsName = allowsName
        self.requiresName = requiresName
        self.commit = commit
        self.extras = extras
        _draft = State(initialValue: CupDraft(group, unit: unit))
    }

    var body: some View {
        Form {
            Section {
                ForEach(0..<3) { index in
                    HStack {
                        Text(L.f("杯量 %@", String(index + 1)))
                        Spacer()
                        TextField(unit.symbol, text: $draft.fields[index])
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .accessibilityLabel(L.f("杯量 %@", String(index + 1)))
                            .accessibilityIdentifier("cups.amount.\(index)")
                        Text(unit.symbol).foregroundStyle(Palette.muted)
                    }
                    .frame(minHeight: 44)
                }
                if allowsName {
                    TextField(L.t("杯量组名称"), text: $draft.name).accessibilityIdentifier("cups.name")
                        .frame(minHeight: 44)
                }
                FieldError(message: validation ?? model.error)
            }
            extras()
        }
        .scrollDismissesKeyboard(.interactively)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button(L.t("保存"), action: save).disabled(busy).accessibilityIdentifier("cups.save")
            }
        }
        .onChange(of: group) { _, updated in draft = CupDraft(updated, unit: unit) }
        .onDisappear { model.error = nil }
    }

    private func save() {
        let name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (!requiresName || !name.isEmpty) && name.count <= 40 else {
            validation = L.t("请输入 1–40 个字符的名称。")
            return
        }
        guard let amounts = draft.values(in: unit) else {
            validation = L.t("每个杯量须相当于 1–5,000 mL。")
            return
        }
        busy = true
        model.error = nil
        validation = nil
        Task {
            await commit(amounts, name.isEmpty ? nil : name)
            busy = false
        }
    }
}

private struct StoredGroupView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let group: CupPresetSet
    let unit: VolumeUnit
    var share: () -> Void
    @State private var confirmRemove = false

    var body: some View {
        Group {
            if model.hasPro {
                GroupEditor(group: group, unit: unit, allowsName: true) { amounts, name in
                    if await model.changeGroup(.edit(group.id, name: name, amounts: amounts)) { dismiss() }
                } extras: {
                    Section {
                        Button(L.t("用这组"), action: makeActive).accessibilityIdentifier("cups.activate")
                        Button(L.t("分享杯量组"), action: share).accessibilityIdentifier("cups.share")
                        Button(L.t("删除杯量组"), role: .destructive) { confirmRemove = true }
                            .accessibilityIdentifier("cups.remove")
                    }
                }
            } else {
                List {
                    ForEach(Array(group.amounts.enumerated()), id: \.offset) { index, value in
                        LabeledContent(L.f("杯量 %@", String(index + 1)), value: unit.label(value))
                    }
                    Button(L.t("分享杯量组"), action: share).accessibilityIdentifier("cups.share")
                    Text(L.t("买断后可切换或编辑其他杯量组。")).font(.footnote).foregroundStyle(Palette.muted)
                }
            }
        }
        .navigationTitle(group.title)
        .confirmationDialog(L.t("删除这个杯量组？"), isPresented: $confirmRemove, titleVisibility: .visible) {
            Button(L.t("删除杯量组"), role: .destructive) {
                Task { if await model.changeGroup(.remove(group.id)) { dismiss() } }
            }
            Button(L.t("取消"), role: .cancel) {}
        }
    }

    private func makeActive() {
        Task { if await model.changeGroup(.activate(group.id)) { dismiss() } }
    }
}

private struct ImportCupView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let unit: VolumeUnit
    @State private var code = ""
    @State private var preview: [Int]?
    @State private var showFile = false
    @State private var busy = false
    @State private var newName: String?
    @State private var validation: String?

    var body: some View {
        Form {
            Section {
                TextField(L.t("杯量口令"), text: $code, axis: .vertical)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .accessibilityIdentifier("import.code")
                Button(L.t("粘贴口令"), action: paste).accessibilityIdentifier("import.paste")
                Button(L.t("预览口令")) { parse(code) }.accessibilityIdentifier("import.preview")
                Button(L.t("导入文件")) { showFile = true }.accessibilityIdentifier("import.file")
            }
            if let preview {
                Section(L.t("杯量预览")) {
                    ForEach(Array(preview.enumerated()), id: \.offset) { index, value in
                        LabeledContent(L.f("杯量 %@", String(index + 1)), value: unit.label(value))
                    }
                    Button(L.t("用这组")) {
                        let active = model.preferences.activeGroup
                        apply(.edit(active.id, name: active.name, amounts: preview))
                    }
                    .disabled(busy)
                    .accessibilityIdentifier("import.apply")
                    if model.hasPro {
                        Button(L.t("另存为新组")) { newName = "" }.accessibilityIdentifier("import.new")
                        if newName != nil {
                            TextField(L.t("杯量组名称"), text: Binding(get: { newName ?? "" }, set: { newName = $0 }))
                                .accessibilityIdentifier("import.name")
                            Button(L.t("保存新组")) {
                                let name = newName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                                guard (1...40).contains(name.count) else {
                                    validation = L.t("请输入 1–40 个字符的名称。")
                                    return
                                }
                                apply(.add(name, preview))
                            }
                            .disabled(busy)
                            .accessibilityIdentifier("import.saveNew")
                        }
                    }
                }
            }
            FieldError(message: validation ?? model.error)
        }
        .scrollDismissesKeyboard(.interactively)
        .navigationTitle(L.t("导入杯量"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(L.t("取消")) { dismiss() }.accessibilityIdentifier("import.cancel")
            }
        }
        .fileImporter(isPresented: $showFile, allowedContentTypes: [.plainText]) { result in
            if case .success(let url) = result { readFile(url) }
        }
        .onChange(of: code) { _, updated in
            if let preview, CupCode.decode(updated) != preview { self.preview = nil }
        }
        .onDisappear { model.error = nil }
    }

    private func paste() {
        let value = model.config.uiTesting
            ? (model.config.environment["WATERLOG_TEST_CUP_CODE"] ?? UIPasteboard.general.string)
            : UIPasteboard.general.string
        parse(value ?? "")
    }

    private func parse(_ value: String) {
        preview = CupCode.decode(value)
        code = value
        newName = nil
        validation = preview == nil ? L.t("无法识别这个杯量口令。") : nil
        model.error = nil
    }

    private func apply(_ change: GroupChange) {
        busy = true
        model.error = nil
        Task {
            let saved = await model.changeGroup(change)
            busy = false
            if saved { dismiss() }
        }
    }

    private func readFile(_ url: URL) {
        Task {
            do {
                let text = try await Task.detached {
                    let scope = url.startAccessingSecurityScopedResource()
                    defer { if scope { url.stopAccessingSecurityScopedResource() } }
                    let file = try FileHandle(forReadingFrom: url)
                    defer { try? file.close() }
                    let data = try file.read(upToCount: 4097) ?? Data()
                    guard data.count <= 4096, let text = String(data: data, encoding: .utf8) else { throw StorageError.invalidInput }
                    return text.trimmingCharacters(in: CharacterSet(charactersIn: "\u{FEFF}"))
                }.value
                parse(text)
            } catch {
                preview = nil
                validation = L.t("无法读取口令文件。")
            }
        }
    }
}

private struct CupCodeView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let group: CupPresetSet
    let unit: VolumeUnit
    @State private var sharing = SharePresentation()
    @State private var copied = false
    @State private var validation: String?
    private var code: String { CupCode.encode(group.amounts) }

    var body: some View {
        Form {
            Section {
                Text(group.amounts.map(unit.label).joined(separator: " · "))
                Text(code).font(.body.monospaced()).textSelection(.enabled).accessibilityIdentifier("cups.code")
                Button(copied ? L.t("已复制") : L.t("复制口令")) {
                    UIPasteboard.general.string = code
                    copied = true
                }.accessibilityIdentifier("cups.copyCode")
            }
            Section {
                Button(L.t("分享口令"), action: shareCode).accessibilityIdentifier("cups.shareCode")
                Button(L.t("分享口令文件"), action: export).accessibilityIdentifier("cups.shareFile")
                FieldError(message: validation)
            }
        }
        .navigationTitle(L.t("分享杯量组"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(L.t("关闭")) { dismiss() }.accessibilityIdentifier("cups.code.close")
            }
        }
        .sharePresentation($sharing)
    }

    private func shareCode() {
        let message = L.f("这是我常用的三个杯量。在饮水记录的「编辑杯量」里导入口令。\n%@", code)
        do {
            try sharing.present(SharedItems(values: [message]), type: L.t("杯量口令"),
                                uiTesting: model.config.uiTesting)
        } catch {
            validation = L.t("无法导出文件，请重试。")
        }
    }

    private func export() {
        let contents = Data(code.utf8)
        Task {
            do {
                let file = try await Task.detached {
                    try ExportFiles.write(contents, filename: "waterlog-cups.txt")
                }.value
                try sharing.present(SharedItems(values: [file], temporaryFile: file),
                                    type: "TXT", uiTesting: model.config.uiTesting)
            } catch {
                validation = L.t("无法导出文件，请重试。")
            }
        }
    }
}
