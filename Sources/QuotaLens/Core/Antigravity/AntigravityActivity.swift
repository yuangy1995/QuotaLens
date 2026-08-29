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
    public let snapshot: AntigravityActivitySnapshot
}

public actor AntigravityActivityStore {
    private let database: SQLiteDatabase
    private let reader: AntigravityLocalStateReader

    public init(database: SQLiteDatabase, reader: AntigravityLocalStateReader = AntigravityLocalStateReader()) {
        self.database = database
        self.reader = reader
    }

    public func scan(preferredProfile: AntigravityStateProfile? = nil) throws -> AntigravityActivityScanSummary {
        let raw = try reader.readRawValue(
            key: "antigravityUnifiedStateSync.trajectorySummaries",
            preferredProfile: preferredProfile
        )
        let records: [AntigravityActivityRecord]
        if let raw {
            records = Self.parseRecords(raw.value, sourceProfile: raw.source.profile.rawValue)
            try replace(records, sourceProfile: raw.source.profile.rawValue)
        } else {
            records = []
        }

        let snapshot = try makeSnapshot(
            sourceProfile: raw?.source.profile.rawValue,
            now: Date()
        )
        return AntigravityActivityScanSummary(
            recordsRead: records.count,
            sourceProfile: raw?.source.profile.rawValue,
            snapshot: snapshot
        )
    }

    public func cachedSnapshot(preferredProfile: AntigravityStateProfile? = nil) throws -> AntigravityActivitySnapshot {
        let profile = preferredProfile?.rawValue
        return try makeSnapshot(sourceProfile: profile, now: Date())
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
        let bindings: [Any?] = sourceProfile.map { [$0] } ?? []
        let whereClause = sourceProfile == nil ? "" : " WHERE source_profile = ?"
        let records = try database.executeQuery(
            sql: """
            SELECT created_at, last_modified_at, last_user_input_at, step_count, project_name
            FROM antigravity_activity_records\(whereClause);
            """,
            bindings: bindings
        ) { statement in
            AntigravityActivityRecord(
                sourceProfile: sourceProfile ?? "",
                trajectoryID: "",
                createdAt: Self.date(sqlite3_column_int64(statement, 0), statement: statement, index: 0),
                lastModifiedAt: Self.date(sqlite3_column_int64(statement, 1), statement: statement, index: 1),
                lastUserInputAt: Self.date(sqlite3_column_int64(statement, 2), statement: statement, index: 2),
                stepCount: max(0, sqlite3_column_int64(statement, 3)),
                projectName: sqlite3_column_type(statement, 4) == SQLITE_NULL
                    ? nil
                    : String(cString: sqlite3_column_text(statement, 4))
            )
        }

        let calendar = UsageDayBucketer.calendar()
        let today = calendar.startOfDay(for: now)
        let sevenDayStart = calendar.date(byAdding: .day, value: -6, to: today) ?? today
        let thirtyDayStart = calendar.date(byAdding: .day, value: -29, to: today) ?? today
        let recent = records.compactMap { record -> (Date, AntigravityActivityRecord)? in
            guard let date = record.activityDate else { return nil }
            return (date, record)
        }
        let thirtyDay = recent.filter { $0.0 >= thirtyDayStart && $0.0 <= now }
        let sevenDay = recent.filter { $0.0 >= sevenDayStart && $0.0 <= now }
        let activeDays = Set(thirtyDay.map { calendar.startOfDay(for: $0.0) }).count
        let stepCount = thirtyDay.reduce(Int64(0)) { partial, item in
            let (sum, overflow) = partial.addingReportingOverflow(item.1.stepCount)
            return overflow ? Int64.max : sum
        }

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
            taskCount7Days: sevenDay.count,
            taskCount30Days: thirtyDay.count,
            activeDays30Days: activeDays,
            stepCount30Days: stepCount,
            latestActivityAt: recent.map(\.0).max(),
            daily: daily,
            projectCounts: projectCounts
        )
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
            lastScanTime = Date()
            statusText = L10n.format(
                "Read %d Antigravity tasks",
                zhHans: "已读取 %d 个 Antigravity 任务",
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
        self.directories = AntigravityLocalStateReader.candidateSources()
            .map { $0.databaseURL.deletingLastPathComponent() }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
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
        try database.executeUpdate(
            sql: """
            INSERT OR REPLACE INTO antigravity_quota_cache (
                source_profile, account_key, captured_at, payload_json
            ) VALUES (?, ?, ?, ?);
            """,
            bindings: [snapshot.sourceProfile, snapshot.accountKey, Int64(snapshot.capturedAt.timeIntervalSince1970), json]
        )
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
