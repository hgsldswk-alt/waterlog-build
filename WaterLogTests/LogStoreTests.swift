import SQLite3
import XCTest

final class LogStoreTests: XCTestCase {
    private let midnight = ISO8601DateFormatter().date(from: "2026-11-20T00:00:00Z")!

    private func databaseURL() -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory.appendingPathComponent("log.sqlite")
    }

    func testRapidAddsDeduplicateAndUndoKeepsTombstoneAcrossMidnight() async throws {
        let url = databaseURL()
        let store = LogStore(url: url)
        let beforeMidnight = midnight.addingTimeInterval(-60)
        let start = try await store.begin(now: beforeMidnight, zone: .gmt, free: false)
        XCTAssertEqual(start.state.preferences.activeGroup.amounts, CupPresetSet.defaults)
        XCTAssertNil(start.state.preferences.goal)

        let entries = [150_000, 250_000, 500_000].map {
            DrinkEntry(volume: $0, date: beforeMidnight, zone: .gmt, now: beforeMidnight)
        }
        for entry in entries { _ = try await store.add(entry, milestone: true) }
        let duplicate = try await store.add(entries[2], milestone: false)
        XCTAssertEqual(duplicate.day("2026-11-19").total, 900_000)
        XCTAssertEqual(duplicate.day("2026-11-19").entries.count, 3)

        let undo = try await store.delete(entries[2].id, now: midnight)
        XCTAssertEqual(undo.day("2026-11-19").total, 400_000)
        XCTAssertEqual(undo.day("2026-11-20").total, 0)
        let retry = try await LogStore(url: url).add(entries[2], milestone: true)
        XCTAssertEqual(retry.day("2026-11-19").total, 400_000)
        XCTAssertEqual(retry.day("2026-11-19").entries.map(\.id), [entries[1].id, entries[0].id])
    }

    func testEditFreezesZoneUnlessTimeChangesAndExportsConsistently() async throws {
        let zone = try XCTUnwrap(TimeZone(identifier: "Asia/Tokyo"))
        let date = midnight.addingTimeInterval(-3600)
        let store = LogStore(url: databaseURL())
        _ = try await store.begin(now: midnight, zone: .gmt, free: false)
        let original = DrinkEntry(volume: 250_123, date: date, zone: zone, now: midnight)
        let logged = try await store.add(original, milestone: false)
        XCTAssertEqual(logged.day("2026-11-19").total, 0)
        XCTAssertEqual(logged.day("2026-11-20").total, 250_123)
        let edited = try await store.edit(original, amount: original.volume, drink: .tea, date: date, now: midnight)
        XCTAssertEqual(edited.day("2026-11-20").entries.first?.zoneID, zone.identifier)
        XCTAssertEqual(edited.day("2026-11-20").entries.first?.volume, 250_123)
        let moved = try await store.edit(original, amount: 330_001, drink: .water,
                                         date: date.addingTimeInterval(-86_400), now: midnight)
        XCTAssertEqual(moved.day("2026-11-19").entries.first?.drink, .tea)
        XCTAssertEqual(moved.day("2026-11-19").total, 330_001)
        let csv = String(decoding: CSV.export(moved.days), as: UTF8.self)
        XCTAssertTrue(csv.contains("Asia/Tokyo,tea,330.001"))
        _ = try await store.delete(original.id, now: midnight)
        let ended = try await store.read()
        XCTAssertTrue(ended.days.isEmpty)
        XCTAssertFalse(String(decoding: CSV.export(ended.days), as: UTF8.self).contains(original.id.uuidString))
    }

    func testWidgetAndAppWriteConcurrentlyAndStaleWidgetDoesNotLog() async throws {
        let url = databaseURL()
        let app = LogStore(url: url)
        let widget = LogStore(url: url)
        let start = try await app.begin(now: midnight, zone: .gmt, free: false)
        let group = start.state.preferences.activeGroup
        let appEntry = DrinkEntry(volume: 500_000, date: midnight, zone: .gmt, now: midnight)
        let requestID = UUID()
        async let left = app.add(appEntry, milestone: true)
        async let right = widget.logFromWidget(group: group.id, amount: group.amounts[1], now: midnight, zone: .gmt, requestID: requestID)
        let (_, saved) = try await (left, right)
        XCTAssertTrue(saved)
        _ = try await widget.logFromWidget(group: group.id, amount: group.amounts[1], now: midnight, zone: .gmt, requestID: requestID)
        let both = try await app.read()
        XCTAssertEqual(both.day("2026-11-20").total, 750_000)

        _ = try await app.apply(.edit(group.id, name: nil, amounts: [150_000, 350_000, 500_000]), now: midnight, free: false)
        let stale = try await widget.logFromWidget(group: group.id, amount: group.amounts[1], now: midnight, zone: .gmt)
        XCTAssertFalse(stale)
        let fresh = try await widget.widgetReading(at: midnight, zone: .gmt)
        XCTAssertEqual(fresh.amount, 350_000)
        let tomorrow = try await widget.widgetReading(at: midnight.addingTimeInterval(86_400), zone: .gmt)
        XCTAssertEqual(tomorrow.total, 0)

        let after = midnight.addingTimeInterval(30 * 86_400)
        let expired = try await widget.widgetReading(at: after, zone: .gmt)
        XCTAssertNil(expired.amount)
        let denied = try await widget.logFromWidget(group: group.id, amount: 350_000, now: after, zone: .gmt)
        XCTAssertFalse(denied)
    }

    func testExpiredGroupKeepsActiveEditableAndOtherGroupsReadable() async throws {
        let url = databaseURL()
        let store = LogStore(url: url)
        let initial = try await store.begin(now: midnight, zone: .gmt, free: false)
        let defaultID = initial.state.preferences.activeGroup.id
        let created = try await store.apply(.add("Office", [150_000, 330_000, 500_000]), now: midnight, free: false)
        let active = created.state.preferences.activeGroup
        let end = midnight.addingTimeInterval(30 * 86_400)
        do {
            _ = try await store.apply(.activate(defaultID), now: end, free: false)
            XCTFail("Switching inactive groups requires Pro.")
        } catch StorageError.proRequired {}
        let edited = try await store.apply(.edit(active.id, name: active.name, amounts: [150_000, 350_000, 500_000]),
                                           now: end, free: false)
        XCTAssertEqual(edited.state.preferences.activeGroup.amounts[1], 350_000)
        let reopened = try await LogStore(url: url).read()
        XCTAssertEqual(reopened.state.preferences.groups.count, 2)
        XCTAssertEqual(reopened.state.preferences.activeGroup.id, active.id)
        XCTAssertEqual(reopened.state.preferences.groups.first?.amounts, CupPresetSet.defaults)
    }

    func testBackfillDefersMilestoneAndUndoClearsUnreachedMilestone() async throws {
        let url = databaseURL()
        let store = LogStore(url: url)
        _ = try await store.begin(now: midnight, zone: .gmt, free: false)
        let week = Days.week(ending: midnight, in: .gmt)
        let entries = week.map { DrinkEntry(volume: 150_000, date: $0, zone: .gmt, now: midnight) }
        for entry in entries { _ = try await store.add(entry, milestone: false) }
        let backfill = try await store.read()
        XCTAssertNil(backfill.state.preferences.pendingMilestone)

        let nextOpen = try await LogStore(url: url).begin(now: midnight.addingTimeInterval(86_400), zone: .gmt, free: false)
        XCTAssertEqual(nextOpen.state.preferences.pendingMilestone, 7)
        let deleted = try await store.delete(entries[6].id, now: midnight)
        XCTAssertEqual(deleted.days.count, 6)
        XCTAssertNil(deleted.state.preferences.pendingMilestone)
    }

    func testMigrationFailureRollsBackBeforeChangingExistingData() throws {
        let url = databaseURL()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try rawDatabase(url) { handle in
            XCTAssertEqual(sqlite3_exec(handle, "CREATE TABLE local_state (sentinel TEXT); INSERT INTO local_state VALUES ('keep me');", nil, nil, nil), SQLITE_OK)
        }
        XCTAssertThrowsError(try SQLiteDatabase(url: url))
        try rawDatabase(url) { handle in
            var statement: OpaquePointer?
            let sql = """
                SELECT sentinel, (SELECT COUNT(*) FROM sqlite_master WHERE name = 'drink_entry'),
                  (SELECT user_version FROM pragma_user_version) FROM local_state
                """
            XCTAssertEqual(sqlite3_prepare_v2(handle, sql, -1, &statement, nil), SQLITE_OK)
            guard let statement else { return XCTFail("Missing prepared statement") }
            defer { sqlite3_finalize(statement) }
            XCTAssertEqual(sqlite3_step(statement), SQLITE_ROW)
            XCTAssertEqual(try SQLiteDatabase.text(statement, 0), "keep me")
            XCTAssertEqual(sqlite3_column_int(statement, 1), 0)
            XCTAssertEqual(sqlite3_column_int(statement, 2), 0)
        }
    }

    private func rawDatabase(_ url: URL, body: (OpaquePointer) throws -> Void) throws {
        var pointer: OpaquePointer?
        let status = sqlite3_open(url.path, &pointer)
        defer { if let pointer { sqlite3_close(pointer) } }
        XCTAssertEqual(status, SQLITE_OK)
        try body(XCTUnwrap(pointer))
    }
}
