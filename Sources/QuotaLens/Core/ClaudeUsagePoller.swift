import Foundation
import SQLite3

enum RateLimitSnapshotRetention {
    static let retentionSeconds: Int64 = 7 * 24 * 60 * 60

    static func prune(database: SQLiteDatabase, now: Date = Date()) throws {
        let cutoff = Int64(now.timeIntervalSince1970) - retentionSeconds
        try database.executeUpdate(
            sql: """
            DELETE FROM rate_limit_snapshots
            WHERE observed_at < ?
              AND id NOT IN (
                SELECT MAX(id)
                FROM rate_limit_snapshots
                GROUP BY provider, account_key, limit_id, slot
              );
            """,
            bindings: [cutoff]
        )
    }
}

enum ClaudeQuotaRepository {
    static let accountKey = "claude-local"

    static func persist(_ snapshot: ClaudeUsageSnapshot, database: SQLiteDatabase) throws {
        let observedAt = Int64(snapshot.capturedAt.timeIntervalSince1970)
        let rows = [snapshot.fiveHour, snapshot.sevenDay].compactMap { $0 }
            + snapshot.scopedWeekly
        try database.transaction {
            try database.executeUpdate(
                sql: "DELETE FROM rate_limit_snapshots WHERE provider = 'claude' AND account_key = ? AND observed_at = ?;",
                bindings: [accountKey, observedAt]
            )
            for window in rows {
                let slot = window.windowDuration <= 18_000 ? "primary" : "secondary"
                try database.executeUpdate(
                    sql: """
                    INSERT INTO rate_limit_snapshots (
                        account_key, observed_at, limit_id, slot,
                        used_percent_milli, window_duration_mins, resets_at,
                        plan_type, raw_json, provider
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, '{}', 'claude');
                    """,
                    bindings: [
                        accountKey,
                        observedAt,
                        window.id,
                        slot,
                        Int((window.usedPercent * 1_000).rounded()),
                        Int(window.windowDuration / 60),
                        Int64(window.resetAt.timeIntervalSince1970),
                        snapshot.tier
                    ]
                )
            }
            try RateLimitSnapshotRetention.prune(database: database, now: snapshot.capturedAt)
        }
    }

    static func hydrate(database: SQLiteDatabase) throws -> ClaudeUsageSnapshot? {
        guard let captured = try database.int64Scalar(
            sql: "SELECT MAX(observed_at) FROM rate_limit_snapshots WHERE provider = 'claude';"
        ) else { return nil }
        let rows = try database.executeQuery(
            sql: """
            SELECT limit_id, used_percent_milli, window_duration_mins, resets_at, plan_type
            FROM rate_limit_snapshots
            WHERE provider = 'claude' AND observed_at = ?
            ORDER BY id ASC;
            """,
            bindings: [captured]
        ) { statement -> (String, Double, Int, Int64, String?) in
            let id = String(cString: sqlite3_column_text(statement, 0))
            let percent = Double(sqlite3_column_int64(statement, 1)) / 1_000
            let duration = Int(sqlite3_column_int64(statement, 2))
            let reset = sqlite3_column_int64(statement, 3)
            let tier: String? = sqlite3_column_type(statement, 4) == SQLITE_NULL
                ? nil
                : String(cString: sqlite3_column_text(statement, 4))
            return (id, percent, duration, reset, tier)
        }
        guard !rows.isEmpty else { return nil }
        let capturedAt = Date(timeIntervalSince1970: TimeInterval(captured))
        var fiveHour: ClaudeUsageSnapshot.Window?
        var sevenDay: ClaudeUsageSnapshot.Window?
        var scoped: [ClaudeUsageSnapshot.Window] = []
        var tier: String?
        for row in rows {
            if tier == nil { tier = row.4 }
            let durationSeconds = TimeInterval(row.2 * 60)
            let title: String
            switch row.0 {
            case "claude": title = L10n.text("5 小时", "5 Hours")
            case "claude-weekly": title = L10n.text("7 天", "7 Days")
            default:
                title = row.0.split(separator: "-")
                    .map { $0.prefix(1).uppercased() + $0.dropFirst() }
                    .joined(separator: " ") + " · 7d"
            }
            let window = ClaudeUsageSnapshot.Window(
                id: row.0,
                title: title,
                usedPercent: row.1,
                resetAt: Date(timeIntervalSince1970: TimeInterval(row.3)),
                windowDuration: durationSeconds
            )
            if row.0 == "claude" { fiveHour = window }
            else if row.0 == "claude-weekly" { sevenDay = window }
            else { scoped.append(window) }
        }

        var staleFiveHour: ClaudeUsageSnapshot.Window?
        if fiveHour == nil {
            staleFiveHour = try latestExpiredFiveHour(before: captured, database: database)
        }
        return ClaudeUsageSnapshot(
            capturedAt: capturedAt,
            tier: tier,
            fiveHour: fiveHour,
            staleFiveHour: staleFiveHour,
            sevenDay: sevenDay,
            scopedWeekly: scoped
        )
    }

