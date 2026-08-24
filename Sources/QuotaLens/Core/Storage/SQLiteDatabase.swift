// QuotaLens 原生 SQLite 驱动与连接管理器
// 支持 WAL 模式、外键约束、互斥锁保护、预编译语句与事务回滚

import Foundation
import SQLite3

public final class SQLiteDatabase: @unchecked Sendable {
    private var dbPointer: OpaquePointer?
    private let lock = NSRecursiveLock()
    private let dbPath: String

    public init(path: String) throws {
        self.dbPath = path
        let fileManager = FileManager.default
        let directory = (path as NSString).deletingLastPathComponent
        if !fileManager.fileExists(atPath: directory) {
            try fileManager.createDirectory(
                atPath: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        } else {
            try? fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory)
        }

        var pointer: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        let status = sqlite3_open_v2(path, &pointer, flags, nil)
        guard status == SQLITE_OK, let db = pointer else {
            let errorMsg = pointer != nil ? String(cString: sqlite3_errmsg(pointer)) : "无法打开 SQLite 数据库"
            if let db = pointer { sqlite3_close(db) }
            throw NSError(domain: "SQLiteDatabase", code: Int(status), userInfo: [NSLocalizedDescriptionKey: errorMsg])
        }
        self.dbPointer = db

        // 配置 WAL 模式与性能参数
        try execute(sql: "PRAGMA journal_mode = WAL;")
        try execute(sql: "PRAGMA synchronous = NORMAL;")
        try execute(sql: "PRAGMA foreign_keys = ON;")
        try execute(sql: "PRAGMA busy_timeout = 5000;")
        try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
    }

    deinit {
        lock.lock()
        defer { lock.unlock() }
        if let db = dbPointer {
            sqlite3_close(db)
            dbPointer = nil
        }
    }

    /// 获取最后插入的行 ID
    public var lastInsertRowID: Int64 {
        lock.lock()
        defer { lock.unlock() }
        guard let db = dbPointer else { return 0 }
        return sqlite3_last_insert_rowid(db)
    }

    /// 执行无返回值的 SQL
    public func execute(sql: String) throws {
        lock.lock()
        defer { lock.unlock() }
        guard let db = dbPointer else {
            throw NSError(domain: "SQLiteDatabase", code: -1, userInfo: [NSLocalizedDescriptionKey: "数据库未连接"])
        }

        var errorMsg: UnsafeMutablePointer<CChar>?
        let status = sqlite3_exec(db, sql, nil, nil, &errorMsg)
        if status != SQLITE_OK {
            let message = errorMsg != nil ? String(cString: errorMsg!) : "SQL 执行失败: \(status)"
            sqlite3_free(errorMsg)
            throw NSError(domain: "SQLiteDatabase", code: Int(status), userInfo: [NSLocalizedDescriptionKey: message])
        }
    }

    /// 执行带参数绑定的 SQL
    public func execute(sql: String, bindings: [Any?]) throws {
        try executeUpdate(sql: sql, bindings: bindings)
    }

    /// 事务封装
    public func transaction<T>(_ block: () throws -> T) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        guard let db = dbPointer else {
            throw NSError(domain: "SQLiteDatabase", code: -1, userInfo: [NSLocalizedDescriptionKey: "数据库未连接"])
        }

