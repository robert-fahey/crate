import Foundation
import SQLite3

public struct SQLiteError: Error, CustomStringConvertible {
    public let code: Int32
    public let message: String
    public var description: String { "SQLite error \(code): \(message)" }
}

public enum SQLValue: Equatable {
    case null
    case int(Int64)
    case double(Double)
    case text(String)
    case blob(Data)

    public static func optional(_ value: String?) -> SQLValue { value.map(SQLValue.text) ?? .null }
    public static func optional(_ value: Double?) -> SQLValue { value.map(SQLValue.double) ?? .null }
    public static func optional(_ value: Int64?) -> SQLValue { value.map(SQLValue.int) ?? .null }
}

public struct SQLRow {
    fileprivate let values: [String: SQLValue]

    public func string(_ column: String) -> String? {
        if case .text(let value)? = values[column] { return value }
        return nil
    }

    public func int(_ column: String) -> Int64? {
        switch values[column] {
        case .int(let value)?: return value
        case .double(let value)?: return Int64(value)
        default: return nil
        }
    }

    public func double(_ column: String) -> Double? {
        switch values[column] {
        case .double(let value)?: return value
        case .int(let value)?: return Double(value)
        default: return nil
        }
    }

    public func data(_ column: String) -> Data? {
        if case .blob(let value)? = values[column] { return value }
        return nil
    }
}

/// A small synchronous SQLite wrapper. One connection, guarded by a lock, so
/// the UI, the scanner and agent tools can all use the same store.
public final class SQLiteDB {
    private var handle: OpaquePointer?
    private let lock = NSRecursiveLock()
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    public init(path: String) throws {
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(path, &handle, flags, nil) == SQLITE_OK else {
            let error = lastError()
            sqlite3_close(handle)
            throw error
        }
        try execute("PRAGMA journal_mode = WAL")
        try execute("PRAGMA foreign_keys = ON")
    }

    deinit { sqlite3_close(handle) }

    private func lastError() -> SQLiteError {
        SQLiteError(code: sqlite3_errcode(handle), message: String(cString: sqlite3_errmsg(handle)))
    }

    public var lastInsertRowID: Int64 { sqlite3_last_insert_rowid(handle) }
    public var changes: Int { Int(sqlite3_changes(handle)) }

    @discardableResult
    public func execute(_ sql: String, _ params: [SQLValue] = []) throws -> Int {
        _ = try query(sql, params)
        return changes
    }

    public func query(_ sql: String, _ params: [SQLValue] = []) throws -> [SQLRow] {
        lock.lock()
        defer { lock.unlock() }

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else { throw lastError() }
        defer { sqlite3_finalize(statement) }

        for (index, param) in params.enumerated() {
            let position = Int32(index + 1)
            let status: Int32
            switch param {
            case .null: status = sqlite3_bind_null(statement, position)
            case .int(let value): status = sqlite3_bind_int64(statement, position, value)
            case .double(let value): status = sqlite3_bind_double(statement, position, value)
            case .text(let value): status = sqlite3_bind_text(statement, position, value, -1, Self.transient)
            case .blob(let value):
                status = value.withUnsafeBytes {
                    sqlite3_bind_blob(statement, position, $0.baseAddress, Int32(value.count), Self.transient)
                }
            }
            guard status == SQLITE_OK else { throw lastError() }
        }

        var rows: [SQLRow] = []
        let columnCount = sqlite3_column_count(statement)
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else { throw lastError() }
            var values: [String: SQLValue] = [:]
            for column in 0..<columnCount {
                let name = String(cString: sqlite3_column_name(statement, column))
                switch sqlite3_column_type(statement, column) {
                case SQLITE_INTEGER: values[name] = .int(sqlite3_column_int64(statement, column))
                case SQLITE_FLOAT: values[name] = .double(sqlite3_column_double(statement, column))
                case SQLITE_TEXT: values[name] = .text(String(cString: sqlite3_column_text(statement, column)))
                case SQLITE_BLOB:
                    let count = Int(sqlite3_column_bytes(statement, column))
                    if let bytes = sqlite3_column_blob(statement, column) {
                        values[name] = .blob(Data(bytes: bytes, count: count))
                    } else {
                        values[name] = .blob(Data())
                    }
                default: values[name] = .null
                }
            }
            rows.append(SQLRow(values: values))
        }
        return rows
    }

    public func transaction<T>(_ body: () throws -> T) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        try execute("BEGIN IMMEDIATE")
        do {
            let result = try body()
            try execute("COMMIT")
            return result
        } catch {
            _ = try? execute("ROLLBACK")
            throw error
        }
    }
}
