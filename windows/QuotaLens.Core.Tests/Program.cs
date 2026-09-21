using QuotaLens.Core;
using System.Text.Json;

var passed = 0;
void Check(bool ok, string name) { if (!ok) throw new Exception("FAILED: " + name); passed++; Console.WriteLine("PASS " + name); }
void Reject(Action action, string name) { bool threw = false; try { action(); } catch { threw = true; } Check(threw, name); }
var fixtures = JsonTools.Parse(File.ReadAllText(Path.Combine(AppContext.BaseDirectory, "capacity-predictions.json")));
foreach (var f in fixtures.Items())
{
    var result = CapacityForecast.Predict(f.At("values").Items().Select(x => x.GetDouble()));
    Check(result is not null && Math.Abs(result.Tokens - f.At("expected").GetDouble()) < 0.0001, f.At("name").GetString()!);
}
Check(CapacityForecast.Predict([double.NaN]) is null, "invalid forecasts rejected");
Check(Account.KeyFor(Provider.Codex, "a") != Account.KeyFor(Provider.Claude, "a"), "provider identity isolation");
Reject(() => new QuotaPool("x", "x", double.NaN, 300, null).Validate(), "NaN quota rejected");
Reject(() => new QuotaPool("x", "x", -1, 300, null).Validate(), "negative quota rejected");
Check(new QuotaPool("x", "x", 100, 300, null).Validate().RemainingPercent == 0, "real zero quota accepted");
Check(!new QuotaPool("x", "x", 1, 300, DateTimeOffset.UnixEpoch).IsCurrent(DateTimeOffset.UtcNow), "expired snapshot stays expired");
Reject(() => CredentialImport.Parse("sk-test", Provider.Codex), "API key rejected");
Check(CredentialImport.Parse("{\"tokens\":{\"access_token\":\"test\",\"refresh_token\":\"refresh\"},\"password\":\"secret\"}", Provider.Codex)[0].Credential?.RefreshToken == "refresh", "Codex auth import");
Check(CredentialImport.Parse("{\"provider\":\"claude\",\"access_token\":\"test\"}", Provider.Codex)[0].Error is not null, "wrong provider rejected");
Check(CredentialImport.Parse("{\"claudeAiOauth\":{\"accessToken\":\"test\",\"expiresAt\":1800000000000}}", Provider.Claude)[0].Credential?.ExpiresAt?.Year == 2027, "millisecond expiry");
Check(!new Credential(Provider.Codex, "private-access", "private-refresh").ToString().Contains("private"), "credential diagnostic redaction");
var e = new UsageEvent("id", Provider.Codex, "source", "session", DateTimeOffset.UtcNow, "unknown", null, new(100, 50, 20));
Check(Pricing.Estimate(e, []) is null, "unknown models unpriced");
Check(Pricing.Estimate(e with { Model = "test" }, [new("test", 2, 1, 4)]) == 0.00023m, "cache is not double charged");
Reject(() => new TokenUsage(1, 2).Validate(), "invalid cache counts rejected");
CapacityObservation O(long t, long? n, double p, long reset = 18000, string key = "a") => new(key, t, n, "pro", null, [new(300, p, reset)]);
var window = CapacityForecast.Analyze([O(1, 1000, 10), O(2, 2000, 20), O(3, 2000, 30)], "a", 4).Single();
Check(window.Current?.Capacity == 10000 && window.Current.AwaitingCloudUsage, "stalled cloud counter preserves estimate");
window = CapacityForecast.Analyze([O(1, 1000, 10), O(2, 2000, 20), O(3, 2000, 30), O(4, 3000, 30)], "a", 5).Single();
Check(window.Current?.Capacity == 10000, "delayed tokens replace accumulated pairing");
Check(CapacityForecast.Analyze([O(1, 1000, 10, key: "b")], "a", 2).Count == 0, "foreign account excluded");
Check(CapacityForecast.Analyze([O(1, 1000, 10), O(2, 2000, 20)], "a", 18001).Single().Current is null, "expired cycle has no remaining prediction");
window = CapacityForecast.Analyze([O(1, 1000, 10), O(2, 2000, 20), O(3, 2000, 0)], "a", 4).Single();
Check(window.Cycles.Count == 2 && window.Cycles[0].EndReason == "restored", "same-deadline restoration splits cycles");
Check(StandardPriceCatalog.Entries.Count > 0, "standard reference catalog is bundled");
Check(StandardPriceCatalog.Entries.Select(x => x.Model).Distinct(StringComparer.OrdinalIgnoreCase).Count() == StandardPriceCatalog.Entries.Count, "reference aliases are unique");
Check(Pricing.Estimate(e with { Model = "gpt-5.4" }, StandardPriceCatalog.Entries) == 0.0004375m, "bundled standard reference rates are used");
Check(Pricing.Estimate(e with { Model = "unrecognized-model" }, StandardPriceCatalog.Entries) is null, "unknown models never inherit a reference price");
Check(Pricing.Estimate(e with { Model = "test" }, [new("test", 2, 0, 4)]) is null, "unsupported cache input is not priced as free");
Check(Pricing.Estimate(e with { Model = "test", Tokens = new(100, 0, 20, 5) }, [new("test", 2, 1, 4)]) is null, "unsupported cache write is not priced as free");
Check(Pricing.Estimate(e with { Model = "test" }, [new("test", -2, 1, 4)]) is null, "invalid reference price rejected");
Console.WriteLine($"{passed} core checks passed.");
