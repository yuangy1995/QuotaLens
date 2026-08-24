// QuotaLens 数据访问与持久化仓储层
// 封装 SQLite 参数化查询与聚合分析

import Foundation
import SQLite3

public final class Repositories: @unchecked Sendable {
    public let db: SQLiteDatabase

    public init(database: SQLiteDatabase) {
        self.db = database
    }

    // MARK: - 账户管理
    public func upsertAccount(_ account: AccountRecord) throws {
        let sql = """
        INSERT INTO accounts (account_key, email_hash, plan_type, first_seen_at, last_seen_at)
        VALUES (?, ?, ?, ?, ?)
        ON CONFLICT(account_key) DO UPDATE SET
            email_hash = excluded.email_hash,
            plan_type = excluded.plan_type,
            last_seen_at = excluded.last_seen_at;
        """
        try db.executeUpdate(sql: sql, bindings: [
            account.accountKey, account.emailHash, account.planType, account.firstSeenAt, account.lastSeenAt
        ])
    }

    public func getLatestAccount() throws -> AccountRecord? {
        let sql = "SELECT account_key, email_hash, plan_type, first_seen_at, last_seen_at FROM accounts ORDER BY last_seen_at DESC LIMIT 1;"
        let list = try db.executeQuery(sql: sql) { stmt -> AccountRecord in
            let key = String(cString: sqlite3_column_text(stmt, 0))
            let email = sqlite3_column_type(stmt, 1) != SQLITE_NULL ? String(cString: sqlite3_column_text(stmt, 1)) : nil
            let plan = sqlite3_column_type(stmt, 2) != SQLITE_NULL ? String(cString: sqlite3_column_text(stmt, 2)) : nil
            let first = sqlite3_column_int64(stmt, 3)
            let last = sqlite3_column_int64(stmt, 4)
            return AccountRecord(accountKey: key, emailHash: email, planType: plan, firstSeenAt: first, lastSeenAt: last)
        }
        return list.first
    }

    public func getAllAccounts() throws -> [AccountRecord] {
        let sql = "SELECT account_key, email_hash, plan_type, first_seen_at, last_seen_at FROM accounts ORDER BY last_seen_at DESC;"
        return try db.executeQuery(sql: sql) { stmt in
            let key = String(cString: sqlite3_column_text(stmt, 0))
            let email = sqlite3_column_type(stmt, 1) != SQLITE_NULL ? String(cString: sqlite3_column_text(stmt, 1)) : nil
            let plan = sqlite3_column_type(stmt, 2) != SQLITE_NULL ? String(cString: sqlite3_column_text(stmt, 2)) : nil
            let first = sqlite3_column_int64(stmt, 3)
            let last = sqlite3_column_int64(stmt, 4)
            return AccountRecord(accountKey: key, emailHash: email, planType: plan, firstSeenAt: first, lastSeenAt: last)
        }
    }

    public func deleteAccount(accountKey: String) throws {
        let sql = "DELETE FROM accounts WHERE account_key = ?;"
        try db.executeUpdate(sql: sql, bindings: [accountKey])
    }

    // MARK: - 账户每日总账快照 (account/usage/read)
    public func insertDailySnapshot(_ snap: AccountDailySnapshotRecord) throws {
        let effectiveState: DailyDataState
        if let previous = try getLatestDailySnapshot(accountKey: snap.accountKey, serverStartDate: snap.serverStartDate),
           previous.dataState == .finalized,
           previous.totalTokens != snap.totalTokens {
            effectiveState = .reopened
        } else {
            effectiveState = snap.dataState
        }

        let sql = """
        INSERT OR REPLACE INTO account_daily_snapshots (account_key, server_start_date, observed_at, total_tokens, data_state, raw_json)
        VALUES (?, ?, ?, ?, ?, ?);
        """
        try db.executeUpdate(sql: sql, bindings: [
            snap.accountKey, snap.serverStartDate, snap.observedAt, snap.totalTokens, effectiveState.rawValue, snap.rawJson
        ])
    }

    public func getDailySnapshots(accountKey: String, limit: Int = 30) throws -> [AccountDailySnapshotRecord] {
        let sql = """
        SELECT s.id, s.account_key, s.server_start_date, s.observed_at, s.total_tokens, s.data_state, s.raw_json
        FROM account_daily_snapshots s
        INNER JOIN (
            SELECT server_start_date, MAX(observed_at) AS latest_observed_at
            FROM account_daily_snapshots
            WHERE account_key = ?
            GROUP BY server_start_date
        ) latest
          ON latest.server_start_date = s.server_start_date
         AND latest.latest_observed_at = s.observed_at
        WHERE s.account_key = ?
        ORDER BY s.server_start_date DESC, s.observed_at DESC
        LIMIT ?;
        """
        return try db.executeQuery(sql: sql, bindings: [accountKey, accountKey, limit]) { stmt in
            let id = sqlite3_column_int64(stmt, 0)
            let acc = String(cString: sqlite3_column_text(stmt, 1))
            let date = String(cString: sqlite3_column_text(stmt, 2))
            let obs = sqlite3_column_int64(stmt, 3)
            let total = sqlite3_column_int64(stmt, 4)
            let stateStr = String(cString: sqlite3_column_text(stmt, 5))
            let json = String(cString: sqlite3_column_text(stmt, 6))
            let state = DailyDataState(rawValue: stateStr) ?? .live
            return AccountDailySnapshotRecord(dbId: id, accountKey: acc, serverStartDate: date, observedAt: obs, totalTokens: total, dataState: state, rawJson: json)
        }
    }

