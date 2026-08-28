// QuotaLens Codex 会话正文按需读取与搜索

import Foundation

public enum CodexConversationRole: String, Hashable, Sendable {
    case user
    case assistant

    public var localizedTitle: String {
        switch self {
        case .user:
            return L10n.text("用户", "You")
        case .assistant:
            return L10n.text("助手", "Assistant")
        }
    }
}

public struct CodexConversationMessageDTO: Identifiable, Hashable, Sendable {
    public let id: String
    public let role: CodexConversationRole
    public let timestamp: Date?
    public let text: String
    public let attachmentCount: Int

    public init(
        id: String,
        role: CodexConversationRole,
        timestamp: Date?,
        text: String,
        attachmentCount: Int = 0
    ) {
        self.id = id
        self.role = role
        self.timestamp = timestamp
        self.text = text
        self.attachmentCount = attachmentCount
    }
}

public struct CodexSessionConversationDTO: Sendable {
    public let sessionId: String
    public let messages: [CodexConversationMessageDTO]

    public init(sessionId: String, messages: [CodexConversationMessageDTO]) {
        self.sessionId = sessionId
        self.messages = messages
    }
}

public enum CodexConversationReader {
    private struct DecodedMessage {
        let role: CodexConversationRole
        let timestamp: Date?
        let text: String
        let attachmentCount: Int
    }

    private enum SearchMatch: Error {
        case found
    }

    public static func readConversation(
        fileURL: URL,
        sessionId: String
    ) throws -> CodexSessionConversationDTO {
        var messages: [CodexConversationMessageDTO] = []

        _ = try StreamingJSONLReader.readLines(
            fileURL: fileURL,
            shouldIncludeLineData: mayContainConversationMessage
        ) { record in
            try Task.checkCancellation()
            guard let decoded = decodeMessage(record.lineString) else { return }

            if let previous = messages.last,
               previous.role == decoded.role,
               previous.text == decoded.text {
                if decoded.attachmentCount > previous.attachmentCount {
                    messages[messages.count - 1] = CodexConversationMessageDTO(
                        id: previous.id,
                        role: previous.role,
                        timestamp: previous.timestamp ?? decoded.timestamp,
                        text: previous.text,
                        attachmentCount: decoded.attachmentCount
                    )
                }
                return
            }

            messages.append(CodexConversationMessageDTO(
                id: "\(sessionId):\(record.startOffset)",
                role: decoded.role,
                timestamp: decoded.timestamp,
                text: decoded.text,
                attachmentCount: decoded.attachmentCount
            ))
        }

        try Task.checkCancellation()
        return CodexSessionConversationDTO(sessionId: sessionId, messages: messages)
    }

    public static func containsConversationText(
        fileURL: URL,
        query: String
    ) throws -> Bool {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedQuery.isEmpty else { return false }
        guard try fileMayContainQuery(fileURL: fileURL, query: normalizedQuery) else {
            return false
        }

        do {
            _ = try StreamingJSONLReader.readLines(
                fileURL: fileURL,
                shouldIncludeLineData: mayContainConversationMessage
            ) { record in
                try Task.checkCancellation()
                guard let decoded = decodeMessage(record.lineString) else { return }
                if localizedContains(decoded.text, query: normalizedQuery) {
                    throw SearchMatch.found
                }
            }
        } catch SearchMatch.found {
            return true
        }

        try Task.checkCancellation()
        return false
    }

    private static func fileMayContainQuery(fileURL: URL, query: String) throws -> Bool {
        try Task.checkCancellation()
        let mappedData = try Data(contentsOf: fileURL, options: .mappedIfSafe)
        var needles = [Data(query.utf8)]

        if let encoded = try? JSONSerialization.data(
            withJSONObject: query,
            options: .fragmentsAllowed
        ), encoded.count >= 2 {
            let escaped = Data(encoded.dropFirst().dropLast())
            if !escaped.isEmpty, escaped != needles[0] {
                needles.append(escaped)
            }
        }

        for needle in needles where !needle.isEmpty {
            try Task.checkCancellation()
            if mappedData.range(of: needle) != nil {
                return true
            }
        }
        return false
    }

