import Foundation
import SQLite3
import Combine
import CoreServices

private struct ClaudeSubagentRelationship: Sendable {
    let rootSessionID: String
    let parentSessionID: String
    let ancestorSessionIDs: [String]
    let depth: Int
}

private func claudeSubagentRelationship(relativePath: String) -> ClaudeSubagentRelationship? {
    let components = (relativePath as NSString).pathComponents
    guard let lastSubagentsIndex = components.lastIndex(of: "subagents"),
          lastSubagentsIndex > components.startIndex,
          components.index(after: lastSubagentsIndex) == components.index(before: components.endIndex) else {
        return nil
    }

    var ancestors = [components[components.index(before: lastSubagentsIndex)]]
    var currentAncestorIndex = components.index(before: lastSubagentsIndex)
    while currentAncestorIndex >= components.index(components.startIndex, offsetBy: 2) {
        let separatorIndex = components.index(before: currentAncestorIndex)
        guard components[separatorIndex] == "subagents" else { break }
        let ancestorIndex = components.index(before: separatorIndex)
        ancestors.append(components[ancestorIndex])
        currentAncestorIndex = ancestorIndex
    }
    ancestors.reverse()
    guard let root = ancestors.first, let parent = ancestors.last else { return nil }
    return ClaudeSubagentRelationship(
        rootSessionID: root,
        parentSessionID: parent,
        ancestorSessionIDs: ancestors,
        depth: ancestors.count
    )
}

private struct ClaudeHistoryFile: Sendable {
    let url: URL
    let relativePath: String
    let size: Int64
    let mtimeMs: Int64

    var path: String { url.path }
    private var subagentRelationship: ClaudeSubagentRelationship? {
        claudeSubagentRelationship(relativePath: relativePath)
    }
    var groupingSessionID: String {
        if let rootSessionID { return rootSessionID }
        return url.deletingPathExtension().lastPathComponent
    }
    var isSubagent: Bool { subagentRelationship != nil }
    var rootSessionID: String? { subagentRelationship?.rootSessionID }
    var parentSessionID: String? { subagentRelationship?.parentSessionID }
    var ancestorSessionIDs: [String] { subagentRelationship?.ancestorSessionIDs ?? [] }
    var depth: Int { subagentRelationship?.depth ?? 0 }
}

private struct ClaudeImportSourceState: Sendable {
    let sourcePath: String
    let relativePath: String
    let sessionID: String?
    let fileSize: Int64
    let mtimeMs: Int64
    let byteOffset: Int64
    let status: String
    let malformedLineCount: Int
    let errorMessage: String?
}

private struct ClaudeHistoryScanResult {
    let files: [ClaudeHistoryFile]
    let errors: [String]
}

private struct ParsedClaudeEvent: Sendable {
    let messageID: String
    let timestamp: Date
    let modelRaw: String
    let uncachedInput: Int64
    let cachedInput: Int64
    let cacheWrite5m: Int64
    let cacheWrite1h: Int64
    let output: Int64
    let lineOffset: Int64
    let lineBytes: Int64

    var totalTokens: Int64 {
        uncachedInput + cachedInput + cacheWrite5m + cacheWrite1h + output
    }
}

private final class ClaudeParsedEventStore: @unchecked Sendable {
    private var database: SQLiteDatabase?
    private let directoryURL: URL

    init() throws {
        directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("QuotaLens-Claude-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        database = nil
        do {
            let database = try SQLiteDatabase(path: directoryURL.appendingPathComponent("events.sqlite").path)
            try database.execute(sql: """
            PRAGMA journal_mode = DELETE;
            PRAGMA synchronous = OFF;
            PRAGMA temp_store = FILE;
            CREATE TABLE parsed_events (
                message_id TEXT NOT NULL,
                day_key TEXT NOT NULL,
                timestamp_ms INTEGER NOT NULL,
                model_raw TEXT NOT NULL,
                uncached_input INTEGER NOT NULL,
                cached_input INTEGER NOT NULL,
                cache_write_5m INTEGER NOT NULL,
                cache_write_1h INTEGER NOT NULL,
                output_tokens INTEGER NOT NULL,
                line_offset INTEGER NOT NULL,
                line_bytes INTEGER NOT NULL,
                order_offset INTEGER NOT NULL,
                total_tokens INTEGER NOT NULL,
                PRIMARY KEY (message_id, day_key)
            );
            """)
            self.database = database
        } catch {
            try? FileManager.default.removeItem(at: directoryURL)
            throw error
        }
    }

    deinit {
        database = nil
        try? FileManager.default.removeItem(at: directoryURL)
    }

    func store(_ events: [ParsedClaudeEvent]) throws {
        guard !events.isEmpty, let database else { return }
        let calendar = UsageDayBucketer.calendar()
        try database.transaction {
            try database.executePreparedUpdates(
                sql: """
                INSERT INTO parsed_events (
                    message_id, day_key, timestamp_ms, model_raw,
                    uncached_input, cached_input, cache_write_5m, cache_write_1h,
                    output_tokens, line_offset, line_bytes, order_offset, total_tokens
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(message_id, day_key) DO UPDATE SET
                    timestamp_ms = excluded.timestamp_ms,
                    model_raw = excluded.model_raw,
                    uncached_input = excluded.uncached_input,
                    cached_input = excluded.cached_input,
                    cache_write_5m = excluded.cache_write_5m,
                    cache_write_1h = excluded.cache_write_1h,
                    output_tokens = excluded.output_tokens,
                    line_offset = excluded.line_offset,
                    line_bytes = excluded.line_bytes,
                    total_tokens = excluded.total_tokens
                WHERE excluded.total_tokens >= parsed_events.total_tokens;
                """,
                values: events
            ) { event in
                let day = LocalDayKey(date: event.timestamp, calendar: calendar).yyyyMMdd
                return [
                    event.messageID,
                    day,
                    Int64(event.timestamp.timeIntervalSince1970 * 1_000),
                    event.modelRaw,
                    event.uncachedInput,
                    event.cachedInput,
                    event.cacheWrite5m,
                    event.cacheWrite1h,
                    event.output,
                    event.lineOffset,
                    event.lineBytes,
                    event.lineOffset,
                    event.totalTokens
                ]
            }
        }
    }

    func forEachEvent(_ body: (ParsedClaudeEvent) throws -> Void) throws {
        guard let database else { return }
        try database.withPreparedStatement(sql: """
        SELECT message_id, timestamp_ms, model_raw, uncached_input, cached_input,
               cache_write_5m, cache_write_1h, output_tokens, line_offset, line_bytes
        FROM parsed_events
        ORDER BY order_offset ASC;
        """) { statement in
            var result = sqlite3_step(statement)
            while result == SQLITE_ROW {
                try body(ParsedClaudeEvent(
                    messageID: String(cString: sqlite3_column_text(statement, 0)),
                    timestamp: Date(timeIntervalSince1970: Double(sqlite3_column_int64(statement, 1)) / 1_000),
                    modelRaw: String(cString: sqlite3_column_text(statement, 2)),
                    uncachedInput: sqlite3_column_int64(statement, 3),
                    cachedInput: sqlite3_column_int64(statement, 4),
                    cacheWrite5m: sqlite3_column_int64(statement, 5),
                    cacheWrite1h: sqlite3_column_int64(statement, 6),
                    output: sqlite3_column_int64(statement, 7),
                    lineOffset: sqlite3_column_int64(statement, 8),
                    lineBytes: sqlite3_column_int64(statement, 9)
                ))
                result = sqlite3_step(statement)
            }
            guard result == SQLITE_DONE else {
                throw NSError(
                    domain: "QuotaLens.ClaudeParsedEventStore",
                    code: Int(result),
                    userInfo: [NSLocalizedDescriptionKey: L10n.text(
                        "Claude 记录暂时无法处理。",
                        "Claude records could not be processed right now."
                    )]
                )
            }
        }
    }
}

private struct ClaudeParseHealth: Sendable {
    var completeLineCount = 0
    var malformedJSONLineCount = 0
    var assistantLineCount = 0
    var recognizedUsageLineCount = 0
    var incompatibleUsageLineCount = 0
    var trailingPartialBytes = 0

    var malformedLineCount: Int {
        malformedJSONLineCount + incompatibleUsageLineCount
    }

