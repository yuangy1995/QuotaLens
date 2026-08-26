// QuotaLens Token 差分归约器与模型状态机
// 严格保证 Token 统计闭环、增量计算、重启补偿、模型归属质量与子会话 Replay 过滤

import Foundation

public struct CodexParsedUsageEvent: Sendable {
    public let eventId: String
    public let sessionId: String
    public let rootSessionId: String
    public let turnIndex: Int
    public let callIndex: Int
    public let timestampMs: Int64
    public let timestampQuality: TimestampQuality
    public let timestampSource: TimestampSource
    public let timestampConflictCount: Int
    public let modelRaw: String
    public let modelCanonical: String
    public let serviceTier: String?
    public let reasoningEffort: String?
    public let tokens: TokenBreakdown
    public let usageDerivation: UsageDerivation
    public let attributionQuality: AttributionQuality
    public let isChildReplay: Bool
    public let sourcePath: String
    public let lineOffset: Int64
    public let lineBytes: Int

    public init(
        eventId: String,
        sessionId: String,
        rootSessionId: String,
        turnIndex: Int,
        callIndex: Int,
        timestampMs: Int64,
        timestampQuality: TimestampQuality,
        timestampSource: TimestampSource = .topLevelTimestamp,
        timestampConflictCount: Int = 0,
        modelRaw: String,
        modelCanonical: String,
        serviceTier: String?,
        reasoningEffort: String? = nil,
        tokens: TokenBreakdown,
        usageDerivation: UsageDerivation,
        attributionQuality: AttributionQuality,
        isChildReplay: Bool,
        sourcePath: String,
        lineOffset: Int64,
        lineBytes: Int
    ) {
        self.eventId = eventId
        self.sessionId = sessionId
        self.rootSessionId = rootSessionId
        self.turnIndex = turnIndex
        self.callIndex = callIndex
        self.timestampMs = timestampMs
        self.timestampQuality = timestampQuality
        self.timestampSource = timestampSource
        self.timestampConflictCount = timestampConflictCount
        self.modelRaw = modelRaw
        self.modelCanonical = modelCanonical
        self.serviceTier = serviceTier
        self.reasoningEffort = reasoningEffort
        self.tokens = tokens
        self.usageDerivation = usageDerivation
        self.attributionQuality = attributionQuality
        self.isChildReplay = isChildReplay
        self.sourcePath = sourcePath
        self.lineOffset = lineOffset
        self.lineBytes = lineBytes
    }
}

public final class CodexUsageReducer: Sendable {
    private let sessionId: String
    private let rootSessionId: String
    private let isChildSession: Bool
    private let sourcePath: String
    private let sourceEventKey: String
    private let fallbackTimestampMs: Int64
    private let fallbackTimestampQuality: TimestampQuality

    public init(
        sessionId: String,
        rootSessionId: String,
        isChildSession: Bool,
        sourcePath: String,
        sourceIdentityKey: String? = nil,
        fallbackTimestampMs: Int64 = 0,
        fallbackTimestampQuality: TimestampQuality = .unresolved
    ) {
        self.sessionId = sessionId
        self.rootSessionId = rootSessionId
        self.isChildSession = isChildSession
        self.sourcePath = sourcePath
        // Physical identity keeps event IDs stable when Codex moves a rollout
        // between active and archived folders. Tests and callers without an
        // identity retain the path-based deterministic fallback.
        self.sourceEventKey = Self.stableSourceKey(sourceIdentityKey ?? sourcePath)
        self.fallbackTimestampMs = fallbackTimestampMs
        self.fallbackTimestampQuality = fallbackTimestampQuality
    }

    /// 归约状态容器
    public struct ReducerState: Sendable {
        public var activeModel: String?
        public var activeServiceTier: String?
        public var activeReasoningEffort: String?
        public var currentTurnIndex: Int
        public var currentCallIndex: Int
        public var cumulativeBaseline: TokenBreakdown
        public var totalLinesConsumed: Int
        public var lastOffset: Int64
        public var hasEncounteredChildFreshTurn: Bool
        public var isIncrementalRootEligible: Bool
        public var childReplayGateKind: String?
        public var childReplayGateTimestampMs: Int64?
        public var hasSeenReplayedSessionMeta: Bool
        public var stableSessionId: String?
        public var requiresFullRebuildReason: String?

