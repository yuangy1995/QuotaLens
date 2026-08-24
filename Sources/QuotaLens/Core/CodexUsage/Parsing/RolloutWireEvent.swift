// QuotaLens Codex Wire 原始事件模型与行解析器

import Foundation

public struct RawTokenUsagePayload: Sendable {
    public let inputTokens: Int64
    public let cachedInputTokens: Int64
    public let outputTokens: Int64
    public let reasoningOutputTokens: Int64
    public let totalTokens: Int64?

    public init(
        inputTokens: Int64 = 0,
        cachedInputTokens: Int64 = 0,
        outputTokens: Int64 = 0,
        reasoningOutputTokens: Int64 = 0,
        totalTokens: Int64? = nil
    ) {
        self.inputTokens = max(0, inputTokens)
        self.cachedInputTokens = min(max(0, cachedInputTokens), max(0, inputTokens))
        self.outputTokens = max(0, outputTokens)
        self.reasoningOutputTokens = min(max(0, reasoningOutputTokens), max(0, outputTokens))
        self.totalTokens = totalTokens
    }
}

public struct RolloutWireEvent: Sendable {
    public let eventType: String
    public let timestampMs: Int64
    public let sessionId: String?
    public let parentSessionId: String?
    public let model: String?
    public let serviceTier: String?
    public let turnIndex: Int?
    public let callIndex: Int?
    public let lastTokenUsage: RawTokenUsagePayload?
    public let totalTokenUsage: RawTokenUsagePayload?
    public let isReplayMarker: Bool

    public init(
        eventType: String,
        timestampMs: Int64,
        sessionId: String? = nil,
        parentSessionId: String? = nil,
        model: String? = nil,
        serviceTier: String? = nil,
        turnIndex: Int? = nil,
        callIndex: Int? = nil,
        lastTokenUsage: RawTokenUsagePayload? = nil,
        totalTokenUsage: RawTokenUsagePayload? = nil,
        isReplayMarker: Bool = false
    ) {
        self.eventType = eventType
        self.timestampMs = timestampMs
        self.sessionId = sessionId
        self.parentSessionId = parentSessionId
        self.model = model
        self.serviceTier = serviceTier
        self.turnIndex = turnIndex
        self.callIndex = callIndex
        self.lastTokenUsage = lastTokenUsage
        self.totalTokenUsage = totalTokenUsage
        self.isReplayMarker = isReplayMarker
    }
}