    var status: String {
        if assistantLineCount > 0,
           recognizedUsageLineCount == 0,
           incompatibleUsageLineCount > 0 {
            return "incompatible"
        }
        if malformedLineCount > 0 { return "partial" }
        if trailingPartialBytes > 0 { return "pending" }
        return "indexed"
    }
}

private struct ClaudeStoredEventFingerprint: Equatable {
    let rootSessionID: String
    let timestampMs: Int64
    let modelRaw: String
    let modelCanonical: String
    let input: Int64
    let cached: Int64
    let cacheWrite: Int64
    let cacheWrite5m: Int64
    let cacheWrite1h: Int64
    let output: Int64
    let total: Int64
    let uncached: Int64
    let cost: Int64
    let pricingRuleID: String?
    let pricingStatus: String
    let sourcePath: String
    let lineOffset: Int64
    let lineBytes: Int64
    let catalogVersion: String?
}

private struct ParsedClaudeSlice: Sendable {
    let payloadSessionID: String?
    let title: String?
    let cwd: String?
    let startedAt: Date?
    let updatedAt: Date?
    let eventStore: ClaudeParsedEventStore
    let endOffset: Int64
    let health: ClaudeParseHealth
}

private enum ClaudeUsageSchemaVersion: Equatable {
    case legacyFlat
    case cacheCreationObject
}

private enum ClaudeSourceReplacementPolicy: Equatable {
    case replace
    case mergeRecognizedEvents
    case preserveLastGood
}

private struct ClaudeSourceImportPlan {
    let file: ClaudeHistoryFile
    let slice: ParsedClaudeSlice
    let rawSessionID: String?
    let sourceStatus: String
    let replacementPolicy: ClaudeSourceReplacementPolicy
    let replacementSourcePaths: Set<String>
}

private enum ClaudeImportError: LocalizedError {
    case selfParentSession(String)

