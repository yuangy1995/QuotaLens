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

public struct AntigravityActivityScanSummary: Sendable, Equatable {
    public let recordsRead: Int
    public let sourceProfile: String?
    public let sourceProfiles: [AntigravityStateProfile]
    public let snapshot: AntigravityActivitySnapshot
    public let snapshotsByProfile: [AntigravityStateProfile: AntigravityActivitySnapshot]
}

public struct AntigravityConversationReader: Sendable {
    public static var defaultDirectoryURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".gemini/antigravity/conversations", isDirectory: true)
    }

    public let directoryURL: URL

    public init(directoryURL: URL = Self.defaultDirectoryURL) {
        self.directoryURL = directoryURL
    }

    public var isAvailable: Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: directoryURL.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }

    public func readRecords() throws -> [AntigravityActivityRecord] {
        guard isAvailable else { return [] }
        let urls = try FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.isRegularFileKey, .creationDateKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )
        .filter { $0.pathExtension.lowercased() == "db" }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }

        var records: [AntigravityActivityRecord] = []
        var firstError: Error?
        for url in urls {
            do {
                if let record = try readRecord(from: url) {
                    records.append(record)
                }
            } catch {
                firstError = firstError ?? error
            }
        }
        if records.isEmpty, let firstError {
            throw firstError
        }
        return records
    }

    private func readRecord(from url: URL) throws -> AntigravityActivityRecord? {
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

        guard let trajectoryID = try stringValue(
            database: database,
            sql: "SELECT trajectory_id FROM trajectory_meta ORDER BY rowid LIMIT 1;"
        ) else { return nil }

        let stepCount = try int64Value(database: database, sql: "SELECT COUNT(*) FROM steps;") ?? 0
        let trajectoryMetadata = try blobValue(
            database: database,
            sql: "SELECT data FROM trajectory_metadata_blob ORDER BY CASE WHEN id = 'main' THEN 0 ELSE 1 END LIMIT 1;"
        )
        let parsedMetadata = trajectoryMetadata.map(Self.parseTrajectoryMetadata)
        let latestStepAt = try latestStepTimestamp(database: database)
        let fileValues = try? url.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
        let createdAt = parsedMetadata?.createdAt ?? fileValues?.creationDate
        let lastModifiedAt = latestStepAt ?? fileValues?.contentModificationDate ?? createdAt

        return AntigravityActivityRecord(
            sourceProfile: AntigravityStateProfile.legacy.rawValue,
            trajectoryID: trajectoryID,
            createdAt: createdAt,
            lastModifiedAt: lastModifiedAt,
            lastUserInputAt: nil,
            stepCount: max(0, stepCount),
            projectName: parsedMetadata?.projectName
        )
    }

    private func stringValue(database: OpaquePointer, sql: String) throws -> String? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else { return nil }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW,
              let value = sqlite3_column_text(statement, 0) else { return nil }
        return String(cString: value)
    }

    private func int64Value(database: OpaquePointer, sql: String) throws -> Int64? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else { return nil }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW,
              sqlite3_column_type(statement, 0) != SQLITE_NULL else { return nil }
        return sqlite3_column_int64(statement, 0)
    }

    private func blobValue(database: OpaquePointer, sql: String) throws -> Data? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else { return nil }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW,
              let bytes = sqlite3_column_blob(statement, 0) else { return nil }
        return Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 0)))
    }

    private func latestStepTimestamp(database: OpaquePointer) throws -> Date? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(
            database,
            "SELECT metadata FROM steps WHERE metadata IS NOT NULL;",
            -1,
            &statement,
            nil
        ) == SQLITE_OK, let statement else { return nil }
        defer { sqlite3_finalize(statement) }

        var latest: Date?
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let bytes = sqlite3_column_blob(statement, 0) else { continue }
            let data = Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 0)))
            if let timestamp = Self.latestTimestamp(inStepMetadata: data) {
                latest = latest.map { max($0, timestamp) } ?? timestamp
            }
        }
        return latest
    }

    private static func parseTrajectoryMetadata(_ data: Data) -> (createdAt: Date?, projectName: String?) {
        var reader = AntigravityProtoReader(data: data)
        var createdAt: Date?
        var projectName: String?
        while let field = try? reader.nextField() {
            switch field.number {
            case 1 where field.wireType == 2:
                projectName = projectName ?? projectNameFromWorkspaceMetadata(field.bytes)
            case 2 where field.wireType == 2:
                createdAt = parseTimestamp(field.bytes)
            case 7 where field.wireType == 2:
                projectName = projectName ?? projectNameFromFileURLData(field.bytes)
            default:
                break
            }
        }
        return (createdAt, projectName)
    }

    private static func projectNameFromWorkspaceMetadata(_ data: Data) -> String? {
        var reader = AntigravityProtoReader(data: data)
        while let field = try? reader.nextField() {
            guard (field.number == 1 || field.number == 2), field.wireType == 2,
                  let project = projectNameFromFileURLData(field.bytes) else { continue }
            return project
        }
        return nil
    }

    private static func projectNameFromFileURLData(_ data: Data) -> String? {
        guard let value = String(data: data, encoding: .utf8),
              let url = URL(string: value), url.scheme == "file" else { return nil }
        let name = url.lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
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
        let rawValues = try reader.readRawValues(
            key: "antigravityUnifiedStateSync.trajectorySummaries",
            preferredProfile: preferredProfile
        )
        var recordsByProfile: [String: [AntigravityActivityRecord]] = [:]
        for raw in rawValues {
            let records = Self.parseRecords(raw.value, sourceProfile: raw.source.profile.rawValue)
            recordsByProfile[raw.source.profile.rawValue, default: []].append(contentsOf: records)
        }
        if conversationReader.isAvailable {
            recordsByProfile[AntigravityStateProfile.legacy.rawValue, default: []]
                .append(contentsOf: try conversationReader.readRecords())
        }
        for (sourceProfile, records) in recordsByProfile {
            try replace(Self.deduplicated(records), sourceProfile: sourceProfile)
        }

        let now = Date()
        let stored = Set(try storedProfiles())
        var scanned = Set(rawValues.map(\.source.profile))
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
            snapshotsByProfile: snapshotsByProfile
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

    private func replace(_ records: [AntigravityActivityRecord], sourceProfile: String) throws {
        try database.transaction {
            try database.executeUpdate(
                sql: "DELETE FROM antigravity_activity_records WHERE source_profile = ?;",
                bindings: [sourceProfile]
            )
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

    private static func parseRecords(_ raw: String, sourceProfile: String) -> [AntigravityActivityRecord] {
        guard let data = Data(base64Encoded: raw, options: [.ignoreUnknownCharacters]) else { return [] }
        var outer = AntigravityProtoReader(data: data)
        var records: [AntigravityActivityRecord] = []
        while let field = try? outer.nextField() {
            guard field.number == 1, field.wireType == 2,
                  let record = parseEntry(field.bytes, sourceProfile: sourceProfile) else { continue }
            records.append(record)
        }
        return records
    }

    private static func parseEntry(_ data: Data, sourceProfile: String) -> AntigravityActivityRecord? {
        var entry = AntigravityProtoReader(data: data)
        var trajectoryID: String?
        var row: Data?
        while let field = try? entry.nextField() {
            if field.number == 1, field.wireType == 2 { trajectoryID = String(data: field.bytes, encoding: .utf8) }
            if field.number == 2, field.wireType == 2 { row = field.bytes }
        }
        guard let trajectoryID, let row else { return nil }
        var rowReader = AntigravityProtoReader(data: row)
        while let field = try? rowReader.nextField() {
            guard field.number == 1, field.wireType == 2,
                  let encoded = String(data: field.bytes, encoding: .utf8),
                  let summary = Data(base64Encoded: encoded, options: [.ignoreUnknownCharacters]) else { continue }
            return parseSummary(summary, trajectoryID: trajectoryID, sourceProfile: sourceProfile)
        }
        return nil
    }

    private static func parseSummary(
        _ data: Data,
        trajectoryID: String,
        sourceProfile: String
    ) -> AntigravityActivityRecord? {
        var reader = AntigravityProtoReader(data: data)
        var createdAt: Date?
        var lastModifiedAt: Date?
        var lastUserInputAt: Date?
        var stepCount: Int64 = 0
        var strings: [String] = []
        while let field = try? reader.nextField() {
            switch field.number {
            case 1 where field.wireType == 2:
                // The summary is intentionally not persisted.
                break
            case 2 where field.wireType == 0:
                stepCount = Int64(field.varint)
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
            lastScanTime = Date()
            statusText = L10n.format(
                "Read %d local sources · %d Antigravity tasks",
                zhHans: "已从 %d 个本机来源读取 %d 个 Antigravity 任务",
                result.sourceProfiles.count,
                result.recordsRead
            )
        } catch {
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
    private var stream: FSEventStreamRef?

    init(onChange: @escaping @Sendable () -> Void) {
        let stateDirectories = AntigravityLocalStateReader.candidateSources()
            .map { $0.databaseURL.deletingLastPathComponent() }
        self.directories = (stateDirectories + [AntigravityConversationReader.defaultDirectoryURL])
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
                Unmanaged<AntigravityStateFileWatcher>.fromOpaque(info).takeUnretainedValue().onChange()
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
    static func persist(_ snapshot: AntigravityQuotaSnapshot, database: SQLiteDatabase) throws {
        let data = try JSONEncoder().encode(snapshot)
        guard let json = String(data: data, encoding: .utf8) else { return }
        let observedAt = Int64(snapshot.capturedAt.timeIntervalSince1970)
        try database.transaction {
            try database.executeUpdate(
                sql: """
                INSERT OR REPLACE INTO antigravity_quota_cache (
                    source_profile, account_key, captured_at, payload_json
                ) VALUES (?, ?, ?, ?);
                """,
                bindings: [snapshot.sourceProfile, snapshot.accountKey, observedAt, json]
            )
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
            try database.executeUpdate(
                sql: """
                DELETE FROM rate_limit_snapshots
                WHERE provider = 'antigravity' AND observed_at < ?;
                """,
                bindings: [observedAt - RateLimitSnapshotRetention.retentionSeconds]
            )
            try RateLimitSnapshotRetention.prune(database: database, now: snapshot.capturedAt)
        }
    }

    static func hydrate(
        database: SQLiteDatabase,
        accountKey: String? = nil,
        sourceProfile: String? = nil
    ) throws -> AntigravityQuotaSnapshot? {
        var clauses: [String] = []
        var bindings: [Any?] = []
        if let accountKey { clauses.append("account_key = ?"); bindings.append(accountKey) }
        if let sourceProfile { clauses.append("source_profile = ?"); bindings.append(sourceProfile) }
        let whereClause = clauses.isEmpty ? "" : " WHERE " + clauses.joined(separator: " AND ")
        let json = try database.stringScalar(
            sql: "SELECT payload_json FROM antigravity_quota_cache\(whereClause) ORDER BY captured_at DESC LIMIT 1;",
            bindings: bindings
        )
        guard let json, let data = json.data(using: .utf8) else { return nil }
        return try JSONDecoder().decode(AntigravityQuotaSnapshot.self, from: data)
    }
}
