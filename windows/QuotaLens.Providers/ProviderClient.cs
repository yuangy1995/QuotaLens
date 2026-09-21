using System.Net.Http.Headers;
using System.Text;
using System.Text.Json;
using QuotaLens.Core;
using static QuotaLens.Providers.HttpTransport;

namespace QuotaLens.Providers;

/// <summary>Fixed-endpoint subscription queries. Never makes model calls or writes third-party configuration.</summary>
public sealed class ProviderClient : IDisposable
{
    public const string CodexClientId = "app_EMoamEEZ73f0CkXaXp7hrann";
    public const string ClaudeClientId = "9d1c250a-e61b-44d9-88ed-5944d1962f5e";
    public const string AntigravityClientId = "1071006060591-tmhssin2h21lcre235vtolojh4g403ep.apps.googleusercontent.com";
    private readonly HttpTransport transport;
    public GoogleOAuthConfiguration? GoogleConfiguration { get; set; }
    public string ApplicationVersion { get; set; } = "1.1.1";
    public string AntigravityVersion { get; set; } = "1.20.5";
    public ProviderClient(HttpMessageHandler? handler = null) => transport = new(handler);
    public void Dispose() => transport.Dispose();
    public string AuthorizationClientId(Provider provider) => provider switch {
        Provider.Codex => CodexClientId, Provider.Claude => ClaudeClientId,
        _ => GoogleConfiguration?.ClientId ?? throw new QuotaException(FailureKind.NotConnected,
            "Import your Google OAuth Desktop client configuration in Settings before independent Google authorization.") };

    public async Task<QueryResult> QueryAsync(Credential credential, CancellationToken ct)
    {
        if (string.IsNullOrWhiteSpace(credential.AccessToken)) throw new QuotaException(FailureKind.Expired, "A valid access token is required.");
        return credential.Provider switch {
            Provider.Codex => await QueryCodexAsync(credential, ct).ConfigureAwait(false),
            Provider.Claude => await QueryClaudeAsync(credential, ct).ConfigureAwait(false),
            Provider.Antigravity => await QueryAntigravityAsync(credential, ct).ConfigureAwait(false),
            _ => throw FormatError() };
    }

    private async Task<QueryResult> QueryCodexAsync(Credential credential, CancellationToken ct)
    {
        var claims = JsonTools.JwtClaims(credential.AccessToken);
        var id = claims.At("https://api.openai.com/auth", "chatgpt_account_id").Text();
        if (string.IsNullOrWhiteSpace(id)) throw new QuotaException(FailureKind.Identity, "The token has no ChatGPT account identity.");
        var root = await GetAsync("https://chatgpt.com/backend-api/wham/usage", credential, id, ct).ConfigureAwait(false);
        if (root.At("account_id").Text() is { } returned && returned != id)
            throw new QuotaException(FailureKind.Identity, "The server returned a different account.");
        // JWT identity is used only after the server accepts the token and its account scope.
        var now = DateTimeOffset.UtcNow; var key = Account.KeyFor(Provider.Codex, id);
        var account = new Account(key, Provider.Codex, id, claims.At("https://api.openai.com/profile", "email").Text() ?? id, "imported", now);
        return new(account, new QuotaSnapshot(key, Provider.Codex, now, root.At("plan_type").Text(), DecodeCodex(root)).Validate());
    }
    public static IReadOnlyList<QuotaPool> DecodeCodex(JsonElement root)
    {
        var result = new List<QuotaPool>();
        AddRate(root.At("rate_limit"), "codex", "Codex");
        if (root.At("code_review_rate_limit").ValueKind == JsonValueKind.Object)
            AddRate(root.At("code_review_rate_limit"), "code_review", "Code review");
        foreach (var extra in root.At("additional_rate_limits").Items())
        {
            var id = extra.At("limit_name").Text() ?? extra.At("limit_id").Text() ?? throw FormatError();
            AddRate(extra.At("rate_limit"), id, extra.At("display_name").Text() ?? id);
        }
        if (result.Count == 0) throw FormatError();
        return result;
        void AddRate(JsonElement rate, string id, string title)
        {
            foreach (var slot in new[] { "primary_window", "secondary_window" })
            {
                var window = rate.At(slot);
                if (window.ValueKind is JsonValueKind.Undefined or JsonValueKind.Null) continue;
                double used = window.At("used_percent").Number() ?? throw FormatError();
                var seconds = window.At("limit_window_seconds").Integer();
                int? minutes = seconds is > 0 and <= int.MaxValue && seconds % 60 == 0 ? (int)(seconds.Value / 60) : null;
                var rawReset = window.At("reset_at"); var reset = rawReset.UnixDate();
                if (rawReset.ValueKind is not (JsonValueKind.Null or JsonValueKind.Undefined) && reset is null) throw FormatError();
                result.Add(new QuotaPool($"{id}:{slot}", title, used, minutes, reset).Validate());
            }
        }
    }