    var errorDescription: String? {
        switch self {
        case .selfParentSession:
            return L10n.text(
                "Claude 子任务的会话关系无效，已保留原有统计。",
                "A Claude child-task relationship is invalid. Existing statistics were kept."
            )
        }
    }
}

actor ClaudeUsageImportActor {
    private static let currentImportVersion = 4
    private static let importVersionKey = "claude_usage_import_version"
    private static let childRepairStatusKey = "claude_child_repair_status"
    private static let repairPendingStatus = "repair_pending"
    private let database: SQLiteDatabase
    private let roots: [URL]

    init(database: SQLiteDatabase, roots: [URL]? = nil) {
        self.database = database
        self.roots = roots ?? Self.defaultRoots()
    }

    func scan(forceRebuild: Bool = false) async throws -> ClaudeUsageImportSummary {
        try ClaudePricingCatalogService.ensureInstalled(database: database)
        let storedImportVersion = try database.int64Scalar(
            sql: "SELECT CAST(value AS INTEGER) FROM app_metadata WHERE key = ?;",
            bindings: [Self.importVersionKey]
        ) ?? 0
        let requiresRepair = storedImportVersion < Self.currentImportVersion
        let fileScan = Self.scanFiles(roots: roots)
        let files = fileScan.files
        let states = try loadSourceStates()
        let discoveredPaths = Set(files.map { Self.canonicalPath($0.path) })
        let migrationRepairPaths = requiresRepair
            ? Set(states.values.compactMap { state -> String? in
                claudeSubagentRelationship(relativePath: state.relativePath) == nil
                    ? nil : Self.canonicalPath(state.sourcePath)
            })
            : []
        if requiresRepair {
            try database.transaction {
                for state in states.values where claudeSubagentRelationship(relativePath: state.relativePath) != nil {
                    try database.executeUpdate(
                        sql: """
                        UPDATE claude_import_sources
                        SET status = ?
                        WHERE source_path = ?
                          AND status NOT IN ('partial', 'incompatible', 'pending_session_identity');
                        """,
                        bindings: [Self.repairPendingStatus, state.sourcePath]
                    )
                }
                try database.executeUpdate(
                    sql: "INSERT OR REPLACE INTO app_metadata (key, value, updated_at) VALUES (?, ?, unixepoch());",
                    bindings: [Self.importVersionKey, Self.currentImportVersion]
                )
                try database.executeUpdate(
                    sql: "INSERT OR REPLACE INTO app_metadata (key, value, updated_at) VALUES (?, 'partial', unixepoch());",
                    bindings: [Self.childRepairStatusKey]
                )
            }
        }
        let inaccessibleRepairSources = states.values.filter { state in
            guard claudeSubagentRelationship(relativePath: state.relativePath) != nil,
                  FileManager.default.fileExists(atPath: state.sourcePath) else { return false }
            let path = Self.canonicalPath(state.sourcePath)
            return !discoveredPaths.contains(path)
                && (state.status == Self.repairPendingStatus || migrationRepairPaths.contains(path))
        }

        var filesByGroup: [String: [ClaudeHistoryFile]] = [:]
        for file in files {
            let group = states[file.path]?.sessionID ?? file.groupingSessionID
            filesByGroup[group, default: []].append(file)
        }

        var changedGroups = Set<String>()
        var resetPathsByGroup: [String: Set<String>] = [:]
        for (group, groupFiles) in filesByGroup {
            for file in groupFiles {
                guard let state = states[file.path] else {
                    changedGroups.insert(group)
                    continue
                }
                let fileChanged = file.size != state.fileSize || file.mtimeMs != state.mtimeMs
                let canonicalPath = Self.canonicalPath(file.path)
                let requiresSourceRepair = state.status == Self.repairPendingStatus
                    || state.status == "repair_invalid_identity"
                    || migrationRepairPaths.contains(canonicalPath)
                let requiresSafeRestart = fileChanged && [
                    "partial", "incompatible", "pending", "pending_session_identity"
                ].contains(state.status)
                if forceRebuild || requiresSourceRepair || file.size < state.byteOffset || requiresSafeRestart {
                    changedGroups.insert(group)
                    resetPathsByGroup[group, default: []].insert(file.path)
                } else if fileChanged {
                    changedGroups.insert(group)
                }
            }
        }

        var sessionsUpdated = 0
        var eventsUpdated = 0
        var errors = fileScan.errors + inaccessibleRepairSources.map {
            "\($0.relativePath): " + L10n.text(
                "Claude 子任务记录暂时无法读取，将在下次扫描重试。",
                "A Claude child-task record could not be read and will be retried on the next scan."
            )
        }
        for group in changedGroups.sorted() {
            guard let groupFiles = filesByGroup[group] else { continue }
            do {
                let result = try importGroup(
                    groupID: group,
                    files: groupFiles.sorted { $0.path < $1.path },
                    states: states,
                    resetSourcePaths: resetPathsByGroup[group] ?? []
                )
                sessionsUpdated += result.sessionsChanged
                eventsUpdated += result.eventsChanged
                errors.append(contentsOf: result.warnings)
            } catch {
                errors.append("\(group): \(error.localizedDescription)")
            }
        }

        do {
            let storedOnlyStates = Dictionary(uniqueKeysWithValues: states.filter {
                let path = Self.canonicalPath($0.value.sourcePath)
                return !discoveredPaths.contains(path)
                    && !FileManager.default.fileExists(atPath: $0.value.sourcePath)
                    && ($0.value.status == Self.repairPendingStatus || migrationRepairPaths.contains(path))
            })
            sessionsUpdated += try repairStoredSubagentSessions(states: storedOnlyStates)
        } catch {
            errors.append(error.localizedDescription)
        }
        try updateChildRepairStatus()
        let currentStates = try loadSourceStates()
        let diagnosticStatuses = Set([
            "partial",
            "incompatible",
            "pending_session_identity",
            Self.repairPendingStatus,
            "repair_invalid_identity"
        ])
        for state in currentStates.values where diagnosticStatuses.contains(state.status) {
            let message = state.errorMessage ?? sourceErrorMessage(status: state.status)
                ?? L10n.text(
                    "部分 Claude 记录暂时无法读取。",
                    "Some Claude records could not be read."
                )
            errors.append("\(state.relativePath): \(message)")
        }
        errors = Array(Set(errors)).sorted()

        try database.executeUpdate(
            sql: "INSERT OR REPLACE INTO app_metadata (key, value, updated_at) VALUES ('claude_usage_generation', ?, unixepoch());",
            bindings: [Int64(Date().timeIntervalSince1970)]
        )
        return ClaudeUsageImportSummary(
            filesScanned: files.count,
            filesChanged: changedGroups.reduce(0) { $0 + (filesByGroup[$1]?.count ?? 0) },
            sessionsUpdated: sessionsUpdated,
            eventsUpdated: eventsUpdated,
            errors: errors
        )
    }

    private func importGroup(
        groupID: String,
        files: [ClaudeHistoryFile],
        states: [String: ClaudeImportSourceState],
        resetSourcePaths requestedResetSourcePaths: Set<String>
    ) throws -> (sessionsChanged: Int, eventsChanged: Int, warnings: [String]) {
        var plans: [ClaudeSourceImportPlan] = []
        for file in files {
            let state = states[file.path]
            var shouldReset = requestedResetSourcePaths.contains(file.path)
            let unchanged = !shouldReset
                && state?.fileSize == file.size
                && state?.mtimeMs == file.mtimeMs
            if unchanged { continue }
            let offset = shouldReset ? 0 : min(max(0, state?.byteOffset ?? 0), file.size)
            var parsed = try Self.parse(file: file, fromOffset: offset)
            if !shouldReset,
               offset > 0,
               let previousSessionID = state?.sessionID,
               let payloadSessionID = parsed.payloadSessionID,
               payloadSessionID != previousSessionID {
                parsed = try Self.parse(file: file, fromOffset: 0)
                shouldReset = true
            }
            let rawSessionID = resolvedSessionID(file: file, slice: parsed, previousState: state)
            let status = sourceStatus(file: file, slice: parsed, sessionID: rawSessionID)
            let replacementPolicy: ClaudeSourceReplacementPolicy
            if status == "incompatible" || status == "pending_session_identity" {
                replacementPolicy = .preserveLastGood
            } else if shouldReset, status == "indexed" {
                replacementPolicy = .replace
            } else {
                replacementPolicy = .mergeRecognizedEvents
            }
            var replacementSourcePaths: Set<String> = [file.path]
            if let previousPath = state?.sourcePath {
                replacementSourcePaths.insert(previousPath)
            }
            plans.append(ClaudeSourceImportPlan(
                file: file,
                slice: parsed,
                rawSessionID: rawSessionID,
                sourceStatus: status,
                replacementPolicy: replacementPolicy,
                replacementSourcePaths: replacementSourcePaths
            ))
        }
        guard !plans.isEmpty else { return (0, 0, []) }

        let groupKey = UsageSessionIdentity.key(provider: .claude, rawSessionID: groupID)
        var affectedSessionKeys: Set<String> = [groupKey]
        var parentSessionKeys = Set<String>()
        for plan in plans {
            let file = plan.file
            if let rawSessionID = plan.rawSessionID {
                affectedSessionKeys.insert(UsageSessionIdentity.key(provider: .claude, rawSessionID: rawSessionID))
            }
            if let previousSessionID = states[file.path]?.sessionID {
                affectedSessionKeys.insert(UsageSessionIdentity.key(provider: .claude, rawSessionID: previousSessionID))
            }
            if let parentSessionID = file.parentSessionID {
                let parentKey = UsageSessionIdentity.key(provider: .claude, rawSessionID: parentSessionID)
                affectedSessionKeys.insert(parentKey)
                parentSessionKeys.insert(parentKey)
            }
        }
        var changedEvents = 0
        var warnings: [String] = []
        try database.transaction {
            for plan in plans {
                guard case .replace = plan.replacementPolicy else { continue }
                for sourcePath in plan.replacementSourcePaths {
                    let existingSessionKeys = try database.executeQuery(
                        sql: "SELECT DISTINCT session_id FROM codex_usage_events WHERE provider = 'claude' AND source_path = ?;",
                        bindings: [sourcePath]
                    ) { statement in
                        String(cString: sqlite3_column_text(statement, 0))
                    }
                    affectedSessionKeys.formUnion(existingSessionKeys)
                    try database.executeUpdate(
                        sql: "DELETE FROM codex_usage_events WHERE provider = 'claude' AND source_path = ?;",
                        bindings: [sourcePath]
                    )
                }
            }

            for plan in plans {
                let file = plan.file
                let slice = plan.slice
                let preservedLastGood: Bool
                if plan.replacementPolicy == .preserveLastGood {
                    preservedLastGood = try hasStoredEvents(sourcePaths: plan.replacementSourcePaths)
                } else {
                    preservedLastGood = false
                }
                let sourceError = sourceErrorMessage(
                    status: plan.sourceStatus,
                    preservedLastGood: preservedLastGood
                )
                if sourceError != nil {
                    warnings.append("\(file.relativePath): \(sourceError ?? "Claude record is incomplete")")
                }
                try migrateStoredEventSourcePath(
                    previousState: states[file.path],
                    canonicalPath: file.path
                )
                guard plan.replacementPolicy != .preserveLastGood,
                      let rawSessionID = plan.rawSessionID else {
                    try persistSourceState(
                        file: file,
                        sessionID: plan.sourceStatus == "pending_session_identity"
                            ? nil : plan.rawSessionID,
                        slice: slice,
                        status: plan.sourceStatus,
                        errorMessage: sourceError
                    )
                    try removeSupersededSourceState(
                        previousState: states[file.path],
                        canonicalPath: file.path
                    )
                    continue
                }
                let sessionID = UsageSessionIdentity.key(provider: .claude, rawSessionID: rawSessionID)
                let rootSessionID = UsageSessionIdentity.key(
                    provider: .claude,
                    rawSessionID: file.rootSessionID ?? rawSessionID
                )
                let parentSessionID = file.parentSessionID.map {
                    UsageSessionIdentity.key(provider: .claude, rawSessionID: $0)
                }
                if parentSessionID == sessionID {
                    throw ClaudeImportError.selfParentSession(sessionID)
                }
                try slice.eventStore.forEachEvent { event in
                    changedEvents += try upsert(
                        event: event,
                        sessionID: sessionID,
                        rootSessionID: rootSessionID,
                        sourcePath: file.path
                    ) ? 1 : 0
                }
                try upsertSessionMetadata(
                    slice: slice,
                    file: file,
                    sessionID: sessionID,
                    rootSessionID: rootSessionID,
                    parentSessionID: parentSessionID
                )
                try persistSourceState(
                    file: file,
                    sessionID: rawSessionID,
                    slice: slice,
                    status: plan.sourceStatus,
                    errorMessage: sourceError
                )
                try removeSupersededSourceState(
                    previousState: states[file.path],
                    canonicalPath: file.path
                )
            }
            for sessionID in affectedSessionKeys.sorted() {
                try rebuildSummaries(sessionID: sessionID)
            }
            try removeOrphanedSessions(affectedSessionKeys)
            for parentSessionID in parentSessionKeys {
                try updateHasSubagents(sessionID: parentSessionID)
            }
        }
        return (affectedSessionKeys.count, changedEvents, warnings)
    }

    private func resolvedSessionID(
        file: ClaudeHistoryFile,
        slice: ParsedClaudeSlice,
        previousState: ClaudeImportSourceState?
    ) -> String? {
        if let sessionID = slice.payloadSessionID?.trimmingCharacters(in: .whitespacesAndNewlines),
           !sessionID.isEmpty,
           !file.ancestorSessionIDs.contains(sessionID) {
            return sessionID
        }
        if let sessionID = previousState?.sessionID,
           !sessionID.isEmpty,
           !file.ancestorSessionIDs.contains(sessionID) {
            return sessionID
        }
        return file.isSubagent ? nil : file.url.deletingPathExtension().lastPathComponent
    }

    private func sourceStatus(
        file: ClaudeHistoryFile,
        slice: ParsedClaudeSlice,
        sessionID: String?
    ) -> String {
        if slice.health.status == "partial" || slice.health.status == "incompatible" {
            return slice.health.status
        }
        if file.isSubagent, sessionID == nil { return "pending_session_identity" }
        return slice.health.status
    }

    private func sourceErrorMessage(status: String, preservedLastGood: Bool = false) -> String? {
        switch status {
        case "partial":
            return L10n.text(
                "部分 Claude 记录无法识别，已计入可识别记录并保留原有统计。",
                "Some Claude records could not be recognized. Recognized records were counted and existing statistics were kept."
            )
        case "incompatible":
            if preservedLastGood {
                return L10n.text(
                    "Claude 记录格式已变化，当前继续显示上次成功统计。",
                    "The Claude record format has changed. The last successful statistics are still shown."
                )
            }
            return L10n.text(
                "Claude 记录格式已变化，新记录尚未计入统计，请检查 QuotaLens 更新。",
                "The Claude record format has changed. New records are not yet included; check for a QuotaLens update."
            )
        case "pending_session_identity":
            return L10n.text(
                "该 Claude 子任务暂时缺少可靠身份，用量尚未计入统计。",
                "This Claude child task does not yet have a reliable identity, so its usage is not included."
            )
        case Self.repairPendingStatus:
            return L10n.text(
                "旧 Claude 子任务正在等待重新修复。",
                "An older Claude child task is waiting to be repaired."
            )
        case "repair_invalid_identity":
            return L10n.text(
                "旧 Claude 子任务缺少可靠身份，已忽略错误层级，原始文件已不存在。",
                "An older Claude child task has no reliable identity. Its invalid hierarchy was ignored because the original file no longer exists."
            )
        default:
            return nil
        }
    }

    private func hasStoredEvents(sourcePaths: Set<String>) throws -> Bool {
        for sourcePath in sourcePaths {
            if try database.intScalar(
                sql: "SELECT COUNT(*) FROM codex_usage_events WHERE provider = 'claude' AND source_path = ?;",
                bindings: [sourcePath]
            ) > 0 {
                return true
            }
        }
        return false
    }

    private func migrateStoredEventSourcePath(
        previousState: ClaudeImportSourceState?,
        canonicalPath: String
    ) throws {
        guard let previousPath = previousState?.sourcePath,
              previousPath != canonicalPath else { return }
        try database.executeUpdate(
            sql: "UPDATE codex_usage_events SET source_path = ? WHERE provider = 'claude' AND source_path = ?;",
            bindings: [canonicalPath, previousPath]
        )
    }

    private func persistSourceState(
        file: ClaudeHistoryFile,
        sessionID: String?,
        slice: ParsedClaudeSlice,
        status: String,
        errorMessage: String?
    ) throws {
        try database.executeUpdate(
            sql: """
            INSERT INTO claude_import_sources (
                source_path, relative_path, session_id, file_size, mtime_ms,
                byte_offset, status, last_imported_at, malformed_line_count, error_message
            ) VALUES (?, ?, ?, ?, ?, ?, ?, unixepoch(), ?, ?)
            ON CONFLICT(source_path) DO UPDATE SET
                relative_path = excluded.relative_path,
                session_id = excluded.session_id,
                file_size = excluded.file_size,
                mtime_ms = excluded.mtime_ms,
                byte_offset = excluded.byte_offset,
                status = excluded.status,
                last_imported_at = unixepoch(),
                malformed_line_count = excluded.malformed_line_count,
                error_message = excluded.error_message;
            """,
            bindings: [
                file.path, file.relativePath, sessionID, file.size, file.mtimeMs,
                slice.endOffset, status, slice.health.malformedLineCount, errorMessage
            ]
        )
    }

    private func removeSupersededSourceState(
        previousState: ClaudeImportSourceState?,
        canonicalPath: String
    ) throws {
        guard let previousPath = previousState?.sourcePath, previousPath != canonicalPath else { return }
        try database.executeUpdate(
            sql: "DELETE FROM claude_import_sources WHERE source_path = ?;",
            bindings: [previousPath]
        )
    }

    private func upsert(
        event: ParsedClaudeEvent,
        sessionID: String,
        rootSessionID: String,
        sourcePath: String
    ) throws -> Bool {
        let calendar = UsageDayBucketer.calendar()
        let dayKey = LocalDayKey(date: event.timestamp, calendar: calendar).yyyyMMdd
        let providerMessageID = "\(event.messageID):\(dayKey)"

        let previous = try database.executeQuery(
            sql: """
            SELECT
                COALESCE(SUM(uncached_input_tokens), 0),
                COALESCE(SUM(cached_input_tokens), 0),
                COALESCE(SUM(cache_write_5m_input_tokens), 0),
                COALESCE(SUM(cache_write_1h_input_tokens), 0),
                COALESCE(SUM(output_tokens), 0)
            FROM codex_usage_events
            WHERE provider = 'claude'
              AND session_id = ?
              AND provider_message_id LIKE ? ESCAPE '\\'
              AND provider_message_id != ?;
            """,
            bindings: [sessionID, Self.escapeLike(event.messageID) + ":%", providerMessageID]
        ) { statement in
            (
                sqlite3_column_int64(statement, 0),
                sqlite3_column_int64(statement, 1),
                sqlite3_column_int64(statement, 2),
                sqlite3_column_int64(statement, 3),
                sqlite3_column_int64(statement, 4)
            )
        }.first ?? (0, 0, 0, 0, 0)

        let uncached = max(0, event.uncachedInput - previous.0)
        let cached = max(0, event.cachedInput - previous.1)
        let write5m = max(0, event.cacheWrite5m - previous.2)
        let write1h = max(0, event.cacheWrite1h - previous.3)
        let output = max(0, event.output - previous.4)
        guard uncached + cached + write5m + write1h + output > 0 else { return false }

        let price = ClaudePricingCatalogService.evaluate(
            modelRaw: event.modelRaw,
            uncachedInput: uncached,
            cachedInput: cached,
            cacheWrite5m: write5m,
            cacheWrite1h: write1h,
            output: output
        )
        let grossInput = uncached + cached + write5m + write1h
        let total = grossInput + output
        let eventID = "\(sessionID):\(providerMessageID)"
        let timestampMs = Int64(event.timestamp.timeIntervalSince1970 * 1_000)
        let proposed = ClaudeStoredEventFingerprint(
            rootSessionID: rootSessionID,
            timestampMs: timestampMs,
            modelRaw: event.modelRaw,
            modelCanonical: price.modelCanonical,
            input: grossInput,
            cached: cached,
            cacheWrite: write5m + write1h,
            cacheWrite5m: write5m,
            cacheWrite1h: write1h,
            output: output,
            total: total,
            uncached: uncached,
            cost: price.cost.rawValue,
            pricingRuleID: price.ruleID,
            pricingStatus: price.status.rawValue,
            sourcePath: sourcePath,
            lineOffset: event.lineOffset,
            lineBytes: event.lineBytes,
            catalogVersion: ClaudeBundledPricingCatalog.version
        )
        let existing = try database.executeQuery(
            sql: """
            SELECT root_session_id, timestamp_ms, model_raw, model_canonical,
                   input_tokens, cached_input_tokens, cache_write_input_tokens,
                   cache_write_5m_input_tokens, cache_write_1h_input_tokens,
                   output_tokens, total_tokens, uncached_input_tokens,
                   estimated_cost_usd_nano, pricing_rule_id, pricing_status,
                   source_path, line_offset, line_bytes, pricing_catalog_version
            FROM codex_usage_events
            WHERE event_id = ?;
            """,
            bindings: [eventID]
        ) { statement in
            ClaudeStoredEventFingerprint(
                rootSessionID: String(cString: sqlite3_column_text(statement, 0)),
                timestampMs: sqlite3_column_int64(statement, 1),
                modelRaw: String(cString: sqlite3_column_text(statement, 2)),
                modelCanonical: String(cString: sqlite3_column_text(statement, 3)),
                input: sqlite3_column_int64(statement, 4),
                cached: sqlite3_column_int64(statement, 5),
                cacheWrite: sqlite3_column_int64(statement, 6),
                cacheWrite5m: sqlite3_column_int64(statement, 7),
                cacheWrite1h: sqlite3_column_int64(statement, 8),
                output: sqlite3_column_int64(statement, 9),
                total: sqlite3_column_int64(statement, 10),
                uncached: sqlite3_column_int64(statement, 11),
                cost: sqlite3_column_int64(statement, 12),
                pricingRuleID: sqlite3_column_type(statement, 13) == SQLITE_NULL
                    ? nil : String(cString: sqlite3_column_text(statement, 13)),
                pricingStatus: String(cString: sqlite3_column_text(statement, 14)),
                sourcePath: String(cString: sqlite3_column_text(statement, 15)),
                lineOffset: sqlite3_column_int64(statement, 16),
                lineBytes: sqlite3_column_int64(statement, 17),
                catalogVersion: sqlite3_column_type(statement, 18) == SQLITE_NULL
                    ? nil : String(cString: sqlite3_column_text(statement, 18))
            )
        }.first
        if existing == proposed { return false }
        try database.executeUpdate(
            sql: """
            INSERT INTO codex_usage_events (
                event_id, session_id, root_session_id, turn_index, call_index,
                timestamp_ms, model_raw, model_canonical, service_tier, reasoning_effort,
                input_tokens, cached_input_tokens, cache_write_input_tokens,
                cache_write_5m_input_tokens, cache_write_1h_input_tokens,
                output_tokens, reasoning_output_tokens, total_tokens, uncached_input_tokens,
                estimated_cost_usd_nano, pricing_rule_id, pricing_status,
                usage_derivation, attribution_quality, is_child_replay,
                source_path, line_offset, line_bytes, created_at,
                timestamp_quality, timestamp_source, timestamp_conflict_count,
                pricing_catalog_version, provider, provider_message_id
            ) VALUES (
                ?, ?, ?, 0, 0, ?, ?, ?, NULL, NULL,
                ?, ?, ?, ?, ?, ?, 0, ?, ?, ?, ?, ?,
                'explicit_last_usage', 'direct_turn_context', 0,
                ?, ?, ?, unixepoch(), 'event_timestamp', 'top_level_timestamp', 0,
                ?, 'claude', ?
            )
            ON CONFLICT(event_id) DO UPDATE SET
                root_session_id = excluded.root_session_id,
                timestamp_ms = excluded.timestamp_ms,
                model_raw = excluded.model_raw,
                model_canonical = excluded.model_canonical,
                input_tokens = excluded.input_tokens,
                cached_input_tokens = excluded.cached_input_tokens,
                cache_write_input_tokens = excluded.cache_write_input_tokens,
                cache_write_5m_input_tokens = excluded.cache_write_5m_input_tokens,
                cache_write_1h_input_tokens = excluded.cache_write_1h_input_tokens,
                output_tokens = excluded.output_tokens,
                total_tokens = excluded.total_tokens,
                uncached_input_tokens = excluded.uncached_input_tokens,
                estimated_cost_usd_nano = excluded.estimated_cost_usd_nano,
                pricing_rule_id = excluded.pricing_rule_id,
                pricing_status = excluded.pricing_status,
                source_path = excluded.source_path,
                line_offset = excluded.line_offset,
                line_bytes = excluded.line_bytes,
                pricing_catalog_version = excluded.pricing_catalog_version;
            """,
            bindings: [
                eventID, sessionID, rootSessionID, timestampMs,
                event.modelRaw, price.modelCanonical,
                grossInput, cached, write5m + write1h, write5m, write1h,
                output, total, uncached,
                price.cost.rawValue, price.ruleID, price.status.rawValue,
                sourcePath, event.lineOffset, event.lineBytes,
                ClaudeBundledPricingCatalog.version, providerMessageID
            ]
        )
        return true
    }

    private func upsertSessionMetadata(
        slice: ParsedClaudeSlice,
        file: ClaudeHistoryFile,
        sessionID: String,
        rootSessionID: String,
        parentSessionID: String?
    ) throws {
        let startedMs = Int64((slice.startedAt ?? slice.updatedAt ?? Date()).timeIntervalSince1970 * 1_000)
        let updatedMs = Int64((slice.updatedAt ?? slice.startedAt ?? Date()).timeIntervalSince1970 * 1_000)
        let project = slice.cwd.flatMap { cwd -> String? in
            let value = URL(fileURLWithPath: cwd).lastPathComponent
            return value.isEmpty ? nil : value
        }
        try database.executeUpdate(
            sql: """
            INSERT INTO codex_sessions (
                session_id, root_session_id, parent_session_id, depth,
                source_path, relative_path, bucket, title, project_name, cwd,
                created_at, updated_at, last_event_at, event_count,
                total_tokens, input_tokens, cached_input_tokens, cache_write_input_tokens,
                output_tokens, reasoning_output_tokens, estimated_cost_usd_nano,
                pricing_status, metadata_fingerprint, has_subagents,
                summary_provenance, provider
            ) VALUES (
                ?, ?, ?, ?, ?, ?, 'active', ?, ?, ?, ?, ?, ?, 0,
                0, 0, 0, 0, 0, 0, 0, 'fullyUnpriced', NULL, 0, 'eventLedger', 'claude'
            )
            ON CONFLICT(session_id) DO UPDATE SET
                root_session_id = excluded.root_session_id,
                parent_session_id = excluded.parent_session_id,
                depth = excluded.depth,
                source_path = CASE WHEN ? = 0 THEN excluded.source_path ELSE codex_sessions.source_path END,
                relative_path = CASE WHEN ? = 0 THEN excluded.relative_path ELSE codex_sessions.relative_path END,
                title = COALESCE(excluded.title, codex_sessions.title),
                project_name = COALESCE(excluded.project_name, codex_sessions.project_name),
                cwd = COALESCE(excluded.cwd, codex_sessions.cwd),
                created_at = MIN(codex_sessions.created_at, excluded.created_at),
                updated_at = MAX(codex_sessions.updated_at, excluded.updated_at),
                last_event_at = MAX(COALESCE(codex_sessions.last_event_at, 0), COALESCE(excluded.last_event_at, 0)),
                has_subagents = EXISTS (
                    SELECT 1 FROM codex_sessions AS children
                    WHERE children.provider = 'claude'
                      AND children.parent_session_id = excluded.session_id
                ),
                provider = 'claude';
            """,
            bindings: [
                sessionID, rootSessionID, parentSessionID, file.depth,
                file.path, file.relativePath,
                slice.title, project, slice.cwd,
                startedMs, updatedMs, updatedMs,
                file.isSubagent ? 1 : 0, file.isSubagent ? 1 : 0
            ]
        )
    }

    private func removeOrphanedSessions(_ sessionIDs: Set<String>) throws {
        for sessionID in sessionIDs {
            let rawSessionID = UsageSessionIdentity.rawID(provider: .claude, sessionKey: sessionID)
            try database.executeUpdate(
                sql: """
                DELETE FROM codex_sessions
                WHERE provider = 'claude'
                  AND session_id = ?
                  AND NOT EXISTS (
                      SELECT 1 FROM codex_usage_events
                      WHERE provider = 'claude' AND session_id = ?
                  )
                  AND NOT EXISTS (
                      SELECT 1 FROM claude_import_sources
                      WHERE session_id = ?
                  )
                  AND NOT EXISTS (
                      SELECT 1 FROM codex_sessions AS children
                      WHERE children.provider = 'claude'
                        AND children.parent_session_id = ?
                  );
                """,
                bindings: [sessionID, sessionID, rawSessionID, sessionID]
            )
        }
    }

    private func updateHasSubagents(sessionID: String) throws {
        try database.executeUpdate(
            sql: """
            UPDATE codex_sessions
            SET has_subagents = EXISTS (
                SELECT 1 FROM codex_sessions AS children
                WHERE children.provider = 'claude'
                  AND children.parent_session_id = codex_sessions.session_id
            )
            WHERE provider = 'claude' AND session_id = ?;
            """,
            bindings: [sessionID]
        )
    }

    private func repairStoredSubagentSessions(
        states: [String: ClaudeImportSourceState]
    ) throws -> Int {
        var repairedSessionIDs = Set<String>()
        var parentSessionIDs = Set<String>()
        try database.transaction {
            for state in states.values {
                guard let relationship = claudeSubagentRelationship(relativePath: state.relativePath) else { continue }
                guard let rawSessionID = state.sessionID?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !rawSessionID.isEmpty,
                      !relationship.ancestorSessionIDs.contains(rawSessionID) else {
                    let errorMessage = sourceErrorMessage(status: "repair_invalid_identity")
                    try database.executeUpdate(
                        sql: """
                        UPDATE claude_import_sources
                        SET status = 'repair_invalid_identity', error_message = ?, last_imported_at = unixepoch()
                        WHERE source_path = ?;
                        """,
                        bindings: [errorMessage, state.sourcePath]
                    )
                    if let rawSessionID = state.sessionID,
                       let ancestorIndex = relationship.ancestorSessionIDs.firstIndex(of: rawSessionID) {
                        let sessionID = UsageSessionIdentity.key(provider: .claude, rawSessionID: rawSessionID)
                        let rootSessionID = UsageSessionIdentity.key(
                            provider: .claude,
                            rawSessionID: relationship.rootSessionID
                        )
                        let parentSessionID = ancestorIndex == 0 ? nil : UsageSessionIdentity.key(
                            provider: .claude,
                            rawSessionID: relationship.ancestorSessionIDs[ancestorIndex - 1]
                        )
                        let isSelfParent = try database.intScalar(
                            sql: """
                            SELECT COUNT(*) FROM codex_sessions
                            WHERE provider = 'claude' AND session_id = ? AND parent_session_id = session_id;
                            """,
                            bindings: [sessionID]
                        ) > 0
                        if isSelfParent {
                            try database.executeUpdate(
                                sql: """
                                UPDATE codex_sessions
                                SET root_session_id = ?, parent_session_id = ?, depth = ?,
                                    has_subagents = EXISTS (
                                        SELECT 1 FROM codex_sessions AS children
                                        WHERE children.provider = 'claude'
                                          AND children.parent_session_id = codex_sessions.session_id
                                          AND children.session_id != codex_sessions.session_id
                                    )
                                WHERE provider = 'claude' AND session_id = ? AND parent_session_id = session_id;
                                """,
                                bindings: [rootSessionID, parentSessionID, ancestorIndex, sessionID]
                            )
                            try database.executeUpdate(
                                sql: """
                                UPDATE codex_usage_events
                                SET root_session_id = ?
                                WHERE provider = 'claude' AND session_id = ?;
                                """,
                                bindings: [rootSessionID, sessionID]
                            )
                            repairedSessionIDs.insert(sessionID)
                            if let parentSessionID { parentSessionIDs.insert(parentSessionID) }
                        }
                    }
                    continue
                }
                let sessionID = UsageSessionIdentity.key(provider: .claude, rawSessionID: rawSessionID)
                let rootSessionID = UsageSessionIdentity.key(
                    provider: .claude,
                    rawSessionID: relationship.rootSessionID
                )
                let parentSessionID = UsageSessionIdentity.key(
                    provider: .claude,
                    rawSessionID: relationship.parentSessionID
                )
                try database.executeUpdate(
                    sql: """
                    UPDATE codex_sessions
                    SET root_session_id = ?, parent_session_id = ?, depth = ?,
                        has_subagents = EXISTS (
                            SELECT 1 FROM codex_sessions AS children
                            WHERE children.provider = 'claude'
                              AND children.parent_session_id = codex_sessions.session_id
                        )
                    WHERE provider = 'claude' AND session_id = ?;
                    """,
                    bindings: [rootSessionID, parentSessionID, relationship.depth, sessionID]
                )
                try database.executeUpdate(
                    sql: """
                    UPDATE codex_usage_events
                    SET root_session_id = ?
                    WHERE provider = 'claude' AND session_id = ?;
                    """,
                    bindings: [rootSessionID, sessionID]
                )
                try rebuildSummaries(sessionID: sessionID)
                try database.executeUpdate(
                    sql: "UPDATE claude_import_sources SET status = 'indexed', error_message = NULL WHERE source_path = ? AND status = ?;",
                    bindings: [state.sourcePath, Self.repairPendingStatus]
                )
                repairedSessionIDs.insert(sessionID)
                parentSessionIDs.insert(parentSessionID)
            }
            for parentSessionID in parentSessionIDs {
                try updateHasSubagents(sessionID: parentSessionID)
            }
        }
        return repairedSessionIDs.count
    }

    private func updateChildRepairStatus() throws {
        let states = try loadSourceStates()
        let hasPendingRepair = states.values.contains { state in
            guard claudeSubagentRelationship(relativePath: state.relativePath) != nil else { return false }
            return [
                Self.repairPendingStatus,
                "partial",
                "incompatible",
                "pending_session_identity",
                "repair_invalid_identity"
            ].contains(state.status)
        }
        try database.executeUpdate(
            sql: "INSERT OR REPLACE INTO app_metadata (key, value, updated_at) VALUES (?, ?, unixepoch());",
            bindings: [Self.childRepairStatusKey, hasPendingRepair ? "partial" : "completed"]
        )
    }

    private func rebuildSummaries(sessionID: String) throws {
        var byModel: [String: ClaudeAggregate] = [:]
        var byDayModel: [ClaudeDayModelKey: ClaudeAggregate] = [:]
        var all = ClaudeAggregate.zero
        let calendar = UsageDayBucketer.calendar()
        try database.withPreparedStatement(sql: """
        SELECT timestamp_ms, model_canonical, input_tokens, cached_input_tokens,
               cache_write_input_tokens, output_tokens, reasoning_output_tokens,
               total_tokens, estimated_cost_usd_nano, pricing_status
        FROM codex_usage_events
        WHERE provider = 'claude' AND session_id = ?
        ORDER BY timestamp_ms ASC;
        """) { statement in
            let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            sqlite3_bind_text(statement, 1, (sessionID as NSString).utf8String, -1, transient)
            var result = sqlite3_step(statement)
            while result == SQLITE_ROW {
                let event = ClaudeAggregateEvent(
                    timestampMs: sqlite3_column_int64(statement, 0),
                    model: String(cString: sqlite3_column_text(statement, 1)),
                    input: sqlite3_column_int64(statement, 2),
                    cached: sqlite3_column_int64(statement, 3),
                    cacheWrite: sqlite3_column_int64(statement, 4),
                    output: sqlite3_column_int64(statement, 5),
                    reasoning: sqlite3_column_int64(statement, 6),
                    total: sqlite3_column_int64(statement, 7),
                    cost: sqlite3_column_int64(statement, 8),
                    priced: String(cString: sqlite3_column_text(statement, 9)) == PricingStatus.priced.rawValue
                )
                byModel[event.model, default: .zero].add(event)
                let date = Date(timeIntervalSince1970: Double(event.timestampMs) / 1_000)
                let key = LocalDayKey(date: date, calendar: calendar)
                let dayStart = Int64(calendar.startOfDay(for: date).timeIntervalSince1970 * 1_000)
                byDayModel[
                    ClaudeDayModelKey(dayKey: key.yyyyMMdd, dayStartMs: dayStart, model: event.model),
                    default: .zero
                ].add(event)
                all.add(event)
                result = sqlite3_step(statement)
            }
            guard result == SQLITE_DONE else {
                throw NSError(
                    domain: "QuotaLens.ClaudeUsageImporter",
                    code: Int(result),
                    userInfo: [NSLocalizedDescriptionKey: L10n.text(
                        "Claude 统计暂时无法更新。",
                        "Claude statistics could not be updated right now."
                    )]
                )
            }
        }

        try database.executeUpdate(
            sql: "DELETE FROM codex_session_summaries WHERE provider = 'claude' AND session_id = ?;",
            bindings: [sessionID]
        )
        try database.executeUpdate(
            sql: "DELETE FROM codex_daily_usage_summaries WHERE provider = 'claude' AND session_id = ?;",
            bindings: [sessionID]
        )

        for (model, aggregate) in byModel {
            try insertSessionSummary(sessionID: sessionID, model: model, aggregate: aggregate)
        }
        for (key, aggregate) in byDayModel {
            try insertDailySummary(sessionID: sessionID, key: key, aggregate: aggregate)
        }

        let status = AggregatePricingStatus(
            eventCount: all.eventCount,
            unpricedEventCount: all.unpricedCount
        ).rawValue
        try database.executeUpdate(
            sql: """
            UPDATE codex_sessions
            SET event_count = ?, total_tokens = ?, input_tokens = ?,
                cached_input_tokens = ?, cache_write_input_tokens = ?,
                output_tokens = ?, reasoning_output_tokens = ?,
                estimated_cost_usd_nano = ?, pricing_status = ?,
                last_event_at = COALESCE((
                    SELECT MAX(timestamp_ms) FROM codex_usage_events
                    WHERE provider = 'claude' AND session_id = ?
                ), last_event_at),
                summary_provenance = 'eventLedger', provider = 'claude'
            WHERE session_id = ?;
            """,
            bindings: [
                all.eventCount, all.total, all.input, all.cached, all.cacheWrite,
                all.output, all.reasoning, all.cost, status, sessionID, sessionID
            ]
        )
    }

    private func insertSessionSummary(
        sessionID: String,
        model: String,
        aggregate: ClaudeAggregate
    ) throws {
        try database.executeUpdate(
            sql: """
            INSERT INTO codex_session_summaries (
                session_id, model_canonical, event_count, total_tokens,
                uncached_input_tokens, cached_input_tokens, cache_write_input_tokens,
                output_tokens, reasoning_output_tokens, estimated_cost_usd_nano,
                unpriced_event_count, unpriced_token_count,
                unpriced_unknown_model_event_count, unpriced_unknown_model_token_count,
                summary_provenance, provider
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'eventLedger', 'claude');
            """,
            bindings: aggregate.bindings(prefix: [sessionID, model])
        )
    }

    private func insertDailySummary(
        sessionID: String,
        key: ClaudeDayModelKey,
        aggregate: ClaudeAggregate
    ) throws {
        try database.executeUpdate(
            sql: """
            INSERT INTO codex_daily_usage_summaries (
                session_id, day_key, day_start_ms, model_canonical,
                event_count, total_tokens, uncached_input_tokens, cached_input_tokens,
                cache_write_input_tokens, output_tokens, reasoning_output_tokens,
                estimated_cost_usd_nano, unpriced_event_count, unpriced_token_count,
                unpriced_unknown_model_event_count, unpriced_unknown_model_token_count,
                summary_provenance, provider
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'eventLedger', 'claude');
            """,
            bindings: aggregate.bindings(prefix: [sessionID, key.dayKey, key.dayStartMs, key.model])
        )
    }

    private func loadSourceStates() throws -> [String: ClaudeImportSourceState] {
        let values = try database.executeQuery(
            sql: """
            SELECT source_path, relative_path, session_id, file_size, mtime_ms,
                   byte_offset, status, malformed_line_count, error_message
            FROM claude_import_sources;
            """
        ) { statement -> ClaudeImportSourceState in
            ClaudeImportSourceState(
                sourcePath: String(cString: sqlite3_column_text(statement, 0)),
                relativePath: String(cString: sqlite3_column_text(statement, 1)),
                sessionID: sqlite3_column_type(statement, 2) == SQLITE_NULL
                    ? nil : String(cString: sqlite3_column_text(statement, 2)),
                fileSize: sqlite3_column_int64(statement, 3),
                mtimeMs: sqlite3_column_int64(statement, 4),
                byteOffset: sqlite3_column_int64(statement, 5),
                status: String(cString: sqlite3_column_text(statement, 6)),
                malformedLineCount: Int(sqlite3_column_int(statement, 7)),
                errorMessage: sqlite3_column_type(statement, 8) == SQLITE_NULL
                    ? nil : String(cString: sqlite3_column_text(statement, 8))
            )
        }
        var result: [String: ClaudeImportSourceState] = [:]
        for value in values {
            let key = Self.canonicalPath(value.sourcePath)
            if let existing = result[key],
               (existing.mtimeMs, existing.byteOffset) >= (value.mtimeMs, value.byteOffset) {
                continue
            }
            result[key] = value
        }
        return result
    }

    private static func defaultRoots() -> [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            home.appendingPathComponent(".claude/projects", isDirectory: true),
            home.appendingPathComponent(".config/claude/projects", isDirectory: true)
        ]
    }

