// QuotaLens Codex 会话元数据抽取与父子会话链协调器
// 安全读取 session_index.jsonl 与 state_5.sqlite（只读快照），计算项目名、父子关系与根节点

import Foundation
import SQLite3

public struct CodexRawSessionMetadata: Sendable {
    public let sessionId: String
    public var title: String?
    public var cwd: String?
    public var projectName: String?
    public var parentSessionId: String?
    public var agentType: String?
    public var createdAt: Date?
    public var updatedAt: Date?

    public init(
        sessionId: String,
        title: String? = nil,
        cwd: String? = nil,
        projectName: String? = nil,
        parentSessionId: String? = nil,
        agentType: String? = nil,
        createdAt: Date? = nil,
        updatedAt: Date? = nil
    ) {
        self.sessionId = sessionId
        self.title = title
        self.cwd = cwd
        self.projectName = projectName
        self.parentSessionId = parentSessionId
        self.agentType = agentType
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct CodexRolloutHeaderMetadata: Sendable {
    public let sourcePath: String
    public let relativePath: String
    public let sessionIdHint: String
    public let sessionId: String?
    public let metadata: CodexRawSessionMetadata?

    public init(
        sourcePath: String,
        relativePath: String,
        sessionIdHint: String,
        sessionId: String?,
        metadata: CodexRawSessionMetadata?
    ) {
        self.sourcePath = sourcePath
        self.relativePath = relativePath
        self.sessionIdHint = sessionIdHint
        self.sessionId = sessionId
        self.metadata = metadata
    }
}

public struct CodexResolvedSessionMetadata: Sendable {
    public let sessionId: String
    public let rootSessionId: String
    public let parentSessionId: String?
    public let depth: Int
    public let title: String?
    public let cwd: String?
    public let projectName: String?
    public let agentType: String?
    public let createdAt: Date
    public let updatedAt: Date
    public let hasSubagents: Bool
    public let subagentCount: Int

    public init(
        sessionId: String,
        rootSessionId: String,
        parentSessionId: String?,
        depth: Int,
        title: String?,
        cwd: String?,
        projectName: String?,
        agentType: String? = nil,
        createdAt: Date,
        updatedAt: Date,
        hasSubagents: Bool,
        subagentCount: Int
    ) {
        self.sessionId = sessionId
        self.rootSessionId = rootSessionId
        self.parentSessionId = parentSessionId
        self.depth = depth
        self.title = title
        self.cwd = cwd
        self.projectName = projectName
        self.agentType = agentType
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.hasSubagents = hasSubagents
        self.subagentCount = subagentCount
    }
}

public enum CodexSessionMetadataStore {
    /// 从 rollout 头部安全字段补充 session_meta。文件名只作为 hint；
    /// 当前 Codex 的分段文件可能是 parent_child 形态，最终 ID 以 session_meta 为准。
    public static func loadFromRolloutHeaders(
        sources: [RolloutDiscoveredSource],
        maxBytesPerFile: Int = 256 * 1024,
        maxLinesPerFile: Int = 200
    ) -> [String: CodexRolloutHeaderMetadata] {
        var result: [String: CodexRolloutHeaderMetadata] = [:]
        for source in sources {
            result[source.fileURL.path] = readRolloutHeader(
                source: source,
                maxBytes: maxBytesPerFile,
                maxLines: maxLinesPerFile
            )
        }
        return result
    }

    /// 从 session_index.jsonl 和 state_5.sqlite 加载并合并所有已知会话元数据
    public static func loadMetadata(paths: CodexHistoryPaths) -> [String: CodexRawSessionMetadata] {
        var metadataMap: [String: CodexRawSessionMetadata] = [:]

        // 1. 读取 session_index.jsonl
        let indexMeta = loadFromSessionIndex(fileURL: paths.sessionIndexURL)
        for (id, meta) in indexMeta {
            metadataMap[id] = meta
        }

        // 2. 只读读取 state_5.sqlite。当前 Codex 通常位于 ~/.codex/sqlite/，
        // 旧布局可能直接位于 ~/.codex/。
        for sqliteURL in paths.stateDbCandidateURLs {
            let sqliteMeta = loadFromStateSqlite(dbURL: sqliteURL)
            for (id, meta) in sqliteMeta {
                if var existing = metadataMap[id] {
                    if existing.cwd == nil { existing.cwd = meta.cwd }
                    if existing.projectName == nil { existing.projectName = meta.projectName }
                    if existing.title == nil || existing.title?.isEmpty == true { existing.title = meta.title }
                    if existing.parentSessionId == nil { existing.parentSessionId = meta.parentSessionId }
                    if existing.agentType == nil { existing.agentType = meta.agentType }
                    if existing.createdAt == nil { existing.createdAt = meta.createdAt }
                    if existing.updatedAt == nil { existing.updatedAt = meta.updatedAt }
                    metadataMap[id] = existing
                } else {
                    metadataMap[id] = meta
                }
            }
        }

        return metadataMap
    }

    /// 解析 session_index.jsonl
    public static func loadFromSessionIndex(fileURL: URL) -> [String: CodexRawSessionMetadata] {
        guard let data = try? Data(contentsOf: fileURL),
              let content = String(data: data, encoding: .utf8) else {
            return [:]
        }

        var result: [String: CodexRawSessionMetadata] = [:]
        content.enumerateLines { line, _ in
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty,
                  let lineData = trimmed.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else {
                return
            }

            guard let id = json["id"] as? String ?? json["sessionId"] as? String ?? json["session_id"] as? String else {
                return
            }

            let title = json["thread_name"] as? String ?? json["title"] as? String ?? json["name"] as? String
            let cwd = json["cwd"] as? String ?? json["working_directory"] as? String
            let parentId = json["parentId"] as? String
                ?? json["parent_session_id"] as? String
                ?? json["parent_id"] as? String
                ?? json["forked_from_id"] as? String
            let agentType = nonEmptyString(json["agent_type"] ?? json["agent_role"])
            let createdDate = dateValue(from: json["created_at"] ?? json["createdAt"])
            let updatedDate = dateValue(from: json["updated_at"] ?? json["updatedAt"])

            let projectName = cwd.map { extractProjectName(from: $0) }

            result[id] = CodexRawSessionMetadata(
                sessionId: id,
                title: title,
                cwd: cwd,
                projectName: projectName,
                parentSessionId: parentId,
                agentType: agentType,
                createdAt: createdDate,
                updatedAt: updatedDate
            )
        }

        return result
    }

    private static func readRolloutHeader(
        source: RolloutDiscoveredSource,
        maxBytes: Int,
        maxLines: Int
    ) -> CodexRolloutHeaderMetadata {
        let empty = CodexRolloutHeaderMetadata(
            sourcePath: source.fileURL.path,
            relativePath: source.relativePath,
            sessionIdHint: source.sessionId,
            sessionId: nil,
            metadata: nil
        )

        guard let handle = try? FileHandle(forReadingFrom: source.fileURL) else {
            return empty
        }
        defer { try? handle.close() }

        guard let data = try? handle.read(upToCount: maxBytes),
              !data.isEmpty,
              let text = String(data: data, encoding: .utf8) else {
            return empty
        }

        var parsedLines = 0
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard parsedLines < maxLines else { break }
            parsedLines += 1

            let trimmed = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty,
                  let lineData = trimmed.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  (json["type"] as? String) == "session_meta",
                  let payload = json["payload"] as? [String: Any] else {
                continue
            }

            let sessionId = nonEmptyString(payload["id"]) ?? source.sessionId
            let cwd = nonEmptyString(payload["cwd"])
            let parentId = resolvedParentSessionId(from: payload)
            let agentType = resolvedAgentType(from: payload)
            let timestamp = payload["timestamp"] ?? json["timestamp"]
            let createdAt = dateValue(from: timestamp)
            let projectName = cwd.map { extractProjectName(from: $0) }
            let metadata = CodexRawSessionMetadata(
                sessionId: sessionId,
                cwd: cwd,
                projectName: projectName,
                parentSessionId: parentId,
                agentType: agentType,
                createdAt: createdAt,
                updatedAt: createdAt
            )

            return CodexRolloutHeaderMetadata(
                sourcePath: source.fileURL.path,
                relativePath: source.relativePath,
                sessionIdHint: source.sessionId,
                sessionId: sessionId,
                metadata: metadata
            )
        }

        return empty
    }

    /// 安全只读读取 state_5.sqlite
    public static func loadFromStateSqlite(dbURL: URL) -> [String: CodexRawSessionMetadata] {
        guard FileManager.default.fileExists(atPath: dbURL.path) else { return [:] }

        var pointer: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_URI | SQLITE_OPEN_FULLMUTEX
        let status = sqlite3_open_v2(dbURL.path, &pointer, flags, nil)
        guard status == SQLITE_OK, let db = pointer else {
            if let pointer { sqlite3_close(pointer) }
            return [:]
        }
        defer { sqlite3_close(db) }

        var result: [String: CodexRawSessionMetadata] = [:]
        if let threads = readThreadsTable(db: db), !threads.isEmpty {
            return threads
        }

        let querySql = """
        SELECT id, title, cwd, parent_id, created_at, updated_at FROM sessions;
        """

        var statement: OpaquePointer?
        if sqlite3_prepare_v2(db, querySql, -1, &statement, nil) == SQLITE_OK, let stmt = statement {
            defer { sqlite3_finalize(stmt) }

            while sqlite3_step(stmt) == SQLITE_ROW {
                guard let idText = sqlite3_column_text(stmt, 0) else { continue }
                let id = String(cString: idText)

                let title = sqlite3_column_type(stmt, 1) != SQLITE_NULL && sqlite3_column_text(stmt, 1) != nil
                    ? String(cString: sqlite3_column_text(stmt, 1)!) : nil
                let cwd = sqlite3_column_type(stmt, 2) != SQLITE_NULL && sqlite3_column_text(stmt, 2) != nil
                    ? String(cString: sqlite3_column_text(stmt, 2)!) : nil
                let parentId = sqlite3_column_type(stmt, 3) != SQLITE_NULL && sqlite3_column_text(stmt, 3) != nil
                    ? String(cString: sqlite3_column_text(stmt, 3)!) : nil

                let createdMs = sqlite3_column_type(stmt, 4) != SQLITE_NULL ? sqlite3_column_int64(stmt, 4) : 0
                let updatedMs = sqlite3_column_type(stmt, 5) != SQLITE_NULL ? sqlite3_column_int64(stmt, 5) : 0

                let createdDate = createdMs > 0 ? Date(timeIntervalSince1970: Double(createdMs) / 1000.0) : nil
                let updatedDate = updatedMs > 0 ? Date(timeIntervalSince1970: Double(updatedMs) / 1000.0) : nil
                let projectName = cwd.map { extractProjectName(from: $0) }

                result[id] = CodexRawSessionMetadata(
                    sessionId: id,
                    title: title,
                    cwd: cwd,
                    projectName: projectName,
                    parentSessionId: parentId,
                    createdAt: createdDate,
                    updatedAt: updatedDate
                )
            }
        }

        return result
    }

    private static func readThreadsTable(db: OpaquePointer) -> [String: CodexRawSessionMetadata]? {
        let columns = tableColumns(db: db, table: "threads")
        guard columns.contains("id") else { return nil }

        func expr(_ column: String) -> String {
            columns.contains(column) ? column : "NULL AS \(column)"
        }

        let querySql = """
        SELECT
            id,
            \(expr("title")),
            \(expr("cwd")),
            \(expr("created_at_ms")),
            \(expr("updated_at_ms")),
            \(expr("created_at")),
            \(expr("updated_at"))
        FROM threads
        WHERE id IS NOT NULL;
        """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, querySql, -1, &statement, nil) == SQLITE_OK, let stmt = statement else {
            return nil
        }
        defer { sqlite3_finalize(stmt) }

        var result: [String: CodexRawSessionMetadata] = [:]
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let idText = sqlite3_column_text(stmt, 0) else { continue }
            let id = String(cString: idText)
            guard !id.isEmpty else { continue }

            let title = columnString(stmt, 1)
            let cwd = columnString(stmt, 2)
            let createdDate = columnDate(stmt, 3) ?? columnDate(stmt, 5)
            let updatedDate = columnDate(stmt, 4) ?? columnDate(stmt, 6)
            let projectName = cwd.map { extractProjectName(from: $0) }

            result[id] = CodexRawSessionMetadata(
                sessionId: id,
                title: title,
                cwd: cwd,
                projectName: projectName,
                createdAt: createdDate,
                updatedAt: updatedDate
            )
        }
        return result
    }

    private static func tableColumns(db: OpaquePointer, table: String) -> Set<String> {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA table_info(\(table));", -1, &statement, nil) == SQLITE_OK,
              let stmt = statement else {
            return []
        }
        defer { sqlite3_finalize(stmt) }

        var columns = Set<String>()
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard sqlite3_column_type(stmt, 1) != SQLITE_NULL,
                  let text = sqlite3_column_text(stmt, 1) else { continue }
            columns.insert(String(cString: text))
        }
        return columns
    }

    /// 从 cwd 路径提取项目名（取最后一级目录，防 / 结尾）
    public static func extractProjectName(from cwd: String) -> String {
        let trimmed = cwd.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        guard !trimmed.isEmpty else { return "Codex" }
        return (trimmed as NSString).lastPathComponent
    }

    private static func dateValue(from value: Any?) -> Date? {
        guard let value else { return nil }
        if let intVal = value as? Int64 {
            return dateFromEpochNumber(Double(intVal))
        }
        if let intVal = value as? Int {
            return dateFromEpochNumber(Double(intVal))
        }
        if let doubleVal = value as? Double {
            return dateFromEpochNumber(doubleVal)
        }
        if let stringVal = value as? String {
            if let parsed = Double(stringVal) {
                return dateFromEpochNumber(parsed)
            }
            return dateFromISO8601(stringVal)
        }
        return nil
    }

    private static func dateFromEpochNumber(_ raw: Double) -> Date {
        let seconds = raw > 100_000_000_000 ? raw / 1000.0 : raw
        return Date(timeIntervalSince1970: seconds)
    }

    private static func dateFromISO8601(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) {
            return date
        }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: value)
    }

    private static func columnString(_ statement: OpaquePointer, _ index: Int32) -> String? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL,
              let text = sqlite3_column_text(statement, index) else { return nil }
        let string = String(cString: text).trimmingCharacters(in: .whitespacesAndNewlines)
        return string.isEmpty ? nil : string
    }

    private static func columnDate(_ statement: OpaquePointer, _ index: Int32) -> Date? {
        switch sqlite3_column_type(statement, index) {
        case SQLITE_INTEGER:
            return dateFromEpochNumber(Double(sqlite3_column_int64(statement, index)))
        case SQLITE_FLOAT:
            return dateFromEpochNumber(sqlite3_column_double(statement, index))
        case SQLITE_TEXT:
            guard let text = columnString(statement, index) else { return nil }
            return dateValue(from: text)
        default:
            return nil
        }
    }

    private static func nonEmptyString(_ value: Any?) -> String? {
        guard let string = value as? String else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func resolvedParentSessionId(from payload: [String: Any]) -> String? {
        if let parent = nonEmptyString(payload["parent_session_id"]) { return parent }
        if let forked = nonEmptyString(payload["forked_from_id"]) { return forked }
        if let parentThread = nonEmptyString(payload["parent_thread_id"]) { return parentThread }

        guard let source = payload["source"] as? [String: Any],
              let subagent = source["subagent"] as? [String: Any],
              let threadSpawn = subagent["thread_spawn"] as? [String: Any] else {
            return nil
        }
        return nonEmptyString(threadSpawn["parent_thread_id"])
    }

    private static func resolvedAgentType(from payload: [String: Any]) -> String? {
        if let direct = nonEmptyString(payload["agent_type"] ?? payload["agent_role"]) {
            return direct
        }
        guard let source = payload["source"] as? [String: Any],
              let subagent = source["subagent"] as? [String: Any],
              let threadSpawn = subagent["thread_spawn"] as? [String: Any] else {
            return nil
        }
        return nonEmptyString(threadSpawn["agent_role"])
            ?? nonEmptyString(threadSpawn["agent_nickname"])
            ?? "subagent"
    }

    /// 协调并构建父子会话树，计算 root_session_id 和 depth，防止循环依赖
    public static func reconcileSessionTree(
        discoveredIds: Set<String>,
        rawMetadata: [String: CodexRawSessionMetadata]
    ) -> [String: CodexResolvedSessionMetadata] {
        var resolved: [String: CodexResolvedSessionMetadata] = [:]
        var childrenMap: [String: [String]] = [:]

        // 收集父子映射
        for id in discoveredIds {
            if let parent = rawMetadata[id]?.parentSessionId, !parent.isEmpty, parent != id {
                childrenMap[parent, default: []].append(id)
            }
        }

        // 逐一解析深度与根节点
        for id in discoveredIds {
            var currentId = id
            var visited = Set<String>([id])
            var depth = 0
            let maxHops = 64

            while let parent = rawMetadata[currentId]?.parentSessionId,
                  !parent.isEmpty,
                  parent != currentId,
                  depth < maxHops {
                if visited.contains(parent) {
                    // 检测到循环依赖，提前熔断
                    break
                }
                visited.insert(parent)
                currentId = parent
                depth += 1
            }

            let rootSessionId = currentId
            let meta = rawMetadata[id]
            let children = childrenMap[id] ?? []

            resolved[id] = CodexResolvedSessionMetadata(
                sessionId: id,
                rootSessionId: rootSessionId,
                parentSessionId: meta?.parentSessionId,
                depth: depth,
                title: meta?.title,
                cwd: meta?.cwd,
                projectName: meta?.projectName,
                agentType: meta?.agentType,
                createdAt: meta?.createdAt ?? Date(timeIntervalSince1970: 0),
                updatedAt: meta?.updatedAt ?? Date(timeIntervalSince1970: 0),
                hasSubagents: !children.isEmpty,
                subagentCount: children.count
            )
        }

        return resolved
    }
}
