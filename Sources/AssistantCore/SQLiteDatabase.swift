import Foundation
import SQLite3

public enum SQLiteStoreError: Error, CustomStringConvertible {
    case open(String)
    case execute(String)
    case prepare(String)
    case step(String)
    case invalidRow(String)

    public var description: String {
        switch self {
        case let .open(message):
            return "SQLite open failed: \(message)"
        case let .execute(message):
            return "SQLite execute failed: \(message)"
        case let .prepare(message):
            return "SQLite prepare failed: \(message)"
        case let .step(message):
            return "SQLite step failed: \(message)"
        case let .invalidRow(message):
            return "SQLite invalid row: \(message)"
        }
    }
}

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

final class SQLiteDatabase {
    private var handle: OpaquePointer?

    init(url: URL) throws {
        if url.path != ":memory:" {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: nil
            )
        }
        var database: OpaquePointer?
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        let result = sqlite3_open_v2(url.path, &database, flags, nil)
        guard result == SQLITE_OK, let database else {
            let message = database.map { String(cString: sqlite3_errmsg($0)) }
                ?? "unknown error"
            if let database {
                sqlite3_close(database)
            }
            throw SQLiteStoreError.open(message)
        }
        handle = database
        sqlite3_busy_timeout(database, 5_000)
    }

    deinit {
        if let handle {
            sqlite3_close(handle)
        }
    }

    var changes: Int {
        Int(sqlite3_changes(handle))
    }

    func execute(_ sql: String) throws {
        var errorMessage: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(handle, sql, nil, nil, &errorMessage)
        guard result == SQLITE_OK else {
            let message = errorMessage.map { String(cString: $0) }
                ?? currentErrorMessage
            sqlite3_free(errorMessage)
            throw SQLiteStoreError.execute(message)
        }
    }

    func prepare(_ sql: String) throws -> SQLiteStatement {
        var statement: OpaquePointer?
        let result = sqlite3_prepare_v2(handle, sql, -1, &statement, nil)
        guard result == SQLITE_OK, let statement else {
            throw SQLiteStoreError.prepare(currentErrorMessage)
        }
        return SQLiteStatement(database: self, handle: statement)
    }

    var currentErrorMessage: String {
        handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
    }
}

final class SQLiteStatement {
    private weak var database: SQLiteDatabase?
    private var handle: OpaquePointer?

    init(database: SQLiteDatabase, handle: OpaquePointer) {
        self.database = database
        self.handle = handle
    }

    deinit {
        if let handle {
            sqlite3_finalize(handle)
        }
    }

    func bind(_ index: Int32, _ value: String) {
        sqlite3_bind_text(handle, index, (value as NSString).utf8String, -1, sqliteTransient)
    }

    func bind(_ index: Int32, _ value: Int) {
        sqlite3_bind_int64(handle, index, sqlite3_int64(value))
    }

    func bind(_ index: Int32, _ value: Double) {
        sqlite3_bind_double(handle, index, value)
    }

    func bind(_ index: Int32, _ value: Data) {
        value.withUnsafeBytes { bytes in
            sqlite3_bind_blob(
                handle,
                index,
                bytes.baseAddress,
                Int32(bytes.count),
                sqliteTransient
            )
        }
    }

    func bindNull(_ index: Int32) {
        sqlite3_bind_null(handle, index)
    }

    func step() throws -> Int32 {
        let result = sqlite3_step(handle)
        if result == SQLITE_ROW || result == SQLITE_DONE {
            return result
        }
        let message = database?.currentErrorMessage ?? "unknown error"
        throw SQLiteStoreError.step(message)
    }

    func text(_ column: Int32) -> String? {
        guard let pointer = sqlite3_column_text(handle, column) else {
            return nil
        }
        return String(cString: pointer)
    }

    func int(_ column: Int32) -> Int {
        Int(sqlite3_column_int64(handle, column))
    }

    func double(_ column: Int32) -> Double {
        sqlite3_column_double(handle, column)
    }

    func data(_ column: Int32) -> Data? {
        guard let pointer = sqlite3_column_blob(handle, column) else {
            return nil
        }
        return Data(bytes: pointer, count: Int(sqlite3_column_bytes(handle, column)))
    }
}