    private static func canonicalPath(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
    }

    private static func scanFiles(roots: [URL]) -> ClaudeHistoryScanResult {
        let manager = FileManager.default
        var results: [ClaudeHistoryFile] = []
        var errors: [String] = []
        var seenCanonicalPaths = Set<String>()
        for root in roots {
            do {
                let attributes = try manager.attributesOfItem(atPath: root.path)
                guard attributes[.type] as? FileAttributeType == .typeDirectory else { continue }
            } catch CocoaError.fileReadNoSuchFile, CocoaError.fileNoSuchFile {
                continue
            } catch {
                errors.append("\(root.lastPathComponent): \(error.localizedDescription)")
                continue
            }
            let canonicalRoot = root.resolvingSymlinksInPath().standardizedFileURL
            guard let enumerator = manager.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles],
                errorHandler: { url, error in
                    errors.append("\(url.lastPathComponent): \(error.localizedDescription)")
                    return true
                }
            ) else {
                errors.append("\(root.lastPathComponent): directory could not be read")
                continue
            }
            for case let url as URL in enumerator where url.pathExtension == "jsonl" {
                let values: URLResourceValues
                do {
                    values = try url.resourceValues(forKeys: [
                        .isRegularFileKey, .fileSizeKey, .contentModificationDateKey
                    ])
                } catch {
                    errors.append("\(url.lastPathComponent): \(error.localizedDescription)")
                    continue
                }
                guard values.isRegularFile == true else { continue }
                let canonicalURL = url.resolvingSymlinksInPath().standardizedFileURL
                guard seenCanonicalPaths.insert(canonicalURL.path).inserted else { continue }
                let rootPrefix = canonicalRoot.path.hasSuffix("/") ? canonicalRoot.path : canonicalRoot.path + "/"
                let relative = canonicalURL.path.hasPrefix(rootPrefix)
                    ? String(canonicalURL.path.dropFirst(rootPrefix.count))
                    : url.lastPathComponent
                results.append(ClaudeHistoryFile(
                    url: canonicalURL,
                    relativePath: relative,
                    size: Int64(values.fileSize ?? 0),
                    mtimeMs: Int64((values.contentModificationDate?.timeIntervalSince1970 ?? 0) * 1_000)
                ))
            }
        }
        return ClaudeHistoryScanResult(
            files: results.sorted { $0.path < $1.path },
            errors: errors
        )
    }

    private static func parse(file: ClaudeHistoryFile, fromOffset: Int64) throws -> ParsedClaudeSlice {
        let handle = try FileHandle(forReadingFrom: file.url)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(fromOffset))
        let newline: UInt8 = 0x0A
        let chunkSize = 256 * 1_024
        let maximumLineBytes = 8 * 1_024 * 1_024
        var buffer = Data()
        var bufferStartOffset = fromOffset
        var discardingOversizedLine = false
        var sessionID: String?
        var title: String?
        var cwd: String?
        var startedAt: Date?
        var updatedAt: Date?
        let eventStore = try ClaudeParsedEventStore()
        var eventBatch: [ParsedClaudeEvent] = []
        eventBatch.reserveCapacity(256)
        var health = ClaudeParseHealth()

        func flushEvents() throws {
            try eventStore.store(eventBatch)
            eventBatch.removeAll(keepingCapacity: true)
        }

        func processLine(_ line: Data, lineOffset: Int64, lineBytes: Int64) throws {
            guard !line.isEmpty else { return }
            health.completeLineCount += 1
            guard line.count <= maximumLineBytes else {
                health.malformedJSONLineCount += 1
                return
            }
            let object: Any
            do {
                object = try JSONSerialization.jsonObject(with: line)
            } catch {
                health.malformedJSONLineCount += 1
                return
            }
            guard let raw = object as? [String: Any] else {
                health.malformedJSONLineCount += 1
                return
            }
            let type = raw["type"] as? String
            if sessionID == nil,
               let value = raw["sessionId"] as? String,
               !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                sessionID = value
            }
            if cwd == nil, let value = raw["cwd"] as? String, !value.isEmpty { cwd = value }
            if title == nil, type == "ai-title",
               let value = raw["aiTitle"] as? String, !value.isEmpty { title = value }
            let timestamp = Self.parseDate(raw["timestamp"] as? String)
            if let timestamp {
                startedAt = startedAt ?? timestamp
                updatedAt = max(updatedAt ?? timestamp, timestamp)
            }
            guard type == "assistant" else { return }
            health.assistantLineCount += 1
            guard let timestamp,
                  let message = raw["message"] as? [String: Any],
                  let usage = message["usage"] as? [String: Any],
                  let messageID = message["id"] as? String,
                  !messageID.isEmpty else {
                health.incompatibleUsageLineCount += 1
                return
            }
            let model = message["model"] as? String ?? "unknown"
            if model == "<synthetic>" {
                health.recognizedUsageLineCount += 1
                return
            }
            guard let schema = usageSchemaVersion(usage) else {
                health.incompatibleUsageLineCount += 1
                return
            }
            let flatTokenKeys = [
                "input_tokens", "cache_read_input_tokens",
                "cache_creation_input_tokens", "output_tokens"
            ]
            guard flatTokenKeys.allSatisfy({ key in
                !usage.keys.contains(key) || parsedInt64(usage[key]) != nil
            }) else {
                health.incompatibleUsageLineCount += 1
                return
            }
            let cache = schema == .cacheCreationObject
                ? usage["cache_creation"] as? [String: Any] : nil
            let nestedTokenKeys = ["ephemeral_1h_input_tokens", "ephemeral_5m_input_tokens"]
            guard nestedTokenKeys.allSatisfy({ key in
                guard let cache else { return true }
                return !cache.keys.contains(key) || parsedInt64(cache[key]) != nil
            }) else {
                health.incompatibleUsageLineCount += 1
                return
            }
            let uncached = parsedInt64(usage["input_tokens"]) ?? 0
            let cached = parsedInt64(usage["cache_read_input_tokens"]) ?? 0
            let totalWrite = parsedInt64(usage["cache_creation_input_tokens"]) ?? 0
            let output = parsedInt64(usage["output_tokens"]) ?? 0
            let oneHour = parsedInt64(cache?["ephemeral_1h_input_tokens"]) ?? 0
            let fiveRaw = parsedInt64(cache?["ephemeral_5m_input_tokens"]) ?? 0
            health.recognizedUsageLineCount += 1
            let five = fiveRaw + max(0, totalWrite - oneHour - fiveRaw)
            let event = ParsedClaudeEvent(
                messageID: messageID,
                timestamp: timestamp,
                modelRaw: model,
                uncachedInput: uncached,
                cachedInput: cached,
                cacheWrite5m: five,
                cacheWrite1h: oneHour,
                output: output,
                lineOffset: lineOffset,
                lineBytes: lineBytes
            )
            guard event.totalTokens > 0 else { return }
            eventBatch.append(event)
            if eventBatch.count == 256 {
                try flushEvents()
            }
        }

        while true {
            let chunk = try handle.read(upToCount: chunkSize) ?? Data()
            guard !chunk.isEmpty else { break }
            var remaining = chunk
            if discardingOversizedLine {
                if let newlineIndex = remaining.firstIndex(of: newline) {
                    let consumed = remaining.distance(from: remaining.startIndex, to: newlineIndex) + 1
                    bufferStartOffset += Int64(consumed)
                    remaining.removeFirst(consumed)
                    discardingOversizedLine = false
                } else {
                    bufferStartOffset += Int64(remaining.count)
                    continue
                }
            }
            buffer.append(remaining)
            var cursor = buffer.startIndex
            while let newlineIndex = buffer[cursor...].firstIndex(of: newline) {
                let lineLength = buffer.distance(from: cursor, to: newlineIndex)
                let line = Data(buffer[cursor..<newlineIndex])
                let lineBytes = Int64(lineLength + 1)
                let relativeOffset = buffer.distance(from: buffer.startIndex, to: cursor)
                try processLine(
                    line,
                    lineOffset: bufferStartOffset + Int64(relativeOffset),
                    lineBytes: lineBytes
                )
                cursor = buffer.index(after: newlineIndex)
            }
            if cursor > buffer.startIndex {
                let consumed = buffer.distance(from: buffer.startIndex, to: cursor)
                buffer.removeFirst(consumed)
                bufferStartOffset += Int64(consumed)
            }
            if buffer.count > maximumLineBytes {
                health.completeLineCount += 1
                health.malformedJSONLineCount += 1
                bufferStartOffset += Int64(buffer.count)
                buffer.removeAll(keepingCapacity: true)
                discardingOversizedLine = true
            }
        }

        var endOffset = bufferStartOffset
        if !buffer.isEmpty {
            if (try? JSONSerialization.jsonObject(with: buffer)) != nil {
                try processLine(
                    buffer,
                    lineOffset: bufferStartOffset,
                    lineBytes: Int64(buffer.count)
                )
                endOffset += Int64(buffer.count)
            } else {
                health.trailingPartialBytes = buffer.count
            }
        }
        try flushEvents()
        return ParsedClaudeSlice(
            payloadSessionID: sessionID,
            title: title,
            cwd: cwd,
            startedAt: startedAt,
            updatedAt: updatedAt,
            eventStore: eventStore,
            endOffset: endOffset,
            health: health
        )
    }

    private static func parseDate(_ raw: String?) -> Date? {
        guard let raw else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: raw) ?? ISO8601DateFormatter().date(from: raw)
    }

    private static func usageSchemaVersion(_ usage: [String: Any]) -> ClaudeUsageSchemaVersion? {
        guard usage.keys.contains("input_tokens"),
              usage.keys.contains("output_tokens") else { return nil }
        if usage.keys.contains("cache_creation") {
            return usage["cache_creation"] is [String: Any] ? .cacheCreationObject : nil
        }
        return .legacyFlat
    }

    private static func parsedInt64(_ value: Any?) -> Int64? {
        if let value = value as? Int64 { return value >= 0 ? value : nil }
        if let value = value as? Int { return value >= 0 ? Int64(value) : nil }
        if let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID() {
            let number = value.doubleValue
            let parsed = value.int64Value
            guard number.isFinite,
                  parsed >= 0,
                  Double(parsed) == number else { return nil }
            return parsed
        }
        if let value = value as? String, let parsed = Int64(value), parsed >= 0 { return parsed }
        return nil
    }

    private static func escapeLike(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
    }
}

