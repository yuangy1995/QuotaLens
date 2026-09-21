using System.Text.Json;
using Microsoft.Data.Sqlite;
using QuotaLens.Core;

namespace QuotaLens.Infrastructure;

/// <summary>Windows-only database, never the macOS file. One background writer; bounded concurrent WAL readers.
/// Checkpoints and derived facts commit together. No conversation bodies or credentials are stored here.</summary>
public sealed class LocalDatabase(string root) : IDisposable
{
    public string Root { get; } = SecureFiles.LocalPath(root);
    public string DatabasePath => Path.Combine(Root, "quotalens.sqlite");
    private readonly SemaphoreSlim writer = new(1, 1);
    private readonly SemaphoreSlim readers = new(2, 2);
    private bool initialized;
    public async Task InitializeAsync(CancellationToken ct = default)
    {
        await writer.WaitAsync(ct).ConfigureAwait(false);
        try
        {
            await Task.Run(() => {
                ct.ThrowIfCancellationRequested(); SecureFiles.CreateDirectory(Root);
                if (File.Exists(DatabasePath)) SecureFiles.RequireRegularFile(DatabasePath);
                using var connection = Open(readOnly: false);
                var version = Convert.ToInt32(Scalar(connection, null, "PRAGMA user_version;"));
                if (version > 1) throw new InvalidDataException("This database was created by a newer QuotaLens version. It was not modified.");
                Execute(connection, null, "PRAGMA journal_mode=WAL; PRAGMA synchronous=FULL;");
                using var transaction = connection.BeginTransaction();
                Execute(connection, transaction, """
                    CREATE TABLE IF NOT EXISTS accounts(key TEXT PRIMARY KEY, provider TEXT NOT NULL, json TEXT NOT NULL);
                    CREATE TABLE IF NOT EXISTS metadata(key TEXT PRIMARY KEY, json TEXT NOT NULL);
                    CREATE TABLE IF NOT EXISTS discovery_exclusions(account_key TEXT PRIMARY KEY);
                    CREATE TABLE IF NOT EXISTS quota_snapshots(account_key TEXT NOT NULL, observed_at INTEGER NOT NULL, json TEXT NOT NULL,
                        PRIMARY KEY(account_key,observed_at)) WITHOUT ROWID;
                    CREATE TABLE IF NOT EXISTS capacity_observations(account_key TEXT NOT NULL, observed_at INTEGER NOT NULL, json TEXT NOT NULL,
                        PRIMARY KEY(account_key,observed_at)) WITHOUT ROWID;
                    CREATE TABLE IF NOT EXISTS sources(id TEXT PRIMARY KEY, provider TEXT NOT NULL, path TEXT NOT NULL, checkpoint TEXT NOT NULL);
                    CREATE TABLE IF NOT EXISTS sessions(source_id TEXT NOT NULL, session_id TEXT NOT NULL, provider TEXT NOT NULL, path TEXT NOT NULL,
                        project TEXT NOT NULL, updated_at INTEGER NOT NULL, model TEXT NOT NULL, PRIMARY KEY(source_id,session_id));
                    CREATE TABLE IF NOT EXISTS usage_events(id TEXT PRIMARY KEY, provider TEXT NOT NULL, session_id TEXT NOT NULL, at INTEGER NOT NULL,
                        model TEXT NOT NULL, effort TEXT, input INTEGER NOT NULL, cached INTEGER NOT NULL, output INTEGER NOT NULL, cache_write INTEGER NOT NULL);
                    CREATE TABLE IF NOT EXISTS event_sources(source_id TEXT NOT NULL, event_id TEXT NOT NULL, PRIMARY KEY(source_id,event_id));
                    CREATE INDEX IF NOT EXISTS event_membership ON event_sources(event_id);
                    CREATE INDEX IF NOT EXISTS usage_provider_time ON usage_events(provider,at);
                    CREATE INDEX IF NOT EXISTS usage_time ON usage_events(at);
                    CREATE INDEX IF NOT EXISTS session_provider_time ON sessions(provider,updated_at DESC);
                    CREATE TABLE IF NOT EXISTS activities(id TEXT NOT NULL, profile TEXT NOT NULL, json TEXT NOT NULL, PRIMARY KEY(id,profile));
                    CREATE TABLE IF NOT EXISTS redemptions(account_key TEXT NOT NULL, credit_id TEXT NOT NULL, json TEXT NOT NULL,
                        PRIMARY KEY(account_key,credit_id));
                    CREATE TABLE IF NOT EXISTS trash(id TEXT PRIMARY KEY, json TEXT NOT NULL);
                    CREATE TABLE IF NOT EXISTS notifications(key TEXT PRIMARY KEY, at INTEGER NOT NULL);
                    PRAGMA user_version=1;
                    """);
                transaction.Commit(); initialized = true;
            }, ct).ConfigureAwait(false);
        }
        finally { writer.Release(); }
    }
    private SqliteConnection Open(bool readOnly)
    {
        var connection = new SqliteConnection(new SqliteConnectionStringBuilder {
            DataSource = DatabasePath, Mode = readOnly ? SqliteOpenMode.ReadOnly : SqliteOpenMode.ReadWriteCreate,
            Pooling = true, DefaultTimeout = 5 }.ToString());
        connection.Open(); Execute(connection, null, "PRAGMA foreign_keys=ON; PRAGMA busy_timeout=5000;");
        return connection;
    }
    internal async Task<T> ReadAsync<T>(Func<SqliteConnection, T> operation, CancellationToken ct = default)
    {
        if (!initialized) throw new InvalidOperationException("Local storage has not initialized.");
        await readers.WaitAsync(ct).ConfigureAwait(false);
        try { return await Task.Run(() => { ct.ThrowIfCancellationRequested(); using var connection = Open(true); return operation(connection); }, ct).ConfigureAwait(false); }
        finally { readers.Release(); }
    }
    internal async Task<T> WriteAsync<T>(Func<SqliteConnection, SqliteTransaction, T> operation, CancellationToken ct = default)
    {
        if (!initialized) throw new InvalidOperationException("Local storage has not initialized.");
        await writer.WaitAsync(ct).ConfigureAwait(false);
        try
        {
            return await Task.Run(() => {
                ct.ThrowIfCancellationRequested(); using var connection = Open(false); using var transaction = connection.BeginTransaction();
                var result = operation(connection, transaction); ct.ThrowIfCancellationRequested(); transaction.Commit(); return result;
            }, ct).ConfigureAwait(false);
        }
        finally { writer.Release(); }
    }
    internal static SqliteCommand Command(SqliteConnection connection, SqliteTransaction? transaction, string sql, params (string Name, object? Value)[] values)
    {
        var command = connection.CreateCommand(); command.Transaction = transaction; command.CommandText = sql;
        foreach (var (name, value) in values) command.Parameters.AddWithValue(name, value ?? DBNull.Value);
        return command;
    }
    internal static int Execute(SqliteConnection connection, SqliteTransaction? transaction, string sql, params (string Name, object? Value)[] values)
    { using var command = Command(connection, transaction, sql, values); return command.ExecuteNonQuery(); }
    internal static object? Scalar(SqliteConnection connection, SqliteTransaction? transaction, string sql, params (string Name, object? Value)[] values)
    { using var command = Command(connection, transaction, sql, values); return command.ExecuteScalar(); }
    internal static string Encode<T>(T value) => JsonSerializer.Serialize(value, JsonTools.Options);
    internal static T Decode<T>(string json) => JsonSerializer.Deserialize<T>(json, JsonTools.Options) ?? throw new InvalidDataException("A saved record is incomplete.");
    internal static List<T> JsonRows<T>(SqliteConnection connection, string sql, params (string Name, object? Value)[] values)
    {
        using var command = Command(connection, null, sql, values); using var reader = command.ExecuteReader(); var result = new List<T>();
        while (reader.Read()) result.Add(Decode<T>(reader.GetString(0))); return result;
    }
    public Task<T?> GetMetadataAsync<T>(string key, CancellationToken ct = default) where T : class => ReadAsync(connection => {
        var json = Scalar(connection, null, "SELECT json FROM metadata WHERE key=$key;", ("$key", key)) as string;
        return json is null ? null : Decode<T>(json);
    }, ct);
    public Task PutMetadataAsync<T>(string key, T value, CancellationToken ct = default)
    {
        if (value is Credential or QuotaLens.Providers.GoogleOAuthConfiguration) throw new InvalidOperationException("Credentials must use the encrypted vault.");
        var json = Encode(value);
        return WriteAsync((connection, transaction) => Execute(connection, transaction,
            "INSERT INTO metadata VALUES($key,$json) ON CONFLICT(key) DO UPDATE SET json=excluded.json;", ("$key", key), ("$json", json)), ct);
    }
    public Task<IReadOnlyList<Account>> AccountsAsync(CancellationToken ct = default) => ReadAsync<IReadOnlyList<Account>>(connection =>
        JsonRows<Account>(connection, "SELECT json FROM accounts ORDER BY provider,key;"), ct);
    public Task SaveAccountAsync(Account account, bool explicitImport = false, CancellationToken ct = default) => WriteAsync((connection, transaction) => {
        Execute(connection, transaction, "INSERT INTO accounts VALUES($key,$provider,$json) ON CONFLICT(key) DO UPDATE SET json=excluded.json;",
            ("$key", account.Key), ("$provider", account.Provider.ToString()), ("$json", Encode(account)));
        if (explicitImport) Execute(connection, transaction, "DELETE FROM discovery_exclusions WHERE account_key=$key;", ("$key", account.Key));
        return true;
    }, ct);
    public Task RemoveAccountAsync(string key, CancellationToken ct = default) => WriteAsync((connection, transaction) => {
        Execute(connection, transaction, "DELETE FROM accounts WHERE key=$key;", ("$key", key));
        Execute(connection, transaction, "INSERT OR IGNORE INTO discovery_exclusions VALUES($key);", ("$key", key));
        // Deliberately retain snapshots, observations, redemptions and local history.
        return true;
    }, ct);
    public Task<bool> IsDiscoveryExcludedAsync(string key, CancellationToken ct = default) => ReadAsync(connection =>
        Scalar(connection, null, "SELECT 1 FROM discovery_exclusions WHERE account_key=$key;", ("$key", key)) is not null, ct);
    public Task SaveQuotaAsync(QuotaSnapshot snapshot, string? subscriptionPlan = null, CancellationToken ct = default)
    {
        snapshot.Validate();
        return WriteAsync((connection, transaction) => {
            Execute(connection, transaction, "INSERT INTO quota_snapshots VALUES($key,$at,$json) ON CONFLICT(account_key,observed_at) DO UPDATE SET json=excluded.json;",
                ("$key", snapshot.AccountKey), ("$at", snapshot.ObservedAt.ToUnixTimeMilliseconds()), ("$json", Encode(snapshot)));
            if (snapshot.Provider == Provider.Codex)
            {
                var windows = snapshot.Pools.Where(x => x.Id.StartsWith("codex:", StringComparison.Ordinal) && x.WindowMinutes is 300 or 10080 && x.ResetsAt is not null)
                    .Select(x => new CapacitySample(x.WindowMinutes!.Value, x.UsedPercent, x.ResetsAt!.Value.ToUnixTimeSeconds())).ToArray();
                var observation = new CapacityObservation(snapshot.AccountKey, snapshot.ObservedAt.ToUnixTimeSeconds(), snapshot.LifetimeTokens,
                    snapshot.Plan?.ToLowerInvariant(), subscriptionPlan, windows);
                Execute(connection, transaction, "INSERT INTO capacity_observations VALUES($key,$at,$json) ON CONFLICT(account_key,observed_at) DO UPDATE SET json=excluded.json;",
                    ("$key", snapshot.AccountKey), ("$at", observation.ObservedAt), ("$json", Encode(observation)));
            }
            return true;
        }, ct);
    }
    public Task<QuotaSnapshot?> LatestQuotaAsync(string key, CancellationToken ct = default) => ReadAsync(connection =>
        JsonRows<QuotaSnapshot>(connection, "SELECT json FROM quota_snapshots WHERE account_key=$key ORDER BY observed_at DESC LIMIT 1;", ("$key", key)).FirstOrDefault()?.Validate(), ct);
    public Task<IReadOnlyList<QuotaSnapshot>> QuotaHistoryAsync(string key, int offset = 0, int limit = 100, CancellationToken ct = default) => ReadAsync<IReadOnlyList<QuotaSnapshot>>(connection =>
        JsonRows<QuotaSnapshot>(connection, "SELECT json FROM quota_snapshots WHERE account_key=$key ORDER BY observed_at DESC LIMIT $limit OFFSET $offset;",
            ("$key", key), ("$limit", Math.Clamp(limit, 1, 500)), ("$offset", Math.Max(0, offset))), ct);
    public Task<IReadOnlyList<CapacityWindow>> ForecastAsync(string key, CancellationToken ct = default) => ReadAsync<IReadOnlyList<CapacityWindow>>(connection => {
        // Bound UI replay memory. Raw observations are retained; this is a query window, not a deletion policy.
        var rows = JsonRows<CapacityObservation>(connection, "SELECT json FROM capacity_observations WHERE account_key=$key ORDER BY observed_at DESC LIMIT 50000;", ("$key", key));
        return CapacityForecast.Analyze(rows, key, DateTimeOffset.UtcNow.ToUnixTimeSeconds());
    }, ct);
    public Task<IReadOnlyList<SourceCheckpoint>> SourcesAsync(Provider? provider = null, CancellationToken ct = default) => ReadAsync<IReadOnlyList<SourceCheckpoint>>(connection =>
        JsonRows<SourceCheckpoint>(connection, "SELECT checkpoint FROM sources WHERE ($provider IS NULL OR provider=$provider) ORDER BY path;", ("$provider", provider?.ToString())), ct);
    internal static SourceCheckpoint? Source(SqliteConnection connection, SqliteTransaction transaction, string id)
    {
        var json = Scalar(connection, transaction, "SELECT checkpoint FROM sources WHERE id=$id;", ("$id", id)) as string;
        return json is null ? null : Decode<SourceCheckpoint>(json);
    }
    internal static void SaveSource(SqliteConnection connection, SqliteTransaction transaction, SourceCheckpoint source) => Execute(connection, transaction,
        "INSERT INTO sources VALUES($id,$provider,$path,$json) ON CONFLICT(id) DO UPDATE SET path=excluded.path,checkpoint=excluded.checkpoint;",
        ("$id", source.Id), ("$provider", source.Provider.ToString()), ("$path", source.Path), ("$json", Encode(source)));
    internal static void RemoveSource(SqliteConnection connection, SqliteTransaction transaction, string id)
    {
        Execute(connection, transaction, "DELETE FROM event_sources WHERE source_id=$id; DELETE FROM sessions WHERE source_id=$id; DELETE FROM sources WHERE id=$id;", ("$id", id));
        Execute(connection, transaction, "DELETE FROM usage_events WHERE NOT EXISTS(SELECT 1 FROM event_sources WHERE event_id=usage_events.id);");
    }
    internal static void PutSession(SqliteConnection connection, SqliteTransaction transaction, string source, string session, Provider provider,
        string path, string project, DateTimeOffset updatedAt, string model) => Execute(connection, transaction,
        """
        INSERT INTO sessions VALUES($source,$session,$provider,$path,$project,$at,$model)
        ON CONFLICT(source_id,session_id) DO UPDATE SET project=excluded.project,updated_at=MAX(sessions.updated_at,excluded.updated_at),
            model=CASE WHEN excluded.model='unknown' THEN sessions.model ELSE excluded.model END;
        """, ("$source", source), ("$session", session), ("$provider", provider.ToString()), ("$path", path),
        ("$project", project), ("$at", updatedAt.ToUnixTimeMilliseconds()), ("$model", model));
    internal static void PutEvent(SqliteConnection connection, SqliteTransaction transaction, UsageEvent item)
    {
        item.Tokens.Validate();
        Execute(connection, transaction, """
            INSERT INTO usage_events VALUES($id,$provider,$session,$at,$model,$effort,$input,$cached,$output,$write)
            ON CONFLICT(id) DO UPDATE SET at=excluded.at,model=excluded.model,effort=excluded.effort,input=excluded.input,
                cached=excluded.cached,output=excluded.output,cache_write=excluded.cache_write WHERE excluded.at>=usage_events.at;
            """, ("$id", item.Id), ("$provider", item.Provider.ToString()), ("$session", item.SessionId), ("$at", item.At.ToUnixTimeMilliseconds()),
            ("$model", item.Model), ("$effort", item.Effort), ("$input", item.Tokens.Input), ("$cached", item.Tokens.CachedInput),
            ("$output", item.Tokens.Output), ("$write", item.Tokens.CacheWrite));
        Execute(connection, transaction, "INSERT OR IGNORE INTO event_sources VALUES($source,$id);", ("$source", item.SourceId), ("$id", item.Id));
    }
    public Task<IReadOnlyList<SessionSummary>> SessionsAsync(Provider? provider, string search = "", int offset = 0, int limit = 100, CancellationToken ct = default) => ReadAsync<IReadOnlyList<SessionSummary>>(connection => {
        string escaped = "%" + search.Replace("\\", "\\\\").Replace("%", "\\%").Replace("_", "\\_") + "%";
        using var command = Command(connection, null, """
            SELECT s.session_id,s.provider,s.source_id,s.path,s.project,s.updated_at,s.model,
              COALESCE((SELECT SUM(e.input+e.output+e.cache_write) FROM usage_events e JOIN event_sources m ON m.event_id=e.id
                WHERE m.source_id=s.source_id AND e.session_id=s.session_id),0),
              (SELECT COUNT(*) FROM usage_events e JOIN event_sources m ON m.event_id=e.id WHERE m.source_id=s.source_id AND e.session_id=s.session_id)
            FROM sessions s WHERE ($provider IS NULL OR s.provider=$provider)
              AND (s.project LIKE $search ESCAPE '\' OR s.path LIKE $search ESCAPE '\' OR s.session_id LIKE $search ESCAPE '\')
            ORDER BY s.updated_at DESC,s.source_id LIMIT $limit OFFSET $offset;
            """, ("$provider", provider?.ToString()), ("$search", escaped), ("$limit", Math.Clamp(limit, 1, 500)), ("$offset", Math.Max(0, offset)));
        using var reader = command.ExecuteReader(); var rows = new List<SessionSummary>();
        while (reader.Read()) rows.Add(new(reader.GetString(0), Enum.Parse<Provider>(reader.GetString(1)), reader.GetString(2), reader.GetString(3), reader.GetString(4),
            DateTimeOffset.FromUnixTimeMilliseconds(reader.GetInt64(5)), reader.GetInt64(7), reader.GetInt32(8), reader.GetString(6)));
        return rows;
    }, ct);
    private sealed record GroupedUsage(string Provider, string Day, string Model, string Effort, TokenUsage Usage, int Count, decimal? Cost);
    public Task<UsageReport> UsageAsync(Provider? provider, DateTimeOffset from, DateTimeOffset to, IReadOnlyList<Price> catalog, CancellationToken ct = default) => ReadAsync(connection => {
        var rows = new List<GroupedUsage>();
        using (var command = Command(connection, null, """
            SELECT provider,date(at/1000,'unixepoch','localtime'),model,COALESCE(effort,'unknown'),
                   SUM(input),SUM(cached),SUM(output),SUM(cache_write),COUNT(*)
            FROM usage_events WHERE ($provider IS NULL OR provider=$provider) AND at >= $from AND at < $to
            GROUP BY provider,date(at/1000,'unixepoch','localtime'),model,effort,(cache_write>0);
            """, ("$provider", provider?.ToString()), ("$from", from.ToUnixTimeMilliseconds()), ("$to", to.ToUnixTimeMilliseconds())))
        using (var reader = command.ExecuteReader())
        {
            while (reader.Read())
            {
                ct.ThrowIfCancellationRequested();
                var tokens = new TokenUsage(reader.GetInt64(4), reader.GetInt64(5), reader.GetInt64(6), reader.GetInt64(7)).Validate();
                var model = reader.GetString(2);
                // Unknown cache-write duration cannot be billed accurately from the aggregate schema.
                decimal? cost = tokens.CacheWrite > 0 ? null : Pricing.Estimate(new UsageEvent("aggregate", Enum.Parse<Provider>(reader.GetString(0)), "", "", from, model, null, tokens), catalog);
                rows.Add(new(reader.GetString(0), reader.GetString(1), model, reader.GetString(3), tokens, reader.GetInt32(8), cost));
            }
        }
        int sessions = Convert.ToInt32(Scalar(connection, null,
            "SELECT COUNT(*) FROM (SELECT provider,session_id FROM usage_events WHERE ($provider IS NULL OR provider=$provider) AND at >= $from AND at < $to GROUP BY provider,session_id);",
            ("$provider", provider?.ToString()), ("$from", from.ToUnixTimeMilliseconds()), ("$to", to.ToUnixTimeMilliseconds())));
        TokenUsage total = new(); foreach (var row in rows) total += row.Usage;
        decimal? Cost(IEnumerable<GroupedUsage> values) { var priced = values.Where(x => x.Cost is not null).ToArray(); return priced.Length == 0 ? null : priced.Sum(x => x.Cost!.Value); }
        IReadOnlyList<UsageBucket> Buckets(Func<GroupedUsage, string> key) => rows.GroupBy(key).Select(group => new UsageBucket(group.Key,
            group.Sum(x => x.Usage.Total), group.Sum(x => x.Count), Cost(group), group.Where(x => x.Cost is null).Sum(x => x.Count))).ToArray();
        return new UsageReport(total.Total, total.Input, total.CachedInput, total.Output, total.CacheWrite, sessions, Cost(rows),
            rows.Where(x => x.Cost is null).Sum(x => x.Count), Buckets(x => x.Day).OrderBy(x => x.Label).ToArray(),
            Buckets(x => x.Model).OrderByDescending(x => x.Tokens).ToArray(), Buckets(x => x.Effort).OrderByDescending(x => x.Tokens).ToArray());
    }, ct);
    public Task SaveActivitiesAsync(string profile, IReadOnlyList<ActivitySummary> records, CancellationToken ct = default) => WriteAsync((connection, transaction) => {
        // Update only a successfully parsed profile. Missing/unreadable profiles are not cleared.
        Execute(connection, transaction, "DELETE FROM activities WHERE profile=$profile;", ("$profile", profile));
        foreach (var item in records) Execute(connection, transaction, "INSERT OR REPLACE INTO activities VALUES($id,$profile,$json);",
            ("$id", item.Id), ("$profile", profile), ("$json", Encode(item)));
        return true;
    }, ct);
    public Task<IReadOnlyList<ActivitySummary>> ActivitiesAsync(CancellationToken ct = default) => ReadAsync<IReadOnlyList<ActivitySummary>>(connection =>
        JsonRows<ActivitySummary>(connection, "SELECT json FROM activities ORDER BY profile,id;"), ct);
    public Task<PendingRedemption> PrepareRedemptionAsync(string account, string credit, CancellationToken ct = default) => WriteAsync((connection, transaction) => {
        var json = Scalar(connection, transaction, "SELECT json FROM redemptions WHERE account_key=$account AND credit_id=$credit;", ("$account", account), ("$credit", credit)) as string;
        if (json is not null) return Decode<PendingRedemption>(json);
        var value = new PendingRedemption(account, credit, Guid.NewGuid().ToString("N"), DateTimeOffset.UtcNow);
        Execute(connection, transaction, "INSERT INTO redemptions VALUES($account,$credit,$json);", ("$account", account), ("$credit", credit), ("$json", Encode(value)));
        return value;
    }, ct);
    public Task SaveRedemptionAsync(PendingRedemption value, CancellationToken ct = default) => WriteAsync((connection, transaction) => Execute(connection, transaction,
        "UPDATE redemptions SET json=$json WHERE account_key=$account AND credit_id=$credit;", ("$json", Encode(value)), ("$account", value.AccountKey), ("$credit", value.CreditId)), ct);
    public Task<IReadOnlyList<PendingRedemption>> RedemptionsAsync(string account, CancellationToken ct = default) => ReadAsync<IReadOnlyList<PendingRedemption>>(connection =>
        JsonRows<PendingRedemption>(connection, "SELECT json FROM redemptions WHERE account_key=$account;", ("$account", account)), ct);
    public Task SaveTrashAsync(TrashEntry value, CancellationToken ct = default) => WriteAsync((connection, transaction) => Execute(connection, transaction,
        "INSERT INTO trash VALUES($id,$json) ON CONFLICT(id) DO UPDATE SET json=excluded.json;", ("$id", value.Id), ("$json", Encode(value))), ct);
    public Task<IReadOnlyList<TrashEntry>> TrashAsync(CancellationToken ct = default) => ReadAsync<IReadOnlyList<TrashEntry>>(connection => JsonRows<TrashEntry>(connection, "SELECT json FROM trash;"), ct);
    public Task ForgetSourceAsync(string source, CancellationToken ct = default) => WriteAsync((connection, transaction) => { RemoveSource(connection, transaction, source); return true; }, ct);
    public Task<bool> MarkNotificationAsync(string key, CancellationToken ct = default) => WriteAsync((connection, transaction) => Execute(connection, transaction,
        "INSERT OR IGNORE INTO notifications VALUES($key,$at);", ("$key", key), ("$at", DateTimeOffset.UtcNow.ToUnixTimeSeconds())) == 1, ct);
    public Task<string> DiagnosticsAsync(CancellationToken ct = default) => ReadAsync(connection => {
        long Count(string table) => Convert.ToInt64(Scalar(connection, null, "SELECT COUNT(*) FROM " + table + ";"));
        return Encode(new { schema = 1, platform = "windows", capturedAt = DateTimeOffset.UtcNow,
            accounts = Count("accounts"), snapshots = Count("quota_snapshots"), sources = Count("sources"),
            sessions = Count("sessions"), usageEvents = Count("usage_events"), observations = Count("capacity_observations"),
            activityRecords = Count("activities"), pendingTrashEntries = Count("trash") });
    }, ct);
    public void Dispose() { SqliteConnection.ClearAllPools(); writer.Dispose(); readers.Dispose(); }
}