    private async Task<QueryResult> QueryClaudeAsync(Credential credential, CancellationToken ct)
    {
        var profile = await GetAsync("https://api.anthropic.com/api/oauth/profile", credential, null, ct).ConfigureAwait(false);
        var id = profile.At("account", "uuid").Text() ?? throw new QuotaException(FailureKind.Identity, "Claude did not return a stable account identity.");
        var usage = await GetAsync("https://api.anthropic.com/api/oauth/usage", credential, null, ct).ConfigureAwait(false);
        var now = DateTimeOffset.UtcNow; var key = Account.KeyFor(Provider.Claude, id);
        var name = profile.At("account", "email").Text() ?? profile.At("account", "email_address").Text() ?? id;
        var plan = profile.At("organization", "subscription_type").Text() ?? profile.At("organization", "organization_type").Text();
        return new(new Account(key, Provider.Claude, id, name, "imported", now), new QuotaSnapshot(key, Provider.Claude, now, plan, DecodeClaude(usage)).Validate());
    }
    public static IReadOnlyList<QuotaPool> DecodeClaude(JsonElement root)
    {
        if (root.ValueKind != JsonValueKind.Object) throw FormatError();
        var result = new List<QuotaPool>();
        foreach (var field in root.EnumerateObject())
        {
            if (field.Value.ValueKind is JsonValueKind.Null or JsonValueKind.Undefined || field.Name == "extra_usage") continue;
            bool recognized = field.Name == "five_hour" || field.Name.StartsWith("seven_day", StringComparison.Ordinal);
            var used = field.Value.At("utilization").Number(); var reset = field.Value.At("resets_at").Date();
            if (used is null || reset is null) { if (recognized) throw FormatError(); continue; }
            int? minutes = field.Name == "five_hour" ? 300 : field.Name.StartsWith("seven_day", StringComparison.Ordinal) ? 10080 : null;
            result.Add(new QuotaPool(field.Name, field.Name.Replace('_', ' '), used.Value, minutes, reset).Validate());
        }
        if (result.Count == 0) throw FormatError();
        return result;
    }