    private static func latestExpiredFiveHour(
        before captured: Int64,
        database: SQLiteDatabase
    ) throws -> ClaudeUsageSnapshot.Window? {
        try database.executeQuery(
            sql: """
            SELECT used_percent_milli, resets_at
            FROM rate_limit_snapshots
            WHERE provider = 'claude'
              AND limit_id = 'claude'
              AND observed_at < ?
              AND resets_at <= ?
            ORDER BY observed_at DESC
            LIMIT 1;
            """,
            bindings: [captured, captured]
        ) { statement in
            ClaudeUsageSnapshot.Window(
                id: "claude",
                title: L10n.text("5 小时", "5 Hours"),
                usedPercent: Double(sqlite3_column_int64(statement, 0)) / 1_000,
                resetAt: Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(statement, 1))),
                windowDuration: 18_000
            )
        }.first
    }
}

actor ClaudeUsagePoller {
    static let defaultInterval: TimeInterval = 600
    static let minimumGap: TimeInterval = 60

    private let client: ClaudeUsageClient
    private let database: SQLiteDatabase
    private let interval: TimeInterval
    private let onResult: @Sendable (Result<ClaudeUsageSnapshot, Error>) async -> Void
    private let onCooldown: @Sendable (Date?) async -> Void
    private var loopTask: Task<Void, Never>?
    private var lastAttemptAt: Date?
    private var cooldownUntil: Date?
    private var rateLimitCount = 0
    private var latestSnapshot: ClaudeUsageSnapshot?
    private var isStopped = false

    init(
        client: ClaudeUsageClient = ClaudeUsageClient(),
        database: SQLiteDatabase,
        interval: TimeInterval = ClaudeUsagePoller.defaultInterval,
        initialSnapshot: ClaudeUsageSnapshot? = nil,
        onResult: @escaping @Sendable (Result<ClaudeUsageSnapshot, Error>) async -> Void,
        onCooldown: @escaping @Sendable (Date?) async -> Void
    ) {
        self.client = client
        self.database = database
        self.interval = interval
        self.latestSnapshot = initialSnapshot
        self.onResult = onResult
        self.onCooldown = onCooldown
    }

    func start() {
        guard loopTask == nil else { return }
        isStopped = false
        loopTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            while !Task.isCancelled {
                await self?.pollOnce()
                guard let self else { return }
                let delay = await self.nextDelay()
                try? await Task.sleep(nanoseconds: UInt64(max(1, delay) * 1_000_000_000))
            }
        }
    }

    func stop() {
        isStopped = true
        loopTask?.cancel()
        loopTask = nil
    }

    func pollOnce(force: Bool = false) async {
        guard !isStopped else { return }
        let now = Date()
        if let cooldownUntil, cooldownUntil > now { return }
        if !force, let lastAttemptAt,
           now.timeIntervalSince(lastAttemptAt) < Self.minimumGap { return }
        lastAttemptAt = now
        do {
            let fresh = try await client.fetch()
                .preservingStaleFiveHour(from: latestSnapshot)
            guard !isStopped else { return }
            latestSnapshot = fresh
            cooldownUntil = nil
            rateLimitCount = 0
            await onCooldown(nil)
            await onResult(.success(fresh))
            try? ClaudeQuotaRepository.persist(fresh, database: database)
        } catch let error as ClaudeUsageClient.FetchError {
            guard !isStopped else { return }
            if case .rateLimited(let retryAfter) = error {
                rateLimitCount += 1
                let fallback: TimeInterval = rateLimitCount == 1 ? 300 : 1_800
                let until = now.addingTimeInterval(max(60, retryAfter ?? fallback))
                cooldownUntil = until
                await onCooldown(until)
            }
            await onResult(.failure(error))
        } catch {
            guard !isStopped else { return }
            await onResult(.failure(error))
        }
    }

    private func nextDelay() -> TimeInterval {
        if let cooldownUntil, cooldownUntil > Date() {
            return cooldownUntil.timeIntervalSinceNow
        }
        return interval
    }
}