        public init(
            checkpoint: ParserCheckpoint = .initial
        ) {
            self.activeModel = checkpoint.currentModel
            self.activeServiceTier = checkpoint.currentServiceTier
            self.activeReasoningEffort = checkpoint.currentReasoningEffort
            self.currentTurnIndex = checkpoint.currentTurnIndex
            self.currentCallIndex = checkpoint.currentCallIndex
            self.cumulativeBaseline = checkpoint.lastCumulativeTokens
            self.totalLinesConsumed = checkpoint.lineCount
            self.lastOffset = checkpoint.lineOffset
            self.hasEncounteredChildFreshTurn = checkpoint.hasSeenFreshTurn
            self.isIncrementalRootEligible = checkpoint.isIncrementalRootEligible
            self.childReplayGateKind = checkpoint.childReplayGateKind
            self.childReplayGateTimestampMs = checkpoint.childReplayGateTimestampMs
            self.hasSeenReplayedSessionMeta = checkpoint.hasSeenReplayedSessionMeta
            self.stableSessionId = checkpoint.stableSessionId
            self.requiresFullRebuildReason = nil
        }

        public func makeCheckpoint(parserVersion: Int = ParserCheckpoint.currentParserVersion) -> ParserCheckpoint {
            ParserCheckpoint(
                lineOffset: lastOffset,
                lineCount: totalLinesConsumed,
                lastCumulativeInput: cumulativeBaseline.inputTokens,
                lastCumulativeCached: cumulativeBaseline.cachedInputTokens,
                lastCumulativeCacheWrite: cumulativeBaseline.cacheWriteInputTokens,
                lastCumulativeOutput: cumulativeBaseline.outputTokens,
                lastCumulativeReasoning: cumulativeBaseline.reasoningOutputTokens,
                currentModel: activeModel,
                currentServiceTier: activeServiceTier,
                currentReasoningEffort: activeReasoningEffort,
                currentTurnIndex: currentTurnIndex,
                currentCallIndex: currentCallIndex,
                hasSeenFreshTurn: hasEncounteredChildFreshTurn,
                isIncrementalRootEligible: isIncrementalRootEligible,
                childReplayGateKind: childReplayGateKind,
                childReplayGateTimestampMs: childReplayGateTimestampMs,
                hasSeenReplayedSessionMeta: hasSeenReplayedSessionMeta,
                stableSessionId: stableSessionId,
                parserVersion: parserVersion
            )
        }
    }