        sqlite3_exec(db, "BEGIN IMMEDIATE TRANSACTION;", nil, nil, nil)
        do {
            let result = try block()
            sqlite3_exec(db, "COMMIT TRANSACTION;", nil, nil, nil)
            return result
        } catch {
            sqlite3_exec(db, "ROLLBACK TRANSACTION;", nil, nil, nil)
            throw error
        }
    }

    /// 参数化执行更新/插入
    public func executeUpdate(sql: String, bindings: [Any?]) throws {
        lock.lock()
        defer { lock.unlock() }
        guard let db = dbPointer else {
            throw NSError(domain: "SQLiteDatabase", code: -1, userInfo: [NSLocalizedDescriptionKey: "数据库未连接"])
        }

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let stmt = statement else {
            let errorMsg = String(cString: sqlite3_errmsg(db))
            throw NSError(domain: "SQLiteDatabase", code: -1, userInfo: [NSLocalizedDescriptionKey: "Prepare 失败: \(errorMsg)"])
        }
        defer { sqlite3_finalize(stmt) }

        try bindParameters(stmt: stmt, bindings: bindings)

        let stepResult = sqlite3_step(stmt)
        if stepResult != SQLITE_DONE && stepResult != SQLITE_ROW {
            let errorMsg = String(cString: sqlite3_errmsg(db))
            throw NSError(domain: "SQLiteDatabase", code: Int(stepResult), userInfo: [NSLocalizedDescriptionKey: "Step 失败: \(errorMsg)"])
        }
    }

    /// 参数化查询多行
    public func executeQuery<T>(sql: String, bindings: [Any?] = [], rowMapper: (OpaquePointer) throws -> T) throws -> [T] {
        lock.lock()
        defer { lock.unlock() }
        guard let db = dbPointer else {
            throw NSError(domain: "SQLiteDatabase", code: -1, userInfo: [NSLocalizedDescriptionKey: "数据库未连接"])
        }

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let stmt = statement else {
            let errorMsg = String(cString: sqlite3_errmsg(db))
            throw NSError(domain: "SQLiteDatabase", code: -1, userInfo: [NSLocalizedDescriptionKey: "Prepare 失败: \(errorMsg)"])
        }
        defer { sqlite3_finalize(stmt) }

        try bindParameters(stmt: stmt, bindings: bindings)

        var results: [T] = []
        var stepResult = sqlite3_step(stmt)
        while stepResult == SQLITE_ROW {
            let item = try rowMapper(stmt)
            results.append(item)
            stepResult = sqlite3_step(stmt)
        }

        if stepResult != SQLITE_DONE {
            let errorMsg = String(cString: sqlite3_errmsg(db))
            throw NSError(domain: "SQLiteDatabase", code: Int(stepResult), userInfo: [NSLocalizedDescriptionKey: "查询失败: \(errorMsg)"])
        }
        return results
    }

    /// 查询 Int 标量值（如 PRAGMA user_version）
    public func intScalar(sql: String, bindings: [Any?] = []) throws -> Int {
        let values: [Int] = try executeQuery(sql: sql, bindings: bindings) { stmt in
            Int(sqlite3_column_int(stmt, 0))
        }
        return values.first ?? 0
    }

    /// 查询 Int64 标量值
    public func int64Scalar(sql: String, bindings: [Any?] = []) throws -> Int64? {
        let values: [Int64] = try executeQuery(sql: sql, bindings: bindings) { stmt in
            sqlite3_column_type(stmt, 0) == SQLITE_NULL ? nil : sqlite3_column_int64(stmt, 0)
        }.compactMap { $0 }
        return values.first
    }

    /// 查询 String 标量值
    public func stringScalar(sql: String, bindings: [Any?] = []) throws -> String? {
        let values: [String] = try executeQuery(sql: sql, bindings: bindings) { stmt in
            guard sqlite3_column_type(stmt, 0) != SQLITE_NULL,
                  let text = sqlite3_column_text(stmt, 0) else { return nil }
            return String(cString: text)
        }.compactMap { $0 }
        return values.first
    }

    /// 预编译语句上下文
    public func withPreparedStatement<T>(sql: String, _ body: (OpaquePointer) throws -> T) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        guard let db = dbPointer else {
            throw NSError(domain: "SQLiteDatabase", code: -1, userInfo: [NSLocalizedDescriptionKey: "数据库未连接"])
        }

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let stmt = statement else {
            let errorMsg = String(cString: sqlite3_errmsg(db))
            throw NSError(domain: "SQLiteDatabase", code: -1, userInfo: [NSLocalizedDescriptionKey: "Prepare 失败: \(errorMsg)"])
        }
        defer { sqlite3_finalize(stmt) }

        return try body(stmt)
    }

    /// 使用 SQLite Online Backup API 备份数据库到指定目标
    public func backup(to destinationURL: URL) throws {
        lock.lock()
        defer { lock.unlock() }
        guard let sourceDb = dbPointer else {
            throw NSError(domain: "SQLiteDatabase", code: -1, userInfo: [NSLocalizedDescriptionKey: "源数据库未连接"])
        }

        let fileManager = FileManager.default
        let targetDir = destinationURL.deletingLastPathComponent()
        if !fileManager.fileExists(atPath: targetDir.path) {
            try fileManager.createDirectory(at: targetDir, withIntermediateDirectories: true)
        }

        var destDb: OpaquePointer?
        let status = sqlite3_open_v2(destinationURL.path, &destDb, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil)
        guard status == SQLITE_OK, let target = destDb else {
            let errorMsg = destDb != nil ? String(cString: sqlite3_errmsg(destDb)) : "无法创建备份目标数据库"
            if let destDb { sqlite3_close(destDb) }
            throw NSError(domain: "SQLiteDatabase", code: Int(status), userInfo: [NSLocalizedDescriptionKey: errorMsg])
        }
        defer { sqlite3_close(target) }

        guard let backup = sqlite3_backup_init(target, "main", sourceDb, "main") else {
            let errorMsg = String(cString: sqlite3_errmsg(target))
            throw NSError(domain: "SQLiteDatabase", code: -1, userInfo: [NSLocalizedDescriptionKey: "初始化备份失败: \(errorMsg)"])
        }
        defer { sqlite3_backup_finish(backup) }

        let stepResult = sqlite3_backup_step(backup, -1)
        if stepResult != SQLITE_DONE {
            let errorMsg = String(cString: sqlite3_errmsg(target))
            throw NSError(domain: "SQLiteDatabase", code: Int(stepResult), userInfo: [NSLocalizedDescriptionKey: "备份复制失败: \(errorMsg)"])
        }
    }

    private func bindParameters(stmt: OpaquePointer, bindings: [Any?]) throws {
        for (index, value) in bindings.enumerated() {
            let col = Int32(index + 1)
            guard let val = value else {
                sqlite3_bind_null(stmt, col)
                continue
            }

            if let intVal = val as? Int64 {
                sqlite3_bind_int64(stmt, col, intVal)
            } else if let intVal = val as? Int {
                sqlite3_bind_int64(stmt, col, Int64(intVal))
            } else if let intVal = val as? Int32 {
                sqlite3_bind_int(stmt, col, intVal)
            } else if let boolVal = val as? Bool {
                sqlite3_bind_int(stmt, col, boolVal ? 1 : 0)
            } else if let doubleVal = val as? Double {
                sqlite3_bind_double(stmt, col, doubleVal)
            } else if let stringVal = val as? String {
                sqlite3_bind_text(stmt, col, (stringVal as NSString).utf8String, -1, SQLITE_TRANSIENT)
            } else if let dataVal = val as? Data {
                _ = dataVal.withUnsafeBytes { rawBytes in
                    sqlite3_bind_blob(stmt, col, rawBytes.baseAddress, Int32(dataVal.count), SQLITE_TRANSIENT)
                }
            } else {
                let str = String(describing: val)
                sqlite3_bind_text(stmt, col, (str as NSString).utf8String, -1, SQLITE_TRANSIENT)
            }
        }
    }

    private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
}