    public func getLatestDailySnapshot(accountKey: String, serverStartDate: String) throws -> AccountDailySnapshotRecord? {
        let sql = """
        SELECT id, account_key, server_start_date, observed_at, total_tokens, data_state, raw_json
        FROM account_daily_snapshots
        WHERE account_key = ? AND server_start_date = ?
        ORDER BY observed_at DESC
        LIMIT 1;
        """
        let list = try db.executeQuery(sql: sql, bindings: [accountKey, serverStartDate]) { stmt in
            let id = sqlite3_column_int64(stmt, 0)
            let acc = String(cString: sqlite3_column_text(stmt, 1))
            let date = String(cString: sqlite3_column_text(stmt, 2))
            let obs = sqlite3_column_int64(stmt, 3)
            let total = sqlite3_column_int64(stmt, 4)
            let stateStr = String(cString: sqlite3_column_text(stmt, 5))
            let json = String(cString: sqlite3_column_text(stmt, 6))
            let state = DailyDataState(rawValue: stateStr) ?? .live
            return AccountDailySnapshotRecord(dbId: id, accountKey: acc, serverStartDate: date, observedAt: obs, totalTokens: total, dataState: state, rawJson: json)
        }
        return list.first
    }

    // MARK: - 额度窗口快照 (account/rateLimits/read)
    public func insertRateLimitSnapshot(_ snap: RateLimitSnapshotRecord) throws {
        let sql = """
        INSERT INTO rate_limit_snapshots (account_key, observed_at, limit_id, slot, used_percent_milli, window_duration_mins, resets_at, plan_type, raw_json)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?);
        """
        try db.executeUpdate(sql: sql, bindings: [
            snap.accountKey, snap.observedAt, snap.limitId, snap.slot, snap.usedPercentMilli, snap.windowDurationMins, snap.resetsAt, snap.planType, snap.rawJson
        ])
    }

    public func getLatestRateLimitSnapshot(accountKey: String, limitId: String? = nil) throws -> RateLimitSnapshotRecord? {
        var bindings: [Any?] = [accountKey]
        let limitClause: String
        if let limitId {
            limitClause = "AND limit_id = ?"
            bindings.append(limitId)
        } else {
            limitClause = ""
        }
        let sql = """
        SELECT id, account_key, observed_at, limit_id, slot, used_percent_milli, window_duration_mins, resets_at, plan_type, raw_json
        FROM rate_limit_snapshots
        WHERE account_key = ? \(limitClause)
        ORDER BY observed_at DESC,
                 CASE WHEN limit_id = 'codex' THEN 0 ELSE 1 END,
                 CASE slot WHEN 'primary' THEN 0 ELSE 1 END,
                 id DESC
        LIMIT 1;
        """
        let list = try db.executeQuery(sql: sql, bindings: bindings) { stmt in
            let id = sqlite3_column_int64(stmt, 0)
            let acc = String(cString: sqlite3_column_text(stmt, 1))
            let obs = sqlite3_column_int64(stmt, 2)
            let lim = String(cString: sqlite3_column_text(stmt, 3))
            let slot = String(cString: sqlite3_column_text(stmt, 4))
            let milli = Int(sqlite3_column_int(stmt, 5))
            let dur = sqlite3_column_type(stmt, 6) != SQLITE_NULL ? Int(sqlite3_column_int(stmt, 6)) : nil
            let resets = sqlite3_column_type(stmt, 7) != SQLITE_NULL ? sqlite3_column_int64(stmt, 7) : nil
            let plan = sqlite3_column_type(stmt, 8) != SQLITE_NULL ? String(cString: sqlite3_column_text(stmt, 8)) : nil
            let json = String(cString: sqlite3_column_text(stmt, 9))
            return RateLimitSnapshotRecord(id: id, accountKey: acc, observedAt: obs, limitId: lim, slot: slot, usedPercentMilli: milli, windowDurationMins: dur, resetsAt: resets, planType: plan, rawJson: json)
        }
        return list.first
    }

    public func getPreviousRateLimitSnapshot(accountKey: String, limitId: String, slot: String, before observedAt: Int64) throws -> RateLimitSnapshotRecord? {
        let sql = """
        SELECT id, account_key, observed_at, limit_id, slot, used_percent_milli, window_duration_mins, resets_at, plan_type, raw_json
        FROM rate_limit_snapshots
        WHERE account_key = ? AND limit_id = ? AND slot = ? AND observed_at < ?
        ORDER BY observed_at DESC
        LIMIT 1;
        """
        let list = try db.executeQuery(sql: sql, bindings: [accountKey, limitId, slot, observedAt]) { stmt in
            let id = sqlite3_column_int64(stmt, 0)
            let acc = String(cString: sqlite3_column_text(stmt, 1))
            let obs = sqlite3_column_int64(stmt, 2)
            let lim = String(cString: sqlite3_column_text(stmt, 3))
            let slot = String(cString: sqlite3_column_text(stmt, 4))
            let milli = Int(sqlite3_column_int(stmt, 5))
            let dur = sqlite3_column_type(stmt, 6) != SQLITE_NULL ? Int(sqlite3_column_int(stmt, 6)) : nil
            let resets = sqlite3_column_type(stmt, 7) != SQLITE_NULL ? sqlite3_column_int64(stmt, 7) : nil
            let plan = sqlite3_column_type(stmt, 8) != SQLITE_NULL ? String(cString: sqlite3_column_text(stmt, 8)) : nil
            let json = String(cString: sqlite3_column_text(stmt, 9))
            return RateLimitSnapshotRecord(id: id, accountKey: acc, observedAt: obs, limitId: lim, slot: slot, usedPercentMilli: milli, windowDurationMins: dur, resetsAt: resets, planType: plan, rawJson: json)
        }
        return list.first
    }

