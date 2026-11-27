import SwiftUI
import WidgetKit
import UIKit
import StoreKit

struct QuickReceipt: Identifiable {
    let entry: DrinkEntry
    var id: UUID { entry.id }
}

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var snapshot: LogSnapshot?
    @Published private(set) var receipt: QuickReceipt?
    @Published private(set) var failedQuick: [DrinkEntry] = []
    @Published private(set) var retrying = false
    @Published private(set) var bootFailed = false
    @Published private(set) var now: Date
    @Published private(set) var zone: TimeZone
    @Published private(set) var permission = ReminderPermission.undetermined
    @Published private(set) var reminderBusy = false
    @Published var error: String?

    @Published private(set) var products: [Product] = []
    @Published private(set) var loadingProducts = false
    @Published private(set) var purchaseBusy = false
    @Published private(set) var purchaseMessage: String?

    let config: LaunchConfiguration
    private let store: LogStore
    private let reminder: ReminderService
    private var booting = false
    private var didResetTestDatabase = false
    private var quickWork: Task<Void, Never>?
    private var receiptTimer: Task<Void, Never>?
    private var purchaseUpdates: Task<Void, Never>?
    private var failNextQuick: Bool

    init(config: LaunchConfiguration = LaunchConfiguration()) {
        self.config = config
        now = config.now
        zone = config.zone
        store = config.store
        failNextQuick = config.enabled("-fail-first-save")
        let client: any ReminderClient = config.uiTesting
            ? TestReminderClient(result: config.enabled("-notifications-denied") ? .denied : .allowed)
            : SystemReminderClient()
        reminder = ReminderService(client: client)
    }

    deinit {
        purchaseUpdates?.cancel()
        receiptTimer?.cancel()
    }

    var preferences: Preferences { snapshot?.state.preferences ?? Preferences() }
    var entitlement: Entitlement { snapshot?.state.entitlement ?? Entitlement(firstOpen: now) }
    var hasPro: Bool { entitlement.hasPro(at: now, free: config.free) }
    var purchaseStatus: String {
        if entitlement.purchasedPro { return L.t("已解锁") }
        guard hasPro else { return L.t("试用已结束") }
        let days = max(1, Int(ceil(entitlement.trialEnd.timeIntervalSince(now) / 86_400)))
        return days == 1 ? L.t("试用剩余 1 天") : L.f("试用剩余 %@ 天", String(days))
    }
    var today: DayLog {
        let key = Days.key(now, in: zone)
        return snapshot?.day(key) ?? DayLog(id: key, entries: [])
    }
    var week: [WeekDay] { snapshot?.week(at: now, in: zone) ?? [] }

    func start() async {
        guard snapshot == nil, !booting else { return }
        booting = true
        bootFailed = false
        defer { booting = false }
        do {
            if config.enabled("-reset") && !didResetTestDatabase {
                try await store.resetTestDatabase()
                didResetTestDatabase = true
            }
            let initial = try await store.begin(now: now, zone: zone, free: config.free,
                                                demo: config.sampleEntries, expired: config.enabled("-expired"))
            publish(initial)
            startPurchaseObserver()
            await refreshReminders()
        } catch {
            bootFailed = true
        }
    }

    func refreshEnvironment(reconcileReminder: Bool = false) async {
        let previousDay = Days.key(now, in: zone)
        let previousZone = zone
        now = config.now
        zone = config.zone
        guard snapshot != nil else { return }
        let day = Days.key(now, in: zone)
        let localDayChanged = day != previousDay || previousZone != zone
        do {
            if !preferences.usageDays.contains(day) {
                publish(try await store.changePreferences { $0.usageDays.insert(day) })
            } else if let updated = try await store.read(changedSince: snapshot?.state.revision) {
                publish(updated)
            }
        } catch {
            if reconcileReminder { self.error = L.t("暂时无法读取记录，请重试。") }
        }
        if reconcileReminder || localDayChanged { await refreshReminders() }
    }

    func logCup(_ amount: Int) {
        let time = config.now
        let entry = DrinkEntry(volume: amount, date: time, zone: config.zone, now: time)
        enqueue(entry, retry: false)
    }

    func retryQuick() {
        guard !retrying, let entry = failedQuick.first else { return }
        retrying = true
        enqueue(entry, retry: true)
    }

    private func enqueue(_ entry: DrinkEntry, retry: Bool) {
        let previous = quickWork
        quickWork = Task { [weak self] in
            await previous?.value
            await self?.commitQuick(entry, retry: retry)
        }
    }

    private func commitQuick(_ entry: DrinkEntry, retry: Bool) async {
        defer { if retry { retrying = false } }
        do {
            if failNextQuick {
                failNextQuick = false
                throw StorageError.unavailable
            }
            publish(try await store.add(entry, milestone: true), widget: true)
            if !config.uiTesting { CoreReview.shared.record(preferences.coreReviewProgress) }
            failedQuick.removeAll { $0.id == entry.id }
            now = config.now
            zone = config.zone
            receiptTimer?.cancel()
            receipt = QuickReceipt(entry: entry)
            UIAccessibility.post(notification: .announcement, argument: L.f("已记入 %@", preferences.unit.label(entry.volume)))
            receiptTimer = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(8)) } catch { return }
                if self?.receipt?.id == entry.id { self?.receipt = nil }
            }
        } catch {
            if !failedQuick.contains(where: { $0.id == entry.id }) { failedQuick.append(entry) }
            UIAccessibility.post(notification: .announcement, argument: L.t("没有记入"))
        }
    }

    func undo(_ id: UUID) {
        guard receipt?.id == id else { return }
        receiptTimer?.cancel()
        receipt = nil
        Task {
            if await delete(id) {
                UIAccessibility.post(notification: .announcement, argument: L.t("已撤销"))
            } else if receipt == nil {
                self.error = L.t("撤销失败。请在记录详情中删除这笔记录。")
            }
        }
    }

    func save(_ entry: DrinkEntry?, draftID: UUID, amount: Int, drink: Drink, date: Date?) async -> Bool {
        do {
            let now = config.now
            let actualDate = date ?? now
            if let entry {
                publish(try await store.edit(entry, amount: amount, drink: drink, date: actualDate, now: now), widget: true)
            } else {
                let new = DrinkEntry(id: draftID, volume: amount, drink: drink, date: actualDate, zone: config.zone, now: now)
                publish(try await store.add(new, milestone: new.day == Days.key(now, in: config.zone)), widget: true)
                if !config.uiTesting { CoreReview.shared.record(preferences.coreReviewProgress) }
            }
            return true
        } catch {
            self.error = L.t("没有保存，请重试。")
            return false
        }
    }

    func delete(_ id: UUID) async -> Bool {
        do {
            publish(try await store.delete(id, now: config.now), widget: true)
            if receipt?.id == id {
                receiptTimer?.cancel()
                receipt = nil
            }
            return true
        } catch {
            self.error = L.t("没有删除，请重试。")
            return false
        }
    }

    @discardableResult
    func update(_ change: @escaping @Sendable (inout Preferences) -> Void, widget: Bool = false) async -> Bool {
        do {
            publish(try await store.changePreferences(change), widget: widget)
            return true
        } catch {
            self.error = L.t("没有保存，请重试。")
            return false
        }
    }

    func changeGroup(_ change: GroupChange) async -> Bool {
        do {
            publish(try await store.apply(change, now: config.now, free: config.free), widget: true)
            return true
        } catch StorageError.proRequired {
            self.error = L.t("这项功能需要高级版。")
            return false
        } catch {
            self.error = L.t("没有保存，请重试。")
            return false
        }
    }

    func configureReminder(_ settings: ReminderSettings, ask: Bool = false) async -> Bool {
        guard !reminderBusy else { return false }
        reminderBusy = true
        defer { reminderBusy = false }
        do {
            permission = try await reminder.reconcile(settings, ask: ask)
            var adjusted = settings
            if ask && permission != .allowed { adjusted.enabled = false }
            let result = adjusted
            if await update({ $0.reminder = result }) { return true }
            _ = try? await reminder.reconcile(preferences.reminder, ask: false)
        } catch {
            self.error = L.t("提醒未更新，请重试。")
        }
        return false
    }

    private func refreshReminders() async {
        guard !reminderBusy else { return }
        reminderBusy = true
        defer { reminderBusy = false }
        do {
            permission = try await reminder.reconcile(preferences.reminder, ask: false)
        } catch {
            self.error = L.t("提醒未更新，请重试。")
        }
    }

    var reviewBlocked: Bool {
        receipt != nil || !failedQuick.isEmpty || reminderBusy || preferences.pendingMilestone != nil
    }

    func requestHistoryReview(_ request: () -> Void) {
        let mark = now
        guard !config.uiTesting, error == nil, !purchaseBusy,
              preferences.mayRequestReview(at: mark, recordedDays: snapshot?.days.count ?? 0, blocked: reviewBlocked),
              CoreReview.shared.attempt(request) else { return }
        Task {
            if let state = try? await store.changePreferences({ $0.lastReview = mark }) { publish(state) }
        }
    }

    private func publish(_ value: LogSnapshot, widget: Bool = false) {
        if value.state.revision >= (snapshot?.state.revision ?? 0) { snapshot = value }
        if widget && !config.uiTesting { WidgetCenter.shared.reloadTimelines(ofKind: Launch.widgetKind) }
    }

    private func startPurchaseObserver() {
        guard !config.free, !config.uiTesting, purchaseUpdates == nil else { return }
        purchaseUpdates = Task { [weak self] in
            for await result in StoreKit.Transaction.updates {
                guard !Task.isCancelled else { return }
                if case .verified(let transaction) = result {
                    await self?.handleUpdate(transaction)
                }
            }
        }
        Task { [weak self] in try? await self?.readPurchases() }
    }

    func loadProducts() async {
        guard !config.uiTesting, !config.free, !loadingProducts else { return }
        loadingProducts = true
        purchaseMessage = nil
        defer { loadingProducts = false }
        do {
            products = try await Product.products(for: [Launch.proID, Launch.trialID])
            if !products.contains(where: { $0.id == Launch.proID }) {
                purchaseMessage = L.t("暂时无法加载商品，请稍后重试。")
            }
        } catch {
            purchaseMessage = L.t("暂时无法加载商品，请稍后重试。")
        }
    }

    func purchase(_ id: String) async {
        guard !config.free, !config.uiTesting, !purchaseBusy,
              let product = products.first(where: { $0.id == id }) else { return }
        purchaseBusy = true
        purchaseMessage = nil
        defer { purchaseBusy = false }
        do {
            switch try await product.purchase() {
            case .success(let verification):
                guard case .verified(let transaction) = verification else {
                    purchaseMessage = L.t("购买未通过验证，请稍后恢复购买。")
                    return
                }
                try await record(transaction)
                await transaction.finish()
                purchaseMessage = L.t("已更新购买状态。")
            case .pending:
                purchaseMessage = L.t("购买正在等待确认。")
            case .userCancelled: break
            @unknown default: break
            }
        } catch {
            purchaseMessage = L.t("购买未完成，请稍后重试。")
        }
    }

    func restorePurchases() async {
        guard !config.free, !purchaseBusy else { return }
        purchaseBusy = true
        purchaseMessage = nil
        defer { purchaseBusy = false }
        do {
            if config.uiTesting {
                if config.enabled("-restore-fails") { throw StorageError.unavailable }
                if config.enabled("-restore-pro") {
                    publish(try await store.apply(.init(kind: .pro, date: now, originalDate: now, revoked: false)))
                }
            } else {
                try await AppStore.sync()
                try await readPurchases()
            }
            purchaseMessage = entitlement.purchasedPro || entitlement.trialClaimedAt != nil
                ? L.t("已恢复购买。") : L.t("没有找到可恢复的购买。")
        } catch {
            purchaseMessage = L.t("恢复购买未完成，请稍后重试。")
        }
    }

    private func readPurchases() async throws {
        for id in [Launch.proID, Launch.trialID] {
            if case .verified(let transaction)? = await StoreKit.Transaction.latest(for: id) {
                try await record(transaction)
            }
        }
    }

    private func handleUpdate(_ transaction: StoreKit.Transaction) async {
        do {
            try await record(transaction)
            await transaction.finish()
        } catch {
            purchaseMessage = L.t("购买未完成，请稍后重试。")
        }
    }

    private func record(_ transaction: StoreKit.Transaction) async throws {
        let kind: VerifiedPurchase.Kind
        switch transaction.productID {
        case Launch.proID: kind = .pro
        case Launch.trialID: kind = .trial
        default: return
        }
        let purchase = VerifiedPurchase(kind: kind, date: transaction.purchaseDate,
                                        originalDate: transaction.originalPurchaseDate, revoked: transaction.revocationDate != nil)
        publish(try await store.apply(purchase), widget: true)
    }
}
