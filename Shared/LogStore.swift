import Foundation
import SQLite3

enum GroupChange {
    case edit(UUID, name: String?, amounts: [Int])
    case activate(UUID)
    case add(String, [Int])
    case remove(UUID)
}

struct WidgetReading {
    let total: Int
    let unit: VolumeUnit
    let groupID: UUID?
    let amount: Int?
    let refresh: Date
}

actor LogStore {
    private let url: URL?
    private var connection: SQLiteDatabase?

    init(url: URL) { self.url = url }
    init() { url = nil }

    private func database() throws -> SQLiteDatabase {
        if let connection { return connection }
        let path: URL
        if let url {
            path = url
        } else {
            guard let group = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: Launch.appGroup) else {
                throw StorageError.unavailable
            }
            var directory = group.appendingPathComponent("LocalData", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try directory.setResourceValues(values)
            path = directory.appendingPathComponent("WaterLog.sqlite")
        }
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        let database = try SQLiteDatabase(url: path)
        connection = database
        return database
    }

    func resetTestDatabase() throws {
        guard let url else { throw StorageError.invalidInput }
        connection = nil
        for suffix in ["", "-journal", "-wal", "-shm"] {
            let file = URL(fileURLWithPath: url.path + suffix)
            if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
        }
    }

    func begin(now: Date, zone: TimeZone, free: Bool, demo: [DrinkEntry]? = nil, expired: Bool = false) throws -> LogSnapshot {
        let db = try database()
        return try db.transaction {
            let old = try readState(db)
            var state = old ?? LocalState(entitlement: Entitlement(firstOpen: now))
            state.entitlement.startPaidPeriod(at: now, free: free)
            if expired { state.entitlement.proStartedAt = now.addingTimeInterval(-31 * 86_400) }
            state.preferences.usageDays.insert(Days.key(now, in: zone))
            if old == nil, let demo {
                state.preferences.goal = 1_500_000
                for entry in demo { _ = try insert(entry, db: db) }
            } else if demo == nil {
                try evaluateMilestone(&state, db: db)
            }
            try save(&state, db: db)
            return try snapshot(state, db: db)
        }
    }

    func read() throws -> LogSnapshot {
        guard let result = try read(changedSince: nil) else { throw StorageError.unavailable }
        return result
    }

    func read(changedSince revision: Int?) throws -> LogSnapshot? {
        let db = try database()
        return try db.transaction(write: false) {
            guard let state = try readState(db) else { throw StorageError.unavailable }
            if let revision, state.revision == revision { return nil }
            return try snapshot(state, db: db)
        }
    }

    func add(_ entry: DrinkEntry, milestone: Bool) throws -> LogSnapshot {
        try update { state, db in
            if try insert(entry, db: db) {
                state.preferences.usageDays.insert(Days.key(entry.createdAt, in: entry.zone))
                state.preferences.coreReviewProgress = .recording(state.preferences.coreReviewProgress, at: entry.createdAt)
                if milestone { try evaluateMilestone(&state, db: db) }
            }
        }
    }

    func edit(_ entry: DrinkEntry, amount: Int, drink: Drink, date: Date, now: Date) throws -> LogSnapshot {
        guard CupCode.limits.contains(amount) else { throw StorageError.invalidInput }
        return try update { state, db in
            guard let current = try entries(db, id: entry.id).first else { throw StorageError.missingEntry }
            let newDate = date == entry.consumedAt ? current.consumedAt : date
            let newAmount = amount == entry.volume ? current.volume : amount
            let newDrink = drink == entry.drink ? current.drink : drink
            let newDay = newDate == current.consumedAt ? current.day : Days.key(newDate, in: current.zone)
            try db.execute("""
                UPDATE drink_entry SET volume = ?, drink = ?, consumed_at = ?, day = ?, updated_at = ?
                WHERE id = ? AND deleted_at IS NULL
                """, [.integer(newAmount), .text(newDrink.rawValue), .date(newDate), .text(newDay), .date(now), .text(entry.id.uuidString)])
            if newDay != current.day { try clearUnreachedMilestone(&state, db: db) }
        }
    }

    func delete(_ id: UUID, now: Date) throws -> LogSnapshot {
        try update { state, db in
            try db.execute("UPDATE drink_entry SET deleted_at = ?, updated_at = ? WHERE id = ? AND deleted_at IS NULL",
                           [.date(now), .date(now), .text(id.uuidString)])
            if db.changedRows != 0 { try clearUnreachedMilestone(&state, db: db) }
        }
    }

    func apply(_ change: GroupChange, now: Date, free: Bool) throws -> LogSnapshot {
        try update { state, _ in
            let pro = state.entitlement.hasPro(at: now, free: free)
            var preferences = state.preferences
            switch change {
            case .edit(let id, let name, let amounts):
                guard let index = preferences.groups.firstIndex(where: { $0.id == id }), CupCode.valid(amounts) else {
                    throw StorageError.invalidInput
                }
                guard index == preferences.activeIndex || pro else { throw StorageError.proRequired }
                preferences.groups[index].amounts = amounts
                preferences.groups[index].name = try validName(name)
            case .activate(let id):
                guard pro else { throw StorageError.proRequired }
                guard preferences.groups.contains(where: { $0.id == id }) else { throw StorageError.invalidInput }
                preferences.activeGroupID = id
            case .add(let name, let amounts):
                guard pro else { throw StorageError.proRequired }
                guard let name = try validName(name), CupCode.valid(amounts) else { throw StorageError.invalidInput }
                let group = CupPresetSet(name: name, amounts: amounts)
                preferences.groups.append(group)
                preferences.activeGroupID = group.id
            case .remove(let id):
                guard pro else { throw StorageError.proRequired }
                guard preferences.activeGroup.id != id else { throw StorageError.invalidInput }
                preferences.groups.removeAll { $0.id == id }
            }
            state.preferences = preferences
        }
    }

    func changePreferences(_ body: @Sendable (inout Preferences) -> Void) throws -> LogSnapshot {
        try update { state, _ in body(&state.preferences) }
    }

    func apply(_ purchase: VerifiedPurchase) throws -> LogSnapshot {
        try update { state, _ in state.entitlement.apply(purchase) }
    }

    func markReview(at now: Date) throws -> (LogSnapshot, Bool) {
        var allowed = false
        let snapshot = try update { state, db in
            let recordedDays = try countRecordedDays(db)
            allowed = state.preferences.mayRequestReview(at: now, recordedDays: recordedDays, blocked: false)
            if allowed { state.preferences.lastReview = now }
        }
        return (snapshot, allowed)
    }

    func widgetReading(at date: Date, zone: TimeZone) throws -> WidgetReading {
        let db = try database()
        return try db.transaction(write: false) {
            let state = try readState(db)
            let total = try db.query("SELECT COALESCE(SUM(volume), 0) FROM drink_entry WHERE day = ? AND deleted_at IS NULL",
                                     [.text(Days.key(date, in: zone))]) { Int(sqlite3_column_int64($0, 0)) }.first ?? 0
            let canLog = state?.entitlement.widgetCanLog(at: date) == true
            let refresh = Days.nextMidnight(after: date, in: zone)
            let expiry = state?.entitlement.trialEnd
            let group = canLog ? state?.preferences.activeGroup : nil
            return WidgetReading(
                total: total, unit: state?.preferences.unit ?? .ml,
                groupID: group?.id, amount: group?.amounts[1],
                refresh: canLog && state?.entitlement.purchasedPro == false && !Launch.isFree
                    ? min(refresh, expiry ?? refresh) : refresh)
        }
    }

    @discardableResult
    func logFromWidget(group: UUID, amount: Int, now: Date, zone: TimeZone, requestID: UUID = UUID()) throws -> Bool {
        let db = try database()
        return try db.transaction {
            guard var state = try readState(db), state.entitlement.widgetCanLog(at: now),
                  state.preferences.activeGroup.id == group, state.preferences.activeGroup.amounts[1] == amount else { return false }
            let entry = DrinkEntry(id: requestID, volume: amount, date: now, zone: zone, now: now)
            if try insert(entry, db: db) {
                state.preferences.usageDays.insert(entry.day)
                try evaluateMilestone(&state, db: db)
                try save(&state, db: db)
            }
            return true
        }
    }

    private func update(_ body: (inout LocalState, SQLiteDatabase) throws -> Void) throws -> LogSnapshot {
        let db = try database()
        return try db.transaction {
            guard var state = try readState(db) else { throw StorageError.unavailable }
            try body(&state, db)
            try save(&state, db: db)
            return try snapshot(state, db: db)
        }
    }

    private func snapshot(_ state: LocalState, db: SQLiteDatabase) throws -> LogSnapshot {
        LogSnapshot(state: state, entries: try entries(db))
    }

    private func readState(_ db: SQLiteDatabase) throws -> LocalState? {
        try db.query("SELECT data FROM local_state WHERE id = 1") { statement in
            guard let blob = sqlite3_column_blob(statement, 0) else { throw StorageError.corrupted }
            let data = Data(bytes: blob, count: Int(sqlite3_column_bytes(statement, 0)))
            let state = try JSONDecoder().decode(LocalState.self, from: data)
            guard !state.preferences.groups.isEmpty, state.preferences.groups.allSatisfy({ CupCode.valid($0.amounts) }) else {
                throw StorageError.corrupted
            }
            return state
        }.first
    }

    private func save(_ state: inout LocalState, db: SQLiteDatabase) throws {
        state.revision += 1
        try db.execute("INSERT INTO local_state (id, data) VALUES (1, ?) ON CONFLICT(id) DO UPDATE SET data = excluded.data",
                       [.blob(try JSONEncoder().encode(state))])
    }

    private func entries(_ db: SQLiteDatabase, id: UUID? = nil) throws -> [DrinkEntry] {
        let filter = id == nil ? "" : " AND id = ?"
        return try db.query("""
            SELECT id, volume, drink, consumed_at, zone, day, created_at, updated_at
            FROM drink_entry WHERE deleted_at IS NULL\(filter)
            ORDER BY consumed_at DESC, created_at DESC, rowid DESC
            """, id.map { [.text($0.uuidString)] } ?? []) { statement in
            guard let id = try UUID(uuidString: SQLiteDatabase.text(statement, 0)),
                  let drink = try Drink(rawValue: SQLiteDatabase.text(statement, 2)) else { throw StorageError.corrupted }
            let zoneID = try SQLiteDatabase.text(statement, 4)
            let date = Date(timeIntervalSince1970: sqlite3_column_double(statement, 3))
            let created = Date(timeIntervalSince1970: sqlite3_column_double(statement, 6))
            var entry = DrinkEntry(id: id, volume: Int(sqlite3_column_int64(statement, 1)), drink: drink,
                                   date: date, zone: TimeZone(identifier: zoneID) ?? .gmt, now: created)
            entry.zoneID = zoneID
            entry.day = try SQLiteDatabase.text(statement, 5)
            entry.updatedAt = Date(timeIntervalSince1970: sqlite3_column_double(statement, 7))
            return entry
        }
    }

    private func insert(_ entry: DrinkEntry, db: SQLiteDatabase) throws -> Bool {
        guard CupCode.limits.contains(entry.volume) else { throw StorageError.invalidInput }
        try db.execute("""
            INSERT INTO drink_entry (id, volume, drink, consumed_at, zone, day, created_at, updated_at, deleted_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, NULL) ON CONFLICT(id) DO NOTHING
            """, [.text(entry.id.uuidString), .integer(entry.volume), .text(entry.drink.rawValue), .date(entry.consumedAt),
                  .text(entry.zoneID), .text(entry.day), .date(entry.createdAt), .date(entry.updatedAt)])
        return db.changedRows == 1
    }

    private func countRecordedDays(_ db: SQLiteDatabase) throws -> Int {
        try db.query("SELECT COUNT(DISTINCT day) FROM drink_entry WHERE deleted_at IS NULL") {
            Int(sqlite3_column_int64($0, 0))
        }.first ?? 0
    }

    private func evaluateMilestone(_ state: inout LocalState, db: SQLiteDatabase) throws {
        if !state.preferences.shownMilestones.contains(30) {
            _ = state.preferences.evaluateMilestone(recordedDays: try countRecordedDays(db))
        }
    }

    private func clearUnreachedMilestone(_ state: inout LocalState, db: SQLiteDatabase) throws {
        if let pending = state.preferences.pendingMilestone, try countRecordedDays(db) < pending {
            state.preferences.pendingMilestone = nil
            state.preferences.shownMilestones.remove(pending)
        }
    }

    private func validName(_ value: String?) throws -> String? {
        guard let value else { return nil }
        let name = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard name.count <= 40 else { throw StorageError.invalidInput }
        return name.isEmpty ? nil : name
    }
}
