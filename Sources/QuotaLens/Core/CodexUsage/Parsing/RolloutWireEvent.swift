// QuotaLens Codex Wire 原始事件模型与行解析器

import Foundation

public struct RawTokenUsagePayload: Sendable {
    public let inputTokens: Int64
    public let cachedInputTokens: Int64
    public let cacheWriteInputTokens: Int64
    public let outputTokens: Int64
    public let reasoningOutputTokens: Int64
    public let totalTokens: Int64?

    public init(
        inputTokens: Int64 = 0,
        cachedInputTokens: Int64 = 0,
        cacheWriteInputTokens: Int64 = 0,
        outputTokens: Int64 = 0,
        reasoningOutputTokens: Int64 = 0,
        totalTokens: Int64? = nil
    ) {
        let normalizedCached = max(0, cachedInputTokens)
        let normalizedCacheWrite = max(0, cacheWriteInputTokens)
        let normalizedReasoning = max(0, reasoningOutputTokens)
        self.inputTokens = max(max(0, inputTokens), normalizedCached + normalizedCacheWrite)
        self.cachedInputTokens = normalizedCached
        self.cacheWriteInputTokens = normalizedCacheWrite
        self.outputTokens = max(max(0, outputTokens), normalizedReasoning)
        self.reasoningOutputTokens = normalizedReasoning
        self.totalTokens = totalTokens
    }
}

public struct RolloutWireEvent: Sendable {
    public let eventType: String
    public let timestampMs: Int64
    public let timestampQuality: TimestampQuality
    public let timestampSource: TimestampSource
    public let timestampConflictCount: Int
    public let replayBoundaryTimestampMs: Int64?
    public let taskStartedAtMs: Int64?
    public let turnId: String?
    public let sessionId: String?
    public let parentSessionId: String?
    public let isChildSessionMeta: Bool
    public let model: String?
    public let serviceTier: String?
    public let reasoningEffort: String?
    public let turnIndex: Int?
    public let callIndex: Int?
    public let lastTokenUsage: RawTokenUsagePayload?
    public let totalTokenUsage: RawTokenUsagePayload?
    public let isReplayMarker: Bool

    public init(
        eventType: String,
        timestampMs: Int64,
        timestampQuality: TimestampQuality = .eventTimestamp,
        timestampSource: TimestampSource = .topLevelTimestamp,
        timestampConflictCount: Int = 0,
        replayBoundaryTimestampMs: Int64? = nil,
        taskStartedAtMs: Int64? = nil,
        turnId: String? = nil,
        sessionId: String? = nil,
        parentSessionId: String? = nil,
        isChildSessionMeta: Bool = false,
        model: String? = nil,
        serviceTier: String? = nil,
        reasoningEffort: String? = nil,
        turnIndex: Int? = nil,
        callIndex: Int? = nil,
        lastTokenUsage: RawTokenUsagePayload? = nil,
        totalTokenUsage: RawTokenUsagePayload? = nil,
        isReplayMarker: Bool = false
    ) {
        self.eventType = eventType
        self.timestampMs = timestampMs
        self.timestampQuality = timestampQuality
        self.timestampSource = timestampSource
        self.timestampConflictCount = timestampConflictCount
        self.replayBoundaryTimestampMs = replayBoundaryTimestampMs
        self.taskStartedAtMs = taskStartedAtMs
        self.turnId = turnId
        self.sessionId = sessionId
        self.parentSessionId = parentSessionId
        self.isChildSessionMeta = isChildSessionMeta
        self.model = model
        self.serviceTier = serviceTier
        self.reasoningEffort = reasoningEffort
        self.turnIndex = turnIndex
        self.callIndex = callIndex
        self.lastTokenUsage = lastTokenUsage
        self.totalTokenUsage = totalTokenUsage
        self.isReplayMarker = isReplayMarker
    }
}

