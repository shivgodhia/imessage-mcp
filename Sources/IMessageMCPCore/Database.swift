import Foundation
import SQLite3

/// One value read from or bound to SQLite.
public enum SQLValue {
    case null
    case int(Int64)
    case double(Double)
    case text(String)
    case blob(Data)

    var int: Int64 {
        switch self {
        case .int(let v): return v
        case .double(let v): return Int64(v)
        case .text(let v): return Int64(v) ?? 0
        default: return 0
        }
    }

    var string: String? {
        switch self {
        case .text(let v): return v
        case .int(let v): return String(v)
        default: return nil
        }
    }

    var data: Data? {
        if case .blob(let v) = self { return v }
        return nil
    }
}

struct SQLiteError: Error {
    let message: String
}

/// A read-only SQLite connection. Nothing in this project writes to a database.
final class Database {
    private var handle: OpaquePointer?

    init(path: String) throws {
        if sqlite3_open_v2(path, &handle, SQLITE_OPEN_READONLY, nil) != SQLITE_OK {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "cannot open"
            sqlite3_close(handle)
            throw SQLiteError(message: message)
        }
        sqlite3_busy_timeout(handle, 5000)
        // Opening is lazy; this is what actually fails when macOS blocks the file.
        _ = try query("select 1 from sqlite_master limit 1")
    }

    deinit {
        sqlite3_close(handle)
    }

    /// Runs a query, handing each row to `body`. Return false from `body` to stop early.
    func forEach(_ sql: String, _ params: [SQLValue] = [], _ body: ([SQLValue]) -> Bool) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
            throw SQLiteError(message: String(cString: sqlite3_errmsg(handle)))
        }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (i, param) in params.enumerated() {
            let index = Int32(i + 1)
            switch param {
            case .null: sqlite3_bind_null(statement, index)
            case .int(let v): sqlite3_bind_int64(statement, index, v)
            case .double(let v): sqlite3_bind_double(statement, index, v)
            case .text(let v): sqlite3_bind_text(statement, index, v, -1, transient)
            case .blob(let v):
                _ = v.withUnsafeBytes {
                    sqlite3_bind_blob(statement, index, $0.baseAddress, Int32(v.count), transient)
                }
            }
        }
        let columns = sqlite3_column_count(statement)
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { return }
            guard step == SQLITE_ROW else {
                throw SQLiteError(message: String(cString: sqlite3_errmsg(handle)))
            }
            var row: [SQLValue] = []
            row.reserveCapacity(Int(columns))
            for c in 0..<columns {
                switch sqlite3_column_type(statement, c) {
                case SQLITE_INTEGER:
                    row.append(.int(sqlite3_column_int64(statement, c)))
                case SQLITE_FLOAT:
                    row.append(.double(sqlite3_column_double(statement, c)))
                case SQLITE_TEXT:
                    row.append(.text(String(cString: sqlite3_column_text(statement, c))))
                case SQLITE_BLOB:
                    let count = Int(sqlite3_column_bytes(statement, c))
                    if let bytes = sqlite3_column_blob(statement, c), count > 0 {
                        row.append(.blob(Data(bytes: bytes, count: count)))
                    } else {
                        row.append(.blob(Data()))
                    }
                default:
                    row.append(.null)
                }
            }
            if !body(row) { return }
        }
    }

    func query(_ sql: String, _ params: [SQLValue] = []) throws -> [[SQLValue]] {
        var rows: [[SQLValue]] = []
        try forEach(sql, params) { rows.append($0); return true }
        return rows
    }
}
