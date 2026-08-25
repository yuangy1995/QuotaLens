// QuotaLens 解析器检查点与状态快照

import Foundation

public struct ParserCheckpoint: Codable, Sendable {
    /// Bump whenever parsing or attribution semantics change. Import checkpoints
    /// from older versions are deliberately rebuilt instead of being resumed.
    public static let currentParserVersion = 4

    public let lineOffset: Int64
    public let lineCount: Int
    public let lastCumulativeInput: Int64
    public let lastCumulativeCached: Int64
    public let lastCumulativeOutput: Int64
    public let lastCumulativeReasoning: Int64
    public let currentModel: String?
    public let currentServiceTier: String?
    public let currentTurnIndex: Int
    public let currentCallIndex: Int
    public let hasSeenFreshTurn: Bool
    public let parserVersion: Int

    public init(
        lineOffset: Int64 = 0,
        lineCount: Int = 0,
        lastCumulativeInput: Int64 = 0,
        lastCumulativeCached: Int64 = 0,
        lastCumulativeOutput: Int64 = 0,
        lastCumulativeReasoning: Int64 = 0,
        currentModel: String? = nil,
        currentServiceTier: String? = nil,
        currentTurnIndex: Int = 0,
        currentCallIndex: Int = 0,
        hasSeenFreshTurn: Bool = false,
        parserVersion: Int = ParserCheckpoint.currentParserVersion
    ) {
        self.lineOffset = lineOffset
        self.lineCount = lineCount
        self.lastCumulativeInput = lastCumulativeInput
        self.lastCumulativeCached = lastCumulativeCached
        self.lastCumulativeOutput = lastCumulativeOutput
        self.lastCumulativeReasoning = lastCumulativeReasoning
        self.currentModel = currentModel
        self.currentServiceTier = currentServiceTier
        self.currentTurnIndex = currentTurnIndex
        self.currentCallIndex = currentCallIndex
        self.hasSeenFreshTurn = hasSeenFreshTurn
        self.parserVersion = parserVersion
    }

    private enum CodingKeys: String, CodingKey {
        case lineOffset
        case lineCount
        case lastCumulativeInput
        case lastCumulativeCached
        case lastCumulativeOutput
        case lastCumulativeReasoning
        case currentModel
        case currentServiceTier
        case currentTurnIndex
        case currentCallIndex
        case hasSeenFreshTurn
        case parserVersion
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.lineOffset = try container.decodeIfPresent(Int64.self, forKey: .lineOffset) ?? 0
        self.lineCount = try container.decodeIfPresent(Int.self, forKey: .lineCount) ?? 0
        self.lastCumulativeInput = try container.decodeIfPresent(Int64.self, forKey: .lastCumulativeInput) ?? 0
        self.lastCumulativeCached = try container.decodeIfPresent(Int64.self, forKey: .lastCumulativeCached) ?? 0
        self.lastCumulativeOutput = try container.decodeIfPresent(Int64.self, forKey: .lastCumulativeOutput) ?? 0
        self.lastCumulativeReasoning = try container.decodeIfPresent(Int64.self, forKey: .lastCumulativeReasoning) ?? 0
        self.currentModel = try container.decodeIfPresent(String.self, forKey: .currentModel)
        self.currentServiceTier = try container.decodeIfPresent(String.self, forKey: .currentServiceTier)
        self.currentTurnIndex = try container.decodeIfPresent(Int.self, forKey: .currentTurnIndex) ?? 0
        self.currentCallIndex = try container.decodeIfPresent(Int.self, forKey: .currentCallIndex) ?? 0
        self.hasSeenFreshTurn = try container.decodeIfPresent(Bool.self, forKey: .hasSeenFreshTurn) ?? false
        self.parserVersion = try container.decodeIfPresent(Int.self, forKey: .parserVersion) ?? 1
    }

    public var lastCumulativeTokens: TokenBreakdown {
        TokenBreakdown(
            inputTokens: lastCumulativeInput,
            cachedInputTokens: lastCumulativeCached,
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
