import SwiftUI
import StoreKit
import UIKit

@main
@MainActor
struct WaterLogApp: App {
    @Environment(\.scenePhase) private var phase
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .environment(\.timeZone, model.zone)
                .modifier(TestTextSize(enabled: model.config.enabled("-large-text")))
                .preferredColorScheme(.light)
                .tint(Palette.blue)
                .task { await model.start() }
                .task(id: phase) {
                    guard phase == .active else { return }
                    await model.refreshEnvironment(reconcileReminder: true)
                    while !Task.isCancelled {
                        do { try await Task.sleep(for: .seconds(20)) } catch { break }
                        await model.refreshEnvironment()
                    }
                }
                .onReceive(NotificationCenter.default.publisher(for: UIApplication.significantTimeChangeNotification)) { _ in
                    Task { await model.refreshEnvironment(reconcileReminder: true) }
                }
                .onReceive(NotificationCenter.default.publisher(for: .NSSystemTimeZoneDidChange)) { _ in
                    Task { await model.refreshEnvironment(reconcileReminder: true) }
                }
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.requestReview) private var requestReview
    @State private var path: [Route] = []
    @State private var sheet: Sheet?
    @State private var didRouteLaunch = false

    enum Route: Hashable {
        case history, settings, day(String), report
    }

    enum Sheet: Identifiable {
        case entry(DrinkEntry?), groups, goal, reminder, paywall, card(Int?)
        var id: String {
            switch self {
            case .entry(let entry): return entry?.id.uuidString ?? "new"
            case .groups: return "groups"
            case .goal: return "goal"
            case .reminder: return "reminder"
            case .paywall: return "paywall"
            case .card: return "card"
            }
        }
    }

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if model.snapshot != nil {
                    TodayView(
                        settings: { path.append(.settings) }, history: { path.append(.history) },
                        add: { sheet = .entry(nil) }, edit: { sheet = .entry($0) },
                        presets: { sheet = .groups }, card: { sheet = .card($0) }
                    )
                } else if model.bootFailed {
                    ContentUnavailableView {
                        Label(L.t("暂时无法读取记录，请重试。"), systemImage: "externaldrive.badge.exclamationmark")
                    } description: {
                        EmptyView()
                    } actions: {
                        Button(L.t("重试")) { Task { await model.start() } }
                            .accessibilityIdentifier("startup.retry")
                    }
                } else {
                    ProgressView().accessibilityLabel(L.t("正在读取记录"))
                }
            }
            .background(Palette.paper.ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: Route.self) { route in
                destination(route).toolbar(.visible, for: .navigationBar)
            }
        }
        .sheet(item: $sheet) { item in
            NavigationStack { modal(item) }
                .presentationDragIndicator(.visible)
        }
        .alert(L.t("饮水记录"), isPresented: Binding(
            get: { model.error != nil && sheet == nil },
            set: { if !$0 { model.error = nil } }
        )) {
            Button(L.t("好"), role: .cancel) { model.error = nil }
        } message: {
            Text(model.error ?? "")
        }
        .onOpenURL { url in
            guard url == Launch.homeURL else { return }
            sheet = nil
            path = []
            Task { await model.refreshEnvironment() }
        }
        .onChange(of: model.snapshot != nil) { _, ready in
            guard ready, !didRouteLaunch else { return }
            didRouteLaunch = true
            if model.config.enabled("-paywall") { sheet = .paywall }
        }
        .reviewAfterCoreAction(when: path.isEmpty && sheet == nil && model.snapshot != nil && model.error == nil && !model.purchaseBusy && !model.reviewBlocked) { requestReview() }
        .onChange(of: path) { old, new in
            guard old == [.history], new.isEmpty, sheet == nil else { return }
            model.requestHistoryReview { requestReview() }
        }
    }

    @ViewBuilder private func destination(_ route: Route) -> some View {
        switch route {
        case .history:
            HistoryView(openDay: { path.append(.day($0)) },
                        report: { if model.hasPro { path.append(.report) } else { sheet = .paywall } })
        case .settings:
            SettingsView(goal: { sheet = .goal }, reminder: { sheet = .reminder }, paywall: { sheet = .paywall })
        case .day(let key):
            HistoryDayView(key: key, edit: { sheet = .entry($0) })
        case .report:
            ReportView(paywall: { sheet = .paywall })
        }
    }

    @ViewBuilder private func modal(_ item: Sheet) -> some View {
        switch item {
        case .entry(let entry): EntryForm(entry: entry, unit: model.preferences.unit)
        case .groups: GroupsView(unit: model.preferences.unit)
        case .goal: GoalView(goal: model.preferences.goal, unit: model.preferences.unit)
        case .reminder: ReminderTimeView(settings: model.preferences.reminder)
        case .paywall: PaywallView()
        case .card(let milestone):
            ShareCardView(week: model.week, milestone: milestone, storeURL: model.config.storeURL)
        }
    }
}