    /// 消费单个 Wire 事件，并产生对应的增量事件（如有）
    public func reduce(
        event: RolloutWireEvent,
        lineRecord: JSONLLineRecord,
        state: inout ReducerState
    ) -> CodexParsedUsageEvent? {
        state.lastOffset = lineRecord.startOffset + Int64(lineRecord.lineBytes)
        state.totalLinesConsumed += 1

        // 1. 更新上下文模型与状态机
        var eventQuality: AttributionQuality = state.activeModel == nil ? .unknownDefault : .sessionFallback
        if let explicitModel = event.model, !explicitModel.isEmpty {
            state.activeModel = explicitModel
            eventQuality = .directTurnContext
        }

        if let explicitTier = event.serviceTier, !explicitTier.isEmpty {
            state.activeServiceTier = explicitTier
        }

        if let explicitEffort = event.reasoningEffort, !explicitEffort.isEmpty {
            state.activeReasoningEffort = explicitEffort
        }

        if let turnIdx = event.turnIndex {
            if turnIdx != state.currentTurnIndex {
                state.currentTurnIndex = turnIdx
                state.currentCallIndex = 0
            }
        }

        if let callIdx = event.callIndex {
            state.currentCallIndex = callIdx
        } else {
            state.currentCallIndex += 1
        }

        updateSessionIdentity(event: event, state: &state)

        let isReplay = resolveReplayState(event: event, state: &state)

        // 2. Token 增量计算
        let resolvedModelRaw = state.activeModel ?? "unknown"
        let resolvedModelCanonical = ModelAliasResolver.resolve(rawModel: resolvedModelRaw)
        let timestamp: Int64
        let timestampQuality: TimestampQuality
        if event.timestampMs > 0 {
            timestamp = event.timestampMs
            timestampQuality = event.timestampQuality
        } else {
            timestamp = fallbackTimestampMs
            timestampQuality = fallbackTimestampQuality
        }
        let canEmitAnalyticsEvent = timestamp > 0 && timestampQuality.isUsableForAnalytics

        // 策略 A: 优先使用 last_token_usage (单步精确增量)
        if let last = event.lastTokenUsage {
            let hasPricableBuckets = last.inputTokens > 0
                || last.cachedInputTokens > 0
                || last.cacheWriteInputTokens > 0
                || last.outputTokens > 0
                || last.reasoningOutputTokens > 0
            guard hasPricableBuckets else {
                return nil
            }

            let total = last.totalTokens ?? (last.inputTokens + last.outputTokens)
            guard total > 0 || last.inputTokens > 0 || last.outputTokens > 0 else {
                return nil
            }

            let deltaBreakdown = TokenBreakdown(
                inputTokens: last.inputTokens,
                cachedInputTokens: last.cachedInputTokens,
                cacheWriteInputTokens: last.cacheWriteInputTokens,
                outputTokens: last.outputTokens,
                reasoningOutputTokens: last.reasoningOutputTokens,
                sourceTotalTokens: last.totalTokens
            )

            // 更新累计基线
            if let totalUsage = event.totalTokenUsage {
                state.cumulativeBaseline = TokenBreakdown(
                    inputTokens: totalUsage.inputTokens,
                    cachedInputTokens: totalUsage.cachedInputTokens,
                    cacheWriteInputTokens: totalUsage.cacheWriteInputTokens,
                    outputTokens: totalUsage.outputTokens,
                    reasoningOutputTokens: totalUsage.reasoningOutputTokens,
                    sourceTotalTokens: totalUsage.totalTokens
                )
            } else {
                state.cumulativeBaseline = state.cumulativeBaseline + deltaBreakdown
            }

            // An unresolved timestamp must not enter user-facing analytics, but
            // it still advances the cumulative baseline so a later valid event
            // does not absorb the skipped record and inflate its delta.
            guard canEmitAnalyticsEvent else { return nil }

            let eventId = makeEventId(lineRecord: lineRecord, timestampMs: timestamp)
            return CodexParsedUsageEvent(
                eventId: eventId,
                sessionId: sessionId,
                rootSessionId: rootSessionId,
                turnIndex: state.currentTurnIndex,
                callIndex: state.currentCallIndex,
                timestampMs: timestamp,
                timestampQuality: timestampQuality,
                timestampSource: event.timestampMs > 0 ? event.timestampSource : timestampFallbackSource(),
                timestampConflictCount: event.timestampConflictCount,
                modelRaw: resolvedModelRaw,
                modelCanonical: resolvedModelCanonical,
                serviceTier: state.activeServiceTier,
                reasoningEffort: state.activeReasoningEffort,
                tokens: deltaBreakdown,
                usageDerivation: .explicitLastUsage,
                attributionQuality: eventQuality,
                isChildReplay: isReplay,
                sourcePath: sourcePath,
                lineOffset: lineRecord.startOffset,
                lineBytes: lineRecord.lineBytes
            )
        }

        // 策略 B: 缺少 last_token_usage 时，利用 total_token_usage 累计快照进行差分
        if let total = event.totalTokenUsage {
            let curInput = total.inputTokens
            let curCached = total.cachedInputTokens
            let curCacheWrite = total.cacheWriteInputTokens
            let curOutput = total.outputTokens
            let curReasoning = total.reasoningOutputTokens

            let prevInput = state.cumulativeBaseline.inputTokens
            let prevCached = state.cumulativeBaseline.cachedInputTokens
            let prevCacheWrite = state.cumulativeBaseline.cacheWriteInputTokens
            let prevOutput = state.cumulativeBaseline.outputTokens
            let prevReasoning = state.cumulativeBaseline.reasoningOutputTokens

            let inputRestarted = curInput < prevInput
            let cachedRestarted = curCached < prevCached
            let cacheWriteRestarted = curCacheWrite < prevCacheWrite
            let outputRestarted = curOutput < prevOutput
            let reasoningRestarted = curReasoning < prevReasoning
            let anyCounterRestarted = inputRestarted
                || cachedRestarted
                || cacheWriteRestarted
                || outputRestarted
                || reasoningRestarted

            // Each counter may restart independently. Treat a decreasing bucket
            // as a new baseline for that bucket instead of either dropping it or
            // replaying every other cumulative bucket in full.
            let deltaInput = inputRestarted ? curInput : curInput - prevInput
            let deltaCached = cachedRestarted ? curCached : curCached - prevCached
            let deltaCacheWrite = cacheWriteRestarted ? curCacheWrite : curCacheWrite - prevCacheWrite
            let deltaOutput = outputRestarted ? curOutput : curOutput - prevOutput
            let deltaReasoning = reasoningRestarted ? curReasoning : curReasoning - prevReasoning
            let hasDelta = deltaInput > 0
                || deltaCached > 0
                || deltaCacheWrite > 0
                || deltaOutput > 0
                || deltaReasoning > 0

            if hasDelta {
                let deltaTokens = TokenBreakdown(
                    inputTokens: max(deltaInput, deltaCached + deltaCacheWrite),
                    cachedInputTokens: deltaCached,
                    cacheWriteInputTokens: deltaCacheWrite,
                    outputTokens: max(deltaOutput, deltaReasoning),
                    reasoningOutputTokens: deltaReasoning
                )
                state.cumulativeBaseline = TokenBreakdown(
                    inputTokens: curInput,
                    cachedInputTokens: curCached,
                    cacheWriteInputTokens: curCacheWrite,
                    outputTokens: curOutput,
                    reasoningOutputTokens: curReasoning,
                    sourceTotalTokens: total.totalTokens
                )

                guard canEmitAnalyticsEvent else { return nil }

                let eventId = makeEventId(lineRecord: lineRecord, timestampMs: timestamp)
                return CodexParsedUsageEvent(
                    eventId: eventId,
                    sessionId: sessionId,
                    rootSessionId: rootSessionId,
                    turnIndex: state.currentTurnIndex,
                    callIndex: state.currentCallIndex,
                    timestampMs: timestamp,
                    timestampQuality: timestampQuality,
                    timestampSource: event.timestampMs > 0 ? event.timestampSource : timestampFallbackSource(),
                    timestampConflictCount: event.timestampConflictCount,
                    modelRaw: resolvedModelRaw,
                    modelCanonical: resolvedModelCanonical,
                    serviceTier: state.activeServiceTier,
                    reasoningEffort: state.activeReasoningEffort,
                    tokens: deltaTokens,
                    usageDerivation: anyCounterRestarted ? .totalUsageRestart : .totalUsageDelta,
                    attributionQuality: eventQuality,
                    isChildReplay: isReplay,
                    sourcePath: sourcePath,
                    lineOffset: lineRecord.startOffset,
                    lineBytes: lineRecord.lineBytes
                )
            }

            // Counters did not change; keep the latest baseline but do not emit
            // a zero-token event.
            state.cumulativeBaseline = TokenBreakdown(
                inputTokens: curInput,
                cachedInputTokens: curCached,
                cacheWriteInputTokens: curCacheWrite,
                outputTokens: curOutput,
                reasoningOutputTokens: curReasoning,
                sourceTotalTokens: total.totalTokens
            )
            return nil
        }

        return nil
    }

