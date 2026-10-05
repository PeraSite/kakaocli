import CSQLCipher
import Foundation

/// Reads KakaoTalk's encrypted SQLite database using SQLCipher.
public final class DatabaseReader: @unchecked Sendable {
    private var db: OpaquePointer?
    public let databasePath: String

    public init(databasePath: String) {
        self.databasePath = databasePath
    }

    deinit {
        close()
    }

    /// Open the database. If a key is provided, attempts PRAGMA key (requires SQLCipher).
    /// Tries cipher compatibility modes 3 and 4 (for newer KakaoTalk versions).
    public func open(key: String? = nil) throws {
        guard FileManager.default.fileExists(atPath: databasePath) else {
            throw KakaoError.databaseNotFound(databasePath)
        }

        if let key {
            // Try compatibility mode 3 first (legacy), then 4 (newer versions)
            let compatModes = [3, 4]
            for compat in compatModes {
                // Close previous attempt if any
                if db != nil { sqlite3_close(db); db = nil }

                let result = sqlite3_open_v2(
                    databasePath, &db,
                    SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil
                )
                guard result == SQLITE_OK else {
                    let msg = db.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
                    throw KakaoError.databaseOpenFailed(msg)
                }

                do {
                    try exec("PRAGMA cipher_default_compatibility = \(compat)")
                    try exec("PRAGMA KEY='\(key.replacingOccurrences(of: "'", with: "''"))'")
                    try exec("PRAGMA cipher_compatibility = \(compat)")
                    try exec("SELECT count(*) FROM sqlite_master")
                    try installReadOnlyGuard()
                    return // success
                } catch {
                    continue
                }
            }
            throw KakaoError.databaseOpenFailed(
                "PRAGMA key failed with all cipher compatibility modes — " +
                "database is encrypted and key may be wrong, or SQLCipher may not be linked. " +
                "Install via: brew install sqlcipher"
            )
        } else {
            let result = sqlite3_open_v2(
                databasePath, &db,
                SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil
            )
            guard result == SQLITE_OK else {
                let msg = db.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
                throw KakaoError.databaseOpenFailed(msg)
            }
            try installReadOnlyGuard()
        }
    }

    private func installReadOnlyGuard() throws {
        try exec("PRAGMA query_only=ON")
        sqlite3_busy_timeout(db, 5000)
        sqlite3_set_authorizer(db, { _, action, arg1, arg2, _, _ in
            switch action {
            case SQLITE_ATTACH, SQLITE_DETACH, SQLITE_INSERT, SQLITE_UPDATE, SQLITE_DELETE,
                 SQLITE_CREATE_TABLE, SQLITE_CREATE_INDEX, SQLITE_CREATE_TRIGGER, SQLITE_CREATE_VIEW,
                 SQLITE_CREATE_TEMP_TABLE, SQLITE_CREATE_TEMP_INDEX, SQLITE_CREATE_TEMP_TRIGGER, SQLITE_CREATE_TEMP_VIEW,
                 SQLITE_DROP_TABLE, SQLITE_DROP_INDEX, SQLITE_DROP_TRIGGER, SQLITE_DROP_VIEW, SQLITE_ALTER_TABLE:
                return SQLITE_DENY
            case SQLITE_FUNCTION:
                if arg2.map({ String(cString: $0).lowercased() }) == "load_extension" { return SQLITE_DENY }
            case SQLITE_PRAGMA:
                let name = arg1.map { String(cString: $0).lowercased() } ?? ""
                let inspections = ["integrity_check", "quick_check", "table_info", "table_xinfo", "index_info", "index_xinfo", "index_list", "foreign_key_list", "foreign_key_check"]
                if arg2 != nil && !inspections.contains(name) { return SQLITE_DENY }
            default: break
            }
            return SQLITE_OK
        }, nil)
    }

    /// Try opening the database with a key. Returns true if the key is valid.
    public func tryOpen(key: String) -> Bool {
        do {
            try open(key: key)
            return true
        } catch {
            close()
            return false
        }
    }

    public func close() {
        if let db {
            sqlite3_close(db)
        }
        db = nil
    }

    // MARK: - Queries

    /// List all chat rooms.
    public func chats(limit: Int = 50, offset: Int = 0, kind: String? = nil, contacted: Bool = false) throws -> [Chat] {
        let all = try localChats().filter { $0.kind.matches(kind) && (!contacted || $0.sentMessageCount > 0) }
        return Array(all.dropFirst(max(0, offset)).prefix(max(0, limit)))
    }

    /// Get messages for a chat, optionally filtered by time.
    public func messages(chatId: Int64? = nil, since: Date? = nil, limit: Int = 50, offset: Int = 0, sender: String = "any") throws -> [Message] {
        try localMessages(chatId: chatId, since: since, limit: limit, offset: offset, sender: sender)
    }

    /// Full-text search across messages.
    public func search(query: String, limit: Int = 20, offset: Int = 0, chatId: Int64? = nil, sender: String = "any") throws -> [Message] {
        try localMessages(chatId: chatId, text: query, limit: limit, offset: offset, sender: sender)
    }

    /// Get the logged-in user's ID from NTChatContext.
    public func myUserId() throws -> Int64 {
        let results = try query("SELECT userId FROM NTChatContext LIMIT 1", bind: []) { row in
            row.int64(0)
        }
        return results.first ?? 0
    }

    /// Get the maximum logId in the messages table (used by DatabaseWatcher).
    public func maxLogId() throws -> Int64 {
        let results = try query("SELECT MAX(logId) FROM NTChatMessage", bind: []) { row in
            row.optionalInt64(0)
        }
        return results.first.flatMap { $0 } ?? 0
    }

    /// Get messages with logId strictly greater than the given value.
    /// Returns SyncMessage structs suitable for JSON streaming.
    public func messagesSince(logId: Int64, myUserId: Int64) throws -> [SyncMessage] {
        let sql = """
            SELECT m.logId, m.chatId,
                   COALESCE(r.chatName, u.displayName, u.friendNickName, u.nickName) as chatName,
                   m.authorId,
                   COALESCE(u2.displayName, u2.friendNickName, u2.nickName) as senderName,
                   m.message, m.type, m.sentAt
            FROM NTChatMessage m
            LEFT JOIN NTChatRoom r ON m.chatId = r.chatId
            LEFT JOIN NTUser u ON r.directChatMemberUserId = u.userId AND u.linkId = 0
            LEFT JOIN NTUser u2 ON m.authorId = u2.userId AND u2.linkId = 0
            WHERE m.logId > ?
            ORDER BY m.logId ASC
            LIMIT 100
            """
        let formatter = ISO8601DateFormatter()
        return try query(sql, bind: [.int64(logId)]) { row in
            SyncMessage(
                type: "message",
                logId: row.int64(0),
                chatId: row.int64(1),
                chatName: row.string(2),
                senderId: row.int64(3),
                senderName: row.string(4),
                text: row.string(5),
                messageType: row.int(6),
                timestamp: formatter.string(from: row.kakaoDate(7)),
                isFromMe: row.int64(3) == myUserId
            )
        }
    }

    /// Run an arbitrary read-only SQL query and return results as arrays of Any.
    public func rawQuery(_ sql: String) throws -> [[Any]] {
        var stmt: OpaquePointer?
        var extra = ""
        let status = sql.withCString { pointer in
            var tail: UnsafePointer<CChar>?
            let status = sqlite3_prepare_v2(db, pointer, -1, &stmt, &tail)
            if let tail { extra = String(cString: tail).trimmingCharacters(in: .whitespacesAndNewlines) }
            return status
        }
        guard status == SQLITE_OK, stmt != nil else {
            let msg = db.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            throw KakaoError.sqlError("prepare: \(msg)")
        }
        defer { sqlite3_finalize(stmt) }
        guard extra.isEmpty, sqlite3_stmt_readonly(stmt) != 0 else { throw KakaoError.sqlError("One read-only SQL statement is required") }

        let colCount = sqlite3_column_count(stmt)
        var results: [[Any]] = []
        var step = sqlite3_step(stmt)
        while step == SQLITE_ROW {
            var row: [Any] = []
            for i in 0..<colCount {
                switch sqlite3_column_type(stmt, i) {
                case SQLITE_INTEGER:
                    row.append(sqlite3_column_int64(stmt, i))
                case SQLITE_FLOAT:
                    row.append(sqlite3_column_double(stmt, i))
                case SQLITE_TEXT:
                    row.append(String(cString: sqlite3_column_text(stmt, i)))
                case SQLITE_NULL:
                    row.append("")
                default:
                    row.append("")
                }
            }
            results.append(row)
            step = sqlite3_step(stmt)
        }
        guard step == SQLITE_DONE else { throw KakaoError.sqlError(String(cString: sqlite3_errmsg(db))) }
        return results
    }

    public func rawNamedQuery(_ sql: String) throws -> [[String: Any]] {
        var stmt: OpaquePointer?
        var extra = ""
        let status = sql.withCString { pointer in
            var tail: UnsafePointer<CChar>?
            let status = sqlite3_prepare_v2(db, pointer, -1, &stmt, &tail)
            if let tail { extra = String(cString: tail).trimmingCharacters(in: .whitespacesAndNewlines) }
            return status
        }
        guard status == SQLITE_OK, let stmt else { throw KakaoError.sqlError(String(cString: sqlite3_errmsg(db))) }
        defer { sqlite3_finalize(stmt) }
        guard extra.isEmpty, sqlite3_stmt_readonly(stmt) != 0 else {
            throw KakaoError.sqlError("One read-only SQL statement is required")
        }
        let columns = (0..<sqlite3_column_count(stmt)).map { String(cString: sqlite3_column_name(stmt, $0)) }
        var rows: [[String: Any]] = [], step = sqlite3_step(stmt)
        while step == SQLITE_ROW {
            var row: [String: Any] = [:]
            for i in 0..<sqlite3_column_count(stmt) {
                let name = columns[Int(i)]
                switch sqlite3_column_type(stmt, i) {
                case SQLITE_INTEGER:
                    let value = sqlite3_column_int64(stmt, i)
                    row[name] = name.lowercased().hasSuffix("id") ? String(value) : value as Any
                case SQLITE_FLOAT: row[name] = sqlite3_column_double(stmt, i)
                case SQLITE_TEXT: row[name] = String(cString: sqlite3_column_text(stmt, i))
                default: row[name] = NSNull()
                }
            }
            rows.append(row); step = sqlite3_step(stmt)
        }
        guard step == SQLITE_DONE else { throw KakaoError.sqlError(String(cString: sqlite3_errmsg(db))) }
        return rows
    }

    /// Discover the actual database schema.
    public func schema() throws -> [(name: String, sql: String)] {
        try query(
            "SELECT name, sql FROM sqlite_master WHERE type='table' ORDER BY name",
            bind: []
        ) { row in
            (name: row.string(0) ?? "", sql: row.string(1) ?? "")
        }
    }

    // MARK: - SQLite Helpers

    enum SQLValue {
        case int(Int)
        case int64(Int64)
        case double(Double)
        case string(String)
        case null
    }

    func exec(_ sql: String) throws {
        var errMsg: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(db, sql, nil, nil, &errMsg)
        if result != SQLITE_OK {
            let msg = errMsg.map { String(cString: $0) } ?? "unknown error"
            sqlite3_free(errMsg)
            throw KakaoError.sqlError(msg)
        }
    }

    func query<T>(_ sql: String, bind: [SQLValue], transform: (Row) -> T) throws -> [T] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            let msg = db.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            throw KakaoError.sqlError("prepare: \(msg)")
        }
        defer { sqlite3_finalize(stmt) }