    public func getRateLimitHistory(accountKey: String, limitId: String? = nil, since: Int64) throws -> [RateLimitSnapshotRecord] {
        var bindings: [Any?] = [accountKey]
        let limitClause: String
        if let limitId {
            limitClause = "AND limit_id = ?"
            bindings.append(limitId)
        } else {
            limitClause = ""
        }
        bindings.append(since)
        let sql = """
        SELECT id, account_key, observed_at, limit_id, slot, used_percent_milli, window_duration_mins, resets_at, plan_type, raw_json
        FROM rate_limit_snapshots
        WHERE account_key = ? \(limitClause) AND observed_at >= ?
        ORDER BY observed_at ASC;
        """
        return try db.executeQuery(sql: sql, bindings: bindings) { stmt in
            let id = sqlite3_column_int64(stmt, 0)
            let acc = String(cString: sqlite3_column_text(stmt, 1))
            let obs = sqlite3_column_int64(stmt, 2)
            let lim = String(cString: sqlite3_column_text(stmt, 3))
            let slot = String(cString: sqlite3_column_text(stmt, 4))
            let milli = Int(sqlite3_column_int(stmt, 5))
            let dur = sqlite3_column_type(stmt, 6) != SQLITE_NULL ? Int(sqlite3_column_int(stmt, 6)) : nil
            let resets = sqlite3_column_type(stmt, 7) != SQLITE_NULL ? sqlite3_column_int64(stmt, 7) : nil
            let plan = sqlite3_column_type(stmt, 8) != SQLITE_NULL ? String(cString: sqlite3_column_text(stmt, 8)) : nil
            let json = String(cString: sqlite3_column_text(stmt, 9))
            return RateLimitSnapshotRecord(id: id, accountKey: acc, observedAt: obs, limitId: lim, slot: slot, usedPercentMilli: milli, windowDurationMins: dur, resetsAt: resets, planType: plan, rawJson: json)
        }
    }

    public func getRecentRateLimitSnapshots(accountKey: String? = nil, limit: Int = 50) throws -> [RateLimitSnapshotRecord] {
        var bindings: [Any?] = []
        let whereClause: String
        if let accountKey {
            whereClause = "WHERE account_key = ?"
            bindings.append(accountKey)
        } else {
            whereClause = ""
        }
        bindings.append(limit)

        let sql = """
        SELECT id, account_key, observed_at, limit_id, slot, used_percent_milli, window_duration_mins, resets_at, plan_type, raw_json
        FROM rate_limit_snapshots
        \(whereClause)
        ORDER BY observed_at DESC
        LIMIT ?;
        """
        return try db.executeQuery(sql: sql, bindings: bindings) { stmt in
            let id = sqlite3_column_int64(stmt, 0)
            let acc = String(cString: sqlite3_column_text(stmt, 1))
            let obs = sqlite3_column_int64(stmt, 2)
            let lim = String(cString: sqlite3_column_text(stmt, 3))
            let slot = String(cString: sqlite3_column_text(stmt, 4))
            let milli = Int(sqlite3_column_int(stmt, 5))
            let dur = sqlite3_column_type(stmt, 6) != SQLITE_NULL ? Int(sqlite3_column_int(stmt, 6)) : nil
            let resets = sqlite3_column_type(stmt, 7) != SQLITE_NULL ? sqlite3_column_int64(stmt, 7) : nil
            let plan = sqlite3_column_type(stmt, 8) != SQLITE_NULL ? String(cString: sqlite3_column_text(stmt, 8)) : nil
            let json = String(cString: sqlite3_column_text(stmt, 9))
            return RateLimitSnapshotRecord(id: id, accountKey: acc, observedAt: obs, limitId: lim, slot: slot, usedPercentMilli: milli, windowDurationMins: dur, resetsAt: resets, planType: plan, rawJson: json)
        }
    }

    public func insertThreadUsageSnapshot(_ snapshot: ThreadUsageSnapshotRecord) throws {
        let sql = """
        INSERT INTO thread_usage_snapshots (
            device_id, observed_at, thread_id, model_raw, model_canonical,
            reasoning_effort, service_tier, input_tokens, cached_input_tokens,
            output_tokens, total_tokens, estimated_credits_micros, raw_json
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
        """
        try db.executeUpdate(sql: sql, bindings: [
            snapshot.deviceId, snapshot.observedAt, snapshot.threadId, snapshot.modelRaw,
            snapshot.modelCanonical, snapshot.reasoningEffort, snapshot.serviceTier,
            snapshot.inputTokens, snapshot.cachedInputTokens, snapshot.outputTokens,
            snapshot.totalTokens, snapshot.estimatedCreditsMicros, snapshot.rawJson
        ])
    }

