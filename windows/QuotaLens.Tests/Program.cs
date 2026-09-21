using QuotaLens.Core;
using System.Text.Json;

var failures = new List<string>(); int passed = 0;
void Test(string name, Action body)
{
    try { body(); passed++; Console.WriteLine($"PASS {name}"); }
    catch (Exception ex) { failures.Add(name); Console.Error.WriteLine($"FAIL {name}: {ex}"); }
}
void Equal<T>(T expected, T actual) { if (!EqualityComparer<T>.Default.Equals(expected, actual)) throw new Exception($"Expected {expected}; got {actual}"); }
void Near(double expected, double? actual) { if (actual == null || Math.Abs(expected - actual.Value) > 0.000001) throw new Exception($"Expected {expected}; got {actual}"); }
CapacityObservation Obs(long time, long? tokens, double used, long reset = 20000, string account = "a", string? plan = "pro") =>
    new(account, time, tokens, plan, null, [new(300, used, reset)]);
CapacityWindow Window(params CapacityObservation[] rows) => CapacityForecast.Analyze(rows, "a", rows.Max(x => x.ObservedAt)).Single();

using var fixtures = JsonDocument.Parse(File.ReadAllText(Path.Combine(AppContext.BaseDirectory, "fixtures", "capacity-prediction.json")));
foreach (var fixture in fixtures.RootElement.EnumerateArray())
{
    string name = fixture.GetProperty("name").GetString()!;
    Test($"shared forecast: {name}", () =>
    {
        var input = fixture.GetProperty("capacities").EnumerateArray().Select(x => x.GetDouble());
        var actual = CapacityForecast.Predict(input);
        var expected = fixture.GetProperty("expected");
        if (expected.ValueKind == JsonValueKind.Null) Equal(true, actual == null);
        else Near(expected.GetDouble(), actual?.Tokens);
    });
}
Test("capacity waits below 10 percentage points", () => Equal(true, Window(Obs(1, 0, 0), Obs(60, 900, 9)).Current!.Capacity == null));
Test("capacity does not require a zero baseline", () => Near(10000, Window(Obs(1, 500, 40), Obs(60, 1500, 50)).Current!.Capacity));
Test("cloud delay preserves the previous denominator", () =>
{
    var c = Window(Obs(1, 0, 0), Obs(60, 1000, 10), Obs(120, 1000, 30)).Current!;
    Near(10000, c.Capacity); Equal(true, c.AwaitingCloudUsage);
});
Test("late cumulative updates replace the interval contribution", () => Near(10000,
    Window(Obs(1, 0, 0), Obs(60, 1000, 10), Obs(120, 1000, 30), Obs(180, 3000, 30)).Current!.Capacity));
Test("temporary missing cloud counter retains the anchor", () => Near(10000,
    Window(Obs(1, 0, 0), Obs(60, null, 10), Obs(120, 2000, 20)).Current!.Capacity));
Test("same deadline early restoration splits cycles", () => Equal(2,
    Window(Obs(1, 0, 0), Obs(60, 1000, 20), Obs(120, 1100, 0)).Cycles.Count));
Test("unsettled counter after reset is discarded", () =>
{
    var c = Window(Obs(1, 0, 0), Obs(60, 0, 20), Obs(120, 0, 0), Obs(180, 2000, 10), Obs(240, 3000, 20)).Current!;
    Near(10000, c.Capacity); Near(1000, c.MeasuredTokens);
});
Test("rolling unused deadline does not create empty cycles", () => Equal(1, Window(Obs(1, 0, 0), Obs(300, 0, 0, 20300)).Cycles.Count));
Test("expired windows have no current capacity", () =>
{
    var w = CapacityForecast.Analyze([Obs(1, 0, 0), Obs(60, 1000, 10)], "a", 21000).Single();
    Equal(false, w.IsAvailable); Equal(true, w.Current == null);
});
Test("other account observations cannot contaminate forecasts", () => Near(10000,
    Window(Obs(1, 0, 0), Obs(30, 999999, 50, account: "b"), Obs(60, 1000, 10)).Current!.Capacity));
Test("plan changes split stages", () => Equal(1,
    Window(Obs(1, 0, 0), Obs(60, 1000, 10), Obs(120, 2000, 20, plan: "plus")).Current!.Stage));
Test("counter rollback does not add negative tokens", () => Near(10000,
    Window(Obs(1, 0, 0), Obs(60, 1000, 10), Obs(120, 100, 20)).Current!.Capacity));
Test("invalid quota rejected", () => Equal(0, CapacityForecast.Analyze([Obs(1, 0, 101)], "a", 1).Count));
Test("unknown duration is not a week", () => Equal(0, CapacityForecast.Analyze([new("a", 1, 0, "pro", null, [new(123, 0, 1000)])], "a", 1).Count));
Test("duplicate observation timestamps are idempotent", () => Near(10000, Window(Obs(1, 0, 0), Obs(60, 1000, 10), Obs(60, 2000, 20)).Current!.Capacity));
Test("stable identities separate providers", () => Equal(false, StableId.Account(ToolId.Codex, "a") == StableId.Account(ToolId.Claude, "a")));
Test("stable identities separate workspaces", () => Equal(false, StableId.Account(ToolId.Codex, "a", "b") == StableId.Account(ToolId.Codex, "a", "c")));
Test("cached input is not counted twice", () => Equal(140L, new UsageEvent("e", ToolId.Codex, "s", "t", DateTimeOffset.UtcNow, "m", 100, 60, 40).TotalTokens));
Test("account failure retains last good snapshot", () =>
{
    var a = new AccountRecord("a", ToolId.Codex, "subject", null, "Test", null, CredentialOrigin.FileImport, DateTimeOffset.UtcNow);
    var snapshot = new QuotaSnapshot(ToolId.Codex, "a", DateTimeOffset.UtcNow, [new("codex:300", "5h", 25, 300, null)]);
    var state = new AccountState(a, snapshot, DataStatus.Available).Failure(new(DataStatus.Offline, "Offline"));
    Equal(snapshot, state.Snapshot); Equal(DataStatus.Offline, state.Status);
});
Test("tools disabled until explicitly enabled", () => Equal(true, new AppPreferences().Tools.Values.All(x => !x.Enabled)));
Test("theme defaults to system", () => Equal("system", new AppPreferences().Theme));
Test("Claude has no reset-card page", () => Equal(false, ToolCatalog.Pages(ToolId.Claude).Contains(PageId.ResetCards)));
Test("JSON roundtrip keeps identities and enum keys", () => Equal(true, JsonData.Decode<AppPreferences>(JsonData.Encode(new AppPreferences())).Tools.ContainsKey(ToolId.Antigravity)));
Test("recovery requires a fresh successful server observation", () =>
{
    var now = DateTimeOffset.UtcNow; var pool = new QuotaPool("week", "week", 50, 10080, now.AddDays(2));
    var before = new QuotaSnapshot(ToolId.Codex, "a", now, [pool]);
    Equal(0, QuotaInsights.RecoveryKeys(before, before).Count);
    var after = before with { CapturedAt = now.AddSeconds(60), Pools = [pool with { UsedPercent = 0, ResetsAt = now.AddDays(7) }] };
    Equal(1, QuotaInsights.RecoveryKeys(before, after).Count);
    Equal(0, QuotaInsights.RecoveryKeys(before, after with { AccountKey = "b" }).Count);
});
Console.WriteLine($"RESULT: {passed} passed, {failures.Count} failed");
return failures.Count == 0 ? 0 : 1;
