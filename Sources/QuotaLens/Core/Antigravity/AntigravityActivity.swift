import Foundation
import SQLite3
import CoreServices

public struct AntigravityActivityRecord: Sendable, Equatable {
    public let sourceProfile: String
    public let trajectoryID: String
    public let createdAt: Date?
    public let lastModifiedAt: Date?
    public let lastUserInputAt: Date?
    public let stepCount: Int64
    public let projectName: String?

    public var activityDate: Date? {
        lastUserInputAt ?? lastModifiedAt ?? createdAt
    }
}

public struct AntigravityUsageRecord: Sendable, Equatable {
    public let generationIndex: Int64
    public let timestamp: Date
    public let timestampSource: TimestampSource
    public let modelRaw: String
    public let modelDisplayName: String?
    public let tokens: TokenBreakdown
    public let responseID: String?

    public init(
        generationIndex: Int64,
        timestamp: Date,
        timestampSource: TimestampSource,
        modelRaw: String,
        modelDisplayName: String?,
        tokens: TokenBreakdown,
        responseID: String?
    ) {
        self.generationIndex = generationIndex
        self.timestamp = timestamp
        self.timestampSource = timestampSource
        self.modelRaw = modelRaw
        self.modelDisplayName = modelDisplayName
        self.tokens = tokens
        self.responseID = responseID
    }
}

public struct AntigravityUsageParseReport: Sendable, Equatable {
    public var metadataRowCount = 0
    public var recognizedUsageCount = 0
    public var knownEmptyCount = 0
    public var incompatibleCount = 0

    public var isComplete: Bool { incompatibleCount == 0 }
}

public struct AntigravityConversationData: Sendable, Equatable {
    public let sessionID: String
    public let sourcePath: String
    public let sourceProfile: String
    public let trajectoryID: String
    public let createdAt: Date?
    public let lastModifiedAt: Date?
    public let lastUserInputAt: Date?
    public let stepCount: Int64
    public let projectName: String?
    public let cwd: String?
    public let usageRecords: [AntigravityUsageRecord]
    public let usageParseReport: AntigravityUsageParseReport

    public var activityRecord: AntigravityActivityRecord {
        AntigravityActivityRecord(
            sourceProfile: sourceProfile,
            trajectoryID: trajectoryID,
            createdAt: createdAt,
            lastModifiedAt: lastModifiedAt,
            lastUserInputAt: lastUserInputAt,
            stepCount: stepCount,
            projectName: projectName
        )
    }
}

public struct AntigravityActivityScanSummary: Sendable, Equatable {
    public let recordsRead: Int
    public let sourceProfile: String?
    public let sourceProfiles: [AntigravityStateProfile]
    public let snapshot: AntigravityActivitySnapshot
    public let snapshotsByProfile: [AntigravityStateProfile: AntigravityActivitySnapshot]
    public let isComplete: Bool
    public let hasIncompatibleUsage: Bool
}

public struct AntigravityConversationScanResult: Sendable {
    public let conversations: [AntigravityConversationData]
    public let discoveredSources: Set<URL>
    public let successfulSources: Set<URL>
    public let failedSources: [URL: String]

    public var isComplete: Bool { failedSources.isEmpty }
}

