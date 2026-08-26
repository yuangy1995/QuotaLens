// QuotaLens 解析器检查点与状态快照

import Foundation

public struct ParserCheckpoint: Codable, Sendable {
    /// 解析、归因或 Replay 边界语义变化时递增；旧版本检查点必须重建后再继续。
    public static let currentParserVersion = 7

    public let lineOffset: Int64
    public let lineCount: Int
    public let lastCumulativeInput: Int64
    public let lastCumulativeCached: Int64
    public let lastCumulativeCacheWrite: Int64
    public let lastCumulativeOutput: Int64
    public let lastCumulativeReasoning: Int64
    public let currentModel: String?
    public let currentServiceTier: String?
    public let currentReasoningEffort: String?
    public let currentTurnIndex: Int
    public let currentCallIndex: Int
    public let hasSeenFreshTurn: Bool
    public let isIncrementalRootEligible: Bool
    public let childReplayGateKind: String?
    public let childReplayGateTimestampMs: Int64?
    public let hasSeenReplayedSessionMeta: Bool
    public let stableSessionId: String?
    public let parserVersion: Int

    public init(
        lineOffset: Int64 = 0,
        lineCount: Int = 0,
        lastCumulativeInput: Int64 = 0,
        lastCumulativeCached: Int64 = 0,
        lastCumulativeCacheWrite: Int64 = 0,
        lastCumulativeOutput: Int64 = 0,
        lastCumulativeReasoning: Int64 = 0,
        currentModel: String? = nil,
        currentServiceTier: String? = nil,
        currentReasoningEffort: String? = nil,
        currentTurnIndex: Int = 0,
        currentCallIndex: Int = 0,
        hasSeenFreshTurn: Bool = false,
        isIncrementalRootEligible: Bool = false,
        childReplayGateKind: String? = nil,
        childReplayGateTimestampMs: Int64? = nil,
        hasSeenReplayedSessionMeta: Bool = false,
        stableSessionId: String? = nil,
        parserVersion: Int = ParserCheckpoint.currentParserVersion
    ) {
        self.lineOffset = lineOffset
        self.lineCount = lineCount
        self.lastCumulativeInput = lastCumulativeInput
        self.lastCumulativeCached = lastCumulativeCached
        self.lastCumulativeCacheWrite = lastCumulativeCacheWrite
        self.lastCumulativeOutput = lastCumulativeOutput
        self.lastCumulativeReasoning = lastCumulativeReasoning
        self.currentModel = currentModel
        self.currentServiceTier = currentServiceTier
        self.currentReasoningEffort = currentReasoningEffort
        self.currentTurnIndex = currentTurnIndex
        self.currentCallIndex = currentCallIndex
        self.hasSeenFreshTurn = hasSeenFreshTurn
        self.isIncrementalRootEligible = isIncrementalRootEligible
        self.childReplayGateKind = childReplayGateKind
        self.childReplayGateTimestampMs = childReplayGateTimestampMs
        self.hasSeenReplayedSessionMeta = hasSeenReplayedSessionMeta
        self.stableSessionId = stableSessionId
        self.parserVersion = parserVersion
    }

    private enum CodingKeys: String, CodingKey {
        case lineOffset
        case lineCount
        case lastCumulativeInput
        case lastCumulativeCached
        case lastCumulativeCacheWrite
        case lastCumulativeOutput
        case lastCumulativeReasoning
        case currentModel
        case currentServiceTier
        case currentReasoningEffort
        case currentTurnIndex
        case currentCallIndex
        case hasSeenFreshTurn
        case isIncrementalRootEligible
        case childReplayGateKind
        case childReplayGateTimestampMs
        case hasSeenReplayedSessionMeta
        case stableSessionId
        case parserVersion
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.lineOffset = try container.decodeIfPresent(Int64.self, forKey: .lineOffset) ?? 0
        self.lineCount = try container.decodeIfPresent(Int.self, forKey: .lineCount) ?? 0
        self.lastCumulativeInput = try container.decodeIfPresent(Int64.self, forKey: .lastCumulativeInput) ?? 0
        self.lastCumulativeCached = try container.decodeIfPresent(Int64.self, forKey: .lastCumulativeCached) ?? 0
        self.lastCumulativeCacheWrite = try container.decodeIfPresent(Int64.self, forKey: .lastCumulativeCacheWrite) ?? 0
        self.lastCumulativeOutput = try container.decodeIfPresent(Int64.self, forKey: .lastCumulativeOutput) ?? 0
        self.lastCumulativeReasoning = try container.decodeIfPresent(Int64.self, forKey: .lastCumulativeReasoning) ?? 0
        self.currentModel = try container.decodeIfPresent(String.self, forKey: .currentModel)
        self.currentServiceTier = try container.decodeIfPresent(String.self, forKey: .currentServiceTier)
        self.currentReasoningEffort = try container.decodeIfPresent(String.self, forKey: .currentReasoningEffort)
        self.currentTurnIndex = try container.decodeIfPresent(Int.self, forKey: .currentTurnIndex) ?? 0
        self.currentCallIndex = try container.decodeIfPresent(Int.self, forKey: .currentCallIndex) ?? 0
        self.hasSeenFreshTurn = try container.decodeIfPresent(Bool.self, forKey: .hasSeenFreshTurn) ?? false
        self.isIncrementalRootEligible = try container.decodeIfPresent(Bool.self, forKey: .isIncrementalRootEligible) ?? false
        self.childReplayGateKind = try container.decodeIfPresent(String.self, forKey: .childReplayGateKind)
        self.childReplayGateTimestampMs = try container.decodeIfPresent(Int64.self, forKey: .childReplayGateTimestampMs)
        self.hasSeenReplayedSessionMeta = try container.decodeIfPresent(Bool.self, forKey: .hasSeenReplayedSessionMeta) ?? false
        self.stableSessionId = try container.decodeIfPresent(String.self, forKey: .stableSessionId)
        self.parserVersion = try container.decodeIfPresent(Int.self, forKey: .parserVersion) ?? 1
    }

    public var canResumeIncrementally: Bool {
        parserVersion == Self.currentParserVersion
            && isIncrementalRootEligible
            && childReplayGateKind == nil
            && stableSessionId?.isEmpty == false
    }

    public var lastCumulativeTokens: TokenBreakdown {
        TokenBreakdown(
            inputTokens: lastCumulativeInput,
            cachedInputTokens: lastCumulativeCached,
            cacheWriteInputTokens: lastCumulativeCacheWrite,
            outputTokens: lastCumulativeOutput,
            reasoningOutputTokens: lastCumulativeReasoning
        )
    }

    public static let initial = ParserCheckpoint()

    public func toJsonString() -> String? {
        guard let data = try? JSONEncoder().encode(self) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public static func fromJsonString(_ json: String) -> ParserCheckpoint? {
        guard let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(ParserCheckpoint.self, from: data)
    }
}