    private func updateSessionIdentity(event: RolloutWireEvent, state: inout ReducerState) {
        guard event.eventType == "session_meta" else { return }
        if state.stableSessionId == nil {
            state.stableSessionId = event.sessionId ?? sessionId
            state.isIncrementalRootEligible = !isChildSession
                && !event.isChildSessionMeta
                && event.parentSessionId == nil
        } else if let eventSessionId = event.sessionId,
                  let stableSessionId = state.stableSessionId,
                  eventSessionId != stableSessionId {
            state.isIncrementalRootEligible = false
            if isChildSession || state.childReplayGateKind != nil {
                state.hasSeenReplayedSessionMeta = true
            } else {
                state.requiresFullRebuildReason = "tail session_meta changed session id"
            }
        }

        if event.isChildSessionMeta || event.parentSessionId != nil {
            state.isIncrementalRootEligible = false
            if !isChildSession {
                state.requiresFullRebuildReason = "tail session_meta introduced child/fork lineage"
            }
        }

        guard isChildSession, state.childReplayGateKind == nil, !state.hasEncounteredChildFreshTurn else {
            return
        }
        if event.isChildSessionMeta || event.sessionId == sessionId || event.parentSessionId != nil {
            state.childReplayGateKind = "childCreatedAt"
            state.childReplayGateTimestampMs = event.replayBoundaryTimestampMs ?? event.timestampMs
        }
    }