    public func getLatestThreadUsageSnapshots(deviceId: String) throws -> [String: ThreadUsageSnapshotRecord] {
        let sql = """
        SELECT s.id, s.device_id, s.observed_at, s.thread_id, s.model_raw, s.model_canonical,
               s.reasoning_effort, s.service_tier, s.input_tokens, s.cached_input_tokens,
               s.output_tokens, s.total_tokens, s.estimated_credits_micros, s.raw_json
        FROM thread_usage_snapshots s
        WHERE s.device_id = ?
        ORDER BY s.thread_id ASC, s.observed_at DESC, s.id DESC;
        """
        let rows = try db.executeQuery(sql: sql, bindings: [deviceId]) { stmt in
            ThreadUsageSnapshotRecord(
                id: sqlite3_column_int64(stmt, 0),
                deviceId: String(cString: sqlite3_column_text(stmt, 1)),
                observedAt: sqlite3_column_int64(stmt, 2),
                threadId: String(cString: sqlite3_column_text(stmt, 3)),
                modelRaw: sqlite3_column_type(stmt, 4) != SQLITE_NULL ? String(cString: sqlite3_column_text(stmt, 4)) : nil,
                modelCanonical: sqlite3_column_type(stmt, 5) != SQLITE_NULL ? String(cString: sqlite3_column_text(stmt, 5)) : nil,
                reasoningEffort: sqlite3_column_type(stmt, 6) != SQLITE_NULL ? String(cString: sqlite3_column_text(stmt, 6)) : nil,
                serviceTier: sqlite3_column_type(stmt, 7) != SQLITE_NULL ? String(cString: sqlite3_column_text(stmt, 7)) : nil,
                inputTokens: sqlite3_column_int64(stmt, 8),
                cachedInputTokens: sqlite3_column_int64(stmt, 9),
                outputTokens: sqlite3_column_int64(stmt, 10),
                totalTokens: sqlite3_column_int64(stmt, 11),
                estimatedCreditsMicros: sqlite3_column_int64(stmt, 12),
                rawJson: String(cString: sqlite3_column_text(stmt, 13))
            )
        }

        var latestByThread: [String: ThreadUsageSnapshotRecord] = [:]
        for row in rows {
            if latestByThread[row.threadId] == nil {
                latestByThread[row.threadId] = row
            }
        }
        return latestByThread
    }

    // MARK: - 增量用量事件 (Usage Events)
    public func insertUsageEvent(_ event: UsageEventRecord) throws {
        let sql = """
        INSERT OR IGNORE INTO usage_events (
            event_id, device_id, interval_start, interval_end, thread_id,
            model_raw, model_canonical, reasoning_effort, service_tier,
            input_tokens, cached_input_tokens, output_tokens, total_tokens,
            meter_version_id, cycle_id, allocation_quality, source
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
        """
        try db.executeUpdate(sql: sql, bindings: [
            event.eventId, event.deviceId, event.intervalStart, event.intervalEnd, event.threadId,
            event.modelRaw, event.modelCanonical, event.reasoningEffort, event.serviceTier,
            event.inputTokens, event.cachedInputTokens, event.outputTokens, event.totalTokens,
            event.meterVersionId, event.cycleId, event.allocationQuality, event.source
        ])
    }

    public func getUsageEvents(startTime: Int64, endTime: Int64, accountKey: String? = nil) throws -> [UsageEventRecord] {
        var bindings: [Any?] = [startTime, endTime]
        var accountFilter = ""
        if let accountKey {
            let prefix = cycleIdPrefix(for: accountKey)
            accountFilter = " AND substr(COALESCE(cycle_id, ''), 1, ?) = ?"
            bindings.append(prefix.count)
            bindings.append(prefix)
        }

        let sql = """
        SELECT event_id, device_id, interval_start, interval_end, thread_id,
               model_raw, model_canonical, reasoning_effort, service_tier,
               input_tokens, cached_input_tokens, output_tokens, total_tokens,
               meter_version_id, cycle_id, allocation_quality, source
        FROM usage_events
        WHERE interval_start >= ? AND interval_end <= ?\(accountFilter)
        ORDER BY interval_start ASC;
        """
        return try db.executeQuery(sql: sql, bindings: bindings) { stmt in
            let eid = String(cString: sqlite3_column_text(stmt, 0))
            let did = String(cString: sqlite3_column_text(stmt, 1))
            let start = sqlite3_column_int64(stmt, 2)
            let end = sqlite3_column_int64(stmt, 3)
            let tid = sqlite3_column_type(stmt, 4) != SQLITE_NULL ? String(cString: sqlite3_column_text(stmt, 4)) : nil
            let mraw = sqlite3_column_type(stmt, 5) != SQLITE_NULL ? String(cString: sqlite3_column_text(stmt, 5)) : nil
            let mcan = sqlite3_column_type(stmt, 6) != SQLITE_NULL ? String(cString: sqlite3_column_text(stmt, 6)) : nil
            let reff = sqlite3_column_type(stmt, 7) != SQLITE_NULL ? String(cString: sqlite3_column_text(stmt, 7)) : nil
            let stier = sqlite3_column_type(stmt, 8) != SQLITE_NULL ? String(cString: sqlite3_column_text(stmt, 8)) : nil
            let inp = sqlite3_column_int64(stmt, 9)
            let cinp = sqlite3_column_int64(stmt, 10)
            let outp = sqlite3_column_int64(stmt, 11)
            let tot = sqlite3_column_int64(stmt, 12)
            let mver = sqlite3_column_type(stmt, 13) != SQLITE_NULL ? String(cString: sqlite3_column_text(stmt, 13)) : nil
            let cid = sqlite3_column_type(stmt, 14) != SQLITE_NULL ? String(cString: sqlite3_column_text(stmt, 14)) : nil
            let qual = String(cString: sqlite3_column_text(stmt, 15))
            let src = String(cString: sqlite3_column_text(stmt, 16))

            return UsageEventRecord(
                eventId: eid, deviceId: did, intervalStart: start, intervalEnd: end,
                threadId: tid, modelRaw: mraw, modelCanonical: mcan, reasoningEffort: reff, serviceTier: stier,
                inputTokens: inp, cachedInputTokens: cinp, outputTokens: outp, totalTokens: tot,
                meterVersionId: mver, cycleId: cid, allocationQuality: qual, source: src
            )
        }
    }