private struct ClaudeAggregateEvent {
    let timestampMs: Int64
    let model: String
    let input: Int64
    let cached: Int64
    let cacheWrite: Int64
    let output: Int64
    let reasoning: Int64
    let total: Int64
    let cost: Int64
    let priced: Bool
}

private struct ClaudeAggregate {
    var eventCount = 0
    var input: Int64 = 0
    var cached: Int64 = 0
    var cacheWrite: Int64 = 0
    var output: Int64 = 0
    var reasoning: Int64 = 0
    var total: Int64 = 0
    var cost: Int64 = 0
    var unpricedCount = 0
    var unpricedTokens: Int64 = 0

    static let zero = ClaudeAggregate()

    mutating func add(_ event: ClaudeAggregateEvent) {
        eventCount += 1
        input += event.input
        cached += event.cached
        cacheWrite += event.cacheWrite
        output += event.output
        reasoning += event.reasoning
        total += event.total
        cost += event.cost
        if !event.priced {
            unpricedCount += 1
            unpricedTokens += event.total
        }
    }

    func bindings(prefix: [Any?]) -> [Any?] {
        prefix + [
            eventCount, total, max(0, input - cached - cacheWrite), cached,
            cacheWrite, output, reasoning, cost, unpricedCount, unpricedTokens,
            unpricedCount, unpricedTokens
        ]
    }
}