    private func resolveReplayState(event: RolloutWireEvent, state: inout ReducerState) -> Bool {
        guard isChildSession else {
            return event.isReplayMarker
        }
        if event.isReplayMarker {
            return true
        }

        if state.childReplayGateKind == nil && !state.hasEncounteredChildFreshTurn {
            state.childReplayGateKind = "firstSelfTimedTask"
        }

        if shouldClearChildReplayGate(event: event, state: state) {
            state.childReplayGateKind = nil
            state.childReplayGateTimestampMs = nil
            state.hasEncounteredChildFreshTurn = true
            return false
        }

        return !state.hasEncounteredChildFreshTurn
    }

    private func shouldClearChildReplayGate(event: RolloutWireEvent, state: ReducerState) -> Bool {
        guard let gateKind = state.childReplayGateKind else {
            return state.hasEncounteredChildFreshTurn
        }
        switch gateKind {
        case "childCreatedAt":
            guard let childCreatedAt = state.childReplayGateTimestampMs, childCreatedAt > 0 else {
                return event.eventType == "task_started" && !state.hasSeenReplayedSessionMeta
            }
            if event.eventType == "task_started" {
                if let taskStarted = event.taskStartedAtMs {
                    return taskStarted >= childCreatedAt
                }
                if let turnStarted = Self.uuidV7TimestampMs(event.turnId) {
                    return turnStarted >= childCreatedAt
                }
                guard event.timestampMs > 0 else { return false }
                return state.hasSeenReplayedSessionMeta
                    ? event.timestampMs > childCreatedAt
                    : event.timestampMs >= childCreatedAt
            }
            guard event.lastTokenUsage != nil || event.totalTokenUsage != nil else { return false }
            if let intrinsicTimestamp = event.replayBoundaryTimestampMs {
                return intrinsicTimestamp > childCreatedAt
            }
            guard event.timestampMs > 0 else { return false }
            return event.timestampMs > childCreatedAt

        case "firstSelfTimedTask":
            if event.eventType == "task_started" {
                return event.taskStartedAtMs != nil || Self.uuidV7TimestampMs(event.turnId) != nil || !state.hasSeenReplayedSessionMeta
            }
            guard event.lastTokenUsage != nil || event.totalTokenUsage != nil else { return false }
            guard !state.hasSeenReplayedSessionMeta else { return false }
            return event.timestampMs > 0 || event.replayBoundaryTimestampMs != nil

        default:
            return false
        }
    }

    private func timestampFallbackSource() -> TimestampSource {
        switch fallbackTimestampQuality {
        case .eventTimestamp:
            return .topLevelTimestamp
        case .fileNameTimestamp:
            return .fileName
        case .sessionTimestamp:
            return .sessionMetadata
        case .fileModificationTime:
            return .fileModification
        case .unresolved:
            return .unresolved
        }
    }

    private func makeEventId(lineRecord: JSONLLineRecord, timestampMs: Int64) -> String {
        "evt_\(sessionId)_\(sourceEventKey)_\(lineRecord.startOffset)_\(lineRecord.lineBytes)_\(timestampMs)"
    }

    private static func uuidV7TimestampMs(_ value: String?) -> Int64? {
        guard let value else { return nil }
        let parts = value.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 5,
              parts[0].count == 8,
              parts[1].count == 4,
              parts[2].first == "7",
              let milliseconds = UInt64(parts[0] + parts[1], radix: 16),
              milliseconds <= UInt64(Int64.max) else {
            return nil
        }
        return Int64(milliseconds)
    }

    private static func stableSourceKey(_ value: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return String(format: "%016llx", hash)
    }
}
