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

public struct RolloutSessionMetadataEvent: Sendable {
    public let timestampMs: Int64
    public let timestampSource: TimestampSource
    public let timestampConflictCount: Int
    public let sessionId: String?
    public let cwd: String?
    public let parentSessionId: String?
    public let agentType: String?
    public let isChildSession: Bool
}

public enum RolloutLineDecoder {
    private static let usageRelevantNeedles = [
        "token_count", "session_meta", "turn_context", "thread_settings_applied",
        "task_started", "task_complete", "user_message", "forked_from_id",
        "parent_session_id", "parent_thread_id", "subagent", "last_token_usage",
        "total_token_usage", "cache_creation_input_tokens",
        "cache_write_input_tokens", "reasoning_effort", "effort"
    ].map { Data($0.utf8) }
    private static let sessionMetadataNeedle = Data("session_meta".utf8)
    private static let topLevelTypeKey = Array("type".utf8)
    private static let sessionMetadataValue = Array("session_meta".utf8)
    private static let usageRelevantTopLevelTypes: Set<String> = [
        "event_msg", "session_meta", "token_count", "turn_context",
        "thread_settings_applied", "task_started", "task_complete", "user_message"
    ]
    private static let fractionalISO8601Style = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    private static let plainISO8601Style = Date.ISO8601FormatStyle()

    private enum SessionMetadataLineKind {
        case sessionMetadata
        case other(String)
        case undetermined
    }

