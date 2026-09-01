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
                SELECT id FROM (
                    SELECT id, ROW_NUMBER() OVER (
                        PARTITION BY provider, account_key, limit_id, slot
                        ORDER BY observed_at DESC, id DESC
                    ) AS recency
                    FROM rate_limit_snapshots
                ) WHERE recency = 1
              );
            """,
            bindings: [cutoff]
        )
    }
}

enum ClaudeQuotaRepository {
    static let legacyAccountKey = "claude-local"

    @discardableResult
    static func persist(_ snapshot: ClaudeUsageSnapshot, database: SQLiteDatabase) throws -> Bool {
        let accountKey = snapshot.accountKey
        let json = String(decoding: try JSONEncoder().encode(snapshot), as: UTF8.self)
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
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 'claude');
                    """,
                    bindings: [
                        accountKey,
                        observedAt,
                        window.id,
                        slot,
                        Int((window.usedPercent * 1_000).rounded()),
                        Int(window.windowDuration / 60),
                        Int64(window.resetAt.timeIntervalSince1970),
                        snapshot.tier,
                        json
                    ]
                )
            }
            try RateLimitSnapshotRetention.prune(database: database, now: snapshot.capturedAt)
        }
        do {
            try migrateIdentity(ClaudeAccountIdentity(
                accountKey: accountKey,
                confidence: snapshot.accountIdentityConfidence ?? .provisionalTokenDerived,
                aliases: snapshot.accountAliases ?? []
            ), database: database)
            return false
        } catch {
            return true
        }
    }

    static func migrateIdentity(_ identity: ClaudeAccountIdentity, database: SQLiteDatabase) throws {
        guard identity.confidence != .provisionalTokenDerived else { return }
        let aliases = identity.aliases.subtracting([legacyAccountKey, identity.accountKey])
        guard !aliases.isEmpty else { return }
        let evidence: ProviderIdentityEvidence
        switch identity.confidence {
        case .stableProviderID:
            evidence = .stableProviderID(identity.accountKey)
        case .verifiedEmail:
            evidence = .verifiedEmail(identity.accountKey)
        case .provisionalTokenDerived:
            return
        }
        try database.transaction {
            let resolved = try aliases.map { key in
                (key, try ProviderAccountAliases.resolve(key, provider: .claude, database: database))
            }
            guard resolved.allSatisfy({ $0.1 == identity.accountKey || aliases.contains($0.1) }) else {
                throw ProviderAccountAliases.MigrationError.conflictingIdentity
            }
            // Move the old root identity first so its aliases stay canonical.
            for (key, target) in resolved where key == target {
                try ProviderAccountAliases.recanonicalize(
                    from: key,
                    to: identity.accountKey,
                    provider: .claude,
                    evidence: evidence,
                    database: database
                )
            }
            for key in aliases {
                try ProviderAccountAliases.attachLegacyAlias(
                    legacyKey: key,
                    canonicalKey: identity.accountKey,
                    provider: .claude,
                    database: database
                )
                try database.executeUpdate(
                    sql: "UPDATE app_metadata SET value = ?, updated_at = unixepoch() WHERE key = 'claude_legacy_account_migration_state' AND value = ?;",
                    bindings: ["migrated:\(identity.accountKey)", "migrated:\(key)"]
                )
            }
        }
    }

    static func migrateLegacyAccount(
        to accountKey: String,
        confirmedAccountKey: String?,
        database: SQLiteDatabase
    ) throws {
        guard accountKey != legacyAccountKey else { return }
        try database.transaction {
            let state = try database.stringScalar(sql: "SELECT value FROM app_metadata WHERE key = 'claude_legacy_account_migration_state';")
            guard state != "conflict", state != "noLegacyRows", state?.hasPrefix("migrated:") != true else { return }
            let resolved = try ProviderAccountAliases.resolve(legacyAccountKey, provider: .claude, database: database)
            let legacyCount = try database.intScalar(
                sql: "SELECT COUNT(*) FROM rate_limit_snapshots WHERE provider = 'claude' AND account_key = ?;",
                bindings: [legacyAccountKey]
            )
            let otherAccountCount = try database.intScalar(
                sql: "SELECT COUNT(*) FROM rate_limit_snapshots WHERE provider = 'claude' AND account_key NOT IN (?, ?);",
                bindings: [legacyAccountKey, accountKey]
            )
            let nextState: String
            if legacyCount == 0 {
                nextState = resolved == legacyAccountKey ? "noLegacyRows" : "migrated:\(resolved)"
            } else if (resolved != legacyAccountKey && resolved != accountKey) || otherAccountCount > 0 {
                nextState = "conflict"
            } else if confirmedAccountKey == accountKey {
                try ProviderAccountAliases.recanonicalize(
                    from: legacyAccountKey,
                    to: accountKey,
                    provider: .claude,
                    evidence: .verifiedCredentialLineage(accountKey),
                    database: database
                )
                nextState = "migrated:\(accountKey)"
            } else {
                nextState = "pending"
            }
            try database.executeUpdate(
                sql: "INSERT OR REPLACE INTO app_metadata (key, value, updated_at) VALUES ('claude_legacy_account_migration_state', ?, unixepoch());",
                bindings: [nextState]
            )
            try database.execute(sql: "DELETE FROM app_metadata WHERE key = 'claude_legacy_account_checked';")
        }
    }

    static func hydrate(accountKey: String, database: SQLiteDatabase) throws -> ClaudeUsageSnapshot? {
        guard let captured = try database.int64Scalar(
            sql: "SELECT MAX(observed_at) FROM rate_limit_snapshots WHERE provider = 'claude' AND account_key = ?;",
            bindings: [accountKey]
        ) else { return nil }
        if let json = try database.stringScalar(
            sql: "SELECT raw_json FROM rate_limit_snapshots WHERE provider = 'claude' AND account_key = ? AND observed_at = ? ORDER BY id DESC LIMIT 1;",
            bindings: [accountKey, captured]
        ), let snapshot = try? JSONDecoder().decode(ClaudeUsageSnapshot.self, from: Data(json.utf8)),
           snapshot.accountKey == accountKey {
            return snapshot
        }
        let rows = try database.executeQuery(
            sql: """
            SELECT limit_id, used_percent_milli, window_duration_mins, resets_at, plan_type
            FROM rate_limit_snapshots
            WHERE provider = 'claude' AND account_key = ? AND observed_at = ?
            ORDER BY id ASC;
            """,
            bindings: [accountKey, captured]
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
            staleFiveHour = try latestExpiredFiveHour(accountKey: accountKey, before: captured, database: database)
        }
        return ClaudeUsageSnapshot(
            capturedAt: capturedAt,
            accountKey: accountKey,
            tier: tier,
            fiveHour: fiveHour,
            staleFiveHour: staleFiveHour,
            sevenDay: sevenDay,
            scopedWeekly: scoped
        )
    }

    private static func latestExpiredFiveHour(
        accountKey: String,
        before captured: Int64,
        database: SQLiteDatabase
    ) throws -> ClaudeUsageSnapshot.Window? {
        try database.executeQuery(
            sql: """
            SELECT used_percent_milli, resets_at
            FROM rate_limit_snapshots
            WHERE provider = 'claude'
              AND account_key = ?
              AND limit_id = 'claude'
              AND observed_at < ?
              AND resets_at <= ?
            ORDER BY observed_at DESC
            LIMIT 1;
            """,
            bindings: [accountKey, captured, captured]
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
    static let minimumGap: TimeInterval = 15

    private let client: ClaudeUsageClient
    private let database: SQLiteDatabase
    private let interval: TimeInterval
    private let onResult: @Sendable (Result<ProviderQuotaRefreshResult<ClaudeUsageSnapshot>, Error>) async -> Void
    private let onCooldown: @Sendable (Date?) async -> Void
    private let onCachedSnapshot: @Sendable (ClaudeUsageSnapshot?) async -> Void
    private var loopTask: Task<Void, Never>?
    private var lastAttemptAt: Date?
    private var cooldownUntil: Date?
    private var rateLimitCount = 0
    private var latestSnapshot: ClaudeUsageSnapshot?
    private var isStopped = false
    private var isPolling = false
    private var pendingSnapshots: [String: ClaudeUsageSnapshot] = [:]
    private var migrationWarnings = Set<String>()

    init(
        client: ClaudeUsageClient = ClaudeUsageClient(),
        database: SQLiteDatabase,
        interval: TimeInterval = ClaudeUsagePoller.defaultInterval,
        initialSnapshot: ClaudeUsageSnapshot? = nil,
        onResult: @escaping @Sendable (Result<ProviderQuotaRefreshResult<ClaudeUsageSnapshot>, Error>) async -> Void,
        onCooldown: @escaping @Sendable (Date?) async -> Void,
        onCachedSnapshot: @escaping @Sendable (ClaudeUsageSnapshot?) async -> Void = { _ in }
    ) {
        self.client = client
        self.database = database
        self.interval = interval
        self.latestSnapshot = initialSnapshot
        self.onResult = onResult
        self.onCooldown = onCooldown
        self.onCachedSnapshot = onCachedSnapshot
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

    func redetectCredentials() async {
        await client.redetectCredentials()
        await pollOnce(force: true)
    }

    func pollOnce(force: Bool = false) async {
        guard !isStopped, !isPolling else { return }
        let now = Date()
        if let cooldownUntil, cooldownUntil > now { return }
        if !force, let lastAttemptAt,
           now.timeIntervalSince(lastAttemptAt) < Self.minimumGap { return }
        lastAttemptAt = now
        isPolling = true
        defer { isPolling = false }
        for (key, pending) in pendingSnapshots {
            do {
                if try ClaudeQuotaRepository.persist(pending, database: database) {
                    migrationWarnings.insert(key)
                }
                pendingSnapshots[key] = nil
            } catch { /* Retain the snapshot for the next scheduled attempt. */ }
        }
        do {
            guard let identity = await client.activeAccountIdentity() else {
                latestSnapshot = nil
                await onCachedSnapshot(nil)
                throw ClaudeUsageClient.FetchError.noCredentials
            }
            guard !isStopped else { return }
            let accountKey = identity.accountKey
            let confirmedKey = await client.legacyAccountKeyForMigration()
            var historySaved = true
            do {
                try ClaudeQuotaRepository.migrateIdentity(identity, database: database)
                try ClaudeQuotaRepository.migrateLegacyAccount(to: accountKey, confirmedAccountKey: confirmedKey, database: database)
            } catch {
                migrationWarnings.insert(accountKey)
            }
            if latestSnapshot?.accountKey != accountKey {
                latestSnapshot = try? ClaudeQuotaRepository.hydrate(accountKey: accountKey, database: database)
                await onCachedSnapshot(latestSnapshot)
            }
            let fresh = try await client.fetch()
                .preservingStaleFiveHour(from: latestSnapshot)
            guard !isStopped else { return }
            let credentialPersistenceWarning = await client.hasCredentialPersistenceWarning()
            latestSnapshot = fresh
            cooldownUntil = nil
            rateLimitCount = 0
            do {
                if try ClaudeQuotaRepository.persist(fresh, database: database) {
                    migrationWarnings.insert(fresh.accountKey)
                }
                pendingSnapshots[fresh.accountKey] = nil
            } catch {
                historySaved = false
                pendingSnapshots[fresh.accountKey] = fresh
            }
            await onCooldown(nil)
            await onResult(.success(ProviderQuotaRefreshResult(
                snapshot: fresh,
                historySaved: historySaved,
                migrationWarning: migrationWarnings.remove(fresh.accountKey) != nil,
                credentialPersistenceWarning: credentialPersistenceWarning
            )))
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