public struct AntigravityConversationReader: Sendable {
    public static var defaultDirectoryURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".gemini/antigravity/conversations", isDirectory: true)
    }

    public static var candidateDirectoryURLs: [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            defaultDirectoryURL,
            home.appendingPathComponent(".gemini/antigravity-cli/conversations", isDirectory: true)
        ]
    }

    public let directoryURL: URL

    public init(directoryURL: URL = Self.defaultDirectoryURL) {
        self.directoryURL = directoryURL
    }

    public var isAvailable: Bool {
        conversationDirectories.contains { url in
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
                && isDirectory.boolValue
        }
    }

    public func readConversations() -> AntigravityConversationScanResult {
        var urls: [URL] = []
        var failures: [URL: String] = [:]
        for directory in conversationDirectories {
            do {
                urls.append(contentsOf: try FileManager.default.contentsOfDirectory(
                    at: directory,
                    includingPropertiesForKeys: [.isRegularFileKey, .creationDateKey, .contentModificationDateKey],
                    options: [.skipsHiddenFiles]
                ).filter { $0.pathExtension.lowercased() == "db" })
            } catch CocoaError.fileReadNoSuchFile, CocoaError.fileNoSuchFile {
                continue
            } catch {
                failures[directory] = error.localizedDescription
            }
        }
        var conversations: [AntigravityConversationData] = []
        var successfulSources = Set<URL>()
        for url in urls.sorted(by: { $0.path < $1.path }) {
            do {
                if let conversation = try readConversationData(from: url) {
                    conversations.append(conversation)
                    if !conversation.usageParseReport.isComplete {
                        failures[url] = "Antigravity usage metadata is not fully compatible"
                        continue
                    }
                }
                successfulSources.insert(url)
            } catch {
                failures[url] = error.localizedDescription
            }
        }
        return AntigravityConversationScanResult(
            conversations: conversations,
            discoveredSources: Set(urls),
            successfulSources: successfulSources,
            failedSources: failures
        )
    }

    private var conversationDirectories: [URL] {
        if directoryURL.standardizedFileURL == Self.defaultDirectoryURL.standardizedFileURL {
            return Self.candidateDirectoryURLs
        }
        return [directoryURL]
    }

    private func readConversationData(from url: URL) throws -> AntigravityConversationData? {
        var database: OpaquePointer?
        let status = sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil)
        guard status == SQLITE_OK, let database else {
            if let database { sqlite3_close(database) }
            throw NSError(
                domain: "QuotaLens.AntigravityConversationReader",
                code: Int(status),
                userInfo: [NSLocalizedDescriptionKey: "Unable to read Antigravity conversation database"]
            )
        }
        defer { sqlite3_close(database) }
        sqlite3_busy_timeout(database, 750)
        // All queries share SQLite's read snapshot, including committed WAL
        // pages. Never copy an active database and its sidecars separately.
        guard sqlite3_exec(database, "BEGIN;", nil, nil, nil) == SQLITE_OK else {
            throw databaseError(database)
        }
        defer { sqlite3_exec(database, "ROLLBACK;", nil, nil, nil) }
        return try makeConversationData(database: database, sourceURL: url)
    }

    private func makeConversationData(
        database: OpaquePointer,
        sourceURL url: URL
    ) throws -> AntigravityConversationData? {

        let sessionID = url.deletingPathExtension().lastPathComponent
        let trajectoryID = try stringValue(
            database: database,
            sql: "SELECT trajectory_id FROM trajectory_meta ORDER BY rowid LIMIT 1;"
        ) ?? sessionID

        let stepCount = try int64Value(database: database, sql: "SELECT COUNT(*) FROM steps;") ?? 0
        let trajectoryMetadata = try blobValue(
            database: database,
            sql: "SELECT data FROM trajectory_metadata_blob ORDER BY CASE WHEN id = 'main' THEN 0 ELSE 1 END LIMIT 1;"
        )
        let parsedMetadata = trajectoryMetadata.map(Self.parseTrajectoryMetadata)
        let stepInfo = try readStepInfo(database: database)
        let fileValues = try? url.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
        let createdAt = parsedMetadata?.createdAt ?? fileValues?.creationDate
        let lastModifiedAt = stepInfo.latestStepAt ?? fileValues?.contentModificationDate ?? createdAt
        let fallbackDate = createdAt ?? lastModifiedAt ?? fileValues?.contentModificationDate ?? Date()
        let usage = try readUsageRecords(
            database: database,
            modelStepTimestamps: stepInfo.modelStepTimestamps,
            createdAt: createdAt,
            fallbackDate: fallbackDate
        )

        return AntigravityConversationData(
            sessionID: sessionID,
            sourcePath: url.path,
            sourceProfile: AntigravityStateProfile.legacy.rawValue,
            trajectoryID: trajectoryID,
            createdAt: createdAt,
            lastModifiedAt: lastModifiedAt,
            lastUserInputAt: stepInfo.lastUserInputAt,
            stepCount: max(0, stepCount),
            projectName: parsedMetadata?.projectName,
            cwd: parsedMetadata?.cwd,
            usageRecords: usage.records,
            usageParseReport: usage.report
        )
    }

    private func databaseError(_ database: OpaquePointer) -> Error {
        NSError(
            domain: "QuotaLens.AntigravityConversationReader",
            code: Int(sqlite3_errcode(database)),
            userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(database))]
        )
    }

    private func nextRow(_ statement: OpaquePointer, database: OpaquePointer) throws -> Bool {
        switch sqlite3_step(statement) {
        case SQLITE_ROW: return true
        case SQLITE_DONE: return false
        default: throw databaseError(database)
        }
    }

    private func stringValue(database: OpaquePointer, sql: String) throws -> String? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else { throw databaseError(database) }
        defer { sqlite3_finalize(statement) }
        guard try nextRow(statement, database: database),
              let value = sqlite3_column_text(statement, 0) else { return nil }
        return String(cString: value)
    }

    private func int64Value(database: OpaquePointer, sql: String) throws -> Int64? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else { throw databaseError(database) }
        defer { sqlite3_finalize(statement) }
        guard try nextRow(statement, database: database),
              sqlite3_column_type(statement, 0) != SQLITE_NULL else { return nil }
        return sqlite3_column_int64(statement, 0)
    }

    private func blobValue(database: OpaquePointer, sql: String) throws -> Data? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else { throw databaseError(database) }
        defer { sqlite3_finalize(statement) }
        guard try nextRow(statement, database: database),
              let bytes = sqlite3_column_blob(statement, 0) else { return nil }
        return Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 0)))
    }

    private struct StepInfo {
        var latestStepAt: Date?
        var lastUserInputAt: Date?
        var modelStepTimestamps: [Date]
    }

    private func readStepInfo(database: OpaquePointer) throws -> StepInfo {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(
            database,
            "SELECT step_type, metadata FROM steps ORDER BY idx;",
            -1,
            &statement,
            nil
        ) == SQLITE_OK, let statement else {
            return try readLegacyStepInfo(database: database)
        }
        defer { sqlite3_finalize(statement) }

        var info = StepInfo(latestStepAt: nil, lastUserInputAt: nil, modelStepTimestamps: [])
        while try nextRow(statement, database: database) {
            guard sqlite3_column_type(statement, 1) != SQLITE_NULL,
                  let bytes = sqlite3_column_blob(statement, 1) else { continue }
            let data = Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 1)))
            guard let timestamp = Self.latestTimestamp(inStepMetadata: data) else { continue }
            info.latestStepAt = info.latestStepAt.map { max($0, timestamp) } ?? timestamp
            let stepType = sqlite3_column_int(statement, 0)
            if stepType == 14 {
                info.lastUserInputAt = info.lastUserInputAt.map { max($0, timestamp) } ?? timestamp
            } else if stepType == 15 {
                info.modelStepTimestamps.append(timestamp)
            }
        }
        return info
    }

    private func readLegacyStepInfo(database: OpaquePointer) throws -> StepInfo {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(
            database,
            "SELECT metadata FROM steps ORDER BY idx;",
            -1,
            &statement,
            nil
        ) == SQLITE_OK, let statement else {
            throw databaseError(database)
        }
        defer { sqlite3_finalize(statement) }

        var latest: Date?
        while try nextRow(statement, database: database) {
            guard sqlite3_column_type(statement, 0) != SQLITE_NULL,
                  let bytes = sqlite3_column_blob(statement, 0) else { continue }
            let data = Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 0)))
            if let timestamp = Self.latestTimestamp(inStepMetadata: data) {
                latest = latest.map { max($0, timestamp) } ?? timestamp
            }
        }
        return StepInfo(latestStepAt: latest, lastUserInputAt: nil, modelStepTimestamps: [])
    }

    private func readUsageRecords(
        database: OpaquePointer,
        modelStepTimestamps: [Date],
        createdAt: Date?,
        fallbackDate: Date
    ) throws -> (records: [AntigravityUsageRecord], report: AntigravityUsageParseReport) {
        var report = AntigravityUsageParseReport()
        // Earlier activity-only databases legitimately have no usage table.
        guard try int64Value(
            database: database,
            sql: "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = 'gen_metadata';"
        ) != 0 else { return ([], report) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(
            database,
            "SELECT idx, data FROM gen_metadata ORDER BY idx;",
            -1,
            &statement,
            nil
        ) == SQLITE_OK, let statement else { throw databaseError(database) }
        defer { sqlite3_finalize(statement) }

        var records: [AntigravityUsageRecord] = []
        var seenResponseIDs = Set<String>()
        var rowIndex = 0
        while try nextRow(statement, database: database) {
            report.metadataRowCount += 1
            defer { rowIndex += 1 }
            guard sqlite3_column_type(statement, 1) != SQLITE_NULL,
                  let bytes = sqlite3_column_blob(statement, 1) else {
                if sqlite3_column_type(statement, 1) == SQLITE_BLOB && sqlite3_column_bytes(statement, 1) == 0 {
                    report.knownEmptyCount += 1
                } else {
                    report.incompatibleCount += 1
                }
                continue
            }
            let data = Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 1)))
            let generationIndex = sqlite3_column_int64(statement, 0)
            let outcome: UsageParseOutcome
            do {
                outcome = try Self.parseUsage(data)
            } catch {
                report.incompatibleCount += 1
                continue
            }
            let parsed: ParsedUsage
            switch outcome {
            case .knownEmpty:
                report.knownEmptyCount += 1
                continue
            case .incompatible:
                report.incompatibleCount += 1
                continue
            case .usage(let usage):
                report.recognizedUsageCount += 1
                parsed = usage
            }
            if let responseID = parsed.responseID, !seenResponseIDs.insert(responseID).inserted {
                continue
            }

            let stepTimestamp = rowIndex < modelStepTimestamps.count ? modelStepTimestamps[rowIndex] : nil
            let timestamp = parsed.timestamp ?? stepTimestamp ?? fallbackDate
            let timestampSource: TimestampSource
            if parsed.timestamp != nil || stepTimestamp != nil {
                timestampSource = .metadataTimestamp
            } else if createdAt != nil {
                timestampSource = .sessionMetadata
            } else {
                timestampSource = .fileModification
            }
            records.append(AntigravityUsageRecord(
                generationIndex: generationIndex,
                timestamp: timestamp,
                timestampSource: timestampSource,
                modelRaw: parsed.modelRaw,
                modelDisplayName: parsed.modelDisplayName,
                tokens: parsed.tokens,
                responseID: parsed.responseID
            ))
        }
        return (records, report)
    }

    private struct ParsedUsage {
        let modelRaw: String
        let modelDisplayName: String?
        let timestamp: Date?
        let tokens: TokenBreakdown
        let responseID: String?
    }

    private enum UsageParseOutcome {
        case usage(ParsedUsage)
        case knownEmpty
        case incompatible
    }

    private static func parseUsage(_ data: Data) throws -> UsageParseOutcome {
        if data.isEmpty { return .knownEmpty }
        try validateProto(data)
        guard let chatModel = messageField(data, number: 1) else { return .incompatible }
        if chatModel.isEmpty { return .knownEmpty }
        try validateProto(chatModel)
        guard let usage = messageField(chatModel, number: 4) else { return .incompatible }
        if usage.isEmpty { return .knownEmpty }
        var usageReader = AntigravityProtoReader(data: usage)
        var tokenFieldCount = 0
        var unknownFieldCount = 0
        while let field = try usageReader.nextField() {
            if [1, 2, 5, 9, 10].contains(field.number) {
                guard field.wireType == 0 else { return .incompatible }
                tokenFieldCount += 1
            } else if field.number != 11 || field.wireType != 2 {
                unknownFieldCount += 1
            }
        }
        if tokenFieldCount == 0 && unknownFieldCount > 0 { return .incompatible }

        let fixedInput = clampedInt64(varintField(usage, number: 1))
        let newInput = clampedInt64(varintField(usage, number: 2))
        let cacheRead = clampedInt64(varintField(usage, number: 5))
        let textOutput = clampedInt64(varintField(usage, number: 9))
        let reasoning = clampedInt64(varintField(usage, number: 10))
        let inputWithoutCache = adding(fixedInput, newInput)
        let input = adding(inputWithoutCache, cacheRead)
        let output = adding(textOutput, reasoning)
        let total = adding(input, output)
        guard total > 0 else { return unknownFieldCount == 0 ? .knownEmpty : .incompatible }

        let responseModel = nonEmpty(stringField(chatModel, number: 19))
        let displayName = nonEmpty(stringField(chatModel, number: 21))
        let modelRaw: String
        if let responseModel, responseModel.lowercased() != "gemini-default" {
            modelRaw = responseModel
        } else {
            modelRaw = displayName ?? responseModel ?? "unknown"
        }

        return .usage(ParsedUsage(
            modelRaw: modelRaw,
            modelDisplayName: displayName,
            timestamp: generationTimestamp(from: chatModel),
            tokens: TokenBreakdown(
                inputTokens: input,
                cachedInputTokens: cacheRead,
                outputTokens: output,
                reasoningOutputTokens: reasoning,
                sourceTotalTokens: total
            ),
            responseID: nonEmpty(stringField(usage, number: 11))
        ))
    }

    private static func generationTimestamp(from chatModel: Data) -> Date? {
        guard let generation = messageField(chatModel, number: 9),
              let timestamp = messageField(generation, number: 4) else { return nil }
        return parseTimestamp(timestamp)
    }

    private static func validateProto(_ data: Data) throws {
        var reader = AntigravityProtoReader(data: data)
        while try reader.nextField() != nil {}
    }

    private static func messageField(_ data: Data, number: Int) -> Data? {
        var reader = AntigravityProtoReader(data: data)
        while let field = try? reader.nextField() {
            if field.number == number, field.wireType == 2 {
                return field.bytes
            }
        }
        return nil
    }

    private static func stringField(_ data: Data, number: Int) -> String? {
        guard let value = messageField(data, number: number) else { return nil }
        return String(data: value, encoding: .utf8)
    }

    private static func varintField(_ data: Data, number: Int) -> UInt64? {
        var reader = AntigravityProtoReader(data: data)
        while let field = try? reader.nextField() {
            if field.number == number, field.wireType == 0 {
                return field.varint
            }
        }
        return nil
    }

    private static func clampedInt64(_ value: UInt64?) -> Int64 {
        guard let value else { return 0 }
        return value > UInt64(Int64.max) ? Int64.max : Int64(value)
    }

    private static func adding(_ lhs: Int64, _ rhs: Int64) -> Int64 {
        let (value, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? Int64.max : value
    }

    private static func parseTrajectoryMetadata(_ data: Data) -> (createdAt: Date?, projectName: String?, cwd: String?) {
        var reader = AntigravityProtoReader(data: data)
        var createdAt: Date?
        var projectName: String?
        var cwd: String?
        while let field = try? reader.nextField() {
            switch field.number {
            case 1 where field.wireType == 2:
                let path = filePathFromWorkspaceMetadata(field.bytes)
                cwd = cwd ?? path
                projectName = projectName ?? path.map { URL(fileURLWithPath: $0).lastPathComponent }
            case 2 where field.wireType == 2:
                createdAt = parseTimestamp(field.bytes)
            case 7 where field.wireType == 2:
                let path = filePathFromFileURLData(field.bytes)
                cwd = cwd ?? path
                projectName = projectName ?? path.map { URL(fileURLWithPath: $0).lastPathComponent }
            default:
                break
            }
        }
        return (createdAt, nonEmpty(projectName), nonEmpty(cwd))
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func filePathFromWorkspaceMetadata(_ data: Data) -> String? {
        var reader = AntigravityProtoReader(data: data)
        while let field = try? reader.nextField() {
            guard (field.number == 1 || field.number == 2), field.wireType == 2,
                  let path = filePathFromFileURLData(field.bytes) else { continue }
            return path
        }
        return nil
    }

    private static func filePathFromFileURLData(_ data: Data) -> String? {
        guard let value = String(data: data, encoding: .utf8),
              let url = URL(string: value), url.scheme == "file" else { return nil }
        let path = url.path.trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : path
    }

    private static func latestTimestamp(inStepMetadata data: Data) -> Date? {
        let timestampFields: Set<Int> = [1, 6, 7, 8, 32]
        var reader = AntigravityProtoReader(data: data)
        var latest: Date?
        while let field = try? reader.nextField() {
            guard timestampFields.contains(field.number), field.wireType == 2,
                  let timestamp = parseTimestamp(field.bytes) else { continue }
            latest = latest.map { max($0, timestamp) } ?? timestamp
        }
        return latest
    }

    private static func parseTimestamp(_ data: Data) -> Date? {
        var reader = AntigravityProtoReader(data: data)
        var seconds: Int64?
        var nanos: Int64 = 0
        while let field = try? reader.nextField() {
            if field.number == 1, field.wireType == 0 { seconds = Int64(bitPattern: field.varint) }
            if field.number == 2, field.wireType == 0 { nanos = Int64(field.varint) }
        }
        guard let seconds, seconds > 0 else { return nil }
        return Date(timeIntervalSince1970: Double(seconds) + Double(nanos) / 1_000_000_000)
    }

    public func readConversation(sessionID: String) throws -> CodexSessionConversationDTO {
        let rawID = UsageSessionIdentity.rawID(provider: .antigravity, sessionKey: sessionID)
        guard let url = transcriptURL(for: rawID) else {
            return CodexSessionConversationDTO(sessionId: sessionID, messages: [])
        }
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        let lines = String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline)
        var messages: [CodexConversationMessageDTO] = []

        for line in lines {
            guard let jsonData = line.data(using: .utf8),
                  let raw = try JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
                  let type = raw["type"] as? String,
                  let source = raw["source"] as? String else { continue }

            let role: CodexConversationRole
            if source == "USER_EXPLICIT", type == "USER_INPUT" {
                role = .user
            } else if source == "MODEL", type == "PLANNER_RESPONSE" {
                role = .assistant
            } else {
                continue
            }

            let content = (raw["content"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let text = role == .user ? userRequest(from: content) : content
            guard !text.isEmpty else { continue }
            let timestamp = transcriptDate(raw["created_at"] as? String)
            if let previous = messages.last,
               previous.role == role,
               previous.text == text {
                continue
            }
            messages.append(CodexConversationMessageDTO(
                id: "\(sessionID):\(raw["step_index"] as? Int ?? messages.count)",
                role: role,
                timestamp: timestamp,
                text: text
            ))
        }

        return CodexSessionConversationDTO(sessionId: sessionID, messages: messages)
    }

    public func containsConversationText(sessionID: String, query: String) throws -> Bool {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedQuery.isEmpty else { return false }
        let conversation = try readConversation(sessionID: sessionID)
        return conversation.messages.contains {
            $0.text.range(
                of: normalizedQuery,
                options: [.caseInsensitive, .diacriticInsensitive],
                range: nil,
                locale: L10n.locale
            ) != nil
        }
    }

    private func transcriptURL(for sessionID: String) -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let roots = [
            home.appendingPathComponent(".gemini/antigravity/brain", isDirectory: true),
            home.appendingPathComponent(".gemini/antigravity-cli/brain", isDirectory: true)
        ]
        for root in roots {
            let directory = root.appendingPathComponent(sessionID, isDirectory: true)
                .appendingPathComponent(".system_generated/logs", isDirectory: true)
            for name in ["transcript_full.jsonl", "transcript.jsonl"] {
                let url = directory.appendingPathComponent(name)
                if FileManager.default.fileExists(atPath: url.path) { return url }
            }
        }
        return nil
    }

    private func transcriptDate(_ value: String?) -> Date? {
        guard let value else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }

    private func userRequest(from content: String) -> String {
        guard let start = content.range(of: "<USER_REQUEST>") else { return content }
        let requestStart = start.upperBound
        if let end = content.range(of: "</USER_REQUEST>", range: requestStart..<content.endIndex) {
            return String(content[requestStart..<end.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return String(content[requestStart...]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public actor AntigravityActivityStore {
    private let database: SQLiteDatabase
    private let reader: AntigravityLocalStateReader
    private let conversationReader: AntigravityConversationReader

    public init(
        database: SQLiteDatabase,
        reader: AntigravityLocalStateReader = AntigravityLocalStateReader(),
        conversationReader: AntigravityConversationReader = AntigravityConversationReader()
    ) {
        self.database = database
        self.reader = reader
        self.conversationReader = conversationReader
    }

    public func scan(preferredProfile: AntigravityStateProfile? = nil) throws -> AntigravityActivityScanSummary {
        let stateScan = reader.scanRawValues(
            key: "antigravityUnifiedStateSync.trajectorySummaries",
            preferredProfile: preferredProfile
        )
        let rawValues = stateScan.values
        var stateReadFailed = !stateScan.failedSources.isEmpty
        var recordsByProfile: [String: [AntigravityActivityRecord]] = Dictionary(
            uniqueKeysWithValues: stateScan.successfulProfiles.map { ($0.rawValue, []) }
        )
        for raw in rawValues {
            do {
                let records = try Self.parseRecords(raw.value, sourceProfile: raw.source.profile.rawValue)
                recordsByProfile[raw.source.profile.rawValue, default: []].append(contentsOf: records)
            } catch {
                stateReadFailed = true
            }
        }
        let conversationScan = conversationReader.readConversations()
        let isComplete = conversationScan.isComplete && !stateReadFailed
        recordsByProfile[AntigravityStateProfile.legacy.rawValue, default: []]
            .append(contentsOf: conversationScan.conversations.map(\.activityRecord))
        try AntigravityUsageImporter.importScan(conversationScan, database: database)
        for (sourceProfile, records) in recordsByProfile {
            try replace(Self.deduplicated(records), sourceProfile: sourceProfile, removeMissing: isComplete)
        }

        let now = Date()
        let stored = Set(try storedProfiles())
        var scanned = stateScan.successfulProfiles
        if conversationReader.isAvailable {
            scanned.insert(.legacy)
        }
        let sourceProfiles = AntigravityStateProfile.allCases.filter {
            stored.contains($0) || scanned.contains($0)
        }
        let snapshotsByProfile = try Dictionary(uniqueKeysWithValues: sourceProfiles.map { profile in
            (profile, try makeSnapshot(sourceProfile: profile.rawValue, now: now))
        })
        let snapshot = try makeSnapshot(sourceProfile: nil, now: now)
        let recordsRead = Self.deduplicated(try loadRecords(sourceProfile: nil)).count
        return AntigravityActivityScanSummary(
            recordsRead: recordsRead,
            sourceProfile: sourceProfiles.count == 1 ? sourceProfiles[0].rawValue : nil,
            sourceProfiles: sourceProfiles,
            snapshot: snapshot,
            snapshotsByProfile: snapshotsByProfile,
            isComplete: isComplete,
            hasIncompatibleUsage: conversationScan.conversations.contains { !$0.usageParseReport.isComplete }
        )
    }

    public func cachedSnapshot(preferredProfile: AntigravityStateProfile? = nil) throws -> AntigravityActivitySnapshot {
        let profile = preferredProfile?.rawValue
        return try makeSnapshot(sourceProfile: profile, now: Date())
    }

    public func cachedSnapshotsByProfile() throws -> [AntigravityStateProfile: AntigravityActivitySnapshot] {
        let now = Date()
        return try Dictionary(uniqueKeysWithValues: storedProfiles().map { profile in
            (profile, try makeSnapshot(sourceProfile: profile.rawValue, now: now))
        })
    }

    private func replace(_ records: [AntigravityActivityRecord], sourceProfile: String, removeMissing: Bool) throws {
        try database.transaction {
            if removeMissing {
                try database.executeUpdate(
                    sql: "DELETE FROM antigravity_activity_records WHERE source_profile = ?;",
                    bindings: [sourceProfile]
                )
            }
            for record in records {
                try database.executeUpdate(
                    sql: """
                    INSERT OR REPLACE INTO antigravity_activity_records (
                        source_profile, trajectory_id, created_at, last_modified_at,
                        last_user_input_at, step_count, project_name
                    ) VALUES (?, ?, ?, ?, ?, ?, ?);
                    """,
                    bindings: [
                        record.sourceProfile,
                        record.trajectoryID,
                        record.createdAt.map { Int64($0.timeIntervalSince1970) },
                        record.lastModifiedAt.map { Int64($0.timeIntervalSince1970) },
                        record.lastUserInputAt.map { Int64($0.timeIntervalSince1970) },
                        record.stepCount,
                        record.projectName
                    ]
                )
            }
        }
    }

    private func makeSnapshot(sourceProfile: String?, now: Date) throws -> AntigravityActivitySnapshot {
        var records = try loadRecords(sourceProfile: sourceProfile)
        if sourceProfile == nil {
            records = Self.deduplicated(records)
        }

        let calendar = UsageDayBucketer.calendar()
        let today = calendar.startOfDay(for: now)
        let sevenDayStart = calendar.date(byAdding: .day, value: -6, to: today) ?? today
        let thirtyDayStart = calendar.date(byAdding: .day, value: -29, to: today) ?? today
        let previousSevenDayStart = calendar.date(byAdding: .day, value: -13, to: today) ?? sevenDayStart
        let previousThirtyDayStart = calendar.date(byAdding: .day, value: -59, to: today) ?? thirtyDayStart
        let recent = records.compactMap { record -> (Date, AntigravityActivityRecord)? in
            guard let date = record.activityDate else { return nil }
            return (date, record)
        }
        let thirtyDay = recent.filter { $0.0 >= thirtyDayStart && $0.0 <= now }
        let sevenDay = recent.filter { $0.0 >= sevenDayStart && $0.0 <= now }
        let previousSevenDay = recent.filter { $0.0 >= previousSevenDayStart && $0.0 < sevenDayStart }
        let previousThirtyDay = recent.filter { $0.0 >= previousThirtyDayStart && $0.0 < thirtyDayStart }

        func periodMetrics(
            _ items: [(Date, AntigravityActivityRecord)],
            days: Int
        ) -> AntigravityActivitySnapshot.PeriodMetrics {
            let activeDays = Set(items.map { calendar.startOfDay(for: $0.0) }).count
            let steps = items.reduce(Int64(0)) { partial, item in
                let (sum, overflow) = partial.addingReportingOverflow(item.1.stepCount)
                return overflow ? Int64.max : sum
            }
            return AntigravityActivitySnapshot.PeriodMetrics(
                days: days,
                taskCount: items.count,
                activeDays: activeDays,
                stepCount: steps
            )
        }
        let sevenDayMetrics = periodMetrics(sevenDay, days: 7)
        let previousSevenDayMetrics = periodMetrics(previousSevenDay, days: 7)
        let thirtyDayMetrics = periodMetrics(thirtyDay, days: 30)
        let previousThirtyDayMetrics = periodMetrics(previousThirtyDay, days: 30)

        var dailyCounts: [Date: (tasks: Int, steps: Int64)] = [:]
        for item in thirtyDay {
            let day = calendar.startOfDay(for: item.0)
            let existing = dailyCounts[day] ?? (0, 0)
            let (steps, overflow) = existing.steps.addingReportingOverflow(item.1.stepCount)
            dailyCounts[day] = (existing.tasks + 1, overflow ? Int64.max : steps)
        }
        let daily = (0..<30).compactMap { offset -> AntigravityActivitySnapshot.Day? in
            guard let date = calendar.date(byAdding: .day, value: offset - 29, to: today) else { return nil }
            let values = dailyCounts[calendar.startOfDay(for: date)] ?? (0, 0)
            return AntigravityActivitySnapshot.Day(date: date, taskCount: values.tasks, stepCount: values.steps)
        }

        var projectCounts: [String: Int] = [:]
        for item in thirtyDay {
            if let project = item.1.projectName, !project.isEmpty {
                projectCounts[project, default: 0] += 1
            }
        }
        return AntigravityActivitySnapshot(
            capturedAt: now,
            taskCount7Days: sevenDayMetrics.taskCount,
            taskCount30Days: thirtyDayMetrics.taskCount,
            activeDays30Days: thirtyDayMetrics.activeDays,
            stepCount30Days: thirtyDayMetrics.stepCount,
            latestActivityAt: recent.map(\.0).max(),
            daily: daily,
            projectCounts: projectCounts,
            sevenDayMetrics: sevenDayMetrics,
            previousSevenDayMetrics: previousSevenDayMetrics,
            thirtyDayMetrics: thirtyDayMetrics,
            previousThirtyDayMetrics: previousThirtyDayMetrics
        )
    }

    private func loadRecords(sourceProfile: String?) throws -> [AntigravityActivityRecord] {
        let bindings: [Any?] = sourceProfile.map { [$0] } ?? []
        let whereClause = sourceProfile == nil ? "" : " WHERE source_profile = ?"
        return try database.executeQuery(
            sql: """
            SELECT source_profile, trajectory_id, created_at, last_modified_at,
                   last_user_input_at, step_count, project_name
            FROM antigravity_activity_records\(whereClause);
            """,
            bindings: bindings
        ) { statement in
            AntigravityActivityRecord(
                sourceProfile: String(cString: sqlite3_column_text(statement, 0)),
                trajectoryID: String(cString: sqlite3_column_text(statement, 1)),
                createdAt: Self.date(sqlite3_column_int64(statement, 2), statement: statement, index: 2),
                lastModifiedAt: Self.date(sqlite3_column_int64(statement, 3), statement: statement, index: 3),
                lastUserInputAt: Self.date(sqlite3_column_int64(statement, 4), statement: statement, index: 4),
                stepCount: max(0, sqlite3_column_int64(statement, 5)),
                projectName: sqlite3_column_type(statement, 6) == SQLITE_NULL
                    ? nil
                    : String(cString: sqlite3_column_text(statement, 6))
            )
        }
    }

    private func storedProfiles() throws -> [AntigravityStateProfile] {
        let profiles = try database.executeQuery(
            sql: "SELECT DISTINCT source_profile FROM antigravity_activity_records;"
        ) { statement in
            AntigravityStateProfile(rawValue: String(cString: sqlite3_column_text(statement, 0)))
        }
        let available = Set(profiles.compactMap { $0 })
        return AntigravityStateProfile.allCases.filter { available.contains($0) }
    }

    private static func deduplicated(_ records: [AntigravityActivityRecord]) -> [AntigravityActivityRecord] {
        var recordsByTrajectory: [String: AntigravityActivityRecord] = [:]
        for record in records {
            guard let existing = recordsByTrajectory[record.trajectoryID] else {
                recordsByTrajectory[record.trajectoryID] = record
                continue
            }
            let existingDate = existing.activityDate ?? .distantPast
            let recordDate = record.activityDate ?? .distantPast
            if recordDate > existingDate || (recordDate == existingDate && record.stepCount > existing.stepCount) {
                recordsByTrajectory[record.trajectoryID] = record
            }
        }
        return Array(recordsByTrajectory.values)
    }

    private static func date(_ value: Int64, statement: OpaquePointer, index: Int) -> Date? {
        guard sqlite3_column_type(statement, Int32(index)) != SQLITE_NULL, value > 0 else { return nil }
        return Date(timeIntervalSince1970: Double(value))
    }

    private static func parseRecords(_ raw: String, sourceProfile: String) throws -> [AntigravityActivityRecord] {
        guard let data = Data(base64Encoded: raw) else { throw AntigravityCredentialError.malformedPayload }
        var outer = AntigravityProtoReader(data: data)
        var records: [AntigravityActivityRecord] = []
        while let field = try outer.nextField() {
            guard field.number == 1, field.wireType == 2 else { continue }
            guard let record = try parseEntry(field.bytes, sourceProfile: sourceProfile) else {
                throw AntigravityCredentialError.malformedPayload
            }
            records.append(record)
        }
        guard data.isEmpty || !records.isEmpty else { throw AntigravityCredentialError.malformedPayload }
        return records
    }

    private static func parseEntry(_ data: Data, sourceProfile: String) throws -> AntigravityActivityRecord? {
        var entry = AntigravityProtoReader(data: data)
        var trajectoryID: String?
        var row: Data?
        while let field = try entry.nextField() {
            if field.number == 1, field.wireType == 2 { trajectoryID = String(data: field.bytes, encoding: .utf8) }
            if field.number == 2, field.wireType == 2 { row = field.bytes }
        }
        guard let trajectoryID, let row else { return nil }
        var rowReader = AntigravityProtoReader(data: row)
        while let field = try rowReader.nextField() {
            guard field.number == 1, field.wireType == 2,
                  let encoded = String(data: field.bytes, encoding: .utf8),
                  let summary = Data(base64Encoded: encoded) else { continue }
            return try parseSummary(summary, trajectoryID: trajectoryID, sourceProfile: sourceProfile)
        }
        return nil
    }

    private static func parseSummary(
        _ data: Data,
        trajectoryID: String,
        sourceProfile: String
    ) throws -> AntigravityActivityRecord? {
        var reader = AntigravityProtoReader(data: data)
        var createdAt: Date?
        var lastModifiedAt: Date?
        var lastUserInputAt: Date?
        var stepCount: Int64 = 0
        var strings: [String] = []
        while let field = try reader.nextField() {
            switch field.number {
            case 1 where field.wireType == 2:
                // The summary is intentionally not persisted.
                break
            case 2 where field.wireType == 0:
                stepCount = Int64(clamping: field.varint)
            case 3 where field.wireType == 2:
                lastModifiedAt = parseTimestamp(field.bytes)
            case 7 where field.wireType == 2:
                createdAt = parseTimestamp(field.bytes)
            case 10 where field.wireType == 2:
                lastUserInputAt = parseTimestamp(field.bytes)
            case 9 where field.wireType == 2:
                strings.append(contentsOf: printableStrings(in: field.bytes))
            default:
                break
            }
        }
        return AntigravityActivityRecord(
            sourceProfile: sourceProfile,
            trajectoryID: trajectoryID,
            createdAt: createdAt,
            lastModifiedAt: lastModifiedAt,
            lastUserInputAt: lastUserInputAt,
            stepCount: max(0, stepCount),
            projectName: projectName(from: strings)
        )
    }

    private static func parseTimestamp(_ data: Data) -> Date? {
        var reader = AntigravityProtoReader(data: data)
        var seconds: Int64?
        var nanos: Int64 = 0
        while let field = try? reader.nextField() {
            if field.number == 1, field.wireType == 0 { seconds = Int64(bitPattern: field.varint) }
            if field.number == 2, field.wireType == 0 { nanos = Int64(field.varint) }
        }
        guard let seconds else { return nil }
        return Date(timeIntervalSince1970: Double(seconds) + Double(nanos) / 1_000_000_000)
    }

    private static func printableStrings(in data: Data) -> [String] {
        var result: [String] = []
        var current: [UInt8] = []
        func flush() {
            guard current.count >= 4,
                  let value = String(bytes: current, encoding: .utf8) else { current.removeAll(); return }
            result.append(value)
            current.removeAll()
        }
        for byte in data {
            if byte >= 32 && byte < 127 { current.append(byte) } else { flush() }
        }
        flush()
        return result
    }

    private static func projectName(from strings: [String]) -> String? {
        for value in strings {
            guard let url = URL(string: value), url.scheme == "file" else { continue }
            let name = url.lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty { return name }
        }
        return nil
    }
}

@MainActor
public final class AntigravityActivityScanCoordinator: ObservableObject {
    @Published public private(set) var isScanning = false
    @Published public private(set) var lastScanTime: Date?
    @Published public private(set) var isPartial = false
    @Published public private(set) var statusText = ""
    @Published public private(set) var latestSnapshot: AntigravityActivitySnapshot?
    @Published public private(set) var snapshotsByProfile: [AntigravityStateProfile: AntigravityActivitySnapshot] = [:]

    private var store: AntigravityActivityStore?

    public init() {}

    public func configure(database: SQLiteDatabase) {
        store = AntigravityActivityStore(database: database)
    }

    public func scanNow(preferredProfile: AntigravityStateProfile? = nil) async {
        guard !isScanning, let store else { return }
        isScanning = true
        statusText = L10n.text("正在读取 Antigravity 本地活动…", "Reading Antigravity local activity...")
        defer { isScanning = false }
        do {
            let result = try await store.scan(preferredProfile: preferredProfile)
            latestSnapshot = result.snapshot
            snapshotsByProfile = result.snapshotsByProfile
            isPartial = !result.isComplete
            if result.isComplete {
                lastScanTime = Date()
                statusText = L10n.format(
                    "Read %d local sources · %d Antigravity sessions",
                    zhHans: "已从 %d 个本机来源读取 %d 个 Antigravity 会话",
                    result.sourceProfiles.count,
                    result.recordsRead
                )
            } else if result.hasIncompatibleUsage {
                statusText = L10n.text(
                    "部分 Antigravity 用量暂时无法识别，已保留上次的用量统计。",
                    "Some Antigravity usage could not be recognized. Previously saved usage statistics have been kept."
                )
            } else {
                statusText = L10n.text(
                    "部分 Antigravity 记录暂时无法读取，统计中保留了上次的数据。",
                    "Some Antigravity records could not be read. Statistics include previously saved data."
                )
            }
        } catch {
            isPartial = true
            statusText = L10n.text(
                "暂时无法读取 Antigravity 本地活动",
                "Antigravity local activity could not be read"
            )
        }
    }
}

final class AntigravityStateFileWatcher: @unchecked Sendable {
    private let directories: [URL]
    private let queue = DispatchQueue(label: "QuotaLens.AntigravityFileWatcher", qos: .utility)
    private let onChange: @Sendable () -> Void
    private var lastChangeDelivery = Date.distantPast
    private let minimumChangeInterval: TimeInterval = 5
    private var stream: FSEventStreamRef?

    init(onChange: @escaping @Sendable () -> Void) {
        let stateDirectories = AntigravityLocalStateReader.candidateSources()
            .map { $0.databaseURL.deletingLastPathComponent() }
        self.directories = (stateDirectories + AntigravityConversationReader.candidateDirectoryURLs)
            .filter { FileManager.default.fileExists(atPath: $0.path) }
            .reduce(into: []) { result, url in
                if !result.contains(url) { result.append(url) }
            }
        self.onChange = onChange
    }

    @discardableResult
    func start() -> Bool {
        if stream != nil { return true }
        guard !directories.isEmpty else { return false }
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        guard let created = FSEventStreamCreate(
            kCFAllocatorDefault,
            { _, info, _, _, _, _ in
                guard let info else { return }
                Unmanaged<AntigravityStateFileWatcher>
                    .fromOpaque(info)
                    .takeUnretainedValue()
                    .deliverChangeIfNeeded()
            },
            &context,
            directories.map(\.path) as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            1.0,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagNoDefer)
        ) else { return false }
        FSEventStreamSetDispatchQueue(created, queue)
        guard FSEventStreamStart(created) else {
            FSEventStreamInvalidate(created)
            FSEventStreamRelease(created)
            return false
        }
        stream = created
        return true
    }

    private func deliverChangeIfNeeded() {
        let now = Date()
        guard now.timeIntervalSince(lastChangeDelivery) >= minimumChangeInterval else { return }
        lastChangeDelivery = now
        onChange()
    }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    deinit { stop() }
}

enum AntigravityQuotaRepository {
    /// Returns whether legacy data could not be fully recovered. Only failure
    /// to save the current snapshot throws; migration cannot roll it back.
    @discardableResult
    static func persist(_ snapshot: AntigravityQuotaSnapshot, database: SQLiteDatabase) throws -> Bool {
        let observedAt = Int64(snapshot.capturedAt.timeIntervalSince1970)
        try database.transaction {
            try storeCache(snapshot, database: database)
            try database.executeUpdate(
                sql: """
                DELETE FROM rate_limit_snapshots
                WHERE provider = 'antigravity' AND account_key = ? AND observed_at = ?;
                """,
                bindings: [snapshot.accountKey, observedAt]
            )
            for group in snapshot.groups {
                for bucket in group.buckets {
                    let duration: Int?
                    switch bucket.window {
                    case .fiveHour: duration = 300
                    case .weekly: duration = 10_080
                    case .other: duration = nil
                    }
                    try database.executeUpdate(
                        sql: """
                        INSERT INTO rate_limit_snapshots (
                            account_key, observed_at, limit_id, slot,
                            used_percent_milli, window_duration_mins, resets_at,
                            plan_type, raw_json, provider
                        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, '{}', 'antigravity');
                        """,
                        bindings: [
                            snapshot.accountKey,
                            observedAt,
                            group.id,
                            bucket.id,
                            Int(((100 - bucket.remainingPercent) * 1_000).rounded()),
                            duration,
                            bucket.resetAt.map { Int64($0.timeIntervalSince1970) },
                            snapshot.planName
                        ]
                    )
                }
            }
            try RateLimitSnapshotRetention.prune(database: database, now: snapshot.capturedAt)
        }
        guard let legacyKey = snapshot.legacyAccountKey, legacyKey != snapshot.accountKey else { return false }
        do {
            return try database.transaction {
                try migrateLegacyAccount(from: legacyKey, to: snapshot.accountKey, database: database)
            }
        } catch {
            return true
        }
    }

    static func hydrate(
        database: SQLiteDatabase,
        accountKey: String,
        sourceProfile: String? = nil
    ) throws -> AntigravityQuotaSnapshot? {
        let accountKey = try ProviderAccountAliases.resolve(accountKey, provider: .antigravity, database: database)
        var clauses = ["account_key = ?"]
        var bindings: [Any?] = [accountKey]
        if let sourceProfile { clauses.append("source_profile = ?"); bindings.append(sourceProfile) }
        let whereClause = clauses.isEmpty ? "" : " WHERE " + clauses.joined(separator: " AND ")
        let json = try database.stringScalar(
            sql: "SELECT payload_json FROM antigravity_quota_cache\(whereClause) ORDER BY captured_at DESC LIMIT 1;",
            bindings: bindings
        )
        guard let json, let data = json.data(using: .utf8) else { return nil }
        let snapshot = try JSONDecoder().decode(AntigravityQuotaSnapshot.self, from: data)
        return snapshot.accountKey == accountKey ? snapshot : nil
    }

    private static func storeCache(_ snapshot: AntigravityQuotaSnapshot, database: SQLiteDatabase, replaceExisting: Bool = true) throws {
        let json = String(decoding: try JSONEncoder().encode(snapshot), as: UTF8.self)
        try database.executeUpdate(
            sql: """
            INSERT INTO antigravity_quota_cache (source_profile, account_key, captured_at, payload_json)
            VALUES (?, ?, ?, ?)
            ON CONFLICT(source_profile, account_key) DO UPDATE SET
                captured_at = excluded.captured_at,
                payload_json = excluded.payload_json
            WHERE ? AND excluded.captured_at >= antigravity_quota_cache.captured_at;
            """,
            bindings: [snapshot.sourceProfile, snapshot.accountKey, Int64(snapshot.capturedAt.timeIntervalSince1970), json, replaceExisting]
        )
    }

    private static func migrateLegacyAccount(from legacyKey: String, to accountKey: String, database: SQLiteDatabase) throws -> Bool {
        try ProviderAccountAliases.attachLegacyAlias(
            legacyKey: legacyKey,
            canonicalKey: accountKey,
            provider: .antigravity,
            database: database
        )
        let payloads = try database.executeQuery(
            sql: "SELECT source_profile, payload_json FROM antigravity_quota_cache WHERE account_key = ?;",
            bindings: [legacyKey]
        ) { (String(cString: sqlite3_column_text($0, 0)), String(cString: sqlite3_column_text($0, 1))) }
        var discardedCache = false
        for (profile, payload) in payloads {
            let old: AntigravityQuotaSnapshot
            do {
                old = try JSONDecoder().decode(AntigravityQuotaSnapshot.self, from: Data(payload.utf8))
            } catch {
                discardedCache = true
                continue
            }
            guard old.accountKey == legacyKey, old.sourceProfile == profile,
                  validCacheDate(old.capturedAt),
                  old.buckets.allSatisfy({ (0...100).contains($0.remainingPercent) && validCacheDate($0.resetAt) }),
                  old.models.allSatisfy({ (0...100).contains($0.remainingPercent) && validCacheDate($0.resetAt) }) else {
                discardedCache = true
                continue
            }
            let migrated = AntigravityQuotaSnapshot(
                sourceProfile: old.sourceProfile,
                accountKey: accountKey,
                accountDisplayName: old.accountDisplayName,
                planName: old.planName,
                capturedAt: old.capturedAt,
                groups: old.groups,
                models: old.models,
                legacyAccountKey: legacyKey
            )
            try storeCache(migrated, database: database, replaceExisting: false)
        }
        try database.executeUpdate(
            sql: "DELETE FROM antigravity_quota_cache WHERE account_key = ?;",
            bindings: [legacyKey]
        )
        return discardedCache
    }

    private static func validCacheDate(_ date: Date?) -> Bool {
        guard let date else { return true }
        let seconds = date.timeIntervalSince1970
        return seconds.isFinite && seconds > Double(Int64.min) && seconds < Double(Int64.max)
    }
}
