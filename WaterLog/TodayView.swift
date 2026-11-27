import SwiftUI

struct TodayView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dynamicTypeSize) private var textSize
    @ScaledMetric(relativeTo: .largeTitle) private var numberSize: CGFloat = 70

    var settings: () -> Void
    var history: () -> Void
    var add: () -> Void
    var edit: (DrinkEntry) -> Void
    var presets: () -> Void
    var card: (Int?) -> Void

    private var unit: VolumeUnit { model.preferences.unit }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                header.padding(.bottom, 2)
                summary
                quickActions
                recent
                shareEntry.padding(.top, 2)
            }
            .padding(.horizontal, 22)
            .padding(.top, 3)
            .padding(.bottom, 26)
            .frame(maxWidth: 600)
            .frame(maxWidth: .infinity)
        }
        .background(Palette.paper.ignoresSafeArea())
        .foregroundStyle(Palette.ink)
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(L.t("今天")).font(.largeTitle.weight(.bold)).accessibilityAddTraits(.isHeader)
                Text(ContextDate.label(model.now, zone: model.zone, format: "MMMdEEE"))
                    .font(.footnote).foregroundStyle(Palette.muted)
            }
            Spacer(minLength: 4)
            Button(L.t("设置"), action: settings)
                .buttonStyle(WaterButton(kind: .outline)).accessibilityIdentifier("today.settings")
        }
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(L.t("今日已记录"))
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Palette.darkBlue)
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: 9) { amount; unitText }
                VStack(alignment: .leading, spacing: 3) { amount; unitText }.frame(maxWidth: .infinity, alignment: .leading)
            }
            if let goal = model.preferences.goal {
                let ratio = Double(model.today.total) / Double(goal)
                ProgressView(value: min(ratio, 1))
                    .progressViewStyle(GoalProgressStyle())
                    .accessibilityLabel(L.t("每日目标完成度"))
                    .accessibilityValue(ratio.formatted(.percent.precision(.fractionLength(0))))
                HStack {
                    Text(L.f("我的目标 %@", unit.label(goal)))
                    Spacer()
                    Text(ratio.formatted(.percent.precision(.fractionLength(0)))).bold()
                }
                .font(.caption)
                .foregroundStyle(Palette.darkBlue)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 19)
        .padding(.vertical, 17)
        .background(Palette.tint, in: RoundedRectangle(cornerRadius: 24))
    }

    private var amount: some View {
        Text(unit.number(model.today.total))
            .font(.system(size: numberSize, weight: .bold))
            .tracking(-numberSize * 0.065)
            .monospacedDigit().lineLimit(1).minimumScaleFactor(0.32)
            .accessibilityLabel(unit.label(model.today.total))
            .accessibilityIdentifier("today.total")
    }

    private var unitText: some View {
        Text(unit.symbol).font(.title3.weight(.semibold)).foregroundStyle(Palette.darkBlue)
            .accessibilityHidden(true)
    }

    private var quickActions: some View {
        VStack(alignment: .leading, spacing: 6) {
            headerRow(L.t("记一杯"), button: L.t("编辑杯量"), id: "today.presets", action: presets)
            let layout = textSize.isAccessibilitySize ? AnyLayout(VStackLayout(spacing: 8)) : AnyLayout(HStackLayout(spacing: 8))
            layout {
                ForEach(Array(model.preferences.activeGroup.amounts.enumerated()), id: \.offset) { index, value in
                    cup(value, index: index)
                }
            }
            let actionLayout = textSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
                : AnyLayout(HStackLayout(spacing: 6))
            actionLayout {
                Button(action: add) { Label(L.t("自填"), systemImage: "plus") }
                    .buttonStyle(WaterButton()).accessibilityIdentifier("today.custom")
                if !textSize.isAccessibilitySize { Spacer(minLength: 0) }
                if let receipt = model.receipt {
                    feedback(L.f("已记入 %@", unit.label(receipt.entry.volume)), button: L.t("撤销"), id: "today.undo") {
                        model.undo(receipt.id)
                    }
                }
            }
            if !model.failedQuick.isEmpty {
                feedback(L.t("没有记入"), button: L.t("重试"), id: "today.retry", action: model.retryQuick)
                    .disabled(model.retrying)
            }
        }
    }

    private func cup(_ value: Int, index: Int) -> some View {
        let featured = index == 1
        return Button {
            model.logCup(value)
        } label: {
            VStack(spacing: 3) {
                Text(unit.number(value)).font(.title2.weight(.bold)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.5)
                Text(unit.symbol).font(.caption)
            }
            .padding(.vertical, 7)
            .padding(.horizontal, 3)
            .frame(maxWidth: .infinity, minHeight: 72)
            .foregroundStyle(featured ? .white : Palette.darkBlue)
            .background(featured ? Palette.blue : .white, in: RoundedRectangle(cornerRadius: 17))
            .overlay { RoundedRectangle(cornerRadius: 17).strokeBorder(featured ? Palette.blue : Palette.line) }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(L.f("记一杯，%@", unit.label(value)))
        .accessibilityIdentifier("today.cup.\(index)")
    }

    private func feedback(_ title: String, button: String, id: String, action: @escaping () -> Void) -> some View {
        HStack(spacing: 4) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(Palette.darkBlue)
                .accessibilityIdentifier(id == "today.undo" ? "today.receipt" : "today.saveFailed")
            Button(button, action: action).buttonStyle(WaterButton()).accessibilityIdentifier(id)
        }
        .padding(.leading, 10)
        .background(Palette.tint, in: RoundedRectangle(cornerRadius: 13))
    }

    private var recent: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerRow(L.t("最近记录"), button: L.t("历史"), id: "today.history", arrow: true, action: history)
            VStack(spacing: 0) {
                if model.today.entries.isEmpty {
                    Text(L.t("今天还没有记录")).font(.subheadline).foregroundStyle(Palette.muted)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 14)
                } else {
                    ForEach(Array(model.today.entries.prefix(3).enumerated()), id: \.element.id) { index, entry in
                        if index > 0 { Divider().overlay(Palette.line) }
                        EntryRow(entry: entry, unit: unit) { edit(entry) }
                            .accessibilityIdentifier("today.entry.\(index)")
                    }
                }
            }
            .padding(.horizontal, 13)
            .frame(minHeight: model.today.entries.isEmpty ? 55 : 133, alignment: .top)
            .modifier(Panel())
        }
    }

    @ViewBuilder private var shareEntry: some View {
        let recorded = model.week.filter(\.recorded).count
        let milestone = model.preferences.pendingMilestone
        if recorded > 0 || milestone != nil {
            let layout = textSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 2))
                : AnyLayout(HStackLayout(spacing: 4))
            layout {
                VStack(alignment: .leading, spacing: 2) {
                    if let milestone {
                        Text(L.f("已记录 %@ 天", String(milestone)))
                            .font(.footnote.weight(.semibold))
                            .accessibilityIdentifier("today.milestone")
                    } else {
                        Text(L.t("近 7 天")).font(.footnote.weight(.semibold))
                        Text(L.daysLogged(recorded)).font(.caption).foregroundStyle(Palette.muted)
                    }
                }
                if !textSize.isAccessibilitySize { Spacer(minLength: 0) }
                Button { card(milestone) } label: {
                    Label(L.t("生成记录卡"), systemImage: "chevron.right").labelStyle(ForwardLabel())
                }
                .buttonStyle(WaterButton()).accessibilityIdentifier("today.share")
                if milestone != nil {
                    Button {
                        Task { await model.update { $0.pendingMilestone = nil } }
                    } label: {
                        Image(systemName: "xmark").font(.caption.weight(.semibold))
                    }
                    .buttonStyle(WaterButton())
                    .accessibilityLabel(L.t("关闭里程碑"))
                    .accessibilityIdentifier("today.dismissMilestone")
                }
            }
            .padding(.leading, 12)
            .padding(.trailing, 4)
            .padding(.vertical, 4)
            .overlay { RoundedRectangle(cornerRadius: 15).strokeBorder(Palette.line).allowsHitTesting(false) }
        }
    }

    private func headerRow(_ title: String, button: String, id: String, arrow: Bool = false, action: @escaping () -> Void) -> some View {
        HStack {
            Text(title).font(.headline).accessibilityAddTraits(.isHeader)
            Spacer(minLength: 6)
            Button(action: action) {
                if arrow { Label(button, systemImage: "chevron.right").labelStyle(ForwardLabel()) }
                else { Text(button) }
            }
            .buttonStyle(WaterButton()).accessibilityIdentifier(id)
        }
    }
}

struct EntryRow: View {
    let entry: DrinkEntry
    let unit: VolumeUnit
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            let time = ContextDate.label(entry.consumedAt, zone: entry.zone, format: "jm")
            HStack(spacing: 8) {
                Text(time).font(.caption.monospacedDigit()).foregroundStyle(Palette.muted)
                Text(entry.drink.title).font(.subheadline.weight(.semibold)).foregroundStyle(Palette.ink)
                Spacer(minLength: 4)
                Text(unit.label(entry.volume)).font(.subheadline.weight(.semibold).monospacedDigit()).foregroundStyle(Palette.darkBlue)
            }
            .padding(.vertical, 4)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct ForwardLabel: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.title
            configuration.icon.font(.caption2.weight(.semibold))
        }
    }
}

private struct GoalProgressStyle: ProgressViewStyle {
    func makeBody(configuration: Configuration) -> some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Palette.progressTrack)
                Capsule().fill(Palette.blue).frame(width: proxy.size.width * (configuration.fractionCompleted ?? 0))
            }
        }
        .frame(height: 7)
    }
}
