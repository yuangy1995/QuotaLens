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
    public let modelRaw: String
    public let modelCanonical: String
    public let serviceTier: String?
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
        modelRaw: String,
        modelCanonical: String,
        serviceTier: String?,
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
        self.modelRaw = modelRaw
        self.modelCanonical = modelCanonical
        self.serviceTier = serviceTier
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
        public var currentTurnIndex: Int
        public var currentCallIndex: Int
        public var cumulativeBaseline: TokenBreakdown
        public var totalLinesConsumed: Int
        public var lastOffset: Int64
        public var hasEncounteredChildFreshTurn: Bool

        public init(
            checkpoint: ParserCheckpoint = .initial
        ) {
            self.activeModel = checkpoint.currentModel
            self.activeServiceTier = checkpoint.currentServiceTier
            self.currentTurnIndex = checkpoint.currentTurnIndex
            self.currentCallIndex = checkpoint.currentCallIndex
            self.cumulativeBaseline = checkpoint.lastCumulativeTokens
            self.totalLinesConsumed = checkpoint.lineCount
            self.lastOffset = checkpoint.lineOffset
            self.hasEncounteredChildFreshTurn = checkpoint.hasSeenFreshTurn
        }

        public func makeCheckpoint(parserVersion: Int = ParserCheckpoint.currentParserVersion) -> ParserCheckpoint {
            ParserCheckpoint(
                lineOffset: lastOffset,
                lineCount: totalLinesConsumed,
                lastCumulativeInput: cumulativeBaseline.inputTokens,
                lastCumulativeCached: cumulativeBaseline.cachedInputTokens,
                lastCumulativeOutput: cumulativeBaseline.outputTokens,
                lastCumulativeReasoning: cumulativeBaseline.reasoningOutputTokens,
                currentModel: activeModel,
                currentServiceTier: activeServiceTier,
                currentTurnIndex: currentTurnIndex,
                currentCallIndex: currentCallIndex,
                hasSeenFreshTurn: hasEncounteredChildFreshTurn,
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

        // 子会话 Replay 判定：如果是子会话且包含重放的历史前缀
        var isReplay = false
        if isChildSession {
            let isFreshTurnMarker = event.eventType == "task_started" || event.eventType == "user_message"
            if isFreshTurnMarker {
                state.hasEncounteredChildFreshTurn = true
            } else if event.isReplayMarker {
                isReplay = true
            } else if !state.hasEncounteredChildFreshTurn {
                isReplay = true
            }
        }

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
                outputTokens: last.outputTokens,
                reasoningOutputTokens: last.reasoningOutputTokens,
                sourceTotalTokens: last.totalTokens
            )

            // 更新累计基线
            if let totalUsage = event.totalTokenUsage {
                state.cumulativeBaseline = TokenBreakdown(
                    inputTokens: totalUsage.inputTokens,
                    cachedInputTokens: totalUsage.cachedInputTokens,
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
                modelRaw: resolvedModelRaw,
                modelCanonical: resolvedModelCanonical,
                serviceTier: state.activeServiceTier,
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
            let curOutput = total.outputTokens
            let curReasoning = total.reasoningOutputTokens

            let prevInput = state.cumulativeBaseline.inputTokens
            let prevCached = state.cumulativeBaseline.cachedInputTokens
            let prevOutput = state.cumulativeBaseline.outputTokens
            let prevReasoning = state.cumulativeBaseline.reasoningOutputTokens

            let inputRestarted = curInput < prevInput
            let cachedRestarted = curCached < prevCached
            let outputRestarted = curOutput < prevOutput
            let reasoningRestarted = curReasoning < prevReasoning
            let anyCounterRestarted = inputRestarted || cachedRestarted || outputRestarted || reasoningRestarted

            // Each counter may restart independently. Treat a decreasing bucket
            // as a new baseline for that bucket instead of either dropping it or
            // replaying every other cumulative bucket in full.
            let deltaInput = inputRestarted ? curInput : curInput - prevInput
            let deltaCached = cachedRestarted ? curCached : curCached - prevCached
            let deltaOutput = outputRestarted ? curOutput : curOutput - prevOutput
            let deltaReasoning = reasoningRestarted ? curReasoning : curReasoning - prevReasoning
            let hasDelta = deltaInput > 0 || deltaCached > 0 || deltaOutput > 0 || deltaReasoning > 0

            if hasDelta {
                let deltaTokens = TokenBreakdown(
                    inputTokens: max(deltaInput, deltaCached),
                    cachedInputTokens: deltaCached,
                    outputTokens: max(deltaOutput, deltaReasoning),
                    reasoningOutputTokens: deltaReasoning
                )
                state.cumulativeBaseline = TokenBreakdown(
                    inputTokens: curInput,
                    cachedInputTokens: curCached,
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
                    modelRaw: resolvedModelRaw,
                    modelCanonical: resolvedModelCanonical,
                    serviceTier: state.activeServiceTier,
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
                outputTokens: curOutput,
                reasoningOutputTokens: curReasoning,
                sourceTotalTokens: total.totalTokens
            )
            return nil
        }

        return nil
    }

    private func makeEventId(lineRecord: JSONLLineRecord, timestampMs: Int64) -> String {
        "evt_\(sessionId)_\(sourceEventKey)_\(lineRecord.startOffset)_\(lineRecord.lineBytes)_\(timestampMs)"
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