private struct ClaudeDayModelKey: Hashable {
    let dayKey: String
    let dayStartMs: Int64
    let model: String
}

@MainActor
public final class ClaudeUsageScanCoordinator: ObservableObject {
    @Published public private(set) var isScanning = false
    @Published public private(set) var lastScanTime: Date?
    @Published public private(set) var lastSummary: ClaudeUsageImportSummary?
    @Published public private(set) var statusText = ""
    @Published public private(set) var errorText: String?

    private var importer: ClaudeUsageImportActor?
    private var hasPendingScan = false
    private var pendingForceRebuild = false

    public init() {}

    public func configure(database: SQLiteDatabase) {
        importer = ClaudeUsageImportActor(database: database)
    }

    public func scanNow(forceRebuild: Bool = false) async {
        guard ClaudeUsageSettings.shared.isEnabled, let importer else { return }
        if isScanning {
            hasPendingScan = true
            pendingForceRebuild = pendingForceRebuild || forceRebuild
            return
        }
        isScanning = true
        errorText = nil
        statusText = L10n.text("正在读取 Claude 本地记录…", "Reading Claude local history...")
        defer {
            isScanning = false
            if hasPendingScan, ClaudeUsageSettings.shared.isEnabled {
                let force = pendingForceRebuild
                hasPendingScan = false
                pendingForceRebuild = false
                Task { @MainActor [weak self] in
                    await self?.scanNow(forceRebuild: force)
                }
            } else {
                hasPendingScan = false
                pendingForceRebuild = false
            }
        }
        do {
            let summary = try await importer.scan(forceRebuild: forceRebuild)
            lastSummary = summary
            lastScanTime = Date()
            if summary.errors.isEmpty {
                statusText = L10n.format(
                    "Read %d Claude files and updated %d records",
                    zhHans: "已读取 %d 个 Claude 文件，更新 %d 条记录",
                    summary.filesScanned,
                    summary.eventsUpdated
                )
            } else {
                statusText = L10n.text("Claude 本地记录已部分更新", "Claude local history was partially updated")
                errorText = userFacingErrorText(summary.errors)
            }
        } catch {
            statusText = L10n.text("Claude 本地记录更新失败", "Claude local history update failed")
            errorText = L10n.text("暂时无法读取 Claude 本地记录，请稍后重试。", "Claude local history could not be read. Try again later.")
        }
    }

