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

    public init(
        sessionId: String,
        rootSessionId: String,
        isChildSession: Bool,
        sourcePath: String
    ) {
        self.sessionId = sessionId
        self.rootSessionId = rootSessionId
        self.isChildSession = isChildSession
        self.sourcePath = sourcePath
        self.sourceEventKey = Self.stableSourceKey(sourcePath)
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
            self.currentCallIndex = 0
            self.cumulativeBaseline = checkpoint.lastCumulativeTokens
            self.totalLinesConsumed = checkpoint.lineCount
            self.lastOffset = checkpoint.lineOffset
            self.hasEncounteredChildFreshTurn = false
        }

        public func makeCheckpoint(parserVersion: Int = 2) -> ParserCheckpoint {
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
        var eventQuality: AttributionQuality = .sessionFallback
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
            if event.isReplayMarker {
                isReplay = true
            } else if !state.hasEncounteredChildFreshTurn {
                // 如果是 task_started / user prompt 产生的新轮次，解除 replay 状态
                if event.eventType == "task_started" || event.eventType == "user_message" {
                    state.hasEncounteredChildFreshTurn = true
                }
            }
        }

        // 2. Token 增量计算
        let resolvedModelRaw = state.activeModel ?? "gpt-5"
        let resolvedModelCanonical = ModelAliasResolver.resolve(rawModel: resolvedModelRaw)
        let timestamp = event.timestampMs > 0 ? event.timestampMs : Int64(Date().timeIntervalSince1970 * 1000)

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

            let eventId = makeEventId(lineRecord: lineRecord, timestampMs: timestamp)
            return CodexParsedUsageEvent(
                eventId: eventId,
                sessionId: sessionId,
                rootSessionId: rootSessionId,
                turnIndex: state.currentTurnIndex,
                callIndex: state.currentCallIndex,
                timestampMs: timestamp,
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

            let deltaInput = curInput - prevInput
            let deltaCached = curCached - prevCached
            let deltaOutput = curOutput - prevOutput
            let deltaReasoning = curReasoning - prevReasoning

            // 情况 1: 正常增量增长
            if deltaInput >= 0 && deltaOutput >= 0 && (deltaInput > 0 || deltaOutput > 0) {
                let deltaTokens = TokenBreakdown(
                    inputTokens: deltaInput,
                    cachedInputTokens: max(0, deltaCached),
                    outputTokens: deltaOutput,
                    reasoningOutputTokens: max(0, deltaReasoning)
                )
                state.cumulativeBaseline = TokenBreakdown(
                    inputTokens: curInput,
                    cachedInputTokens: curCached,
                    outputTokens: curOutput,
                    reasoningOutputTokens: curReasoning,
                    sourceTotalTokens: total.totalTokens
                )

                let eventId = makeEventId(lineRecord: lineRecord, timestampMs: timestamp)
                return CodexParsedUsageEvent(
                    eventId: eventId,
                    sessionId: sessionId,
                    rootSessionId: rootSessionId,
                    turnIndex: state.currentTurnIndex,
                    callIndex: state.currentCallIndex,
                    timestampMs: timestamp,
                    modelRaw: resolvedModelRaw,
                    modelCanonical: resolvedModelCanonical,
                    serviceTier: state.activeServiceTier,
                    tokens: deltaTokens,
                    usageDerivation: .totalUsageDelta,
                    attributionQuality: eventQuality,
                    isChildReplay: isReplay,
                    sourcePath: sourcePath,
                    lineOffset: lineRecord.startOffset,
                    lineBytes: lineRecord.lineBytes
                )
            }

            // 情况 2: 计数器重置 (Counter Restart)
            if deltaInput < 0 || deltaOutput < 0 {
                let restartTokens = TokenBreakdown(
                    inputTokens: curInput,
                    cachedInputTokens: curCached,
                    outputTokens: curOutput,
                    reasoningOutputTokens: curReasoning,
                    sourceTotalTokens: total.totalTokens
                )
                state.cumulativeBaseline = restartTokens

                let eventId = makeEventId(lineRecord: lineRecord, timestampMs: timestamp)
                return CodexParsedUsageEvent(
                    eventId: eventId,
                    sessionId: sessionId,
                    rootSessionId: rootSessionId,
                    turnIndex: state.currentTurnIndex,
                    callIndex: state.currentCallIndex,
                    timestampMs: timestamp,
                    modelRaw: resolvedModelRaw,
                    modelCanonical: resolvedModelCanonical,
                    serviceTier: state.activeServiceTier,
                    tokens: restartTokens,
                    usageDerivation: .totalUsageRestart,
                    attributionQuality: eventQuality,
                    isChildReplay: isReplay,
                    sourcePath: sourcePath,
                    lineOffset: lineRecord.startOffset,
                    lineBytes: lineRecord.lineBytes
                )
            }

            // 情况 3: 计数器未发生变化（重复快照），不产生空事件
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
