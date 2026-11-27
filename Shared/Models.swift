import Foundation

enum Drink: String, Codable, CaseIterable, Identifiable {
    case water, tea, other

    var id: Self { self }
    var title: String {
        switch self {
        case .water: return L.t("水")
        case .tea: return L.t("茶")
        case .other: return L.t("其他")
        }
    }
}

enum Days {
    static func calendar(in zone: TimeZone = .current) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        return calendar
    }

    static func key(_ date: Date, in zone: TimeZone = .current) -> String {
        let parts = calendar(in: zone).dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    static func date(_ key: String, in zone: TimeZone = .current) -> Date? {
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return calendar(in: zone).date(from: .init(year: parts[0], month: parts[1], day: parts[2], hour: 12))
    }

    static func week(ending date: Date, in zone: TimeZone = .current) -> [Date] {
        let calendar = calendar(in: zone)
        let today = self.date(key(date, in: zone), in: zone) ?? date
        return (-6...0).compactMap { calendar.date(byAdding: .day, value: $0, to: today) }
    }

    static func nextMidnight(after date: Date, in zone: TimeZone = .current) -> Date {
        calendar(in: zone).dateInterval(of: .day, for: date)?.end ?? date.addingTimeInterval(3600)
    }
}

struct DrinkEntry: Identifiable, Equatable {
    var id = UUID()
    var volume: Int
    var drink: Drink = .water
    var consumedAt: Date
    var zoneID: String
    var day: String
    var createdAt: Date
    var updatedAt: Date
    var deletedAt: Date?

    init(id: UUID = UUID(), volume: Int, drink: Drink = .water, date: Date, zone: TimeZone, now: Date) {
        self.id = id
        self.volume = volume
        self.drink = drink
        consumedAt = date
        zoneID = zone.identifier
        day = Days.key(date, in: zone)
        createdAt = now
        updatedAt = now
    }

    var zone: TimeZone { TimeZone(identifier: zoneID) ?? .gmt }
}

struct CupPresetSet: Codable, Identifiable, Equatable {
    static let defaults = [150_000, 250_000, 500_000]

    var id = UUID()
    var name: String?
    var amounts = Self.defaults

    var title: String { name ?? L.t("常用杯量") }
}

struct ReminderSettings: Codable, Equatable {
    var enabled = false
    var hour = 15
    var minute = 30
}

struct Preferences: Codable {
    var unit: VolumeUnit = .ml
    var groups = [CupPresetSet()]
    var activeGroupID: UUID?
    var goal: Int?
    var reminder = ReminderSettings()
    var shownMilestones: Set<Int> = []
    var pendingMilestone: Int?
    var usageDays: Set<String> = []
    var lastReview: Date?
    var coreReviewProgress: CoreReviewProgress?

    var activeIndex: Int { groups.firstIndex { $0.id == activeGroupID } ?? 0 }
    var activeGroup: CupPresetSet { groups[activeIndex] }

    mutating func evaluateMilestone(recordedDays: Int) -> Bool {
        let reached = Set([7, 30].filter { recordedDays >= $0 }).subtracting(shownMilestones)
        guard let newest = reached.max() else { return false }
        shownMilestones.formUnion(reached)
        pendingMilestone = newest
        return true
    }

    func mayRequestReview(at now: Date, recordedDays: Int, blocked: Bool) -> Bool {
        !blocked && pendingMilestone == nil && usageDays.count >= 3 && recordedDays >= 7 &&
            (lastReview.map { now.timeIntervalSince($0) >= 120 * 86_400 } ?? true)
    }
}

struct LocalState: Codable {
    var preferences = Preferences()
    var entitlement: Entitlement
    var revision = 0
}

struct DayLog: Identifiable {
    let id: String
    let entries: [DrinkEntry]
    let total: Int

    init(id: String, entries: [DrinkEntry]) {
        self.id = id
        self.entries = entries
        total = entries.reduce(0) { $0 + $1.volume }
    }
}

struct WeekDay: Identifiable {
    let id: String
    let date: Date
    let total: Int
    let recorded: Bool
}

struct LogSnapshot {
    let state: LocalState
    let days: [DayLog]
    private let byDay: [String: DayLog]

    init(state: LocalState, entries: [DrinkEntry]) {
        self.state = state
        byDay = Dictionary(grouping: entries, by: \.day).mapValues { DayLog(id: $0[0].day, entries: $0) }
        days = byDay.values.sorted { $0.id > $1.id }
    }

    func day(_ key: String) -> DayLog { byDay[key] ?? DayLog(id: key, entries: []) }

    func week(at date: Date, in zone: TimeZone) -> [WeekDay] {
        Days.week(ending: date, in: zone).map {
            let key = Days.key($0, in: zone)
            let log = day(key)
            return WeekDay(id: key, date: $0, total: log.total, recorded: !log.entries.isEmpty)
        }
    }
}