public enum RolloutLineDecoder {
    public static func mayContainUsageRelevantEvent(_ lineString: String) -> Bool {
        lineString.contains("token_count")
            || lineString.contains("session_meta")
            || lineString.contains("turn_context")
            || lineString.contains("thread_settings_applied")
            || lineString.contains("task_started")
            || lineString.contains("task_complete")
            || lineString.contains("user_message")
            || lineString.contains("forked_from_id")
            || lineString.contains("parent_session_id")
            || lineString.contains("parent_thread_id")
            || lineString.contains("subagent")
            || lineString.contains("last_token_usage")
            || lineString.contains("total_token_usage")
            || lineString.contains("cache_creation_input_tokens")
            || lineString.contains("cache_write_input_tokens")
            || lineString.contains("reasoning_effort")
            || lineString.contains("effort")
    }

    public static func mayContainUsageRelevantEvent(_ lineData: Data.SubSequence) -> Bool {
        guard !lineData.isEmpty else { return false }
        // This predicate is only applied to a complete line. It intentionally
        // does not assume compact JSON, key order, or a short prefix.
        let needles = [
            "token_count", "session_meta", "turn_context", "thread_settings_applied",
            "task_started", "task_complete", "user_message", "forked_from_id",
            "parent_session_id", "parent_thread_id", "subagent", "last_token_usage",
            "total_token_usage", "cache_creation_input_tokens",
            "cache_write_input_tokens", "reasoning_effort", "effort"
        ]
        return needles.contains { needle in
            lineData.range(of: Data(needle.utf8)) != nil
        }
    }

    /// 快速将一行 JSONL 解析为 RolloutWireEvent
    public static func decodeLine(_ lineString: String) -> RolloutWireEvent? {
        let normalizedLine = lineString.hasPrefix("\u{feff}")
            ? String(lineString.dropFirst())
            : lineString
        guard mayContainUsageRelevantEvent(normalizedLine) else {
            return nil
        }

        guard let data = normalizedLine.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        let outerType = (json["type"] as? String ?? json["event"] as? String ?? "unknown").lowercased()
        let timestamp = extractTimestamp(from: json)

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
        let collabMode = payload["collaboration_mode"] as? [String: Any] ?? json["collaboration_mode"] as? [String: Any]
        let collabSettings = collabMode?["settings"] as? [String: Any]
        let reasoningEffort = firstString([
            payload["reasoning_effort"],
            payload["effort"],
            collabSettings?["reasoning_effort"],
            collabSettings?["effort"],
            threadSettings?["reasoning_effort"],
            threadSettings?["effort"],
            info?["reasoning_effort"],
            info?["effort"],
            metadata?["reasoning_effort"],
            metadata?["effort"],
            infoMetadata?["reasoning_effort"],
            infoMetadata?["effort"],
            json["reasoning_effort"],
            json["effort"]
        ])
        let turnIndex = payload["turn_index"] as? Int ?? json["turn_index"] as? Int
        let callIndex = payload["call_index"] as? Int ?? json["call_index"] as? Int
        let sessionId = firstString([payload["session_id"], payload["id"], json["session_id"], json["id"]])
        let parentSessionId = firstString([
            payload["parent_session_id"],
            payload["parentSessionId"],
            payload["parent_id"],
            payload["forked_from_id"],
            payload["parent_thread_id"],
            json["parent_session_id"],
            json["parentSessionId"],
            json["parent_id"],
            json["forked_from_id"],
            json["parent_thread_id"]
        ])
        let threadSource = firstString([payload["thread_source"], json["thread_source"]])?.lowercased()
        let isChildSessionMeta = type == "session_meta"
            && (parentSessionId != nil || threadSource == "subagent" || containsSubagentMarker(payload["source"]))
        let taskObject = payload["task"] as? [String: Any]
        let taskStartedAt = timestampFromAny(
            payload["started_at"]
                ?? payload["startedAt"]
                ?? taskObject?["startedAt"]
                ?? taskObject?["started_at"]
                ?? json["started_at"]
                ?? json["startedAt"]
        )
        let replayBoundaryTimestamp = firstTimestampCandidate([
            payload["timestamp"],
            info?["timestamp"],
            metadata?["timestamp"],
            json["started_at"],
            payload["started_at"],
            taskObject?["startedAt"],
            taskObject?["started_at"]
        ])
        let turnId = firstString([payload["turn_id"], payload["turnId"], json["turn_id"], json["turnId"]])

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
                || payload["cache_creation_input_tokens"] != nil
                || payload["cache_write_input_tokens"] != nil
                || payload["output_tokens"] != nil
                || payload["reasoning_output_tokens"] != nil
                || json["input_tokens"] != nil
                || json["cached_input_tokens"] != nil
                || json["cache_creation_input_tokens"] != nil
                || json["cache_write_input_tokens"] != nil
                || json["output_tokens"] != nil
                || json["reasoning_output_tokens"] != nil
            if hasBucketField {
                lastUsage = parseTokenUsageDict(payload.merging(json) { current, _ in current })
            }
        }

