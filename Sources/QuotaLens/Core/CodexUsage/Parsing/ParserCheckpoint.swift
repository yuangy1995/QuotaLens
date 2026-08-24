// QuotaLens 解析器检查点与状态快照

import Foundation

public struct ParserCheckpoint: Codable, Sendable {
    public let lineOffset: Int64
    public let lineCount: Int
    public let lastCumulativeInput: Int64
    public let lastCumulativeCached: Int64
    public let lastCumulativeOutput: Int64
    public let lastCumulativeReasoning: Int64
    public let currentModel: String?
    public let currentServiceTier: String?
    public let currentTurnIndex: Int
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
        parserVersion: Int = 2
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
        self.parserVersion = parserVersion
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
