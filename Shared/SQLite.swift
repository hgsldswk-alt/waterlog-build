import Foundation
import SQLite3

enum StorageError: Error {
    case sqlite(Int32, String)
    case unsupportedSchema(Int)
    case unavailable
    case corrupted
    case invalidInput
    case missingEntry
    case proRequired
}

final class SQLiteDatabase {
    private let handle: OpaquePointer
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    enum Value {
        case integer(Int)
        case real(Double)
        case text(String)
        case blob(Data)
        case null
    }

    init(url: URL) throws {
        var pointer: OpaquePointer?
        let result = sqlite3_open_v2(url.path, &pointer, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil)
        guard result == SQLITE_OK, let pointer else {
            if let pointer { sqlite3_close(pointer) }
            throw StorageError.sqlite(result, "open")
        }
        handle = pointer
        sqlite3_busy_timeout(handle, 5000)
        guard try schemaVersion() != 1 else { return }
        try transaction {
            let version = try schemaVersion()
            switch version {
            case 0:
                try execute("""
                    CREATE TABLE drink_entry (
                        id TEXT PRIMARY KEY NOT NULL, volume INTEGER NOT NULL CHECK (volume BETWEEN 1000 AND 5000000),
                        drink TEXT NOT NULL, consumed_at REAL NOT NULL, zone TEXT NOT NULL, day TEXT NOT NULL,
                        created_at REAL NOT NULL, updated_at REAL NOT NULL, deleted_at REAL
                    )
                    """)
                try execute("CREATE INDEX live_entries_by_day ON drink_entry(day, consumed_at) WHERE deleted_at IS NULL")
                try execute("CREATE TABLE local_state (id INTEGER PRIMARY KEY CHECK (id = 1), data BLOB NOT NULL)")
                try execute("PRAGMA user_version = 1")
            case 1: break
            default: throw StorageError.unsupportedSchema(version)
            }
        }
    }

    deinit { sqlite3_close(handle) }

    private func schemaVersion() throws -> Int {
        try query("PRAGMA user_version") { Int(sqlite3_column_int($0, 0)) }.first ?? -1
    }

    func transaction<Result>(write: Bool = true, _ work: () throws -> Result) throws -> Result {
        try execute(write ? "BEGIN IMMEDIATE" : "BEGIN")
        do {
            let result = try work()
            try execute("COMMIT")
            return result
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    func execute(_ sql: String, _ values: [Value] = []) throws {
        try withStatement(sql, values) {
            let result = sqlite3_step($0)
            guard result == SQLITE_DONE else { throw failure(result) }
        }
    }

    func query<T>(_ sql: String, _ values: [Value] = [], row: (OpaquePointer) throws -> T) throws -> [T] {
        try withStatement(sql, values) { statement in
            var rows: [T] = []
            var result = sqlite3_step(statement)
            while result == SQLITE_ROW {
                rows.append(try row(statement))
                result = sqlite3_step(statement)
            }
            guard result == SQLITE_DONE else { throw failure(result) }
            return rows
        }
    }

    var changedRows: Int { Int(sqlite3_changes(handle)) }

    private func withStatement<T>(_ sql: String, _ values: [Value], _ work: (OpaquePointer) throws -> T) throws -> T {
        var prepared: OpaquePointer?
        let result = sqlite3_prepare_v2(handle, sql, -1, &prepared, nil)
        guard result == SQLITE_OK, let statement = prepared else { throw failure(result) }
        defer { sqlite3_finalize(statement) }
        for (offset, value) in values.enumerated() {
            let i = Int32(offset + 1)
            let status: Int32
            switch value {
            case .integer(let value): status = sqlite3_bind_int64(statement, i, Int64(value))
            case .real(let value): status = sqlite3_bind_double(statement, i, value)
            case .text(let value): status = value.withCString { sqlite3_bind_text(statement, i, $0, -1, Self.transient) }
            case .blob(let value):
                status = value.withUnsafeBytes { sqlite3_bind_blob(statement, i, $0.baseAddress, Int32($0.count), Self.transient) }
            case .null: status = sqlite3_bind_null(statement, i)
            }
            guard status == SQLITE_OK else { throw failure(status) }
        }
        return try work(statement)
    }

    private func failure(_ result: Int32) -> StorageError {
        .sqlite(result, String(cString: sqlite3_errmsg(handle)))
    }

    static func text(_ statement: OpaquePointer, _ column: Int32) throws -> String {
        guard let bytes = sqlite3_column_text(statement, column) else { throw StorageError.corrupted }
        return String(cString: bytes)
    }
}

extension SQLiteDatabase.Value {
    static func date(_ date: Date) -> Self { .real(date.timeIntervalSince1970) }
}