    public struct DailyLocalUsageSummary: Sendable, Identifiable {
        public var id: String { serverStartDate }
        public let serverStartDate: String
        public let totalTokens: Int64
    }

    public struct ModelUsageSummary: Sendable, Identifiable {
        public var id: String { modelCanonical }
        public let modelCanonical: String
        public let totalInput: Int64
        public let totalCachedInput: Int64
        public let totalOutput: Int64
        public let totalTokens: Int64
    }

    public func deleteLocalSessionBaselineSnapshots(deviceId: String = "macOS_local") throws {
        try db.executeUpdate(
            sql: """
            DELETE FROM thread_usage_snapshots
            WHERE device_id = ?
              AND raw_json LIKE '%local_session_baseline%';
            """,
            bindings: [deviceId]
        )
    }

    public func getLocalSnapshotDailyUsage(deviceId: String = "macOS_local", since: Int64) throws -> [DailyLocalUsageSummary] {
        let sql = """
        SELECT thread_id, observed_at, total_tokens
        FROM thread_usage_snapshots
        WHERE device_id = ? AND observed_at >= ?
        ORDER BY thread_id ASC, observed_at ASC, id ASC;
        """
        let rows = try db.executeQuery(sql: sql, bindings: [deviceId, since]) { stmt in
            (
                threadId: String(cString: sqlite3_column_text(stmt, 0)),
                observedAt: sqlite3_column_int64(stmt, 1),
                totalTokens: sqlite3_column_int64(stmt, 2)
            )
        }

        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"

        var previousTotalByThread: [String: Int64] = [:]
        var totalByDay: [String: Int64] = [:]

        for row in rows {
            let previous = previousTotalByThread[row.threadId]
            previousTotalByThread[row.threadId] = row.totalTokens

            let delta: Int64
            if let previous {
                guard row.totalTokens >= previous else { continue }
                delta = row.totalTokens - previous
            } else {
                delta = row.totalTokens
            }

            guard delta > 0 else { continue }
            let day = formatter.string(from: Date(timeIntervalSince1970: Double(row.observedAt)))
            totalByDay[day, default: 0] += delta
        }

        return totalByDay
            .map { DailyLocalUsageSummary(serverStartDate: $0.key, totalTokens: $0.value) }
            .sorted { $0.serverStartDate > $1.serverStartDate }
    }

    public func getModelUsageSummary(startTime: Int64, endTime: Int64, accountKey: String? = nil) throws -> [ModelUsageSummary] {
        var bindings: [Any?] = [startTime, endTime]
        var accountFilter = ""
        if let accountKey {
            let prefix = cycleIdPrefix(for: accountKey)
            accountFilter = " AND substr(COALESCE(cycle_id, ''), 1, ?) = ?"
            bindings.append(prefix.count)
            bindings.append(prefix)
        }

        let sql = """
        SELECT COALESCE(model_canonical, '未归因') as model,
               SUM(input_tokens) as sum_in,
               SUM(cached_input_tokens) as sum_cached,
               SUM(output_tokens) as sum_out,
               SUM(total_tokens) as sum_tot
        FROM usage_events
        WHERE interval_start >= ? AND interval_end <= ?\(accountFilter)
        GROUP BY COALESCE(model_canonical, '未归因')
        ORDER BY sum_tot DESC;
        """
        return try db.executeQuery(sql: sql, bindings: bindings) { stmt in
            let model = String(cString: sqlite3_column_text(stmt, 0))
            let inp = sqlite3_column_int64(stmt, 1)
            let cinp = sqlite3_column_int64(stmt, 2)
            let outp = sqlite3_column_int64(stmt, 3)
            let tot = sqlite3_column_int64(stmt, 4)
            return ModelUsageSummary(modelCanonical: model, totalInput: inp, totalCachedInput: cinp, totalOutput: outp, totalTokens: tot)
        }
    }

    public func getLatestThreadSnapshotModelSummary(deviceId: String = "macOS_local") throws -> [ModelUsageSummary] {
        let sql = """
        SELECT COALESCE(NULLIF(s.model_canonical, ''), '未知模型') as model,
               SUM(s.input_tokens) as sum_in,
               SUM(s.cached_input_tokens) as sum_cached,
               SUM(s.output_tokens) as sum_out,
               SUM(s.total_tokens) as sum_tot
        FROM thread_usage_snapshots s
        INNER JOIN (
            SELECT thread_id, MAX(id) AS latest_id
            FROM thread_usage_snapshots
            WHERE device_id = ?
            GROUP BY thread_id
        ) latest
          ON latest.latest_id = s.id
        WHERE s.device_id = ?
        GROUP BY COALESCE(NULLIF(s.model_canonical, ''), '未知模型')
        HAVING sum_tot > 0
        ORDER BY sum_tot DESC;
        """
        return try db.executeQuery(sql: sql, bindings: [deviceId, deviceId]) { stmt in
            let model = String(cString: sqlite3_column_text(stmt, 0))
            let inp = sqlite3_column_int64(stmt, 1)
            let cinp = sqlite3_column_int64(stmt, 2)
            let outp = sqlite3_column_int64(stmt, 3)
            let tot = sqlite3_column_int64(stmt, 4)
            return ModelUsageSummary(modelCanonical: model, totalInput: inp, totalCachedInput: cinp, totalOutput: outp, totalTokens: tot)
        }
    }

