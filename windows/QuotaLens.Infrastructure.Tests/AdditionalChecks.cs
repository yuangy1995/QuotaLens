using System.Text;
using Microsoft.Data.Sqlite;
using QuotaLens.Core;
using QuotaLens.Infrastructure;

internal static class AdditionalChecks
{
    internal static async Task RunAsync(string root, Action<bool, string> check, Func<Func<Task>, string, Task> reject)
    {
        byte[] Join(params byte[][] values) => values.SelectMany(x => x).ToArray();
        byte[] Var(ulong number) { var result = new List<byte>(); do { byte next = (byte)(number & 127); number >>= 7; result.Add((byte)(next | (number > 0 ? 128 : 0))); } while (number > 0); return result.ToArray(); }
        byte[] Field(int id, byte[] value) => Join(Var((ulong)(id * 8 + 2)), Var((ulong)value.Length), value);
        byte[] Text(int id, string text) => Field(id, Encoding.UTF8.GetBytes(text));
        byte[] Integer(int id, ulong value) => Join(Var((ulong)(id * 8)), Var(value));
        string Map(string key, byte[] value) => Convert.ToBase64String(Field(1, Join(Text(1, key), Field(2, Text(1, Convert.ToBase64String(value))))));
        var expiry = DateTimeOffset.Parse("2030-01-01T00:00:00Z");
        string path = Path.Combine(root, "state.vscdb");
        string summary = Map("synthetic-task", Join(Text(1, "PRIVATE-SUMMARY-MUST-NOT-BE-SAVED"), Integer(2, 7), Field(3, Integer(1, (ulong)expiry.ToUnixTimeSeconds()))));
        using (var db = new SqliteConnection(new SqliteConnectionStringBuilder { DataSource = path, Pooling = false }.ToString())) {
            await db.OpenAsync(); using var command = db.CreateCommand();
            command.CommandText = "CREATE TABLE ItemTable(key TEXT PRIMARY KEY,value TEXT); INSERT INTO ItemTable VALUES($key,$value)";
            command.Parameters.AddWithValue("$key", "antigravityUnifiedStateSync.trajectorySummaries");
            command.Parameters.AddWithValue("$value", summary); await command.ExecuteNonQueryAsync();
        }
        byte[] originalDatabase = await File.ReadAllBytesAsync(path);
        var records = await AntigravityActivityReader.ReadAsync(path, CancellationToken.None);
        check(records.Count == 1 && records[0].Steps == 7 && !System.Text.Json.JsonSerializer.Serialize(records).Contains("PRIVATE-SUMMARY"), "task aggregation excludes summary text");
        check(originalDatabase.SequenceEqual(await File.ReadAllBytesAsync(path)), "activity reader does not modify the source database");
        await using var engine = new AppEngine(Path.Combine(root, "engine-tests")); await engine.InitializeAsync(false);
        var unsafePreferences = new AppSettings { EnabledTools = null!, DiscoverLocalTools = null!, ViewingAccounts = null!, OverlayX = double.NaN, OverlayY = double.PositiveInfinity }.Normalize();
        check(unsafePreferences.EnabledTools.Length == 0 && unsafePreferences.ViewingAccounts.Count == 0 && unsafePreferences.OverlayX is null && unsafePreferences.OverlayY is null,
            "malformed optional preferences normalize safely");
        await Task.WhenAll(Enumerable.Range(0, 40).Select(_ => engine.UpdateSettingsAsync(s => s with { OverlayX = (s.OverlayX ?? 0) + 1 })));
        check(engine.Settings.OverlayX == 40, "concurrent settings callbacks are atomic");
        check((await engine.Database.GetMetadataAsync<AppSettings>("settings"))?.OverlayX == 40, "atomic preferences are persisted");
        await engine.UpdateSettingsAsync(s => s with { EnabledTools = [Provider.Antigravity], AntigravityStateFile = path });
        var report = await engine.ScanAsync(Provider.Antigravity);
        check(report.Updated == 1 && (await engine.Database.ActivitiesAsync()).Single().Steps == 7, "activity service is connected to persistent storage");
        await engine.ScanAsync(Provider.Antigravity);
        check((await engine.Database.ActivitiesAsync()).Count == 1, "activity refresh is idempotent");
        using (var db = new SqliteConnection(new SqliteConnectionStringBuilder { DataSource = path, Pooling = false }.ToString())) {
            await db.OpenAsync(); using var command = db.CreateCommand(); command.CommandText = "UPDATE ItemTable SET value='malformed' WHERE key=$key";
            command.Parameters.AddWithValue("$key", "antigravityUnifiedStateSync.trajectorySummaries"); await command.ExecuteNonQueryAsync();
        }
        report = await engine.ScanAsync(Provider.Antigravity);
        check(report.Failed == 1 && (await engine.Database.ActivitiesAsync()).Single().Steps == 7, "failed activity scan retains previous facts");
        await engine.UpdateSettingsAsync(s => s with { EnabledTools = [] });
        await reject(async () => { await engine.ScanAsync(Provider.Antigravity); }, "disabled tool cannot scan local activity");
    }
}