    private async Task<QueryResult> QueryAntigravityAsync(Credential credential, CancellationToken ct)
    {
        var user = await GetAsync("https://www.googleapis.com/oauth2/v2/userinfo", credential, null, ct).ConfigureAwait(false);
        var id = user.At("id").Text() ?? user.At("sub").Text() ?? throw new QuotaException(FailureKind.Identity, "Google did not return a stable identity.");
        var origin = credential.IsGcpTos ? "https://cloudcode-pa.googleapis.com" : "https://daily-cloudcode-pa.googleapis.com";
        var load = await PostAsync(origin + "/v1internal:loadCodeAssist", credential, new {
            metadata = new { ideName = "antigravity", ideType = "ANTIGRAVITY", ideVersion = AntigravityVersion,
                pluginVersion = ApplicationVersion, platform = "WINDOWS_AMD64", updateChannel = "stable", pluginType = "GEMINI" },
            mode = "FULL_ELIGIBILITY_CHECK" }, ct).ConfigureAwait(false);
        var project = load.At("cloudaicompanionProject").Text() ?? load.At("cloudaicompanionProject", "id").Text();
        object body = project is null ? new { } : new { project };
        var summary = PostAsync(origin + "/v1internal:retrieveUserQuotaSummary", credential, body, ct);
        var models = PostAsync(origin + "/v1internal:fetchAvailableModels", credential, body, ct);
        await Task.WhenAll(summary, models).ConfigureAwait(false);
        var now = DateTimeOffset.UtcNow; var key = Account.KeyFor(Provider.Antigravity, "user:" + id);
        return new(new Account(key, Provider.Antigravity, id, user.At("email").Text() ?? id, "imported", now),
            new QuotaSnapshot(key, Provider.Antigravity, now, load.At("paidTier", "id").Text() ?? load.At("currentTier", "id").Text(),
                DecodeAntigravity(await summary.ConfigureAwait(false), await models.ConfigureAwait(false))).Validate());
    }
    public static IReadOnlyList<QuotaPool> DecodeAntigravity(JsonElement summary, JsonElement models)
    {
        var result = new List<QuotaPool>(); var groups = summary.At("groups"); int index = 0;
        if (groups.ValueKind is not (JsonValueKind.Array or JsonValueKind.Null or JsonValueKind.Undefined)) throw FormatError();
        foreach (var group in groups.Items())
        {
            var groupId = group.At("groupId").Text() ?? "group-" + index++;
            var title = group.At("displayName").Text() ?? groupId;
            var buckets = group.At("buckets").Items().ToArray();
            if (buckets.Length == 0) throw FormatError();
            foreach (var bucket in buckets)
            {
                var id = bucket.At("bucketId").Text() ?? throw FormatError();
                double fraction = bucket.At("remainingFraction").Number() ?? throw FormatError();
                if (fraction is < 0 or > 1) throw FormatError();
                result.Add(new QuotaPool(groupId + ":" + id, title + " · " + (bucket.At("displayName").Text() ?? id),
                    (1 - fraction) * 100, null, Reset(bucket)).Validate());
            }
        }
        // Authoritative group limits and alternative model quotas are never added together.
        if (result.Count > 0) return result;
        var map = models.At("models");
        if (map.ValueKind != JsonValueKind.Object) throw FormatError();
        foreach (var model in map.EnumerateObject())
        {
            var quota = model.Value.At("quotaInfo");
            double fraction = quota.At("remainingFraction").Number() ?? throw FormatError();
            if (fraction is < 0 or > 1) throw FormatError();
            result.Add(new QuotaPool(model.Name, model.Value.At("displayName").Text() ?? model.Name, (1 - fraction) * 100, null, Reset(quota)).Validate());
        }
        if (result.Count == 0) throw FormatError();
        return result;
        static DateTimeOffset? Reset(JsonElement value) => value.At("resetTime").ValueKind is JsonValueKind.Null or JsonValueKind.Undefined
            ? null : value.At("resetTime").Date() ?? throw FormatError();
    }

    public Task<Credential> RefreshAsync(Credential credential, CancellationToken ct)
    {
        if (string.IsNullOrWhiteSpace(credential.RefreshToken)) throw new QuotaException(FailureKind.Expired, "Authorize this account again; no refresh token is available.");
        return TokenAsync(credential.Provider, new() { ["grant_type"] = "refresh_token", ["refresh_token"] = credential.RefreshToken }, credential, ct);
    }
    public Task<Credential> ExchangeAsync(Provider provider, string code, string redirect, string state, string verifier, CancellationToken ct) =>
        TokenAsync(provider, new() { ["grant_type"] = "authorization_code", ["code"] = code, ["redirect_uri"] = redirect,
            ["state"] = state, ["code_verifier"] = verifier }, null, ct);
    private async Task<Credential> TokenAsync(Provider provider, Dictionary<string, string> values, Credential? old, CancellationToken ct)
    {
        string clientId;
        if (provider == Provider.Antigravity)
        {
            var configuration = GoogleConfiguration ?? throw new QuotaException(FailureKind.NotConnected,
                "Google token renewal requires the matching OAuth Desktop client configuration. Reimport a fresh local token or configure independent authorization.");
            var expected = old?.ClientId ?? (old is null ? configuration.ClientId : AntigravityClientId);
            if (configuration.ClientId != expected) throw new QuotaException(FailureKind.Identity, "The Google OAuth client does not match the imported refresh token.");
            clientId = configuration.ClientId; values["client_secret"] = configuration.ClientSecret;
        }
        else
        {
            clientId = AuthorizationClientId(provider);
            if (old?.ClientId is { Length: > 0 } imported && imported != clientId && imported != provider.ToString().ToLowerInvariant())
                throw new QuotaException(FailureKind.Incompatible, "Unsupported OAuth client. Authorize the account independently.");
        }
        values["client_id"] = clientId;
        var endpoint = provider switch { Provider.Codex => "https://auth.openai.com/oauth/token",
            Provider.Claude => "https://platform.claude.com/v1/oauth/token", _ => "https://oauth2.googleapis.com/token" };
        using var request = new HttpRequestMessage(HttpMethod.Post, endpoint) {
            Content = provider == Provider.Claude ? JsonContent(values) : new FormUrlEncodedContent(values) };
        var root = await transport.SendAsync(request, ct, tokenExchange: true).ConfigureAwait(false);
        var access = root.At("access_token").Text();
        if (string.IsNullOrWhiteSpace(access)) throw FormatError();
        var seconds = root.At("expires_in").Number();
        DateTimeOffset? expiry = seconds is > 0 and < 31_536_000 ? DateTimeOffset.UtcNow.AddSeconds(seconds.Value) : null;
        return new(provider, access, root.At("refresh_token").Text() ?? old?.RefreshToken, expiry,
            root.At("id_token").Text() ?? old?.IdToken, clientId, old?.IsGcpTos ?? false);
    }

