using System.Net;
using System.Text;
using QuotaLens.Core;
using QuotaLens.Providers;

int passed = 0;
void Check(bool value, string name) { if (!value) throw new Exception("FAILED: " + name); passed++; Console.WriteLine("PASS " + name); }
void Reject(Action action, string name) { bool failed = false; try { action(); } catch { failed = true; } Check(failed, name); }
var codex = ProviderClient.DecodeCodex(JsonTools.Parse("""{"rate_limit":{"primary_window":{"used_percent":12.5,"limit_window_seconds":18000,"reset_at":1800000000}}}"""));
Check(codex.Single().WindowMinutes == 300 && codex.Single().RemainingPercent == 87.5, "Codex window duration and remaining quota");
Reject(() => ProviderClient.DecodeCodex(JsonTools.Parse("""{"rate_limit":{"primary_window":{"used_percent":true}}}""")), "boolean quota rejected");
Reject(() => ProviderClient.DecodeCodex(JsonTools.Parse("{}")), "missing quota is not zero");
var claude = ProviderClient.DecodeClaude(JsonTools.Parse("""{"five_hour":{"utilization":20,"resets_at":"2026-10-01T00:00:00Z"},"seven_day_sonnet":{"utilization":30,"resets_at":"2026-10-02T00:00:00Z"},"extra_usage":{"utilization":99},"seven_day_opus":null}"""));
Check(claude.Count == 2 && claude[1].WindowMinutes == 10080, "Claude model windows, no currency-pool mixing");
Reject(() => ProviderClient.DecodeClaude(JsonTools.Parse("""{"five_hour":{"utilization":20}}""")), "incomplete Claude window rejected");
var ag = ProviderClient.DecodeAntigravity(JsonTools.Parse("""{"groups":[{"groupId":"group","buckets":[{"bucketId":"a","remainingFraction":0.4}]}]}"""), JsonTools.Parse("""{"models":{"m":{"quotaInfo":{"remainingFraction":0.3}}}}"""));
Check(ag.Count == 1 && ag[0].RemainingPercent == 40, "Antigravity groups are not added to models");
Reject(() => ProviderClient.DecodeAntigravity(JsonTools.Parse("""{"groups":[{"buckets":[{"bucketId":"a","remainingFraction":2}]}]}"""), default), "invalid fraction rejected");
Check(OAuthSession.CallbackCode("/oauth/callback?state=expected&code=hello", "expected") == "hello", "loopback callback accepted");
Check(OAuthSession.CallbackCode("/oauth/callback?state=bad&code=hello", "expected") is null, "wrong state rejected");
Check(OAuthSession.CallbackCode("/oauth/callback?state=expected&state=expected&code=hello", "expected") is null, "duplicate state rejected");
Check(OAuthSession.CallbackCode("/oauth/callback?state=expected&code=a&code=b", "expected") is null, "duplicate code rejected");
Check(OAuthSession.CallbackCode("https://evil.example/oauth/callback?state=expected&code=a", "expected") is null, "absolute callback target rejected");
Check(OAuthSession.CallbackCode("/oauth/callback/extra?state=expected&code=a", "expected") is null, "wrong callback path rejected");
Reject(() => GoogleOAuthConfiguration.Parse("""{"web":{"client_id":"test.apps.googleusercontent.com","client_secret":"synthetic-only"}}"""), "web OAuth client rejected");
var configuration = GoogleOAuthConfiguration.Parse("""{"installed":{"client_id":"test.apps.googleusercontent.com","client_secret":"synthetic-only","token_uri":"https://evil.example"}}""");
Check(!configuration.ToString().Contains("synthetic-only"), "OAuth configuration diagnostic redaction");
using var client = new ProviderClient(new ResponseHandler(HttpStatusCode.OK, "{}"));
Reject(() => client.AuthorizationClientId(Provider.Antigravity), "no embedded Google secret fallback");
var account = new Account("account", Provider.Codex, "identity", "test@example.invalid", "test", DateTimeOffset.UtcNow);
var rpc = CodexRpc.DecodeExtended(JsonTools.Parse("""{"rateLimits":{"limitId":"codex","primary":{"usedPercent":5,"windowDurationMins":300,"resetsAt":1800000000}},"rateLimitResetCredits":{"availableCount":1,"credits":[{"id":"server-id","status":"available","expiresAt":1900000000}]}}"""), account, 500, DateTimeOffset.UtcNow);
Check(rpc.Quota.LifetimeTokens == 500 && rpc.Credits.Single().Available(DateTimeOffset.UtcNow), "RPC cloud counters and actual reset IDs");
Check(!new ResetCredit("reset_credit_synthetic", "available", null, null).Available(DateTimeOffset.UtcNow), "synthetic credit IDs cannot be spent");
foreach (var (status, expected) in new[] { (HttpStatusCode.Unauthorized, FailureKind.Expired), (HttpStatusCode.Forbidden, FailureKind.Forbidden),
    (HttpStatusCode.TooManyRequests, FailureKind.RateLimited), (HttpStatusCode.ServiceUnavailable, FailureKind.Offline), (HttpStatusCode.Redirect, FailureKind.Incompatible) })
{
    using var transport = new HttpTransport(new ResponseHandler(status, "{}"));
    using var request = new HttpRequestMessage(HttpMethod.Get, "https://example.invalid/");
    try { await transport.SendAsync(request, CancellationToken.None); Check(false, status.ToString()); }
    catch (QuotaException error) { Check(error.Kind == expected, status + " classification"); }
}
using (var transport = new HttpTransport(new ResponseHandler(HttpStatusCode.BadRequest, """{"error":"invalid_grant"}""")))
using (var request = new HttpRequestMessage(HttpMethod.Post, "https://example.invalid/"))
{
    try { await transport.SendAsync(request, CancellationToken.None, true); Check(false, "invalid grant"); }
    catch (QuotaException error) { Check(error.Kind == FailureKind.Revoked, "only explicit invalid grant is revoked"); }
}
Console.WriteLine($"{passed} provider checks passed; no live credentials or network used.");

sealed class ResponseHandler(HttpStatusCode code, string json) : HttpMessageHandler
{
    protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken) =>
        Task.FromResult(new HttpResponseMessage(code) { Content = new StringContent(json, Encoding.UTF8, "application/json") });
}