    private func userFacingErrorText(_ errors: [String]) -> String {
        var messages: [String] = []
        for error in errors {
            let message: String
            if let separator = error.range(of: ": ") {
                message = String(error[separator.upperBound...])
            } else {
                message = error
            }
            if !messages.contains(message) { messages.append(message) }
        }
        let visible = messages.prefix(3)
        var text = visible.joined(separator: "\n")
        if messages.count > visible.count {
            text += "\n" + L10n.format(
                "%d more Claude records need attention.",
                zhHans: "另有 %d 条 Claude 记录需要处理。",
                messages.count - visible.count
            )
        }
        return text
    }
}

final class ClaudeFileWatcher: @unchecked Sendable {
    private let directories: [URL]
    private let queue = DispatchQueue(label: "QuotaLens.ClaudeFileWatcher", qos: .utility)
    private let onChange: @Sendable () -> Void
    private var stream: FSEventStreamRef?

    init(
        directories: [URL] = ClaudeFileWatcher.defaultDirectories(),
        onChange: @escaping @Sendable () -> Void
    ) {
        self.directories = directories
        self.onChange = onChange
    }

    static func defaultDirectories() -> [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            home.appendingPathComponent(".claude/projects", isDirectory: true),
            home.appendingPathComponent(".config/claude/projects", isDirectory: true)
        ].filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    @discardableResult
    func start() -> Bool {
        if stream != nil { return true }
        guard !directories.isEmpty else { return false }
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        guard let created = FSEventStreamCreate(
            kCFAllocatorDefault,
            { _, info, _, _, _, _ in
                guard let info else { return }
                Unmanaged<ClaudeFileWatcher>
                    .fromOpaque(info)
                    .takeUnretainedValue()
                    .onChange()
            },
            &context,
            directories.map(\.path) as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            1.0,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagNoDefer)
        ) else { return false }
        FSEventStreamSetDispatchQueue(created, queue)
        guard FSEventStreamStart(created) else {
            FSEventStreamInvalidate(created)
            FSEventStreamRelease(created)
            return false
        }
        stream = created
        return true
    }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    deinit { stop() }
}