    public func upsertMeterVersion(_ version: MeterVersionRecord) throws {
        let sql = """
        INSERT OR REPLACE INTO meter_versions (
            meter_version_id, effective_from, effective_to, reason, source, confidence
        ) VALUES (?, ?, ?, ?, ?, ?);
        """
        try db.executeUpdate(sql: sql, bindings: [
            version.meterVersionId, version.effectiveFrom, version.effectiveTo,
            version.reason, version.source, version.confidence
        ])
    }

    public func getMeterVersion(id versionId: String) throws -> MeterVersionRecord? {
        let sql = """
        SELECT meter_version_id, effective_from, effective_to, reason, source, confidence
        FROM meter_versions
        WHERE meter_version_id = ?
        LIMIT 1;
        """
        let list = try db.executeQuery(sql: sql, bindings: [versionId]) { stmt in
            MeterVersionRecord(
                meterVersionId: String(cString: sqlite3_column_text(stmt, 0)),
                effectiveFrom: sqlite3_column_int64(stmt, 1),
                effectiveTo: sqlite3_column_type(stmt, 2) != SQLITE_NULL ? sqlite3_column_int64(stmt, 2) : nil,
                reason: String(cString: sqlite3_column_text(stmt, 3)),
                source: String(cString: sqlite3_column_text(stmt, 4)),
                confidence: String(cString: sqlite3_column_text(stmt, 5))
            )
        }
        return list.first
    }

    // MARK: - 额度周期与分段
    public func upsertQuotaCycle(_ cycle: QuotaCycleRecord) throws {
        let sql = """
        INSERT OR REPLACE INTO quota_cycles (
            cycle_id, account_key, limit_id, slot, start_at, end_at, expected_end_at, window_duration_mins, boundary_reason, is_complete, predecessor_cycle_id
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
        """
        try db.executeUpdate(sql: sql, bindings: [
            cycle.cycleId, cycle.accountKey, cycle.limitId, cycle.slot, cycle.startAt,
            cycle.endAt, cycle.expectedEndAt, cycle.windowDurationMins, cycle.boundaryReason, cycle.isComplete ? 1 : 0, cycle.predecessorCycleId
        ])
    }

    public func upsertQuotaCycleSegment(_ segment: QuotaCycleSegmentRecord) throws {
        let sql = """
        INSERT OR REPLACE INTO quota_cycle_segments (
            segment_id, cycle_id, start_at, end_at, meter_version_id, boundary_quality
        ) VALUES (?, ?, ?, ?, ?, ?);
        """
        try db.executeUpdate(sql: sql, bindings: [
            segment.segmentId, segment.cycleId, segment.startAt, segment.endAt,
            segment.meterVersionId, segment.boundaryQuality
        ])
    }

    public func getLatestQuotaCycle(accountKey: String, limitId: String? = nil) throws -> QuotaCycleRecord? {
        var bindings: [Any?] = [accountKey]
        let limitClause: String
        if let limitId {
            limitClause = "AND limit_id = ?"
            bindings.append(limitId)
        } else {
            limitClause = ""
        }
        let sql = """
        SELECT cycle_id, account_key, limit_id, slot, start_at, end_at, expected_end_at, window_duration_mins, boundary_reason, is_complete, predecessor_cycle_id
        FROM quota_cycles
        WHERE account_key = ? \(limitClause)
        ORDER BY start_at DESC
        LIMIT 1;
        """
        let list = try db.executeQuery(sql: sql, bindings: bindings) { stmt in
            let cid = String(cString: sqlite3_column_text(stmt, 0))
            let acc = String(cString: sqlite3_column_text(stmt, 1))
            let lid = String(cString: sqlite3_column_text(stmt, 2))
            let slot = String(cString: sqlite3_column_text(stmt, 3))
            let start = sqlite3_column_int64(stmt, 4)
            let end = sqlite3_column_type(stmt, 5) != SQLITE_NULL ? sqlite3_column_int64(stmt, 5) : nil
            let exp = sqlite3_column_type(stmt, 6) != SQLITE_NULL ? sqlite3_column_int64(stmt, 6) : nil
            let dur = sqlite3_column_type(stmt, 7) != SQLITE_NULL ? Int(sqlite3_column_int(stmt, 7)) : nil
            let rsn = String(cString: sqlite3_column_text(stmt, 8))
            let comp = sqlite3_column_int(stmt, 9) != 0
            let pred = sqlite3_column_type(stmt, 10) != SQLITE_NULL ? String(cString: sqlite3_column_text(stmt, 10)) : nil
            return QuotaCycleRecord(cycleId: cid, accountKey: acc, limitId: lid, slot: slot, startAt: start, endAt: end, expectedEndAt: exp, windowDurationMins: dur, boundaryReason: rsn, isComplete: comp, predecessorCycleId: pred)
        }
        return list.first
    }