    private struct SessionMetadataFields {
        var type: String?
        var event: String?
        var topLevelTimestamp: Int64?
        var topLevelId: String?
        var topLevelSessionId: String?
        var hasPayload = false
        var payloadObjectComplete = false
        var payloadTimestamp: Int64?
        var payloadId: String?
        var payloadSessionId: String?
        var cwd: String?
        var parentSessionId: String?
        var parentSessionIdCamel: String?
        var parentId: String?
        var forkedFromId: String?
        var parentThreadId: String?
        var nestedParentThreadId: String?
        var threadSource: String?
        var agentType: String?
        var agentRole: String?
        var agentNickname: String?
        var nestedAgentRole: String?
        var nestedAgentNickname: String?
        var hasSubagent = false
    }

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
        guard usageRelevantNeedles.contains(where: { needle in
            lineData.range(of: needle) != nil
        }) else {
            return false
        }
        switch classifySessionMetadataLine(lineData) {
        case .sessionMetadata:
            return true
        case .other(let type):
            return usageRelevantTopLevelTypes.contains(type)
        case .undetermined:
            return true
        }
    }

    public static func mayContainSessionMetadata(_ lineData: Data.SubSequence) -> Bool {
        guard lineData.range(of: sessionMetadataNeedle) != nil else { return false }
        switch classifySessionMetadataLine(lineData) {
        case .sessionMetadata, .undetermined:
            return true
        case .other:
            return false
        }
    }

    public static func decodeSessionMetadataLine(_ lineString: String) -> RolloutSessionMetadataEvent? {
        let normalizedLine = lineString.hasPrefix("\u{feff}")
            ? String(lineString.dropFirst())
            : lineString
        guard let data = normalizedLine.data(using: .utf8) else { return nil }
        return decodeSessionMetadataPrefix(data[data.startIndex..<data.endIndex])
    }

    public static func decodeSessionMetadataPrefix(
        _ lineData: Data.SubSequence
    ) -> RolloutSessionMetadataEvent? {
        guard let fields = scanSessionMetadataFields(lineData),
              (fields.type ?? fields.event)?.lowercased() == "session_meta",
              fields.hasPayload else { return nil }

        let topLevelTimestamp = fields.topLevelTimestamp
        let payloadTimestamp = fields.payloadTimestamp
        let timestampMs = topLevelTimestamp ?? payloadTimestamp ?? 0
        let timestampSource: TimestampSource = topLevelTimestamp != nil
            ? .topLevelTimestamp
            : (payloadTimestamp != nil ? .payloadTimestamp : .unresolved)
        let timestampConflictCount = if let topLevelTimestamp, let payloadTimestamp,
                                        abs(topLevelTimestamp - payloadTimestamp) > 60_000 {
            1
        } else {
            0
        }

        let parentSessionId = firstString([
            fields.parentSessionId,
            fields.parentSessionIdCamel,
            fields.parentId,
            fields.forkedFromId,
            fields.parentThreadId,
            fields.nestedParentThreadId
        ])
        let sessionId = firstString([
            fields.payloadId,
            fields.payloadSessionId,
            fields.topLevelSessionId,
            fields.topLevelId
        ])
        guard sessionId != nil,
              fields.payloadObjectComplete
                || fields.threadSource != nil
                || parentSessionId != nil
                || fields.hasSubagent
                || fields.cwd != nil else {
            return nil
        }
        let agentType = firstString([
            fields.agentType,
            fields.agentRole,
            fields.agentNickname,
            fields.nestedAgentRole,
            fields.nestedAgentNickname,
            fields.hasSubagent ? "subagent" : nil
        ])
        let threadSource = fields.threadSource?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        return RolloutSessionMetadataEvent(
            timestampMs: timestampMs,
            timestampSource: timestampSource,
            timestampConflictCount: timestampConflictCount,
            sessionId: sessionId,
            cwd: firstString([fields.cwd]),
            parentSessionId: parentSessionId,
            agentType: agentType,
            isChildSession: parentSessionId != nil
                || threadSource == "subagent"
                || fields.hasSubagent
        )
    }

    private static func scanSessionMetadataFields(_ data: Data.SubSequence) -> SessionMetadataFields? {
        data.withUnsafeBytes { rawBuffer in
            let bytes = rawBuffer.bindMemory(to: UInt8.self)
            var fields = SessionMetadataFields()
            var cursor = skipJSONWhitespace(bytes, from: 0, limit: bytes.count)
            guard cursor < bytes.count, bytes[cursor] == 0x7B else { return nil }
            cursor += 1

            while cursor < bytes.count {
                cursor = skipJSONWhitespace(bytes, from: cursor, limit: bytes.count)
                if cursor < bytes.count, bytes[cursor] == 0x7D { return fields }
                guard cursor < bytes.count, bytes[cursor] == 0x22,
                      let keyEnd = jsonStringEnd(bytes, startingAt: cursor, limit: bytes.count),
                      let key = jsonString(bytes, range: cursor..<(keyEnd + 1)) else {
                    return fields
                }
                cursor = skipJSONWhitespace(bytes, from: keyEnd + 1, limit: bytes.count)
                guard cursor < bytes.count, bytes[cursor] == 0x3A else { return fields }
                cursor = skipJSONWhitespace(bytes, from: cursor + 1, limit: bytes.count)

                if key == "payload" {
                    fields.hasPayload = scanSessionMetadataPayload(
                        bytes,
                        range: cursor..<bytes.count,
                        fields: &fields
                    )
                }

                guard let valueEnd = skipJSONValue(bytes, from: cursor, limit: bytes.count) else {
                    return fields
                }
                let valueRange = cursor..<valueEnd
                switch key {
                case "type":
                    fields.type = jsonString(bytes, range: valueRange)
                case "event":
                    fields.event = jsonString(bytes, range: valueRange)
                case "timestamp":
                    fields.topLevelTimestamp = jsonTimestamp(bytes, range: valueRange)
                case "id":
                    fields.topLevelId = jsonString(bytes, range: valueRange)
                case "session_id":
                    fields.topLevelSessionId = jsonString(bytes, range: valueRange)
                default:
                    break
                }
                cursor = skipJSONWhitespace(bytes, from: valueEnd, limit: bytes.count)
                if cursor < bytes.count, bytes[cursor] == 0x2C {
                    cursor += 1
                    continue
                }
                if cursor < bytes.count, bytes[cursor] == 0x7D { return fields }
                return fields
            }
            return fields
        }
    }

    private static func scanSessionMetadataPayload(
        _ bytes: UnsafeBufferPointer<UInt8>,
        range: Range<Int>,
        fields: inout SessionMetadataFields
    ) -> Bool {
        let objectStart = skipJSONWhitespace(bytes, from: range.lowerBound, limit: range.upperBound)
        guard objectStart < range.upperBound, bytes[objectStart] == 0x7B else { return false }
        fields.payloadObjectComplete = scanJSONObject(
            bytes,
            from: objectStart,
            limit: range.upperBound
        ) { key, valueRange in
            switch key {
            case "id": fields.payloadId = jsonString(bytes, range: valueRange)
            case "session_id": fields.payloadSessionId = jsonString(bytes, range: valueRange)
            case "timestamp": fields.payloadTimestamp = jsonTimestamp(bytes, range: valueRange)
            case "cwd": fields.cwd = jsonString(bytes, range: valueRange)
            case "parent_session_id": fields.parentSessionId = jsonString(bytes, range: valueRange)
            case "parentSessionId": fields.parentSessionIdCamel = jsonString(bytes, range: valueRange)
            case "parent_id": fields.parentId = jsonString(bytes, range: valueRange)
            case "forked_from_id": fields.forkedFromId = jsonString(bytes, range: valueRange)
            case "parent_thread_id": fields.parentThreadId = jsonString(bytes, range: valueRange)
            case "thread_source": fields.threadSource = jsonString(bytes, range: valueRange)
            case "agent_type": fields.agentType = jsonString(bytes, range: valueRange)
            case "agent_role": fields.agentRole = jsonString(bytes, range: valueRange)
            case "agent_nickname": fields.agentNickname = jsonString(bytes, range: valueRange)
            case "source": scanSessionMetadataSource(bytes, range: valueRange, fields: &fields)
            default: break
            }
        }
        return true
    }

    private static func scanSessionMetadataSource(
        _ bytes: UnsafeBufferPointer<UInt8>,
        range: Range<Int>,
        fields: inout SessionMetadataFields
    ) {
        _ = scanJSONObject(bytes, from: range.lowerBound, limit: range.upperBound) { key, valueRange in
            guard key == "subagent", !isJSONNull(bytes, range: valueRange) else { return }
            fields.hasSubagent = true
            _ = scanJSONObject(bytes, from: valueRange.lowerBound, limit: valueRange.upperBound) { key, valueRange in
                guard key == "thread_spawn" else { return }
                _ = scanJSONObject(bytes, from: valueRange.lowerBound, limit: valueRange.upperBound) { key, valueRange in
                    switch key {
                    case "parent_thread_id":
                        fields.nestedParentThreadId = jsonString(bytes, range: valueRange)
                    case "agent_role":
                        fields.nestedAgentRole = jsonString(bytes, range: valueRange)
                    case "agent_nickname":
                        fields.nestedAgentNickname = jsonString(bytes, range: valueRange)
                    default:
                        break
                    }
                }
            }
        }
    }

    private static func scanJSONObject(
        _ bytes: UnsafeBufferPointer<UInt8>,
        from start: Int,
        limit: Int,
        onField: (_ key: String, _ valueRange: Range<Int>) -> Void
    ) -> Bool {
        var cursor = skipJSONWhitespace(bytes, from: start, limit: limit)
        guard cursor < limit, bytes[cursor] == 0x7B else { return false }
        cursor += 1

        while cursor < limit {
            cursor = skipJSONWhitespace(bytes, from: cursor, limit: limit)
            if cursor < limit, bytes[cursor] == 0x7D { return true }
            guard cursor < limit, bytes[cursor] == 0x22,
                  let keyEnd = jsonStringEnd(bytes, startingAt: cursor, limit: limit),
                  let key = jsonString(bytes, range: cursor..<(keyEnd + 1)) else {
                return false
            }
            cursor = skipJSONWhitespace(bytes, from: keyEnd + 1, limit: limit)
            guard cursor < limit, bytes[cursor] == 0x3A else { return false }
            cursor = skipJSONWhitespace(bytes, from: cursor + 1, limit: limit)
            guard let valueEnd = skipJSONValue(bytes, from: cursor, limit: limit) else { return false }
            onField(key, cursor..<valueEnd)
            cursor = skipJSONWhitespace(bytes, from: valueEnd, limit: limit)
            if cursor < limit, bytes[cursor] == 0x2C {
                cursor += 1
                continue
            }
            if cursor < limit, bytes[cursor] == 0x7D { return true }
            return false
        }
        return false
    }

    private static func skipJSONValue(
        _ bytes: UnsafeBufferPointer<UInt8>,
        from start: Int,
        limit: Int
    ) -> Int? {
        guard start < limit else { return nil }
        if bytes[start] == 0x22 {
            return jsonStringEnd(bytes, startingAt: start, limit: limit).map { $0 + 1 }
        }
        if bytes[start] == 0x7B || bytes[start] == 0x5B {
            var depth = 0
            var cursor = start
            while cursor < limit {
                switch bytes[cursor] {
                case 0x22:
                    guard let end = jsonStringEnd(bytes, startingAt: cursor, limit: limit) else { return nil }
                    cursor = end + 1
                case 0x7B, 0x5B:
                    depth += 1
                    cursor += 1
                case 0x7D, 0x5D:
                    depth -= 1
                    cursor += 1
                    if depth == 0 { return cursor }
                default:
                    cursor += 1
                }
            }
            return nil
        }

        var cursor = start
        while cursor < limit, bytes[cursor] != 0x2C, bytes[cursor] != 0x7D, bytes[cursor] != 0x5D {
            cursor += 1
        }
        var end = cursor
        while end > start, isJSONWhitespace(bytes[end - 1]) { end -= 1 }
        return end > start ? end : nil
    }

    private static func jsonStringEnd(
        _ bytes: UnsafeBufferPointer<UInt8>,
        startingAt quoteIndex: Int,
        limit: Int
    ) -> Int? {
        var cursor = quoteIndex + 1
        var escaped = false
        while cursor < limit {
            let byte = bytes[cursor]
            if escaped {
                escaped = false
            } else if byte == 0x5C {
                escaped = true
            } else if byte == 0x22 {
                return cursor
            }
            cursor += 1
        }
        return nil
    }

    private static func jsonString(
        _ bytes: UnsafeBufferPointer<UInt8>,
        range: Range<Int>
    ) -> String? {
        guard range.count >= 2,
              bytes[range.lowerBound] == 0x22,
              bytes[range.upperBound - 1] == 0x22 else {
            return nil
        }
        let contentRange = (range.lowerBound + 1)..<(range.upperBound - 1)
        if !bytes[contentRange].contains(0x5C) {
            return String(decoding: bytes[contentRange], as: UTF8.self)
        }
        let encoded = Data(bytes[range])
        return try? JSONDecoder().decode(String.self, from: encoded)
    }

    private static func jsonTimestamp(
        _ bytes: UnsafeBufferPointer<UInt8>,
        range: Range<Int>
    ) -> Int64? {
        let raw: String
        if bytes[range.lowerBound] == 0x22 {
            guard let value = jsonString(bytes, range: range) else { return nil }
            raw = value
        } else {
            raw = String(decoding: bytes[range], as: UTF8.self)
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let numeric = Double(trimmed) {
            return normalizeEpochMilliseconds(numeric)
        }
        guard let date = dateFromISO8601(trimmed) else { return nil }
        return normalizeEpochMilliseconds(date.timeIntervalSince1970)
    }

    private static func skipJSONWhitespace(
        _ bytes: UnsafeBufferPointer<UInt8>,
        from start: Int,
        limit: Int
    ) -> Int {
        var cursor = start
        while cursor < limit, isJSONWhitespace(bytes[cursor]) { cursor += 1 }
        return cursor
    }

    private static func isJSONWhitespace(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D
    }

    private static func isJSONNull(
        _ bytes: UnsafeBufferPointer<UInt8>,
        range: Range<Int>
    ) -> Bool {
        range.count == 4
            && bytes[range.lowerBound] == 0x6E
            && bytes[range.lowerBound + 1] == 0x75
            && bytes[range.lowerBound + 2] == 0x6C
            && bytes[range.lowerBound + 3] == 0x6C
    }

    private static func classifySessionMetadataLine(_ lineData: Data.SubSequence) -> SessionMetadataLineKind {
        lineData.withUnsafeBytes { rawBuffer in
            let bytes = rawBuffer.bindMemory(to: UInt8.self)
            var depth = 0
            var expectsTopLevelKey = false
            var index = 0

            func stringEnd(startingAt quoteIndex: Int) -> Int? {
                var cursor = quoteIndex + 1
                var escaped = false
                while cursor < bytes.count {
                    let byte = bytes[cursor]
                    if escaped {
                        escaped = false
                    } else if byte == 0x5C {
                        escaped = true
                    } else if byte == 0x22 {
                        return cursor
                    }
                    cursor += 1
                }
                return nil
            }

            func matches(_ range: Range<Int>, _ expected: [UInt8]) -> Bool {
                guard range.count == expected.count else { return false }
                for offset in expected.indices where bytes[range.lowerBound + offset] != expected[offset] {
                    return false
                }
                return true
            }

            func skipWhitespace(from start: Int) -> Int {
                var cursor = start
                while cursor < bytes.count,
                      bytes[cursor] == 0x20 || bytes[cursor] == 0x09
                        || bytes[cursor] == 0x0A || bytes[cursor] == 0x0D {
                    cursor += 1
                }
                return cursor
            }

            while index < bytes.count {
                switch bytes[index] {
                case 0x7B, 0x5B: // { [
                    depth += 1
                    if depth == 1 { expectsTopLevelKey = true }
                    index += 1
                case 0x7D, 0x5D: // } ]
                    depth = max(0, depth - 1)
                    index += 1
                case 0x2C: // ,
                    if depth == 1 { expectsTopLevelKey = true }
                    index += 1
                case 0x22: // "
                    guard let end = stringEnd(startingAt: index) else {
                        return .undetermined
                    }
                    guard depth == 1, expectsTopLevelKey else {
                        index = end + 1
                        continue
                    }

                    let keyRange = (index + 1)..<end
                    expectsTopLevelKey = false
                    guard matches(keyRange, topLevelTypeKey) else {
                        index = end + 1
                        continue
                    }

                    var valueStart = skipWhitespace(from: end + 1)
                    guard valueStart < bytes.count, bytes[valueStart] == 0x3A else {
                        return .undetermined
                    }
                    valueStart = skipWhitespace(from: valueStart + 1)
                    guard valueStart < bytes.count, bytes[valueStart] == 0x22,
                          let valueEnd = stringEnd(startingAt: valueStart) else {
                        return .undetermined
                    }
                    let valueRange = (valueStart + 1)..<valueEnd
                    return matches(valueRange, sessionMetadataValue)
                        ? .sessionMetadata
                        : .other(String(decoding: bytes[valueRange], as: UTF8.self).lowercased())
                default:
                    index += 1
                }
            }
            return .undetermined
        }
    }

    /// 快速将一行 JSONL 解析为 RolloutWireEvent
    public static func decodeLine(_ lineString: String) -> RolloutWireEvent? {
        let normalizedLine = lineString.hasPrefix("\u{feff}")
            ? String(lineString.dropFirst())
            : lineString
        guard let data = normalizedLine.data(using: .utf8),
              mayContainUsageRelevantEvent(data[data.startIndex..<data.endIndex]) else {
            return nil
        }

        if let metadata = decodeSessionMetadataPrefix(data[data.startIndex..<data.endIndex]) {
            return RolloutWireEvent(
                eventType: "session_meta",
                timestampMs: metadata.timestampMs,
                timestampQuality: metadata.timestampSource.quality,
                timestampSource: metadata.timestampSource,
                timestampConflictCount: metadata.timestampConflictCount,
                sessionId: metadata.sessionId,
                parentSessionId: metadata.parentSessionId,
                isChildSessionMeta: metadata.isChildSession
            )
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
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
        if let date = try? Date(value, strategy: fractionalISO8601Style) {
            return date
        }
        return try? Date(value, strategy: plainISO8601Style)
    }
}