    private static func mayContainConversationMessage(_ lineData: Data.SubSequence) -> Bool {
        guard !Task.isCancelled else { return false }
        let responseItem = lineData.range(of: Data("response_item".utf8)) != nil
        let eventMessage = lineData.range(of: Data("event_msg".utf8)) != nil
        guard responseItem || eventMessage else { return false }

        return lineData.range(of: Data("user_message".utf8)) != nil
            || lineData.range(of: Data("agent_message".utf8)) != nil
            || lineData.range(of: Data("\"message\"".utf8)) != nil
    }

    private static func decodeMessage(_ line: String) -> DecodedMessage? {
        guard let data = line.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        let outerType = (json["type"] as? String ?? "").lowercased()
        guard outerType == "response_item" || outerType == "event_msg" else { return nil }

        let payload = json["payload"] as? [String: Any] ?? [:]
        let payloadType = (payload["type"] as? String ?? "").lowercased()

        let role: CodexConversationRole
        switch (outerType, payloadType) {
        case ("response_item", "message"):
            guard let rawRole = (payload["role"] as? String)?.lowercased() else { return nil }
            if rawRole == "user" {
                role = .user
            } else if rawRole == "assistant" {
                role = .assistant
            } else {
                return nil
            }
        case ("response_item", "agent_message"), ("event_msg", "agent_message"):
            role = .assistant
        case ("event_msg", "user_message"):
            role = .user
        default:
            return nil
        }

        let extracted = extractContent(from: payload)
        guard !extracted.text.isEmpty || extracted.attachmentCount > 0 else { return nil }

        return DecodedMessage(
            role: role,
            timestamp: timestamp(from: json),
            text: extracted.text,
            attachmentCount: extracted.attachmentCount
        )
    }

    private static func extractContent(from payload: [String: Any]) -> (text: String, attachmentCount: Int) {
        var textParts: [String] = []
        var attachmentCount = 0

        if let content = payload["content"] as? [[String: Any]] {
            for item in content {
                let type = (item["type"] as? String ?? "").lowercased()
                if ["input_text", "output_text", "text"].contains(type),
                   let text = item["text"] as? String {
                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        textParts.append(trimmed)
                    }
                } else if type.contains("image") || type.contains("audio") || type == "file" {
                    attachmentCount += 1
                }
            }
        } else if let content = payload["content"] as? String {
            textParts.append(content)
        }

        if textParts.isEmpty {
            if let message = payload["message"] as? String {
                textParts.append(message)
            } else if let text = payload["text"] as? String {
                textParts.append(text)
            }
        }

        for key in ["images", "local_images", "audio", "local_audio"] {
            if let items = payload[key] as? [Any] {
                attachmentCount += items.count
            } else if payload[key] != nil {
                attachmentCount += 1
            }
        }

        let text = textParts
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
        return (text, attachmentCount)
    }

    private static func timestamp(from json: [String: Any]) -> Date? {
        let payload = json["payload"] as? [String: Any]
        let rawValue = json["timestamp"] ?? payload?["timestamp"]

        if let value = rawValue as? Double {
            let seconds = value > 100_000_000_000 ? value / 1_000 : value
            return Date(timeIntervalSince1970: seconds)
        }
        if let value = rawValue as? Int64 {
            let seconds = value > 100_000_000_000 ? Double(value) / 1_000 : Double(value)
            return Date(timeIntervalSince1970: seconds)
        }
        if let value = rawValue as? Int {
            let numeric = Double(value)
            let seconds = numeric > 100_000_000_000 ? numeric / 1_000 : numeric
            return Date(timeIntervalSince1970: seconds)
        }
        guard let value = rawValue as? String else { return nil }

        if let date = try? Date(
            value,
            strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)
        ) {
            return date
        }
        return try? Date(value, strategy: Date.ISO8601FormatStyle())
    }

    private static func localizedContains(_ value: String, query: String) -> Bool {
        value.range(
            of: query,
            options: [.caseInsensitive, .diacriticInsensitive],
            range: nil,
            locale: L10n.locale
        ) != nil
    }
}