    public func getLatestOpenQuotaCycle(accountKey: String, limitId: String, slot: String) throws -> QuotaCycleRecord? {
        let sql = """
        SELECT cycle_id, account_key, limit_id, slot, start_at, end_at, expected_end_at, window_duration_mins, boundary_reason, is_complete, predecessor_cycle_id
        FROM quota_cycles
        WHERE account_key = ? AND limit_id = ? AND slot = ? AND is_complete = 0
        ORDER BY CASE WHEN boundary_reason = 'active' THEN 0 ELSE 1 END, start_at DESC
        LIMIT 1;
        """
        let list = try db.executeQuery(sql: sql, bindings: [accountKey, limitId, slot]) { stmt in
            let cid = String(cString: sqlite3_column_text(stmt, 0))
            let acc = String(cString: sqlite3_column_text(stmt, 1))
            let lid = String(cString: sqlite3_column_text(stmt, 2))
            let slot = String(cString: sqlite3_column_text(stmt, 3))
            let start = sqlite3_column_int64(stmt, 4)
            let end = sqlite3_column_type(stmt, 5) != SQLITE_NULL ? sqlite3_column_int64(stmt, 5) : nil
            let exp = sqlite3_column_type(stmt, 6) != SQLITE_NULL ? sqlite3_column_int64(stmt, 6) : nil
            let dur = sqlite3_column_type(stmt, 7) != SQLITE_NULL ? Int(sqlite3_column_int(stmt, 7)) : nil
            let rsn = String(cString: sqlite3_column_text(stmt, 8))
            let comp = sqlite3_column_int(stmt, 9) != 0
            let pred = sqlite3_column_type(stmt, 10) != SQLITE_NULL ? String(cString: sqlite3_column_text(stmt, 10)) : nil
            return QuotaCycleRecord(cycleId: cid, accountKey: acc, limitId: lid, slot: slot, startAt: start, endAt: end, expectedEndAt: exp, windowDurationMins: dur, boundaryReason: rsn, isComplete: comp, predecessorCycleId: pred)
        }
        return list.first
    }

    public func getAllQuotaCycles(accountKey: String, limit: Int = 50) throws -> [QuotaCycleRecord] {
        let sql = """
        SELECT cycle_id, account_key, limit_id, slot, start_at, end_at, expected_end_at, window_duration_mins, boundary_reason, is_complete, predecessor_cycle_id
        FROM quota_cycles
        WHERE account_key = ?
        ORDER BY start_at DESC
        LIMIT ?;
        """
        return try db.executeQuery(sql: sql, bindings: [accountKey, limit]) { stmt in
            let cid = String(cString: sqlite3_column_text(stmt, 0))
            let acc = String(cString: sqlite3_column_text(stmt, 1))
            let lid = String(cString: sqlite3_column_text(stmt, 2))
            let slot = String(cString: sqlite3_column_text(stmt, 3))
            let start = sqlite3_column_int64(stmt, 4)
            let end = sqlite3_column_type(stmt, 5) != SQLITE_NULL ? sqlite3_column_int64(stmt, 5) : nil
            let exp = sqlite3_column_type(stmt, 6) != SQLITE_NULL ? sqlite3_column_int64(stmt, 6) : nil
            let dur = sqlite3_column_type(stmt, 7) != SQLITE_NULL ? Int(sqlite3_column_int(stmt, 7)) : nil
            let rsn = String(cString: sqlite3_column_text(stmt, 8))
            let comp = sqlite3_column_int(stmt, 9) != 0
            let pred = sqlite3_column_type(stmt, 10) != SQLITE_NULL ? String(cString: sqlite3_column_text(stmt, 10)) : nil
            return QuotaCycleRecord(cycleId: cid, accountKey: acc, limitId: lid, slot: slot, startAt: start, endAt: end, expectedEndAt: exp, windowDurationMins: dur, boundaryReason: rsn, isComplete: comp, predecessorCycleId: pred)
        }
    }

    public func deleteQuotaCycle(cycleId: String) throws {
        try db.transaction {
            try db.executeUpdate(sql: "DELETE FROM quota_cycle_segments WHERE cycle_id = ?;", bindings: [cycleId])
            try db.executeUpdate(sql: "DELETE FROM quota_cycles WHERE cycle_id = ?;", bindings: [cycleId])
        }
    }

    @discardableResult
    public func repairDuplicateOpenQuotaCycles(accountKey: String, toleranceSeconds: Int64 = 60) throws -> Int {
        let cycles = try getAllQuotaCycles(accountKey: accountKey, limit: 500)
            .filter { !$0.isComplete }
            .sorted {
                if $0.limitId != $1.limitId { return $0.limitId < $1.limitId }
                if $0.slot != $1.slot { return $0.slot < $1.slot }
                return $0.startAt < $1.startAt
            }

        var deleted = 0
        var kept: [QuotaCycleRecord] = []

        for cycle in cycles {
            if let matchIndex = kept.firstIndex(where: { existing in
                existing.accountKey == cycle.accountKey
                    && existing.limitId == cycle.limitId
                    && existing.slot == cycle.slot
                    && abs(existing.startAt - cycle.startAt) <= toleranceSeconds
                    && optionalSecondsNear(existing.expectedEndAt, cycle.expectedEndAt, toleranceSeconds: toleranceSeconds)
                    && existing.windowDurationMins == cycle.windowDurationMins
            }) {
                let existing = kept[matchIndex]
                let keepCycle: QuotaCycleRecord
                let dropCycle: QuotaCycleRecord
                if existing.boundaryReason == "active" || cycle.boundaryReason != "active" {
                    keepCycle = existing
                    dropCycle = cycle
                } else {
                    keepCycle = cycle
                    dropCycle = existing
                    kept[matchIndex] = cycle
                }
                if keepCycle.cycleId != dropCycle.cycleId {
                    try deleteQuotaCycle(cycleId: dropCycle.cycleId)
                    deleted += 1
                }
            } else {
                kept.append(cycle)
            }
        }

        return deleted
    }

    private func optionalSecondsNear(_ lhs: Int64?, _ rhs: Int64?, toleranceSeconds: Int64) -> Bool {
        switch (lhs, rhs) {
        case let (left?, right?):
            return abs(left - right) <= toleranceSeconds
        case (nil, nil):
            return true
        default:
            return false
        }
    }