    internal Task<JsonElement> GetAsync(string uri, Credential credential, string? accountId, CancellationToken ct) =>
        AuthorizedAsync(HttpMethod.Get, uri, credential, accountId, null, ct);
    internal Task<JsonElement> PostAsync(string uri, Credential credential, object body, CancellationToken ct) =>
        AuthorizedAsync(HttpMethod.Post, uri, credential, null, body, ct);
    private async Task<JsonElement> AuthorizedAsync(HttpMethod method, string uri, Credential credential, string? accountId, object? body, CancellationToken ct)
    {
        using var request = new HttpRequestMessage(method, uri);
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", credential.AccessToken);
        request.Headers.Accept.Add(new MediaTypeWithQualityHeaderValue("application/json"));
        if (accountId is not null) request.Headers.Add("ChatGPT-Account-Id", accountId);
        if (credential.Provider == Provider.Claude) request.Headers.Add("anthropic-beta", "oauth-2025-04-20");
        if (credential.Provider == Provider.Antigravity) request.Headers.TryAddWithoutValidation("User-Agent", $"antigravity/{AntigravityVersion} win32/amd64");
        if (body is not null) request.Content = JsonContent(body);
        return await transport.SendAsync(request, ct).ConfigureAwait(false);
    }
    private static StringContent JsonContent(object body) => new(JsonSerializer.Serialize(body), Encoding.UTF8, "application/json");

    public async Task<SubscriptionInfo> SubscriptionAsync(Account account, Credential credential, CancellationToken ct)
    {
        if (account.Provider != Provider.Codex) throw new ArgumentException("Codex account required.");
        var root = await GetAsync("https://chatgpt.com/backend-api/accounts/check/v4-2023-04-27", credential, account.ProviderId, ct).ConfigureAwait(false);
        var accounts = root.At("accounts");
        if (accounts.ValueKind != JsonValueKind.Object) throw FormatError();
        foreach (var item in accounts.EnumerateObject())
        {
            var identity = item.Value.At("account");
            var id = identity.At("account_id").Text() ?? identity.At("id").Text() ?? item.Name;
            if (id != account.ProviderId) continue;
            var entitlement = item.Value.At("entitlement");
            bool? active = entitlement.At("has_active_subscription").ValueKind switch { JsonValueKind.True => true, JsonValueKind.False => false, _ => null };
            bool? renew = item.Value.At("last_active_subscription", "will_renew").ValueKind switch { JsonValueKind.True => true, JsonValueKind.False => false, _ => null };
            return new(account.Key, entitlement.At("subscription_plan").Text() ?? identity.At("plan_type").Text(), active, renew,
                entitlement.At("renews_at").Date(), entitlement.At("expires_at").Date(), entitlement.At("cancels_at").Date(), DateTimeOffset.UtcNow);
        }
        throw new QuotaException(FailureKind.Identity, "No matching subscription identity was returned.");
    }
    public Task<JsonElement> ResetHistoryAsync(Account account, Credential credential, string? cursor, CancellationToken ct)
    {
        if (account.Provider != Provider.Codex) throw new ArgumentException("Codex account required.");
        var suffix = cursor is null ? "" : "?cursor=" + Uri.EscapeDataString(cursor);
        return GetAsync("https://chatgpt.com/backend-api/wham/rate-limit-reset-credits/history" + suffix, credential, account.ProviderId, ct);
    }
}