public enum RolloutLineDecoder {
    public static func mayContainUsageRelevantEvent(_ lineString: String) -> Bool {
        lineString.contains(#""token_count""#)
            || lineString.contains(#""turn_context""#)
            || lineString.contains(#""thread_settings_applied""#)
            || lineString.contains(#""task_started""#)
    }

    public static func mayContainUsageRelevantEvent(_ lineData: Data.SubSequence) -> Bool {
        // Relevant rollout discriminators live at the top of the JSON record.
        // Limit the scan to the prefix so multi-MB response/tool records do not
        // get searched repeatedly before being skipped.
        let prefixEnd = lineData.index(lineData.startIndex, offsetBy: min(lineData.count, 2_048))
        let prefix = lineData[lineData.startIndex..<prefixEnd]
        for needle in relevantEventNeedles where contains(needle, in: prefix) {
            return true
        }
        return false
    }

    /// 快速将一行 JSONL 解析为 RolloutWireEvent
    public static func decodeLine(_ lineString: String) -> RolloutWireEvent? {
        guard mayContainUsageRelevantEvent(lineString) else {
            return nil
        }

        guard let data = lineString.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        let outerType = (json["type"] as? String ?? json["event"] as? String ?? "unknown").lowercased()
        let timestampMs = extractTimestampMs(from: json)

        let payload = (json["payload"] as? [String: Any]) ?? json
        let info = payload["info"] as? [String: Any]
        let metadata = payload["metadata"] as? [String: Any]
        let infoMetadata = info?["metadata"] as? [String: Any]
        let threadSettings = payload["thread_settings"] as? [String: Any]

        let payloadType = payload["type"] as? String
        let type = outerType == "event_msg"
            ? (payloadType?.lowercased() ?? outerType)
            : outerType

        let model = firstString([
            payload["model"],
            info?["model"],
            info?["model_name"],
            metadata?["model"],
            infoMetadata?["model"],
            json["model"]
        ])
        let serviceTier = firstString([
            threadSettings?["service_tier"],
            payload["service_tier"],
            json["service_tier"]
        ])
        let turnIndex = payload["turn_index"] as? Int ?? json["turn_index"] as? Int
        let callIndex = payload["call_index"] as? Int ?? json["call_index"] as? Int
        let sessionId = firstString([payload["session_id"], payload["id"], json["session_id"], json["id"]])
        let parentSessionId = firstString([
            payload["parent_session_id"],
            payload["parentSessionId"],
            payload["parent_id"],
            payload["forked_from_id"],
            json["parent_session_id"],
            json["parentSessionId"],
            json["parent_id"],
            json["forked_from_id"]
        ])

        var lastUsage: RawTokenUsagePayload?
        if let lastDict = info?["last_token_usage"] as? [String: Any]
            ?? payload["last_token_usage"] as? [String: Any]
            ?? json["last_token_usage"] as? [String: Any] {
            lastUsage = parseTokenUsageDict(lastDict)
        }

        var totalUsage: RawTokenUsagePayload?
        if let totalDict = info?["total_token_usage"] as? [String: Any]
            ?? payload["total_token_usage"] as? [String: Any]
            ?? json["total_token_usage"] as? [String: Any] {
            totalUsage = parseTokenUsageDict(totalDict)
        }

        // 如果顶层就是 token_count 且直接包含 input_tokens / output_tokens
        if lastUsage == nil && totalUsage == nil {
            let hasBucketField = payload["input_tokens"] != nil
                || payload["cached_input_tokens"] != nil
                || payload["output_tokens"] != nil
                || payload["reasoning_output_tokens"] != nil
                || json["input_tokens"] != nil
                || json["cached_input_tokens"] != nil
                || json["output_tokens"] != nil
                || json["reasoning_output_tokens"] != nil
            if hasBucketField {
                lastUsage = parseTokenUsageDict(payload.merging(json) { current, _ in current })
            }
        }

        return RolloutWireEvent(
            eventType: type,
            timestampMs: timestampMs,
            sessionId: sessionId,
            parentSessionId: parentSessionId,
            model: model,
            serviceTier: serviceTier,
            turnIndex: turnIndex,
            callIndex: callIndex,
            lastTokenUsage: lastUsage,
            totalTokenUsage: totalUsage
        )
    }

    private static func extractTimestampMs(from json: [String: Any]) -> Int64 {
        if let ts = json["timestamp"] as? Int64 {
            // 如果是毫秒 (> 10^11) 直接使用，否则作为秒转换
            return ts > 100_000_000_000 ? ts : ts * 1000
        }
        if let tsDouble = json["timestamp"] as? Double {
            return Int64(tsDouble > 100_000_000_000 ? tsDouble : tsDouble * 1000)
        }
        if let tsStr = json["timestamp"] as? String {
            if let intVal = Int64(tsStr) {
                return intVal > 100_000_000_000 ? intVal : intVal * 1000
            }
            if let date = dateFromISO8601(tsStr) {
                return Int64(date.timeIntervalSince1970 * 1000)
            }
        }
        if let createdAt = json["created_at"] as? Int64 {
            return createdAt > 100_000_000_000 ? createdAt : createdAt * 1000
        }
        return Int64(Date().timeIntervalSince1970 * 1000)
    }

    private static func parseTokenUsageDict(_ dict: [String: Any]) -> RawTokenUsagePayload {
        let input = int64Value(from: dict["input_tokens"])
        let cached = int64Value(from: dict["cached_input_tokens"] ?? dict["cache_read_input_tokens"])
        let output = int64Value(from: dict["output_tokens"])
        let reasoning = int64Value(from: dict["reasoning_output_tokens"] ?? dict["reasoning_tokens"])
        let total = dict["total_tokens"] != nil ? int64Value(from: dict["total_tokens"]) : nil

        return RawTokenUsagePayload(
            inputTokens: input,
            cachedInputTokens: cached,
            outputTokens: output,
            reasoningOutputTokens: reasoning,
            totalTokens: total
        )
    }

    private static func int64Value(from anyVal: Any?) -> Int64 {
        guard let anyVal else { return 0 }
        if let i64 = anyVal as? Int64 { return i64 }
        if let intVal = anyVal as? Int { return Int64(intVal) }
        if let dbl = anyVal as? Double { return Int64(dbl) }
        if let str = anyVal as? String, let parsed = Int64(str) { return parsed }
        return 0
    }

    private static func firstString(_ values: [Any?]) -> String? {
        for value in values {
            guard let string = value as? String else { continue }
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return nil
    }

    private static let relevantEventNeedles: [[UInt8]] = [
        Array(#""type":"token_count""#.utf8),
        Array(#""type":"turn_context""#.utf8),
        Array(#""type":"thread_settings_applied""#.utf8),
        Array(#""type":"task_started""#.utf8),
    ]

    private static func contains(_ needle: [UInt8], in haystack: Data.SubSequence) -> Bool {
        guard !needle.isEmpty, haystack.count >= needle.count else { return false }
        var matched = 0
        for byte in haystack {
            if byte == needle[matched] {
                matched += 1
                if matched == needle.count { return true }
            } else {
                matched = byte == needle[0] ? 1 : 0
            }
        }
        return false
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
}