    private func cycleIdPrefix(for accountKey: String) -> String {
        let safe = accountKey.map { char in
            char.isLetter || char.isNumber ? char : "_"
        }
        return "cycle_\(String(safe))_"
    }

    // MARK: - 周容量估算
    public func upsertQuotaEstimate(_ estimate: QuotaEstimateRecord) throws {
        let sql = """
        INSERT OR REPLACE INTO quota_estimates (
            estimate_id, cycle_id, meter_version_id, capacity_units_micros, confidence_low_micros, confidence_high_micros,
            account_tokens, attributed_tokens, coverage_ppm, percent_span_milli, sample_count, residual_micros, confidence_level, algorithm_version, calculated_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
        """
        try db.executeUpdate(sql: sql, bindings: [
            estimate.estimateId, estimate.cycleId, estimate.meterVersionId,
            estimate.capacityUnitsMicros, estimate.confidenceLowMicros, estimate.confidenceHighMicros,
            estimate.accountTokens, estimate.attributedTokens, estimate.coveragePpm,
            estimate.percentSpanMilli, estimate.sampleCount, estimate.residualMicros,
            estimate.confidenceLevel, estimate.algorithmVersion, estimate.calculatedAt
        ])
    }

    public func getQuotaEstimate(for cycleId: String) throws -> QuotaEstimateRecord? {
        let sql = """
        SELECT estimate_id, cycle_id, meter_version_id, capacity_units_micros, confidence_low_micros, confidence_high_micros,
               account_tokens, attributed_tokens, coverage_ppm, percent_span_milli, sample_count, residual_micros, confidence_level, algorithm_version, calculated_at
        FROM quota_estimates
        WHERE cycle_id = ?
        ORDER BY calculated_at DESC
        LIMIT 1;
        """
        let list = try db.executeQuery(sql: sql, bindings: [cycleId]) { stmt in
            let eid = String(cString: sqlite3_column_text(stmt, 0))
            let cid = String(cString: sqlite3_column_text(stmt, 1))
            let mid = String(cString: sqlite3_column_text(stmt, 2))
            let cap = sqlite3_column_type(stmt, 3) != SQLITE_NULL ? sqlite3_column_int64(stmt, 3) : nil
            let low = sqlite3_column_type(stmt, 4) != SQLITE_NULL ? sqlite3_column_int64(stmt, 4) : nil
            let high = sqlite3_column_type(stmt, 5) != SQLITE_NULL ? sqlite3_column_int64(stmt, 5) : nil
            let accTok = sqlite3_column_int64(stmt, 6)
            let attTok = sqlite3_column_int64(stmt, 7)
            let cov = Int(sqlite3_column_int(stmt, 8))
            let span = Int(sqlite3_column_int(stmt, 9))
            let samples = Int(sqlite3_column_int(stmt, 10))
            let res = sqlite3_column_type(stmt, 11) != SQLITE_NULL ? sqlite3_column_int64(stmt, 11) : nil
            let conf = String(cString: sqlite3_column_text(stmt, 12))
            let algo = String(cString: sqlite3_column_text(stmt, 13))
            let calc = sqlite3_column_int64(stmt, 14)

            return QuotaEstimateRecord(
                estimateId: eid, cycleId: cid, meterVersionId: mid,
                capacityUnitsMicros: cap, confidenceLowMicros: low, confidenceHighMicros: high,
                accountTokens: accTok, attributedTokens: attTok, coveragePpm: cov,
                percentSpanMilli: span, sampleCount: samples, residualMicros: res,
                confidenceLevel: conf, algorithmVersion: algo, calculatedAt: calc
            )
        }
        return list.first
    }

    // MARK: - 额度事件与审计日志
    public func insertQuotaEvent(_ event: QuotaEventRecord) throws {
        let sql = """
        INSERT OR IGNORE INTO quota_events (event_id, occurred_at, event_type, severity, limit_id, old_cycle_id, new_cycle_id, evidence_json)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?);
        """
        try db.executeUpdate(sql: sql, bindings: [
            event.eventId, event.occurredAt, event.eventType, event.severity, event.limitId, event.oldCycleId, event.newCycleId, event.evidenceJson
        ])
    }

    public func getRecentQuotaEvents(limit: Int = 50) throws -> [QuotaEventRecord] {
        let sql = """
        SELECT event_id, occurred_at, event_type, severity, limit_id, old_cycle_id, new_cycle_id, evidence_json
        FROM quota_events
        ORDER BY occurred_at DESC
        LIMIT ?;
        """
        return try db.executeQuery(sql: sql, bindings: [limit]) { stmt in
            let eid = String(cString: sqlite3_column_text(stmt, 0))
            let time = sqlite3_column_int64(stmt, 1)
            let type = String(cString: sqlite3_column_text(stmt, 2))
            let sev = String(cString: sqlite3_column_text(stmt, 3))
            let lid = sqlite3_column_type(stmt, 4) != SQLITE_NULL ? String(cString: sqlite3_column_text(stmt, 4)) : nil
            let oldC = sqlite3_column_type(stmt, 5) != SQLITE_NULL ? String(cString: sqlite3_column_text(stmt, 5)) : nil
            let newC = sqlite3_column_type(stmt, 6) != SQLITE_NULL ? String(cString: sqlite3_column_text(stmt, 6)) : nil
            let json = String(cString: sqlite3_column_text(stmt, 7))
            return QuotaEventRecord(eventId: eid, occurredAt: time, eventType: type, severity: sev, limitId: lid, oldCycleId: oldC, newCycleId: newC, evidenceJson: json)
        }
    }
}