        let isRelevantType = [
            "session_meta",
            "token_count",
            "turn_context",
            "thread_settings_applied",
            "task_started",
            "task_complete",
            "user_message"
        ].contains(type)
        guard isRelevantType || lastUsage != nil || totalUsage != nil || model != nil || serviceTier != nil || reasoningEffort != nil else {
            return nil
        }

        return RolloutWireEvent(
            eventType: type,
            timestampMs: timestamp.value,
            timestampQuality: timestamp.source.quality,
            timestampSource: timestamp.source,
            timestampConflictCount: timestamp.conflictCount,
            replayBoundaryTimestampMs: replayBoundaryTimestamp,
            taskStartedAtMs: taskStartedAt,
            turnId: turnId,
            sessionId: sessionId,
            parentSessionId: parentSessionId,
            isChildSessionMeta: isChildSessionMeta,
            model: model,
            serviceTier: serviceTier,
            reasoningEffort: reasoningEffort,
            turnIndex: turnIndex,
            callIndex: callIndex,
            lastTokenUsage: lastUsage,
            totalTokenUsage: totalUsage,
            isReplayMarker: extractReplayMarker(type: type, json: json, payload: payload)
        )
    }

    private struct TimestampCandidate {
        let value: Int64
        let source: TimestampSource
    }

    private static func extractTimestamp(from json: [String: Any]) -> (value: Int64, source: TimestampSource, conflictCount: Int) {
        let payload = json["payload"] as? [String: Any]
        let info = json["info"] as? [String: Any]
        let payloadInfo = payload?["info"] as? [String: Any]
        let metadata = json["metadata"] as? [String: Any]
        let payloadMetadata = payload?["metadata"] as? [String: Any]
        let task = payload?["task"] as? [String: Any]
        let candidates: [TimestampCandidate] = [
            timestampCandidate(json["timestamp"], source: .topLevelTimestamp),
            timestampCandidate(payload?["timestamp"], source: .payloadTimestamp),
            timestampCandidate(info?["timestamp"], source: .infoTimestamp),
            timestampCandidate(payloadInfo?["timestamp"], source: .infoTimestamp),
            timestampCandidate(metadata?["timestamp"], source: .metadataTimestamp),
            timestampCandidate(payloadMetadata?["timestamp"], source: .metadataTimestamp),
            timestampCandidate(json["created_at"] ?? json["createdAt"], source: .createdAt),
            timestampCandidate(payload?["created_at"] ?? payload?["createdAt"], source: .createdAt),
            timestampCandidate(json["started_at"] ?? json["startedAt"], source: .startedAt),
            timestampCandidate(payload?["started_at"] ?? payload?["startedAt"], source: .startedAt),
            timestampCandidate(task?["startedAt"] ?? task?["started_at"], source: .taskStartedAt)
        ].compactMap { $0 }
        guard let selected = candidates.first else {
            return (0, .unresolved, 0)
        }
        let conflictCount = candidates.dropFirst().filter {
            abs($0.value - selected.value) > 60_000
        }.count
        return (selected.value, selected.source, conflictCount)
    }

    private static func parseTokenUsageDict(_ dict: [String: Any]) -> RawTokenUsagePayload {
        let input = int64Value(from: dict["input_tokens"])
        let cached = int64Value(from: dict["cached_input_tokens"] ?? dict["cache_read_input_tokens"])
        let cacheWrite = int64Value(from: dict["cache_creation_input_tokens"] ?? dict["cache_write_input_tokens"])
        let output = int64Value(from: dict["output_tokens"])
        let reasoning = int64Value(from: dict["reasoning_output_tokens"] ?? dict["reasoning_tokens"])
        let total = dict["total_tokens"] != nil ? int64Value(from: dict["total_tokens"]) : nil

        return RawTokenUsagePayload(
            inputTokens: input,
            cachedInputTokens: cached,
            cacheWriteInputTokens: cacheWrite,
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

    private static func firstTimestampCandidate(_ values: [Any?]) -> Int64? {
        for value in values {
            if let timestamp = timestampFromAny(value) {
                return timestamp
            }
        }
        return nil
    }

    private static func timestampCandidate(_ value: Any?, source: TimestampSource) -> TimestampCandidate? {
        guard let timestamp = timestampFromAny(value) else { return nil }
        return TimestampCandidate(value: timestamp, source: source)
    }

    private static func timestampFromAny(_ value: Any?) -> Int64? {
        guard let value else { return nil }
        if value is Bool { return nil }
        if let intVal = value as? Int64 {
            return normalizeEpochMilliseconds(Double(intVal))
        }
        if let intVal = value as? Int {
            return normalizeEpochMilliseconds(Double(intVal))
        }
        if let doubleVal = value as? Double {
            return normalizeEpochMilliseconds(doubleVal)
        }
        if let number = value as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return nil }
            return normalizeEpochMilliseconds(number.doubleValue)
        }
        if let stringVal = value as? String {
            let trimmed = stringVal.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            if let numeric = Double(trimmed) {
                return normalizeEpochMilliseconds(numeric)
            }
            if let date = dateFromISO8601(trimmed) {
                return normalizeEpochMilliseconds(date.timeIntervalSince1970)
            }
        }
        return nil
    }

    private static func normalizeEpochMilliseconds(_ raw: Double) -> Int64? {
        guard raw.isFinite, raw > 0 else { return nil }
        let milliseconds = raw > 100_000_000_000 ? raw : raw * 1_000
        guard milliseconds.isFinite,
              milliseconds >= 1_500_000_000_000,
              milliseconds <= 4_102_444_800_000 else {
            return nil
        }
        return Int64(milliseconds.rounded())
    }

    private static func firstString(_ values: [Any?]) -> String? {
        for value in values {
            guard let string = value as? String else { continue }
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return nil
    }

    private static func extractReplayMarker(type: String, json: [String: Any], payload: [String: Any]) -> Bool {
        if type.contains("replay") || type.contains("history") {
            return true
        }
        for key in ["is_replay", "replay", "is_child_replay", "history_replay"] {
            if let value = (payload[key] as? Bool) ?? (json[key] as? Bool), value {
                return true
            }
            if let value = (payload[key] as? String) ?? (json[key] as? String),
               ["1", "true", "yes"].contains(value.lowercased()) {
                return true
            }
        }
        return false
    }

    private static func containsSubagentMarker(_ value: Any?) -> Bool {
        guard let object = value as? [String: Any],
              let subagent = object["subagent"] else {
            return false
        }
        if subagent is NSNull { return false }
        return true
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
