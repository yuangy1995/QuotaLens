// QuotaLens 增量用量导入引擎 (单写者 Actor)
// 管理完整扫描、增量流式解析、内存聚合与最终汇总提交

import Foundation
import Darwin
import SQLite3

public struct ImportSummary: Sendable {
    public let sourcesScanned: Int
    public let sourcesUpdated: Int
    public let eventsInserted: Int
    public let bytesRead: Int64
    public let durationSeconds: Double

    public init(
        sourcesScanned: Int = 0,
        sourcesUpdated: Int = 0,
        eventsInserted: Int = 0,
        bytesRead: Int64 = 0,
        durationSeconds: Double = 0
    ) {
        self.sourcesScanned = sourcesScanned
        self.sourcesUpdated = sourcesUpdated
        self.eventsInserted = eventsInserted
        self.bytesRead = bytesRead
        self.durationSeconds = durationSeconds
    }
}

public actor CodexUsageImportActor {
    private let database: SQLiteDatabase
    private var isImporting = false

    public init(database: SQLiteDatabase) {
        self.database = database
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

        let startTime = CFAbsoluteTimeGetCurrent()
        try PricingCatalogService.shared.ensureCatalogInstalled(database: database)
        let pricingSnapshot = try PricingCatalogService.shared.loadSnapshot(database: database)

        // 1. 扫描文件源
        onProgress?(0.05, L10n.text("正在扫描 Codex 会话文件…", "Scanning Codex session files..."))
        let scannedSources = CodexRolloutScanner.scan(
            paths: paths,
            scanArchived: UsageFeatureFlags.shared.isScanArchivedSessionsEnabled
        )
        let rolloutHeaders = CodexSessionMetadataStore.loadFromRolloutHeaders(sources: scannedSources)
        let discoveredSources = scannedSources.map { source in
            canonicalizedSource(source, header: rolloutHeaders[source.fileURL.path])
        }

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
                    forceRebuild: forceRebuild
                )
            }
            ImportMemoryBudget.relieveAllocatorPressure()

            if result.eventsInserted > 0 || result.bytesRead > 0 {
                sourcesUpdated += 1
                totalEventsInserted += result.eventsInserted
                totalBytesRead += result.bytesRead
            }
        }

        // 4. 更新全局代数与导入历史
        let endTime = CFAbsoluteTimeGetCurrent()
        let duration = max(0.001, endTime - startTime)

        let runId = "run_\(Int64(Date().timeIntervalSince1970 * 1000))"
        try? database.executeUpdate(
            sql: """
            INSERT INTO codex_import_runs (
                run_id, started_at, completed_at, sources_scanned, sources_updated,
                events_inserted, bytes_read, status, error_message
            ) VALUES (?, ?, ?, ?, ?, ?, ?, 'success', NULL);
            """,
            bindings: [
                runId,
                Int64(startTime * 1000),
                Int64(endTime * 1000),
                discoveredSources.count,
                sourcesUpdated,
                totalEventsInserted,
                totalBytesRead
            ]
        )

        try? database.executeUpdate(
            sql: "INSERT OR REPLACE INTO app_metadata (key, value, updated_at) VALUES ('codex_usage_generation', unixepoch(), unixepoch());",
            bindings: []
        )

        onProgress?(1.0, L10n.text("导入完成", "Import complete"))

        return ImportSummary(
            sourcesScanned: discoveredSources.count,
            sourcesUpdated: sourcesUpdated,
            eventsInserted: totalEventsInserted,
            bytesRead: totalBytesRead,
            durationSeconds: duration
        )
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
        var lastEventAtMs: Int64?

        mutating func add(event: CodexParsedUsageEvent, price: PricingEvaluationResult) {
            eventCount += 1
            tokens = tokens + event.tokens
            estimatedCost = estimatedCost + price.estimatedCost
            if !price.pricingStatus.isPriced {
                unpricedEventCount += 1
            }
            if let current = lastEventAtMs {
                lastEventAtMs = max(current, event.timestampMs)
            } else {
                lastEventAtMs = event.timestampMs
            }
        }
    }

    private struct SourceAggregation {
        var session = UsageAggregate()
        var models: [String: UsageAggregate] = [:]
        var days: [DailyAggregateKey: UsageAggregate] = [:]

        mutating func add(
            event: CodexParsedUsageEvent,
            price: PricingEvaluationResult,
            calendar: Calendar
        ) {
            guard !event.isChildReplay else { return }
            session.add(event: event, price: price)

            var modelAgg = models[event.modelCanonical] ?? UsageAggregate()
            modelAgg.add(event: event, price: price)
            models[event.modelCanonical] = modelAgg

            let eventDate = Date(timeIntervalSince1970: Double(event.timestampMs) / 1000.0)
            let dayKey = LocalDayKey(date: eventDate, calendar: calendar)
            let dayStartMs = Int64(dayKey.date(calendar: calendar).timeIntervalSince1970 * 1000.0)
            let key = DailyAggregateKey(
                dayKey: dayKey.yyyyMMdd,
                dayStartMs: dayStartMs,
                modelCanonical: event.modelCanonical
            )
            var dayAgg = days[key] ?? UsageAggregate()
            dayAgg.add(event: event, price: price)
            days[key] = dayAgg
        }

        var isEmpty: Bool {
            session.eventCount == 0 && models.isEmpty && days.isEmpty
        }

        var estimatedMemoryBytes: Int {
            4_096
                + models.reduce(0) { partial, item in
                    partial + 512 + item.key.utf8.count
                }
                + days.reduce(0) { partial, item in
                    partial + 640 + item.key.dayKey.utf8.count + item.key.modelCanonical.utf8.count
                }
        }

        mutating func removeAll(keepingCapacity: Bool = true) {
            session = UsageAggregate()
            models.removeAll(keepingCapacity: keepingCapacity)
            days.removeAll(keepingCapacity: keepingCapacity)
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
        forceRebuild: Bool
    ) throws -> SingleSourceProcessResult {
        // 读取该源之前的检查点
        let existingCheckpointRow = try database.executeQuery(
            sql: "SELECT last_imported_size, checkpoint_state_json FROM codex_import_sources WHERE source_path = ?;",
            bindings: [source.fileURL.path]
        ) { stmt -> (Int64, String?) in
            let size = sqlite3_column_int64(stmt, 0)
            let json = sqlite3_column_type(stmt, 1) != SQLITE_NULL && sqlite3_column_text(stmt, 1) != nil
                ? String(cString: sqlite3_column_text(stmt, 1)!) : nil
            return (size, json)
        }.first

        var startOffset: Int64 = 0
        var initialCheckpoint = ParserCheckpoint.initial
        var replaceExistingDerivedRows = forceRebuild

        if !forceRebuild, let existing = existingCheckpointRow {
            if source.fileSize == existing.0 {
                // 文件大小完全未变，无需重新读取
                return SingleSourceProcessResult(eventsInserted: 0, bytesRead: 0)
            } else if source.fileSize > existing.0 {
                // 文件增量追加
                startOffset = existing.0
                if let json = existing.1, let parsedCp = ParserCheckpoint.fromJsonString(json) {
                    initialCheckpoint = parsedCp
                }
            } else {
                // 文件发生截断，重新从头全量解析
                startOffset = 0
                initialCheckpoint = .initial
                replaceExistingDerivedRows = true
            }
        }

        let isChild = (resolvedSession?.depth ?? 0) > 0
        let rootSessionId = resolvedSession?.rootSessionId ?? source.sessionId

        let reducer = CodexUsageReducer(
            sessionId: source.sessionId,
            rootSessionId: rootSessionId,
            isChildSession: isChild,
            sourcePath: source.fileURL.path
        )

        var reducerState = CodexUsageReducer.ReducerState(checkpoint: initialCheckpoint)
        var aggregation = SourceAggregation()
        let memoryBudget = ImportMemoryBudget.current()
        let calendar = Calendar.current
        var totalInserted = 0
        var eventsSinceMemoryCheck = 0
        var hasCommittedChunks = false

        // 流式逐行读取
        let (finalOffset, _) = try StreamingJSONLReader.readLines(
            fileURL: source.fileURL,
            startOffset: startOffset,
            shouldIncludeLineData: RolloutLineDecoder.mayContainUsageRelevantEvent
        ) { lineRecord in
            if let wireEvent = RolloutLineDecoder.decodeLine(lineRecord.lineString) {
                if let parsedEvent = reducer.reduce(event: wireEvent, lineRecord: lineRecord, state: &reducerState) {
                    let priceResult = pricingSnapshot.evaluate(
                        modelCanonical: parsedEvent.modelCanonical,
                        serviceTier: parsedEvent.serviceTier,
                        timestampMs: parsedEvent.timestampMs,
                        tokens: parsedEvent.tokens
                    )
                    aggregation.add(event: parsedEvent, price: priceResult, calendar: calendar)
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
                                    replaceExisting: replaceExistingDerivedRows && !hasCommittedChunks
                                )
                            }
                            try persistSourceCheckpointInTransaction(
                                source: source,
                                importedSize: lineRecord.startOffset + Int64(lineRecord.lineBytes),
                                checkpoint: checkpoint,
                                status: "partial"
                            )
                        }

                        totalInserted += aggregation.session.eventCount
                        aggregation.removeAll()
                        ImportMemoryBudget.relieveAllocatorPressure()
                        replaceExistingDerivedRows = false
                        hasCommittedChunks = true
                        eventsSinceMemoryCheck = 0
                    }
                }
            }
        }

        // 提交最终检查点与会话汇总
        let finalCheckpoint = reducerState.makeCheckpoint()

        try database.transaction {
            // 1. 更新文件源状态
            try persistSourceCheckpointInTransaction(
                source: source,
                importedSize: finalOffset,
                checkpoint: finalCheckpoint,
                status: "indexed"
            )

            // 2. 写入最终聚合结果。扫描过程不落事件明细，避免大文件导致持续写盘。
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
                        replaceExisting: shouldReplace
                    )
                } else if shouldReplace {
                    try deleteDerivedRowsForSession(
                        sessionId: session.sessionId,
                        sourcePath: source.fileURL.path,
                        relativePath: source.relativePath
                    )
                }
            }
        }

        totalInserted += aggregation.session.eventCount
        ImportMemoryBudget.relieveAllocatorPressure()
        let bytesRead = max(0, finalOffset - startOffset)
        return SingleSourceProcessResult(eventsInserted: totalInserted, bytesRead: bytesRead)
    }

    private func persistSourceCheckpointInTransaction(
        source: RolloutDiscoveredSource,
        importedSize: Int64,
        checkpoint: ParserCheckpoint,
        status: String
    ) throws {
        let checkpointJson = checkpoint.toJsonString() ?? "{}"
        try database.executeUpdate(
            sql: """
            INSERT OR REPLACE INTO codex_import_sources (
                source_path, relative_path, bucket, device_id, inode, birthtime_ns,
                file_size, mtime_ms, last_imported_size, last_imported_line,
                checkpoint_state_json, status, last_imported_at, error_message
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, unixepoch(), NULL);
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
                checkpointJson,
                status
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
        replaceExisting: Bool
    ) throws {
        if replaceExisting {
            try deleteDerivedRowsForSession(sessionId: sessionId, sourcePath: sourcePath, relativePath: relativePath)
        } else {
            try database.executeUpdate(
                sql: "DELETE FROM codex_usage_events WHERE source_path = ? OR source_path = ?;",
                bindings: [sourcePath, relativePath]
            )
        }

        for (model, aggregate) in aggregation.models {
            try upsertSessionModelSummary(sessionId: sessionId, modelCanonical: model, aggregate: aggregate)
        }

        for (key, aggregate) in aggregation.days {
            try upsertDailySummary(sessionId: sessionId, key: key, aggregate: aggregate)
        }

        let totals = try loadSessionTotalsFromSummaries(sessionId: sessionId)
        let existingLastEventAt: Int64? = replaceExisting ? nil : try database.executeQuery(
            sql: "SELECT last_event_at FROM codex_sessions WHERE session_id = ?;",
            bindings: [sessionId]
        ) { stmt -> Int64? in
            sqlite3_column_type(stmt, 0) != SQLITE_NULL ? sqlite3_column_int64(stmt, 0) : nil
        }.first ?? nil
        let lastEventAt = maxOptional(existingLastEventAt, aggregation.session.lastEventAtMs)
        let updatedAtMs = max(
            Int64(metadata.updatedAt.timeIntervalSince1970 * 1000),
            lastEventAt ?? 0
        )
        let pricingStatus: PricingStatus = totals.unpricedEventCount > 0 ? .unpricedUnknownModel : .priced

        try database.executeUpdate(
            sql: """
            INSERT OR REPLACE INTO codex_sessions (
                session_id, root_session_id, parent_session_id, depth, source_path,
                relative_path, bucket, title, project_name, cwd, created_at, updated_at,
                last_event_at, event_count, total_tokens, input_tokens, cached_input_tokens,
                output_tokens, reasoning_output_tokens, estimated_cost_usd_nano,
                pricing_status, metadata_fingerprint, has_subagents
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, NULL, ?);
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
                Int64(metadata.createdAt.timeIntervalSince1970 * 1000),
                updatedAtMs,
                lastEventAt,
                totals.eventCount,
                totals.tokens.canonicalTotalTokens,
                totals.tokens.inputTokens,
                totals.tokens.cachedInputTokens,
                totals.tokens.outputTokens,
                totals.tokens.reasoningOutputTokens,
                totals.estimatedCost.rawValue,
                pricingStatus.rawValue,
                metadata.hasSubagents ? 1 : 0
            ]
        )
    }

    private func deleteDerivedRowsForSession(sessionId: String, sourcePath: String, relativePath: String) throws {
        try database.executeUpdate(sql: "DELETE FROM codex_usage_events WHERE source_path = ? OR source_path = ?;", bindings: [sourcePath, relativePath])
        try database.executeUpdate(sql: "DELETE FROM codex_session_summaries WHERE session_id = ?;", bindings: [sessionId])
        try database.executeUpdate(sql: "DELETE FROM codex_daily_usage_summaries WHERE session_id = ?;", bindings: [sessionId])
        try database.executeUpdate(sql: "DELETE FROM codex_sessions WHERE session_id = ?;", bindings: [sessionId])
    }

    private func upsertSessionModelSummary(
        sessionId: String,
        modelCanonical: String,
        aggregate: UsageAggregate
    ) throws {
        try database.executeUpdate(
            sql: """
            INSERT INTO codex_session_summaries (
                session_id, model_canonical, event_count, total_tokens,
                uncached_input_tokens, cached_input_tokens, output_tokens,
                reasoning_output_tokens, estimated_cost_usd_nano, unpriced_event_count
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(session_id, model_canonical) DO UPDATE SET
                event_count = event_count + excluded.event_count,
                total_tokens = total_tokens + excluded.total_tokens,
                uncached_input_tokens = uncached_input_tokens + excluded.uncached_input_tokens,
                cached_input_tokens = cached_input_tokens + excluded.cached_input_tokens,
                output_tokens = output_tokens + excluded.output_tokens,
                reasoning_output_tokens = reasoning_output_tokens + excluded.reasoning_output_tokens,
                estimated_cost_usd_nano = estimated_cost_usd_nano + excluded.estimated_cost_usd_nano,
                unpriced_event_count = unpriced_event_count + excluded.unpriced_event_count;
            """,
            bindings: aggregateBindings(prefix: [sessionId, modelCanonical], aggregate: aggregate)
        )
    }

    private func upsertDailySummary(
        sessionId: String,
        key: DailyAggregateKey,
        aggregate: UsageAggregate
    ) throws {
        try database.executeUpdate(
            sql: """
            INSERT INTO codex_daily_usage_summaries (
                session_id, day_key, day_start_ms, model_canonical, event_count,
                total_tokens, uncached_input_tokens, cached_input_tokens, output_tokens,
                reasoning_output_tokens, estimated_cost_usd_nano, unpriced_event_count
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(session_id, day_key, model_canonical) DO UPDATE SET
                day_start_ms = excluded.day_start_ms,
                event_count = event_count + excluded.event_count,
                total_tokens = total_tokens + excluded.total_tokens,
                uncached_input_tokens = uncached_input_tokens + excluded.uncached_input_tokens,
                cached_input_tokens = cached_input_tokens + excluded.cached_input_tokens,
                output_tokens = output_tokens + excluded.output_tokens,
                reasoning_output_tokens = reasoning_output_tokens + excluded.reasoning_output_tokens,
                estimated_cost_usd_nano = estimated_cost_usd_nano + excluded.estimated_cost_usd_nano,
                unpriced_event_count = unpriced_event_count + excluded.unpriced_event_count;
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
            aggregate.tokens.outputTokens,
            aggregate.tokens.reasoningOutputTokens,
            aggregate.estimatedCost.rawValue,
            aggregate.unpricedEventCount
        ]
    }

    private func loadSessionTotalsFromSummaries(
        sessionId: String
    ) throws -> (eventCount: Int, tokens: TokenBreakdown, estimatedCost: MoneyNanoUSD, unpricedEventCount: Int) {
        try database.executeQuery(
            sql: """
            SELECT
                COALESCE(SUM(event_count), 0),
                COALESCE(SUM(total_tokens), 0),
                COALESCE(SUM(uncached_input_tokens), 0),
                COALESCE(SUM(cached_input_tokens), 0),
                COALESCE(SUM(output_tokens), 0),
                COALESCE(SUM(reasoning_output_tokens), 0),
                COALESCE(SUM(estimated_cost_usd_nano), 0),
                COALESCE(SUM(unpriced_event_count), 0)
            FROM codex_session_summaries
            WHERE session_id = ?;
            """,
            bindings: [sessionId]
        ) { stmt in
            let uncached = sqlite3_column_int64(stmt, 2)
            let cached = sqlite3_column_int64(stmt, 3)
            return (
                eventCount: Int(sqlite3_column_int(stmt, 0)),
                tokens: TokenBreakdown(
                    inputTokens: uncached + cached,
                    cachedInputTokens: cached,
                    outputTokens: sqlite3_column_int64(stmt, 4),
                    reasoningOutputTokens: sqlite3_column_int64(stmt, 5),
                    sourceTotalTokens: sqlite3_column_int64(stmt, 1)
                ),
                estimatedCost: MoneyNanoUSD(sqlite3_column_int64(stmt, 6)),
                unpricedEventCount: Int(sqlite3_column_int(stmt, 7))
            )
        }.first ?? (0, .zero, .zero, 0)
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
}