        for (i, value) in bind.enumerated() {
            let idx = Int32(i + 1)
            switch value {
            case .int(let v): sqlite3_bind_int64(stmt, idx, Int64(v))
            case .int64(let v): sqlite3_bind_int64(stmt, idx, v)
            case .double(let v): sqlite3_bind_double(stmt, idx, v)
            case .string(let v): sqlite3_bind_text(stmt, idx, v, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            case .null: sqlite3_bind_null(stmt, idx)
            }
        }

        var results: [T] = []
        var status = sqlite3_step(stmt)
        while status == SQLITE_ROW {
            results.append(transform(Row(stmt: stmt!)))
            status = sqlite3_step(stmt)
        }
        guard status == SQLITE_DONE else { throw KakaoError.sqlError(String(cString: sqlite3_errmsg(db))) }
        return results
    }

    struct Row {
        let stmt: OpaquePointer

        func int(_ col: Int32) -> Int {
            Int(sqlite3_column_int(stmt, col))
        }

        func int64(_ col: Int32) -> Int64 {
            sqlite3_column_int64(stmt, col)
        }

        func optionalInt64(_ col: Int32) -> Int64? {
            sqlite3_column_type(stmt, col) == SQLITE_NULL ? nil : int64(col)
        }

        func string(_ col: Int32) -> String? {
            guard let ptr = sqlite3_column_text(stmt, col) else { return nil }
            return String(cString: ptr)
        }

        func bool(_ col: Int32) -> Bool {
            sqlite3_column_int(stmt, col) != 0
        }

        func data(_ col: Int32) -> Data? {
            guard let ptr = sqlite3_column_blob(stmt, col) else { return nil }
            return Data(bytes: ptr, count: Int(sqlite3_column_bytes(stmt, col)))
        }

        /// KakaoTalk stores timestamps as seconds since epoch.
        func kakaoDate(_ col: Int32) -> Date {
            let ts = sqlite3_column_int64(stmt, col)
            return Date(timeIntervalSince1970: Double(ts))
        }

        func optionalKakaoDate(_ col: Int32) -> Date? {
            let val = sqlite3_column_int64(stmt, col)
            return val == 0 ? nil : Date(timeIntervalSince1970: Double(val))
        }
    }
}
