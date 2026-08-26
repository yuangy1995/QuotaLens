// QuotaLens 增量用量导入引擎 (单写者 Actor)
// 管理完整扫描、增量流式解析、内存聚合与最终汇总提交

import Foundation
import Darwin
import CryptoKit
import SQLite3

public struct ImportSummary: Sendable {
    public let sourcesScanned: Int
    public let sourcesUpdated: Int
    public let eventsInserted: Int
    public let bytesRead: Int64
    public let durationSeconds: Double
    public let warningMessage: String?

    public init(
        sourcesScanned: Int = 0,
        sourcesUpdated: Int = 0,
        eventsInserted: Int = 0,
        bytesRead: Int64 = 0,
        durationSeconds: Double = 0,
        warningMessage: String? = nil
    ) {
        self.sourcesScanned = sourcesScanned
        self.sourcesUpdated = sourcesUpdated
        self.eventsInserted = eventsInserted
        self.bytesRead = bytesRead
        self.durationSeconds = durationSeconds
        self.warningMessage = warningMessage
    }
}

public actor CodexUsageImportActor {
    private let database: SQLiteDatabase
    private let scanHistory: @Sendable (CodexHistoryPaths, Bool) -> ScanOutcome
    private var isImporting = false

    public init(
        database: SQLiteDatabase,
        scanHistory: @escaping @Sendable (CodexHistoryPaths, Bool) -> ScanOutcome = { paths, scanArchived in
            CodexRolloutScanner.scan(paths: paths, scanArchived: scanArchived)
        }
    ) {
        self.database = database
        self.scanHistory = scanHistory
    }

    /// 执行全量或增量导入流水线
    public func importCodexHistory(
        paths: CodexHistoryPaths,
        forceRebuild: Bool = false,
        onProgress: (@Sendable (Double, String) -> Void)? = nil
    ) async throws -> ImportSummary {
        guard !isImporting else {
            return ImportSummary()
        }
        isImporting = true
        defer { isImporting = false }

        let monotonicStart = CFAbsoluteTimeGetCurrent()
        let startedAtMs = Self.unixMillis()
        let aggregationTimeZone = TimeZone.current
        onProgress?(0.01, L10n.text("正在检查计价目录与日期口径…", "Checking pricing and day boundaries..."))
        try PricingCatalogService.shared.ensureCatalogInstalled(database: database, timeZone: aggregationTimeZone) { progress, message in
            onProgress?(0.01 + 0.035 * progress, message)
        }
        let pricingSnapshot = try PricingCatalogService.shared.loadSnapshot(database: database)
        let scanGeneration = try nextScanGeneration()
        var parserRebuildDidFinish = false
        defer {
            if !parserRebuildDidFinish {
                try? updateParserRebuildMetadata(
                    status: "failed",
                    generation: scanGeneration,
                    error: "import interrupted before completion"
                )
            }
        }
        try updateParserRebuildMetadata(
            status: "running",
            generation: scanGeneration,
            error: nil,
            processedSources: 0,
            totalSources: 0
        )
        // 1. 扫描文件源
        onProgress?(0.05, L10n.text("正在扫描 Codex 会话文件…", "Scanning Codex session files..."))
        let scanOutcome = scanHistory(paths, UsageFeatureFlags.shared.isScanArchivedSessionsEnabled)
        try persistScanDiagnostics(scanOutcome.diagnostics, scanGeneration: scanGeneration)
        let scanIssueMessage = [
            Self.scanIssue(root: "sessions", status: scanOutcome.active),
            Self.scanIssue(root: "archived_sessions", status: scanOutcome.archived)
        ]
        .compactMap { $0 }
        .joined(separator: "; ")
        let scannedSources = scanOutcome.sources
        let rolloutHeaders = CodexSessionMetadataStore.loadFromRolloutHeaders(sources: scannedSources)
        let discoveredSources = scannedSources.map { source in
            canonicalizedSource(source, header: rolloutHeaders[source.fileURL.path])
        }
        try updateParserRebuildMetadata(
            status: "running",
            generation: scanGeneration,
            error: nil,
            processedSources: 0,
            totalSources: discoveredSources.count
        )

        // 2. 加载元数据与构建会话树
        onProgress?(0.15, L10n.text("正在解析会话元数据与父子关系…", "Resolving session metadata and tree..."))
        var rawMeta = CodexSessionMetadataStore.loadMetadata(paths: paths)
        for header in rolloutHeaders.values {
            guard let metadata = header.metadata else { continue }
            mergeMetadata(metadata, into: &rawMeta)
        }
        let discoveredIds = Set(discoveredSources.map(\.sessionId))
        let resolvedSessions = CodexSessionMetadataStore.reconcileSessionTree(
            discoveredIds: discoveredIds,
            rawMetadata: rawMeta
        )

        // 3. 读取现有检查点
        var sourcesUpdated = 0
        var totalEventsInserted = 0
        var totalBytesRead: Int64 = 0

        let totalFiles = max(1, discoveredSources.count)

        for (index, source) in discoveredSources.enumerated() {
            let progressFraction = 0.20 + (Double(index) / Double(totalFiles)) * 0.75
            onProgress?(progressFraction, L10n.format("Processing %d/%d: %@", zhHans: "正在处理 %d/%d: %@", index + 1, totalFiles, source.fileURL.lastPathComponent))

            let result = try autoreleasepool {
                try processSingleSource(
                    source: source,
                    resolvedSession: resolvedSessions[source.sessionId],
                    pricingSnapshot: pricingSnapshot,
                    forceRebuild: forceRebuild,
                    scanGeneration: scanGeneration,
                    aggregationTimeZone: aggregationTimeZone
                )
            }
            ImportMemoryBudget.relieveAllocatorPressure()

            if result.eventsInserted > 0 || result.bytesRead > 0 {
                sourcesUpdated += 1
                totalEventsInserted += result.eventsInserted
                totalBytesRead += result.bytesRead
            }
            try updateParserRebuildMetadata(
                status: "running",
                generation: scanGeneration,
                error: nil,
                processedSources: index + 1,
                totalSources: discoveredSources.count
            )
        }

        // 4. 更新全局代数与导入历史
        try tombstoneMissingSources(
            currentSourcePaths: Set(discoveredSources.map { $0.fileURL.path }),
            currentSessionIds: Set(discoveredSources.map(\.sessionId)),
            scanGeneration: scanGeneration,
            scanOutcome: scanOutcome,
            preserveMissingSources: forceRebuild
        )
        if try database.stringScalar(
            sql: "SELECT value FROM app_metadata WHERE key = 'pricing_reprice_status';"
        ) == "pending" {
            // 旧聚合索引在本轮恢复出事件后即可完成重计价，无需用户再启动一次扫描。
            try PricingCatalogService.shared.ensureCatalogInstalled(database: database, timeZone: aggregationTimeZone) { progress, message in
                onProgress?(0.95 + 0.04 * progress, message)
            }
        }

        let pendingSourceCount = try database.intScalar(
            sql: """
            SELECT COUNT(*) FROM codex_import_sources
            WHERE status != 'tombstoned' AND (parser_version != ? OR status = 'stale');
            """,
            bindings: [ParserCheckpoint.currentParserVersion]
        )
        let pendingMessage = pendingSourceCount > 0
            ? L10n.format("%d sources unavailable; previous index retained for retry", zhHans: "%d 个来源暂不可用，已保留旧索引，等待重试", pendingSourceCount)
            : ""
        let warningMessage = [scanIssueMessage, pendingMessage].filter { !$0.isEmpty }.joined(separator: "; ")

        let completedAtMs = Self.unixMillis()
        let duration = max(0.001, CFAbsoluteTimeGetCurrent() - monotonicStart)
        let runStatus = warningMessage.isEmpty ? "success" : "partial"
        try updateParserRebuildMetadata(
            status: !scanIssueMessage.isEmpty ? "failed" : (pendingSourceCount > 0 ? "pending" : "completed"),
            generation: scanGeneration,
            error: warningMessage.isEmpty ? nil : warningMessage,
            processedSources: discoveredSources.count,
            totalSources: discoveredSources.count + pendingSourceCount
        )
        parserRebuildDidFinish = true

        let runId = "run_\(Int64(Date().timeIntervalSince1970 * 1000))"
        try? database.executeUpdate(
            sql: """
            INSERT INTO codex_import_runs (
                run_id, started_at, completed_at, sources_scanned, sources_updated,
                events_inserted, bytes_read, status, error_message
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?);
            """,
            bindings: [
                runId,
                startedAtMs,
                completedAtMs,
                discoveredSources.count,
                sourcesUpdated,
                totalEventsInserted,
                totalBytesRead,
                runStatus,
                warningMessage.isEmpty ? nil : warningMessage
            ]
        )

        try? database.executeUpdate(
            sql: "INSERT OR REPLACE INTO app_metadata (key, value, updated_at) VALUES ('codex_usage_generation', unixepoch(), unixepoch());",
            bindings: []
        )

        let completionMessage = warningMessage.isEmpty
            ? L10n.text("导入完成", "Import complete")
            : L10n.text("导入完成（部分来源待重试）", "Import complete (some sources pending retry)")
        onProgress?(1.0, completionMessage)

        return ImportSummary(
            sourcesScanned: discoveredSources.count,
            sourcesUpdated: sourcesUpdated,
            eventsInserted: totalEventsInserted,
            bytesRead: totalBytesRead,
            durationSeconds: duration,
            warningMessage: warningMessage.isEmpty ? nil : warningMessage
        )
    }

    private static func scanIssue(root: String, status: RootScanStatus) -> String? {
        switch status {
        case .inaccessible:
            return "\(root): inaccessible"
        case .failed(let message):
            return "\(root): \(message)"
        case .success, .notFound, .disabled:
            return nil
        }
    }

    private struct SingleSourceProcessResult {
        let eventsInserted: Int
        let bytesRead: Int64
    }

    private struct DailyAggregateKey: Hashable {
        let dayKey: String
        let dayStartMs: Int64
        let modelCanonical: String
    }

    private struct UsageAggregate {
        var eventCount = 0
        var tokens = TokenBreakdown.zero
        var estimatedCost = MoneyNanoUSD.zero
        var unpricedEventCount = 0
        var unpricedTokenCount: Int64 = 0
        var unpricedReasonCounts = UnpricedReasonCounts.zero
        var firstEventAtMs: Int64?
        var lastEventAtMs: Int64?

        mutating func add(event: CodexParsedUsageEvent, price: PricingEvaluationResult) {
            eventCount += 1
            tokens = tokens + event.tokens
            estimatedCost = estimatedCost + price.estimatedCost
            if !price.pricingStatus.isPriced {
                unpricedEventCount += 1
                let (sum, overflow) = unpricedTokenCount.addingReportingOverflow(
                    event.tokens.canonicalTotalTokens
                )
                unpricedTokenCount = overflow ? Int64.max : sum
                unpricedReasonCounts.add(
                    status: price.pricingStatus,
                    tokenCount: event.tokens.canonicalTotalTokens
                )
            }
            if let current = firstEventAtMs {
                firstEventAtMs = min(current, event.timestampMs)
            } else {
                firstEventAtMs = event.timestampMs
            }
            if let current = lastEventAtMs {
                lastEventAtMs = max(current, event.timestampMs)
            } else {
                lastEventAtMs = event.timestampMs
            }
        }
    }

    private struct PricedUsageEvent {
        let event: CodexParsedUsageEvent
        let price: PricingEvaluationResult
    }

    private struct SourceContentFingerprint {
        let headSHA256: String
        let tailSHA256: String
    }

    private struct ExistingSourceState {
        let sourcePath: String
        let relativePath: String
        let lastImportedSize: Int64
        let checkpointJSON: String?
        let deviceID: Int64
        let inode: Int64
        let birthtimeNs: Int64?
        let fileSize: Int64
        let mtimeMs: Int64
        let headSHA256: String?
        let tailSHA256: String?
        let importedTailSHA256: String?
        let parserVersion: Int
        let malformedLineCount: Int
        let unresolvedTimestampCount: Int
        let unknownEventTypeCount: Int
        let status: String
    }

    private enum PersistenceTarget: Equatable {
        case live
        case rebuildShadow

        var eventsTable: String {
            self == .live ? "codex_usage_events" : "codex_usage_events_parser_shadow"
        }

        var sessionsTable: String {
            self == .live ? "codex_sessions" : "codex_sessions_parser_shadow"
        }

        var sessionSummariesTable: String {
            self == .live ? "codex_session_summaries" : "codex_session_summaries_parser_shadow"
        }

        var dailySummariesTable: String {
            self == .live ? "codex_daily_usage_summaries" : "codex_daily_usage_summaries_parser_shadow"
        }
    }

    private struct SourceAggregation {
        var session = UsageAggregate()
        var models: [String: UsageAggregate] = [:]
        var days: [DailyAggregateKey: UsageAggregate] = [:]
        var events: [PricedUsageEvent] = []

        mutating func add(
            event: CodexParsedUsageEvent,
            price: PricingEvaluationResult,
            calendar: Calendar,
            timeZone: TimeZone
        ) {
            guard !event.isChildReplay else { return }
            session.add(event: event, price: price)
            events.append(PricedUsageEvent(event: event, price: price))

            var modelAgg = models[event.modelCanonical] ?? UsageAggregate()
            modelAgg.add(event: event, price: price)
            models[event.modelCanonical] = modelAgg

            let bucket = UsageDayBucketer.bucket(
                timestampMs: event.timestampMs,
                calendar: calendar,
                timeZone: timeZone
            )
            let key = DailyAggregateKey(
                dayKey: bucket.dayKey.yyyyMMdd,
                dayStartMs: bucket.dayStartMs,
                modelCanonical: event.modelCanonical
            )
            var dayAgg = days[key] ?? UsageAggregate()
            dayAgg.add(event: event, price: price)
            days[key] = dayAgg
        }

        var isEmpty: Bool {
            session.eventCount == 0 && models.isEmpty && days.isEmpty && events.isEmpty
        }

        var estimatedMemoryBytes: Int {
            4_096
                + models.reduce(0) { partial, item in
                    partial + 512 + item.key.utf8.count
                }
                + days.reduce(0) { partial, item in
                    partial + 640 + item.key.dayKey.utf8.count + item.key.modelCanonical.utf8.count
                }
                + events.count * 640
        }

        mutating func removeAll(keepingCapacity: Bool = true) {
            session = UsageAggregate()
            models.removeAll(keepingCapacity: keepingCapacity)
            days.removeAll(keepingCapacity: keepingCapacity)
            events.removeAll(keepingCapacity: keepingCapacity)
        }
    }

    private struct ImportMemoryBudget {
        let maxAggregateBytes: Int
        let checkEveryEvents: Int

        static func current() -> ImportMemoryBudget {
            let physical = ProcessInfo.processInfo.physicalMemory
            let physicalBound = clamp(
                Int(physical / 256),
                min: 4 * 1024 * 1024,
                max: 96 * 1024 * 1024
            )

            let availableBound: Int
            if let available = availableMemoryBytes() {
                availableBound = clamp(
                    Int(available / 20),
                    min: 2 * 1024 * 1024,
                    max: physicalBound
                )
            } else {
                availableBound = physicalBound
            }

            return ImportMemoryBudget(
                maxAggregateBytes: max(1 * 1024 * 1024, min(physicalBound, availableBound)),
                checkEveryEvents: 2_000
            )
        }

        func shouldFlush(aggregation: SourceAggregation, eventCountSinceLastCheck: Int) -> Bool {
            guard eventCountSinceLastCheck >= checkEveryEvents else { return false }
            return aggregation.estimatedMemoryBytes >= maxAggregateBytes
        }

        private static func clamp(_ value: Int, min minValue: Int, max maxValue: Int) -> Int {
            Swift.max(minValue, Swift.min(value, maxValue))
        }

        private static func availableMemoryBytes() -> UInt64? {
            var stats = vm_statistics64()
            var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
            let result = withUnsafeMutablePointer(to: &stats) {
                $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                    host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
                }
            }
            guard result == KERN_SUCCESS else { return nil }
            let pages = UInt64(stats.free_count) + UInt64(stats.inactive_count) + UInt64(stats.speculative_count)
            return pages * UInt64(getpagesize())
        }

        static func relieveAllocatorPressure() {
            #if os(macOS)
            _ = malloc_zone_pressure_relief(nil, 0)
            #endif
        }
    }

    private func canonicalizedSource(
        _ source: RolloutDiscoveredSource,
        header: CodexRolloutHeaderMetadata?
    ) -> RolloutDiscoveredSource {
        guard let sessionId = header?.sessionId,
              !sessionId.isEmpty,
              sessionId != source.sessionId else {
            return source
        }

        return RolloutDiscoveredSource(
            fileURL: source.fileURL,
            relativePath: source.relativePath,
            bucket: source.bucket,
            sessionId: sessionId,
            identity: source.identity,
            fileSize: source.fileSize,
            mtimeMs: source.mtimeMs
        )
    }

    private func mergeMetadata(
        _ incoming: CodexRawSessionMetadata,
        into map: inout [String: CodexRawSessionMetadata]
    ) {
        if var existing = map[incoming.sessionId] {
            if existing.title == nil || existing.title?.isEmpty == true {
                existing.title = incoming.title
            }
            if existing.cwd == nil || existing.cwd?.isEmpty == true {
                existing.cwd = incoming.cwd
            }
            if existing.projectName == nil || existing.projectName?.isEmpty == true {
                existing.projectName = incoming.projectName
            }
            if existing.parentSessionId == nil || existing.parentSessionId?.isEmpty == true {
                existing.parentSessionId = incoming.parentSessionId
            }
            if existing.agentType == nil || existing.agentType?.isEmpty == true {
                existing.agentType = incoming.agentType
            }
            if existing.createdAt == nil {
                existing.createdAt = incoming.createdAt
            }
            if existing.updatedAt == nil {
                existing.updatedAt = incoming.updatedAt
            }
            map[incoming.sessionId] = existing
        } else {
            map[incoming.sessionId] = incoming
        }
    }

    private func processSingleSource(
        source: RolloutDiscoveredSource,
        resolvedSession: CodexResolvedSessionMetadata?,
        pricingSnapshot: PricingCatalogSnapshot,
        forceRebuild: Bool,
        scanGeneration: Int64,
        aggregationTimeZone: TimeZone
    ) throws -> SingleSourceProcessResult {
        let fingerprint = Self.fingerprint(fileURL: source.fileURL, fileSize: source.fileSize)

        // 读取该源之前的检查点与内容指纹
        let existingSourceState = try database.executeQuery(
            sql: """
            SELECT
                source_path, relative_path,
                last_imported_size, checkpoint_state_json, device_id, inode, birthtime_ns,
                file_size, mtime_ms, head_sha256, tail_sha256, imported_tail_sha256, parser_version,
                malformed_line_count, unresolved_timestamp_count, unknown_event_type_count, status
            FROM codex_import_sources
            WHERE source_path = ?
               OR (device_id = ? AND inode = ? AND birthtime_ns IS ?)
            ORDER BY CASE WHEN source_path = ? THEN 0 ELSE 1 END
            LIMIT 1;
            """,
            bindings: [
                source.fileURL.path,
                Int64(source.identity.device),
                Int64(source.identity.inode),
                source.identity.birthtimeNs,
                source.fileURL.path
            ]
        ) { stmt -> ExistingSourceState in
            let json = sqlite3_column_type(stmt, 3) != SQLITE_NULL && sqlite3_column_text(stmt, 3) != nil
                ? String(cString: sqlite3_column_text(stmt, 3)!) : nil
            let birthtime = sqlite3_column_type(stmt, 6) != SQLITE_NULL ? sqlite3_column_int64(stmt, 6) : nil
            let head = sqlite3_column_type(stmt, 9) != SQLITE_NULL && sqlite3_column_text(stmt, 9) != nil
                ? String(cString: sqlite3_column_text(stmt, 9)!) : nil
            let tail = sqlite3_column_type(stmt, 10) != SQLITE_NULL && sqlite3_column_text(stmt, 10) != nil
                ? String(cString: sqlite3_column_text(stmt, 10)!) : nil
            let importedTail = sqlite3_column_type(stmt, 11) != SQLITE_NULL && sqlite3_column_text(stmt, 11) != nil
                ? String(cString: sqlite3_column_text(stmt, 11)!) : nil
            return ExistingSourceState(
                sourcePath: String(cString: sqlite3_column_text(stmt, 0)),
                relativePath: String(cString: sqlite3_column_text(stmt, 1)),
                lastImportedSize: sqlite3_column_int64(stmt, 2),
                checkpointJSON: json,
                deviceID: sqlite3_column_int64(stmt, 4),
                inode: sqlite3_column_int64(stmt, 5),
                birthtimeNs: birthtime,
                fileSize: sqlite3_column_int64(stmt, 7),
                mtimeMs: sqlite3_column_int64(stmt, 8),
                headSHA256: head,
                tailSHA256: tail,
                importedTailSHA256: importedTail,
                parserVersion: Int(sqlite3_column_int(stmt, 12)),
                malformedLineCount: Int(sqlite3_column_int(stmt, 13)),
                unresolvedTimestampCount: Int(sqlite3_column_int(stmt, 14)),
                unknownEventTypeCount: Int(sqlite3_column_int(stmt, 15)),
                status: String(cString: sqlite3_column_text(stmt, 16))
            )
        }.first

        if let existing = existingSourceState, existing.sourcePath != source.fileURL.path {
            try relocatePhysicalSource(
                existing: existing,
                source: source,
                scanGeneration: scanGeneration
            )
        }

        var startOffset: Int64 = 0
        var initialCheckpoint = ParserCheckpoint.initial
        var replaceExistingDerivedRows = forceRebuild
        var rebuildReason: String? = forceRebuild ? "forced" : nil

        let existingSessionSourcePath = try database.stringScalar(
            sql: "SELECT source_path FROM codex_sessions WHERE session_id = ?;",
            bindings: [source.sessionId]
        )
        if let existingSessionSourcePath, existingSessionSourcePath != source.fileURL.path {
            replaceExistingDerivedRows = true
            rebuildReason = rebuildReason ?? "session_source_replaced"
        }

        if !forceRebuild, let existing = existingSourceState {
            let sameIdentity = existing.deviceID == Int64(source.identity.device)
                && existing.inode == Int64(source.identity.inode)
                && existing.birthtimeNs == source.identity.birthtimeNs
            let sameContentEnvelope = existing.headSHA256 == fingerprint.headSHA256
                && existing.tailSHA256 == fingerprint.tailSHA256
            let parserMatches = existing.parserVersion == ParserCheckpoint.currentParserVersion
                && existing.status != "stale"

            if source.fileSize == existing.lastImportedSize,
               source.fileSize == existing.fileSize,
               source.mtimeMs == existing.mtimeMs,
               sameIdentity,
               sameContentEnvelope,
               parserMatches {
                try markSourceSeen(source: source, fingerprint: fingerprint, scanGeneration: scanGeneration)
                return SingleSourceProcessResult(eventsInserted: 0, bytesRead: 0)
            } else if source.fileSize > existing.lastImportedSize,
                      sameIdentity,
                      parserMatches,
                      existing.headSHA256 == Self.hashWindow(
                        fileURL: source.fileURL,
                        startOffset: 0,
                        length: min(existing.fileSize, 4_096)
                      ),
                      let importedTail = existing.importedTailSHA256,
                      importedTail == Self.tailHash(fileURL: source.fileURL, endOffset: existing.lastImportedSize) {
                startOffset = existing.lastImportedSize
                if let json = existing.checkpointJSON,
                   let parsedCp = ParserCheckpoint.fromJsonString(json),
                   parsedCp.parserVersion == ParserCheckpoint.currentParserVersion {
                    initialCheckpoint = parsedCp
                } else {
                    startOffset = 0
                    initialCheckpoint = .initial
                    replaceExistingDerivedRows = true
                }
            } else {
                startOffset = 0
                initialCheckpoint = .initial
                replaceExistingDerivedRows = true
                if !parserMatches {
                    rebuildReason = "parser_upgraded"
                } else if !sameIdentity {
                    rebuildReason = "physical_identity_changed"
                } else if source.fileSize < existing.lastImportedSize {
                    rebuildReason = "file_truncated"
                } else if source.fileSize == existing.fileSize {
                    rebuildReason = "same_size_rewrite"
                } else {
                    rebuildReason = "append_boundary_changed"
                }
            }
        }

        let persistenceTarget: PersistenceTarget = replaceExistingDerivedRows ? .rebuildShadow : .live
        var rebuildShadowPublished = false
        if persistenceTarget == .rebuildShadow {
            guard resolvedSession != nil else {
                throw NSError(
                    domain: "QuotaLens.CodexUsageImport",
                    code: 2001,
                    userInfo: [NSLocalizedDescriptionKey: "无法解析会话元数据，已保留旧索引"]
                )
            }
            try prepareParserRebuildShadowTables()
        }
        defer {
            if persistenceTarget == .rebuildShadow && !rebuildShadowPublished {
                try? clearParserRebuildShadowTables()
            }
        }

        let isChild = (resolvedSession?.depth ?? 0) > 0
        let rootSessionId = resolvedSession?.rootSessionId ?? source.sessionId
        let timestampFallback = fallbackTimestamp(for: source, resolvedSession: resolvedSession)

        let reducer = CodexUsageReducer(
            sessionId: source.sessionId,
            rootSessionId: rootSessionId,
            isChildSession: isChild,
            sourcePath: source.fileURL.path,
            sourceIdentityKey: source.identity.stableKey,
            fallbackTimestampMs: timestampFallback.0,
            fallbackTimestampQuality: timestampFallback.1
        )

        var reducerState = CodexUsageReducer.ReducerState(checkpoint: initialCheckpoint)
        var aggregation = SourceAggregation()
        let memoryBudget = ImportMemoryBudget.current()
        let timeZone = aggregationTimeZone
        let calendar = UsageDayBucketer.calendar(timeZone: timeZone)
        var totalInserted = 0
        var eventsSinceMemoryCheck = 0
        var hasCommittedChunks = false
        let isResuming = startOffset > 0 && !replaceExistingDerivedRows
        var malformedLineCount = isResuming ? (existingSourceState?.malformedLineCount ?? 0) : 0
        var unresolvedTimestampCount = isResuming ? (existingSourceState?.unresolvedTimestampCount ?? 0) : 0
        var unknownEventTypeCount = isResuming ? (existingSourceState?.unknownEventTypeCount ?? 0) : 0

        // 流式逐行读取
        let (finalOffset, _) = try StreamingJSONLReader.readLines(
            fileURL: source.fileURL,
            startOffset: startOffset,
            endLimitOffset: source.fileSize,
            shouldIncludeLineData: RolloutLineDecoder.mayContainUsageRelevantEvent
        ) { lineRecord in
            if let wireEvent = RolloutLineDecoder.decodeLine(lineRecord.lineString) {
                if (wireEvent.lastTokenUsage != nil || wireEvent.totalTokenUsage != nil),
                   wireEvent.timestampMs <= 0,
                   !timestampFallback.1.isUsableForAnalytics {
                    unresolvedTimestampCount += 1
                }
                if let parsedEvent = reducer.reduce(event: wireEvent, lineRecord: lineRecord, state: &reducerState) {
                    let priceResult = pricingSnapshot.evaluate(
                        modelCanonical: parsedEvent.modelCanonical,
                        serviceTier: parsedEvent.serviceTier,
                        timestampMs: parsedEvent.timestampMs,
                        tokens: parsedEvent.tokens
                    )
                    aggregation.add(
                        event: parsedEvent,
                        price: priceResult,
                        calendar: calendar,
                        timeZone: timeZone
                    )
                    eventsSinceMemoryCheck += 1

                    if memoryBudget.shouldFlush(
                        aggregation: aggregation,
                        eventCountSinceLastCheck: eventsSinceMemoryCheck
                    ) {
                        let checkpoint = reducerState.makeCheckpoint()
                        try database.transaction {
                            if let session = resolvedSession {
                                try persistAggregatesInTransaction(
                                    sessionId: session.sessionId,
                                    metadata: session,
                                    bucket: source.bucket,
                                    sourcePath: source.fileURL.path,
                                    relativePath: source.relativePath,
                                    aggregation: aggregation,
                                    replaceExisting: replaceExistingDerivedRows && !hasCommittedChunks,
                                    target: persistenceTarget
                                )
                            }
                            if persistenceTarget == .live {
                                try persistSourceCheckpointInTransaction(
                                    source: source,
                                    importedSize: lineRecord.startOffset + Int64(lineRecord.lineBytes),
                                    checkpoint: checkpoint,
                                    status: "partial",
                                    fingerprint: fingerprint,
                                    scanGeneration: scanGeneration,
                                    rebuildReason: rebuildReason,
                                    malformedLineCount: malformedLineCount,
                                    unresolvedTimestampCount: unresolvedTimestampCount,
                                    unknownEventTypeCount: unknownEventTypeCount
                                )
                            }
                        }

                        totalInserted += aggregation.session.eventCount
                        aggregation.removeAll()
                        ImportMemoryBudget.relieveAllocatorPressure()
                        replaceExistingDerivedRows = false
                        hasCommittedChunks = true
                        eventsSinceMemoryCheck = 0
                    }
                }
            } else if Self.isSyntacticallyValidJSON(lineRecord.lineString) {
                unknownEventTypeCount += 1
            } else {
                malformedLineCount += 1
            }
        }

        // 提交最终检查点与会话汇总
        let finalCheckpoint = reducerState.makeCheckpoint()

        if persistenceTarget == .rebuildShadow, let session = resolvedSession {
            try database.transaction {
                let shouldReplace = !hasCommittedChunks
                if !aggregation.isEmpty {
                    try persistAggregatesInTransaction(
                        sessionId: session.sessionId,
                        metadata: session,
                        bucket: source.bucket,
                        sourcePath: source.fileURL.path,
                        relativePath: source.relativePath,
                        aggregation: aggregation,
                        replaceExisting: shouldReplace,
                        target: .rebuildShadow
                    )
                } else if shouldReplace {
                    try deleteDerivedRowsForSession(
                        sessionId: session.sessionId,
                        sourcePath: source.fileURL.path,
                        relativePath: source.relativePath,
                        target: .rebuildShadow
                    )
                }
            }
            try publishParserRebuildShadow(
                sessionId: session.sessionId,
                source: source,
                importedSize: finalOffset,
                checkpoint: finalCheckpoint,
                fingerprint: fingerprint,
                scanGeneration: scanGeneration,
                rebuildReason: rebuildReason,
                malformedLineCount: malformedLineCount,
                unresolvedTimestampCount: unresolvedTimestampCount,
                unknownEventTypeCount: unknownEventTypeCount
            )
            rebuildShadowPublished = true
        } else {
            try database.transaction {
                // 增量导入可以逐批直接追加，最终原子更新正式检查点。
                try persistSourceCheckpointInTransaction(
                    source: source,
                    importedSize: finalOffset,
                    checkpoint: finalCheckpoint,
                    status: "indexed",
                    fingerprint: fingerprint,
                    scanGeneration: scanGeneration,
                    rebuildReason: rebuildReason,
                    malformedLineCount: malformedLineCount,
                    unresolvedTimestampCount: unresolvedTimestampCount,
                    unknownEventTypeCount: unknownEventTypeCount
                )

                if let session = resolvedSession {
                    let shouldReplace = replaceExistingDerivedRows && !hasCommittedChunks
                    if !aggregation.isEmpty {
                        try persistAggregatesInTransaction(
                            sessionId: session.sessionId,
                            metadata: session,
                            bucket: source.bucket,
                            sourcePath: source.fileURL.path,
                            relativePath: source.relativePath,
                            aggregation: aggregation,
                            replaceExisting: shouldReplace,
                            target: .live
                        )
                    } else if shouldReplace {
                        try deleteDerivedRowsForSession(
                            sessionId: session.sessionId,
                            sourcePath: source.fileURL.path,
                            relativePath: source.relativePath,
                            target: .live
                        )
                    }
                }
            }
        }

        totalInserted += aggregation.session.eventCount
        ImportMemoryBudget.relieveAllocatorPressure()
        let bytesRead = max(0, finalOffset - startOffset)
        return SingleSourceProcessResult(eventsInserted: totalInserted, bytesRead: bytesRead)
    }

    private func prepareParserRebuildShadowTables() throws {
        try database.execute(sql: """
        CREATE TEMP TABLE IF NOT EXISTS codex_usage_events_parser_shadow
            AS SELECT * FROM codex_usage_events WHERE 0;
        CREATE TEMP TABLE IF NOT EXISTS codex_sessions_parser_shadow
            AS SELECT * FROM codex_sessions WHERE 0;
        CREATE TEMP TABLE IF NOT EXISTS codex_session_summaries_parser_shadow
            AS SELECT * FROM codex_session_summaries WHERE 0;
        CREATE TEMP TABLE IF NOT EXISTS codex_daily_usage_summaries_parser_shadow
            AS SELECT * FROM codex_daily_usage_summaries WHERE 0;

        CREATE UNIQUE INDEX IF NOT EXISTS temp.idx_parser_shadow_event_id
            ON codex_usage_events_parser_shadow(event_id);
        CREATE UNIQUE INDEX IF NOT EXISTS temp.idx_parser_shadow_session_id
            ON codex_sessions_parser_shadow(session_id);
        CREATE UNIQUE INDEX IF NOT EXISTS temp.idx_parser_shadow_session_model
            ON codex_session_summaries_parser_shadow(session_id, model_canonical);
        CREATE UNIQUE INDEX IF NOT EXISTS temp.idx_parser_shadow_daily_model
            ON codex_daily_usage_summaries_parser_shadow(session_id, day_key, model_canonical);
        """)
        try clearParserRebuildShadowTables()
    }

    private func clearParserRebuildShadowTables() throws {
        try database.execute(sql: """
        DELETE FROM codex_usage_events_parser_shadow;
        DELETE FROM codex_sessions_parser_shadow;
        DELETE FROM codex_session_summaries_parser_shadow;
        DELETE FROM codex_daily_usage_summaries_parser_shadow;
        """)
    }

    private func validateParserRebuildShadow(sessionId: String) throws {
        let eventCount = try database.intScalar(
            sql: "SELECT COUNT(*) FROM codex_usage_events_parser_shadow WHERE session_id = ?;",
            bindings: [sessionId]
        )
        let sessionCount = try database.intScalar(
            sql: "SELECT COUNT(*) FROM codex_sessions_parser_shadow WHERE session_id = ?;",
            bindings: [sessionId]
        )
        let summaryEventCount = try database.intScalar(
            sql: "SELECT COALESCE(SUM(event_count), 0) FROM codex_session_summaries_parser_shadow WHERE session_id = ?;",
            bindings: [sessionId]
        )
        let dailyEventCount = try database.intScalar(
            sql: "SELECT COALESCE(SUM(event_count), 0) FROM codex_daily_usage_summaries_parser_shadow WHERE session_id = ?;",
            bindings: [sessionId]
        )
        let eventTokens = try database.int64Scalar(
            sql: "SELECT COALESCE(SUM(total_tokens), 0) FROM codex_usage_events_parser_shadow WHERE session_id = ?;",
            bindings: [sessionId]
        ) ?? 0
        let summaryTokens = try database.int64Scalar(
            sql: "SELECT COALESCE(SUM(total_tokens), 0) FROM codex_session_summaries_parser_shadow WHERE session_id = ?;",
            bindings: [sessionId]
        ) ?? 0
        let dailyTokens = try database.int64Scalar(
            sql: "SELECT COALESCE(SUM(total_tokens), 0) FROM codex_daily_usage_summaries_parser_shadow WHERE session_id = ?;",
            bindings: [sessionId]
        ) ?? 0
        let sessionTokens = try database.int64Scalar(
            sql: "SELECT total_tokens FROM codex_sessions_parser_shadow WHERE session_id = ?;",
            bindings: [sessionId]
        ) ?? 0

        let expectedSessionCount = eventCount > 0 ? 1 : 0
        guard sessionCount == expectedSessionCount,
              summaryEventCount == eventCount,
              dailyEventCount == eventCount,
              summaryTokens == eventTokens,
              dailyTokens == eventTokens,
              sessionTokens == eventTokens else {
            throw NSError(
                domain: "QuotaLens.CodexUsageImport",
                code: 2002,
                userInfo: [NSLocalizedDescriptionKey: "解析器影子索引一致性检查失败，已保留旧索引"]
            )
        }
    }

    private func publishParserRebuildShadow(
        sessionId: String,
        source: RolloutDiscoveredSource,
        importedSize: Int64,
        checkpoint: ParserCheckpoint,
        fingerprint: SourceContentFingerprint,
        scanGeneration: Int64,
        rebuildReason: String?,
        malformedLineCount: Int,
        unresolvedTimestampCount: Int,
        unknownEventTypeCount: Int
    ) throws {
        try validateParserRebuildShadow(sessionId: sessionId)
        try database.transaction {
            try validateParserRebuildShadow(sessionId: sessionId)
            try deleteDerivedRowsForSession(
                sessionId: sessionId,
                sourcePath: source.fileURL.path,
                relativePath: source.relativePath,
                target: .live
            )
            try database.executeUpdate(
                sql: "INSERT INTO codex_sessions SELECT * FROM codex_sessions_parser_shadow WHERE session_id = ?;",
                bindings: [sessionId]
            )
            try database.executeUpdate(
                sql: "INSERT INTO codex_usage_events SELECT * FROM codex_usage_events_parser_shadow WHERE session_id = ?;",
                bindings: [sessionId]
            )
            try database.executeUpdate(
                sql: "INSERT INTO codex_session_summaries SELECT * FROM codex_session_summaries_parser_shadow WHERE session_id = ?;",
                bindings: [sessionId]
            )
            try database.executeUpdate(
                sql: "INSERT INTO codex_daily_usage_summaries SELECT * FROM codex_daily_usage_summaries_parser_shadow WHERE session_id = ?;",
                bindings: [sessionId]
            )
            try persistSourceCheckpointInTransaction(
                source: source,
                importedSize: importedSize,
                checkpoint: checkpoint,
                status: "indexed",
                fingerprint: fingerprint,
                scanGeneration: scanGeneration,
                rebuildReason: rebuildReason,
                malformedLineCount: malformedLineCount,
                unresolvedTimestampCount: unresolvedTimestampCount,
                unknownEventTypeCount: unknownEventTypeCount
            )
            try clearParserRebuildShadowTables()
        }
    }

    private func persistSourceCheckpointInTransaction(
        source: RolloutDiscoveredSource,
        importedSize: Int64,
        checkpoint: ParserCheckpoint,
        status: String,
        fingerprint: SourceContentFingerprint,
        scanGeneration: Int64,
        rebuildReason: String?,
        malformedLineCount: Int,
        unresolvedTimestampCount: Int,
        unknownEventTypeCount: Int
    ) throws {
        let checkpointJson = checkpoint.toJsonString() ?? "{}"
        try database.executeUpdate(
            sql: """
            INSERT OR REPLACE INTO codex_import_sources (
                source_path, relative_path, bucket, device_id, inode, birthtime_ns,
                file_size, mtime_ms, last_imported_size, last_imported_line,
                last_imported_sha256, checkpoint_state_json, status, last_imported_at,
                error_message, head_sha256, tail_sha256, imported_tail_sha256,
                parser_version, scan_generation, rebuild_reason, malformed_line_count,
                unresolved_timestamp_count, unknown_event_type_count
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, unixepoch(), NULL, ?, ?, ?, ?, ?, ?, ?, ?, ?);
            """,
            bindings: [
                source.fileURL.path,
                source.relativePath,
                source.bucket.rawValue,
                Int64(source.identity.device),
                Int64(source.identity.inode),
                source.identity.birthtimeNs,
                source.fileSize,
                source.mtimeMs,
                importedSize,
                checkpoint.lineCount,
                fingerprint.tailSHA256,
                checkpointJson,
                status,
                fingerprint.headSHA256,
                fingerprint.tailSHA256,
                Self.tailHash(fileURL: source.fileURL, endOffset: importedSize),
                ParserCheckpoint.currentParserVersion,
                scanGeneration,
                rebuildReason,
                malformedLineCount,
                unresolvedTimestampCount,
                unknownEventTypeCount
            ]
        )
    }

    private func persistAggregatesInTransaction(
        sessionId: String,
        metadata: CodexResolvedSessionMetadata,
        bucket: SessionBucket,
        sourcePath: String,
        relativePath: String,
        aggregation: SourceAggregation,
        replaceExisting: Bool,
        target: PersistenceTarget = .live
    ) throws {
        if replaceExisting {
            try deleteDerivedRowsForSession(
                sessionId: sessionId,
                sourcePath: sourcePath,
                relativePath: relativePath,
                target: target
            )
        }

        try persistUsageEvents(aggregation.events, target: target)

        for (model, aggregate) in aggregation.models {
            try upsertSessionModelSummary(
                sessionId: sessionId,
                modelCanonical: model,
                aggregate: aggregate,
                target: target
            )
        }

        for (key, aggregate) in aggregation.days {
            try upsertDailySummary(
                sessionId: sessionId,
                key: key,
                aggregate: aggregate,
                target: target
            )
        }

        let totals = try loadSessionTotalsFromSummaries(sessionId: sessionId, target: target)
        let existingLastEventAt: Int64? = replaceExisting ? nil : try database.executeQuery(
            sql: "SELECT last_event_at FROM \(target.sessionsTable) WHERE session_id = ?;",
            bindings: [sessionId]
        ) { stmt -> Int64? in
            sqlite3_column_type(stmt, 0) != SQLITE_NULL ? sqlite3_column_int64(stmt, 0) : nil
        }.first ?? nil
        let lastEventAt = maxOptional(existingLastEventAt, aggregation.session.lastEventAtMs)
        let metadataCreatedMs = Int64(metadata.createdAt.timeIntervalSince1970 * 1000)
        let createdAtMs = metadataCreatedMs > 0
            ? metadataCreatedMs
            : (aggregation.session.firstEventAtMs ?? lastEventAt ?? sourceTimestampFallback(relativePath: relativePath))
        let updatedAtMs = max(Int64(metadata.updatedAt.timeIntervalSince1970 * 1000), lastEventAt ?? createdAtMs)
        let pricingStatus = AggregatePricingStatus(
            eventCount: totals.eventCount,
            unpricedEventCount: totals.unpricedEventCount
        )

        try database.executeUpdate(
            sql: """
            INSERT OR REPLACE INTO \(target.sessionsTable) (
                session_id, root_session_id, parent_session_id, depth, source_path,
                relative_path, bucket, title, project_name, cwd, created_at, updated_at,
                last_event_at, event_count, total_tokens, input_tokens, cached_input_tokens,
                cache_write_input_tokens, output_tokens, reasoning_output_tokens, estimated_cost_usd_nano,
                pricing_status, metadata_fingerprint, has_subagents, agent_type,
                unpriced_unknown_model_event_count, unpriced_unknown_model_token_count,
                unpriced_unsupported_tier_event_count, unpriced_unsupported_tier_token_count,
                unpriced_historical_rule_missing_event_count, unpriced_historical_rule_missing_token_count,
                unpriced_unsupported_context_event_count, unpriced_unsupported_context_token_count,
                unpriced_invalid_record_event_count, unpriced_invalid_record_token_count,
                unpriced_overflow_event_count, unpriced_overflow_token_count
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, NULL, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
            """,
            bindings: [
                sessionId,
                metadata.rootSessionId,
                metadata.parentSessionId,
                metadata.depth,
                sourcePath,
                relativePath,
                bucket.rawValue,
                metadata.title,
                metadata.projectName,
                metadata.cwd,
                createdAtMs,
                updatedAtMs,
                lastEventAt,
                totals.eventCount,
                totals.tokens.canonicalTotalTokens,
                totals.tokens.inputTokens,
                totals.tokens.cachedInputTokens,
                totals.tokens.cacheWriteInputTokens,
                totals.tokens.outputTokens,
                totals.tokens.reasoningOutputTokens,
                totals.estimatedCost.rawValue,
                pricingStatus.rawValue,
                metadata.hasSubagents ? 1 : 0,
                metadata.agentType,
                totals.unpricedReasonCounts.unknownModelEvents,
                totals.unpricedReasonCounts.unknownModelTokens,
                totals.unpricedReasonCounts.unsupportedTierEvents,
                totals.unpricedReasonCounts.unsupportedTierTokens,
                totals.unpricedReasonCounts.historicalRuleMissingEvents,
                totals.unpricedReasonCounts.historicalRuleMissingTokens,
                totals.unpricedReasonCounts.unsupportedContextEvents,
                totals.unpricedReasonCounts.unsupportedContextTokens,
                totals.unpricedReasonCounts.invalidRecordEvents,
                totals.unpricedReasonCounts.invalidRecordTokens,
                totals.unpricedReasonCounts.overflowEvents,
                totals.unpricedReasonCounts.overflowTokens
            ]
        )
    }

    private func deleteDerivedRowsForSession(
        sessionId: String,
        sourcePath: String,
        relativePath: String,
        target: PersistenceTarget = .live
    ) throws {
        try database.executeUpdate(
            sql: "DELETE FROM \(target.eventsTable) WHERE session_id = ?;",
            bindings: [sessionId]
        )
        try database.executeUpdate(
            sql: "DELETE FROM \(target.sessionSummariesTable) WHERE session_id = ?;",
            bindings: [sessionId]
        )
        try database.executeUpdate(
            sql: "DELETE FROM \(target.dailySummariesTable) WHERE session_id = ?;",
            bindings: [sessionId]
        )
        try database.executeUpdate(
            sql: "DELETE FROM \(target.sessionsTable) WHERE session_id = ?;",
            bindings: [sessionId]
        )
    }

    private func persistUsageEvents(
        _ events: [PricedUsageEvent],
        target: PersistenceTarget = .live
    ) throws {
        guard !events.isEmpty else { return }
        for priced in events {
            let event = priced.event
            let price = priced.price
            try database.executeUpdate(
                sql: """
                INSERT OR REPLACE INTO \(target.eventsTable) (
                    event_id, session_id, root_session_id, turn_index, call_index,
                    timestamp_ms, model_raw, model_canonical, service_tier, reasoning_effort,
                    input_tokens, cached_input_tokens, cache_write_input_tokens,
                    output_tokens, reasoning_output_tokens,
                    total_tokens, uncached_input_tokens, estimated_cost_usd_nano,
                    pricing_rule_id, pricing_status, usage_derivation, attribution_quality,
                    is_child_replay, source_path, line_offset, line_bytes, payload_sha256,
                    created_at, timestamp_quality, pricing_catalog_version
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, NULL, ?, ?, ?);
                """,
                bindings: [
                    event.eventId,
                    event.sessionId,
                    event.rootSessionId,
                    event.turnIndex,
                    event.callIndex,
                    event.timestampMs,
                    event.modelRaw,
                    event.modelCanonical,
                    event.serviceTier,
                    event.reasoningEffort,
                    event.tokens.inputTokens,
                    event.tokens.cachedInputTokens,
                    event.tokens.cacheWriteInputTokens,
                    event.tokens.outputTokens,
                    event.tokens.reasoningOutputTokens,
                    event.tokens.canonicalTotalTokens,
                    event.tokens.uncachedInputTokens,
                    price.estimatedCost.rawValue,
                    price.pricingRuleId,
                    price.pricingStatus.rawValue,
                    event.usageDerivation.rawValue,
                    event.attributionQuality.rawValue,
                    event.isChildReplay ? 1 : 0,
                    event.sourcePath,
                    event.lineOffset,
                    event.lineBytes,
                    Self.unixMillis(),
                    event.timestampQuality.rawValue,
                    price.catalogVersion
                ]
            )
        }
    }

    private func upsertSessionModelSummary(
        sessionId: String,
        modelCanonical: String,
        aggregate: UsageAggregate,
        target: PersistenceTarget = .live
    ) throws {
        try database.executeUpdate(
            sql: """
            INSERT INTO \(target.sessionSummariesTable) (
                session_id, model_canonical, event_count, total_tokens,
                uncached_input_tokens, cached_input_tokens, cache_write_input_tokens,
                output_tokens, reasoning_output_tokens,
                estimated_cost_usd_nano, unpriced_event_count, unpriced_token_count,
                unpriced_unknown_model_event_count, unpriced_unknown_model_token_count,
                unpriced_unsupported_tier_event_count, unpriced_unsupported_tier_token_count,
                unpriced_historical_rule_missing_event_count, unpriced_historical_rule_missing_token_count,
                unpriced_unsupported_context_event_count, unpriced_unsupported_context_token_count,
                unpriced_invalid_record_event_count, unpriced_invalid_record_token_count,
                unpriced_overflow_event_count, unpriced_overflow_token_count
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(session_id, model_canonical) DO UPDATE SET
                event_count = event_count + excluded.event_count,
                total_tokens = total_tokens + excluded.total_tokens,
                uncached_input_tokens = uncached_input_tokens + excluded.uncached_input_tokens,
                cached_input_tokens = cached_input_tokens + excluded.cached_input_tokens,
                cache_write_input_tokens = cache_write_input_tokens + excluded.cache_write_input_tokens,
                output_tokens = output_tokens + excluded.output_tokens,
                reasoning_output_tokens = reasoning_output_tokens + excluded.reasoning_output_tokens,
                estimated_cost_usd_nano = estimated_cost_usd_nano + excluded.estimated_cost_usd_nano,
                unpriced_event_count = unpriced_event_count + excluded.unpriced_event_count,
                unpriced_token_count = unpriced_token_count + excluded.unpriced_token_count,
                unpriced_unknown_model_event_count = unpriced_unknown_model_event_count + excluded.unpriced_unknown_model_event_count,
                unpriced_unknown_model_token_count = unpriced_unknown_model_token_count + excluded.unpriced_unknown_model_token_count,
                unpriced_unsupported_tier_event_count = unpriced_unsupported_tier_event_count + excluded.unpriced_unsupported_tier_event_count,
                unpriced_unsupported_tier_token_count = unpriced_unsupported_tier_token_count + excluded.unpriced_unsupported_tier_token_count,
                unpriced_historical_rule_missing_event_count = unpriced_historical_rule_missing_event_count + excluded.unpriced_historical_rule_missing_event_count,
                unpriced_historical_rule_missing_token_count = unpriced_historical_rule_missing_token_count + excluded.unpriced_historical_rule_missing_token_count,
                unpriced_unsupported_context_event_count = unpriced_unsupported_context_event_count + excluded.unpriced_unsupported_context_event_count,
                unpriced_unsupported_context_token_count = unpriced_unsupported_context_token_count + excluded.unpriced_unsupported_context_token_count,
                unpriced_invalid_record_event_count = unpriced_invalid_record_event_count + excluded.unpriced_invalid_record_event_count,
                unpriced_invalid_record_token_count = unpriced_invalid_record_token_count + excluded.unpriced_invalid_record_token_count,
                unpriced_overflow_event_count = unpriced_overflow_event_count + excluded.unpriced_overflow_event_count,
                unpriced_overflow_token_count = unpriced_overflow_token_count + excluded.unpriced_overflow_token_count;
            """,
            bindings: aggregateBindings(prefix: [sessionId, modelCanonical], aggregate: aggregate)
        )
    }

    private func upsertDailySummary(
        sessionId: String,
        key: DailyAggregateKey,
        aggregate: UsageAggregate,
        target: PersistenceTarget = .live
    ) throws {
        try database.executeUpdate(
            sql: """
            INSERT INTO \(target.dailySummariesTable) (
                session_id, day_key, day_start_ms, model_canonical, event_count,
                total_tokens, uncached_input_tokens, cached_input_tokens, cache_write_input_tokens,
                output_tokens, reasoning_output_tokens,
                estimated_cost_usd_nano, unpriced_event_count, unpriced_token_count,
                unpriced_unknown_model_event_count, unpriced_unknown_model_token_count,
                unpriced_unsupported_tier_event_count, unpriced_unsupported_tier_token_count,
                unpriced_historical_rule_missing_event_count, unpriced_historical_rule_missing_token_count,
                unpriced_unsupported_context_event_count, unpriced_unsupported_context_token_count,
                unpriced_invalid_record_event_count, unpriced_invalid_record_token_count,
                unpriced_overflow_event_count, unpriced_overflow_token_count
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(session_id, day_key, model_canonical) DO UPDATE SET
                day_start_ms = excluded.day_start_ms,
                event_count = event_count + excluded.event_count,
                total_tokens = total_tokens + excluded.total_tokens,
                uncached_input_tokens = uncached_input_tokens + excluded.uncached_input_tokens,
                cached_input_tokens = cached_input_tokens + excluded.cached_input_tokens,
                cache_write_input_tokens = cache_write_input_tokens + excluded.cache_write_input_tokens,
                output_tokens = output_tokens + excluded.output_tokens,
                reasoning_output_tokens = reasoning_output_tokens + excluded.reasoning_output_tokens,
                estimated_cost_usd_nano = estimated_cost_usd_nano + excluded.estimated_cost_usd_nano,
                unpriced_event_count = unpriced_event_count + excluded.unpriced_event_count,
                unpriced_token_count = unpriced_token_count + excluded.unpriced_token_count,
                unpriced_unknown_model_event_count = unpriced_unknown_model_event_count + excluded.unpriced_unknown_model_event_count,
                unpriced_unknown_model_token_count = unpriced_unknown_model_token_count + excluded.unpriced_unknown_model_token_count,
                unpriced_unsupported_tier_event_count = unpriced_unsupported_tier_event_count + excluded.unpriced_unsupported_tier_event_count,
                unpriced_unsupported_tier_token_count = unpriced_unsupported_tier_token_count + excluded.unpriced_unsupported_tier_token_count,
                unpriced_historical_rule_missing_event_count = unpriced_historical_rule_missing_event_count + excluded.unpriced_historical_rule_missing_event_count,
                unpriced_historical_rule_missing_token_count = unpriced_historical_rule_missing_token_count + excluded.unpriced_historical_rule_missing_token_count,
                unpriced_unsupported_context_event_count = unpriced_unsupported_context_event_count + excluded.unpriced_unsupported_context_event_count,
                unpriced_unsupported_context_token_count = unpriced_unsupported_context_token_count + excluded.unpriced_unsupported_context_token_count,
                unpriced_invalid_record_event_count = unpriced_invalid_record_event_count + excluded.unpriced_invalid_record_event_count,
                unpriced_invalid_record_token_count = unpriced_invalid_record_token_count + excluded.unpriced_invalid_record_token_count,
                unpriced_overflow_event_count = unpriced_overflow_event_count + excluded.unpriced_overflow_event_count,
                unpriced_overflow_token_count = unpriced_overflow_token_count + excluded.unpriced_overflow_token_count;
            """,
            bindings: aggregateBindings(
                prefix: [sessionId, key.dayKey, key.dayStartMs, key.modelCanonical],
                aggregate: aggregate
            )
        )
    }

    private func aggregateBindings(prefix: [Any?], aggregate: UsageAggregate) -> [Any?] {
        prefix + [
            aggregate.eventCount,
            aggregate.tokens.canonicalTotalTokens,
            aggregate.tokens.uncachedInputTokens,
            aggregate.tokens.cachedInputTokens,
            aggregate.tokens.cacheWriteInputTokens,
            aggregate.tokens.outputTokens,
            aggregate.tokens.reasoningOutputTokens,
            aggregate.estimatedCost.rawValue,
            aggregate.unpricedEventCount,
            aggregate.unpricedTokenCount,
            aggregate.unpricedReasonCounts.unknownModelEvents,
            aggregate.unpricedReasonCounts.unknownModelTokens,
            aggregate.unpricedReasonCounts.unsupportedTierEvents,
            aggregate.unpricedReasonCounts.unsupportedTierTokens,
            aggregate.unpricedReasonCounts.historicalRuleMissingEvents,
            aggregate.unpricedReasonCounts.historicalRuleMissingTokens,
            aggregate.unpricedReasonCounts.unsupportedContextEvents,
            aggregate.unpricedReasonCounts.unsupportedContextTokens,
            aggregate.unpricedReasonCounts.invalidRecordEvents,
            aggregate.unpricedReasonCounts.invalidRecordTokens,
            aggregate.unpricedReasonCounts.overflowEvents,
            aggregate.unpricedReasonCounts.overflowTokens
        ]
    }

    private func loadSessionTotalsFromSummaries(
        sessionId: String,
        target: PersistenceTarget = .live
    ) throws -> (
        eventCount: Int,
        tokens: TokenBreakdown,
        estimatedCost: MoneyNanoUSD,
        unpricedEventCount: Int,
        unpricedReasonCounts: UnpricedReasonCounts
    ) {
        try database.executeQuery(
            sql: """
            SELECT
                COALESCE(SUM(event_count), 0),
                COALESCE(SUM(total_tokens), 0),
                COALESCE(SUM(uncached_input_tokens), 0),
                COALESCE(SUM(cached_input_tokens), 0),
                COALESCE(SUM(cache_write_input_tokens), 0),
                COALESCE(SUM(output_tokens), 0),
                COALESCE(SUM(reasoning_output_tokens), 0),
                COALESCE(SUM(estimated_cost_usd_nano), 0),
                COALESCE(SUM(unpriced_event_count), 0),
                COALESCE(SUM(unpriced_unknown_model_event_count), 0),
                COALESCE(SUM(unpriced_unknown_model_token_count), 0),
                COALESCE(SUM(unpriced_unsupported_tier_event_count), 0),
                COALESCE(SUM(unpriced_unsupported_tier_token_count), 0),
                COALESCE(SUM(unpriced_historical_rule_missing_event_count), 0),
                COALESCE(SUM(unpriced_historical_rule_missing_token_count), 0),
                COALESCE(SUM(unpriced_unsupported_context_event_count), 0),
                COALESCE(SUM(unpriced_unsupported_context_token_count), 0),
                COALESCE(SUM(unpriced_invalid_record_event_count), 0),
                COALESCE(SUM(unpriced_invalid_record_token_count), 0),
                COALESCE(SUM(unpriced_overflow_event_count), 0),
                COALESCE(SUM(unpriced_overflow_token_count), 0)
            FROM \(target.sessionSummariesTable)
            WHERE session_id = ?;
            """,
            bindings: [sessionId]
        ) { stmt in
            let uncached = sqlite3_column_int64(stmt, 2)
            let cached = sqlite3_column_int64(stmt, 3)
            let cacheWrite = sqlite3_column_int64(stmt, 4)
            return (
                eventCount: Int(sqlite3_column_int(stmt, 0)),
                tokens: TokenBreakdown(
                    inputTokens: uncached + cached + cacheWrite,
                    cachedInputTokens: cached,
                    cacheWriteInputTokens: cacheWrite,
                    outputTokens: sqlite3_column_int64(stmt, 5),
                    reasoningOutputTokens: sqlite3_column_int64(stmt, 6),
                    sourceTotalTokens: sqlite3_column_int64(stmt, 1)
                ),
                estimatedCost: MoneyNanoUSD(sqlite3_column_int64(stmt, 7)),
                unpricedEventCount: Int(sqlite3_column_int(stmt, 8)),
                unpricedReasonCounts: UnpricedReasonCounts(
                    unknownModelEvents: Int(sqlite3_column_int(stmt, 9)),
                    unknownModelTokens: sqlite3_column_int64(stmt, 10),
                    unsupportedTierEvents: Int(sqlite3_column_int(stmt, 11)),
                    unsupportedTierTokens: sqlite3_column_int64(stmt, 12),
                    historicalRuleMissingEvents: Int(sqlite3_column_int(stmt, 13)),
                    historicalRuleMissingTokens: sqlite3_column_int64(stmt, 14),
                    unsupportedContextEvents: Int(sqlite3_column_int(stmt, 15)),
                    unsupportedContextTokens: sqlite3_column_int64(stmt, 16),
                    invalidRecordEvents: Int(sqlite3_column_int(stmt, 17)),
                    invalidRecordTokens: sqlite3_column_int64(stmt, 18),
                    overflowEvents: Int(sqlite3_column_int(stmt, 19)),
                    overflowTokens: sqlite3_column_int64(stmt, 20)
                )
            )
        }.first ?? (0, .zero, .zero, 0, .zero)
    }

    private func maxOptional(_ lhs: Int64?, _ rhs: Int64?) -> Int64? {
        switch (lhs, rhs) {
        case let (l?, r?):
            return max(l, r)
        case let (l?, nil):
            return l
        case let (nil, r?):
            return r
        case (nil, nil):
            return nil
        }
    }

    private func nextScanGeneration() throws -> Int64 {
        let previous = try database.int64Scalar(
            sql: "SELECT value FROM app_metadata WHERE key = 'codex_usage_scan_generation';"
        ) ?? 0
        let next = previous + 1
        try database.executeUpdate(
            sql: "INSERT OR REPLACE INTO app_metadata (key, value, updated_at) VALUES ('codex_usage_scan_generation', ?, unixepoch());",
            bindings: [String(next)]
        )
        return next
    }

    private func updateParserRebuildMetadata(
        status: String,
        generation: Int64,
        error: String?,
        processedSources: Int? = nil,
        totalSources: Int? = nil
    ) throws {
        try database.executeUpdate(
            sql: "INSERT OR REPLACE INTO app_metadata (key, value, updated_at) VALUES ('codex_parser_rebuild_status', ?, unixepoch());",
            bindings: [status]
        )
        try database.executeUpdate(
            sql: "INSERT OR REPLACE INTO app_metadata (key, value, updated_at) VALUES ('codex_parser_rebuild_generation', ?, unixepoch());",
            bindings: [String(generation)]
        )
        if let processedSources {
            try database.executeUpdate(
                sql: "INSERT OR REPLACE INTO app_metadata (key, value, updated_at) VALUES ('codex_parser_rebuild_processed_sources', ?, unixepoch());",
                bindings: [String(processedSources)]
            )
        }
        if let totalSources {
            try database.executeUpdate(
                sql: "INSERT OR REPLACE INTO app_metadata (key, value, updated_at) VALUES ('codex_parser_rebuild_total_sources', ?, unixepoch());",
                bindings: [String(totalSources)]
            )
        }
        if let error, !error.isEmpty {
            try database.executeUpdate(
                sql: "INSERT OR REPLACE INTO app_metadata (key, value, updated_at) VALUES ('codex_parser_rebuild_error', ?, unixepoch());",
                bindings: [error]
            )
        } else {
            try database.executeUpdate(sql: "DELETE FROM app_metadata WHERE key = 'codex_parser_rebuild_error';", bindings: [])
        }
    }

    private func persistScanDiagnostics(
        _ diagnostics: [RolloutScanDiagnostic],
        scanGeneration: Int64
    ) throws {
        try database.transaction {
            try database.executeUpdate(
                sql: "DELETE FROM codex_scan_diagnostics;",
                bindings: []
            )
            for diagnostic in diagnostics {
                try database.executeUpdate(
                    sql: """
                    INSERT INTO codex_scan_diagnostics (
                        source_path, relative_path, bucket, diagnostic_code,
                        message, scan_generation, created_at
                    ) VALUES (?, ?, ?, ?, ?, ?, unixepoch());
                    """,
                    bindings: [
                        diagnostic.fileURL.path,
                        diagnostic.relativePath,
                        diagnostic.bucket.rawValue,
                        diagnostic.code,
                        diagnostic.message,
                        scanGeneration
                    ]
                )
            }
        }
    }

    private func markSourceSeen(
        source: RolloutDiscoveredSource,
        fingerprint: SourceContentFingerprint,
        scanGeneration: Int64
    ) throws {
        try database.executeUpdate(
            sql: """
            UPDATE codex_import_sources
            SET file_size = ?, mtime_ms = ?, head_sha256 = ?, tail_sha256 = ?,
                parser_version = ?, scan_generation = ?, status = 'indexed',
                last_imported_at = unixepoch(), error_message = NULL
            WHERE source_path = ?;
            """,
            bindings: [
                source.fileSize,
                source.mtimeMs,
                fingerprint.headSHA256,
                fingerprint.tailSHA256,
                ParserCheckpoint.currentParserVersion,
                scanGeneration,
                source.fileURL.path
            ]
        )
    }

    private func relocatePhysicalSource(
        existing: ExistingSourceState,
        source: RolloutDiscoveredSource,
        scanGeneration: Int64
    ) throws {
        try database.transaction {
            try database.executeUpdate(
                sql: """
                UPDATE codex_import_sources
                SET source_path = ?, relative_path = ?, bucket = ?, file_size = ?,
                    mtime_ms = ?, scan_generation = ?, status = 'indexed', error_message = NULL
                WHERE source_path = ?;
                """,
                bindings: [
                    source.fileURL.path,
                    source.relativePath,
                    source.bucket.rawValue,
                    source.fileSize,
                    source.mtimeMs,
                    scanGeneration,
                    existing.sourcePath
                ]
            )
            try database.executeUpdate(
                sql: "UPDATE codex_usage_events SET source_path = ? WHERE source_path = ? OR source_path = ?;",
                bindings: [source.fileURL.path, existing.sourcePath, existing.relativePath]
            )
            try database.executeUpdate(
                sql: """
                UPDATE codex_sessions
                SET source_path = ?, relative_path = ?, bucket = ?
                WHERE source_path = ? OR relative_path = ?;
                """,
                bindings: [
                    source.fileURL.path,
                    source.relativePath,
                    source.bucket.rawValue,
                    existing.sourcePath,
                    existing.relativePath
                ]
            )
        }
    }

    private func tombstoneMissingSources(
        currentSourcePaths: Set<String>,
        currentSessionIds: Set<String>,
        scanGeneration: Int64,
        scanOutcome: ScanOutcome,
        preserveMissingSources: Bool
    ) throws {
        let staleSources = try database.executeQuery(
            sql: """
            SELECT source_path, relative_path, bucket, parser_version, status
            FROM codex_import_sources
            WHERE scan_generation < ? AND status != 'tombstoned';
            """,
            bindings: [scanGeneration]
        ) { stmt -> (String, String, SessionBucket, Bool) in
            let path = String(cString: sqlite3_column_text(stmt, 0))
            let relative = sqlite3_column_type(stmt, 1) != SQLITE_NULL && sqlite3_column_text(stmt, 1) != nil
                ? String(cString: sqlite3_column_text(stmt, 1)!)
                : ""
            let bucketRaw = sqlite3_column_type(stmt, 2) != SQLITE_NULL && sqlite3_column_text(stmt, 2) != nil
                ? String(cString: sqlite3_column_text(stmt, 2)!)
                : SessionBucket.active.rawValue
            let needsRebuild = Int(sqlite3_column_int(stmt, 3)) != ParserCheckpoint.currentParserVersion
                || String(cString: sqlite3_column_text(stmt, 4)) == "stale"
            return (path, relative, SessionBucket(rawValue: bucketRaw) ?? .active, needsRebuild)
        }

        for stale in staleSources {
            guard !currentSourcePaths.contains(stale.0) else { continue }
            let sessions = try database.executeQuery(
                sql: "SELECT session_id FROM codex_sessions WHERE source_path = ? OR relative_path = ?;",
                bindings: [stale.0, stale.1]
            ) { stmt in
                String(cString: sqlite3_column_text(stmt, 0))
            }

            let movedSessionStillPresent = sessions.contains { currentSessionIds.contains($0) }
            // 重建所需原件缺失时保留旧账本；只有明确已搬迁的旧路径才可直接作废。
            if !movedSessionStillPresent && (preserveMissingSources || stale.3) {
                try database.executeUpdate(
                    sql: "UPDATE codex_import_sources SET status = 'stale', error_message = 'source unavailable; previous index retained' WHERE source_path = ?;",
                    bindings: [stale.0]
                )
                continue
            }
            guard scanOutcome.status(for: stale.2).allowsTombstone else { continue }
            if !movedSessionStillPresent {
                try deleteDerivedRowsForSource(sourcePath: stale.0, relativePath: stale.1)
            }

            try database.executeUpdate(
                sql: "UPDATE codex_import_sources SET status = 'tombstoned', scan_generation = ?, error_message = NULL WHERE source_path = ?;",
                bindings: [scanGeneration, stale.0]
            )
        }
    }

    private func deleteDerivedRowsForSource(sourcePath: String, relativePath: String) throws {
        let sessionIds = try database.executeQuery(
            sql: "SELECT session_id FROM codex_sessions WHERE source_path = ? OR relative_path = ?;",
            bindings: [sourcePath, relativePath]
        ) { stmt in
            String(cString: sqlite3_column_text(stmt, 0))
        }
        try database.executeUpdate(sql: "DELETE FROM codex_usage_events WHERE source_path = ? OR source_path = ?;", bindings: [sourcePath, relativePath])
        for sessionId in sessionIds {
            try database.executeUpdate(sql: "DELETE FROM codex_session_summaries WHERE session_id = ?;", bindings: [sessionId])
            try database.executeUpdate(sql: "DELETE FROM codex_daily_usage_summaries WHERE session_id = ?;", bindings: [sessionId])
            try database.executeUpdate(sql: "DELETE FROM codex_sessions WHERE session_id = ?;", bindings: [sessionId])
        }
    }

    private func fallbackTimestamp(
        for source: RolloutDiscoveredSource,
        resolvedSession: CodexResolvedSessionMetadata?
    ) -> (Int64, TimestampQuality) {
        if let fromFileName = Self.timestampFromFilename(source.fileURL.lastPathComponent) {
            return (fromFileName, .fileNameTimestamp)
        }
        if let resolvedSession {
            let createdMs = Int64(resolvedSession.createdAt.timeIntervalSince1970 * 1000)
            if createdMs > 0 {
                return (createdMs, .sessionTimestamp)
            }
        }
        if source.mtimeMs > 0 {
            return (source.mtimeMs, .fileModificationTime)
        }
        return (0, .unresolved)
    }

    private func sourceTimestampFallback(relativePath: String) -> Int64 {
        Self.timestampFromFilename((relativePath as NSString).lastPathComponent) ?? 0
    }

    static func timestampFromFilename(_ fileName: String) -> Int64? {
        if let range = fileName.range(
            of: #"rollout-(\d{4}-\d{2}-\d{2}T\d{2}-\d{2}-\d{2})"#,
            options: .regularExpression
        ) {
            let matched = String(fileName[range]).dropFirst("rollout-".count)
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = "yyyy-MM-dd'T'HH-mm-ss"
            if let date = formatter.date(from: String(matched)) {
                return Int64(date.timeIntervalSince1970 * 1_000)
            }
        }
        if let range = fileName.range(of: #"\d{13}"#, options: .regularExpression),
           let value = Int64(fileName[range]),
           value > 1_000_000_000_000 {
            return value
        }
        if let range = fileName.range(of: #"\d{10}"#, options: .regularExpression),
           let value = Int64(fileName[range]),
           value > 1_000_000_000 {
            return value * 1000
        }
        return nil
    }

    private static func isSyntacticallyValidJSON(_ line: String) -> Bool {
        let normalized = line.hasPrefix("\u{feff}") ? String(line.dropFirst()) : line
        guard let data = normalized.data(using: .utf8) else { return false }
        return (try? JSONSerialization.jsonObject(with: data)) != nil
    }

    private static func fingerprint(fileURL: URL, fileSize: Int64) -> SourceContentFingerprint {
        SourceContentFingerprint(
            headSHA256: hashWindow(fileURL: fileURL, startOffset: 0, length: min(fileSize, 4_096)),
            tailSHA256: tailHash(fileURL: fileURL, endOffset: fileSize)
        )
    }

    private static func tailHash(fileURL: URL, endOffset: Int64, length: Int64 = 4_096) -> String {
        let safeEnd = max(0, endOffset)
        let start = max(0, safeEnd - length)
        return hashWindow(fileURL: fileURL, startOffset: start, length: safeEnd - start)
    }

    private static func hashWindow(fileURL: URL, startOffset: Int64, length: Int64) -> String {
        guard length > 0,
              let handle = try? FileHandle(forReadingFrom: fileURL) else {
            return sha256Hex(Data())
        }
        defer { try? handle.close() }
        do {
            try handle.seek(toOffset: UInt64(max(0, startOffset)))
            let data = handle.readData(ofLength: Int(length))
            return sha256Hex(data)
        } catch {
            return sha256Hex(Data())
        }
    }

    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func unixMillis() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1000)
    }
}
