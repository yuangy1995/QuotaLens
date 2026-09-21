using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace QuotaLens.Core;

[JsonConverter(typeof(JsonStringEnumConverter<Provider>))]
public enum Provider { Codex, Claude, Antigravity }
public enum FailureKind { NotConnected, Expired, Revoked, Forbidden, RateLimited, Offline, Incompatible, Storage, Identity, Cancelled }
public sealed class QuotaException(FailureKind kind, string message, DateTimeOffset? retryAt = null) : Exception(message)
{
    public FailureKind Kind { get; } = kind;
    public DateTimeOffset? RetryAt { get; } = retryAt;
}

public sealed record Credential(Provider Provider, string AccessToken, string? RefreshToken = null,
    DateTimeOffset? ExpiresAt = null, string? IdToken = null, string? ClientId = null, bool IsGcpTos = false)
{
    // Never print a credential through record-generated diagnostic formatting.
    public override string ToString() => $"Credential({Provider}, [REDACTED])";
    public DateTimeOffset? EffectiveExpiry
    {
        get
        {
            var jwt = JsonTools.JwtClaims(AccessToken).At("exp").UnixDate();
            return ExpiresAt is { } expiry && jwt is { } j ? (expiry < j ? expiry : j) : ExpiresAt ?? jwt;
        }
    }
    public bool NeedsRefresh(DateTimeOffset now) => string.IsNullOrWhiteSpace(AccessToken) || EffectiveExpiry <= now.AddMinutes(5);
}

public sealed record Account(string Key, Provider Provider, string ProviderId, string Name, string Source,
    DateTimeOffset VerifiedAt, string? Alias = null)
{
    public string DisplayName => string.IsNullOrWhiteSpace(Alias) ? Name : Alias;
    public static string KeyFor(Provider provider, string identity)
    {
        if (string.IsNullOrWhiteSpace(identity)) throw new QuotaException(FailureKind.Identity, "Missing verified identity.");
        return provider.ToString().ToLowerInvariant() + "_" + Convert.ToHexStringLower(SHA256.HashData(Encoding.UTF8.GetBytes(identity)));
    }
}

public sealed record QuotaPool(string Id, string Title, double UsedPercent, int? WindowMinutes, DateTimeOffset? ResetsAt)
{
    public double RemainingPercent => 100 - UsedPercent;
    public bool IsCurrent(DateTimeOffset now) => ResetsAt is null || ResetsAt > now;
    public QuotaPool Validate()
    {
        if (string.IsNullOrWhiteSpace(Id) || !double.IsFinite(UsedPercent) || UsedPercent < 0 || UsedPercent > 100 || WindowMinutes <= 0)
            throw new QuotaException(FailureKind.Incompatible, "Invalid quota window; previous data was retained.");
        return this;
    }
}

public sealed record QuotaSnapshot(string AccountKey, Provider Provider, DateTimeOffset ObservedAt, string? Plan,
    IReadOnlyList<QuotaPool> Pools, long? LifetimeTokens = null)
{
    public QuotaSnapshot Validate()
    {
        if (string.IsNullOrWhiteSpace(AccountKey) || Pools.Count == 0 || Pools.Select(x => x.Id).Distinct().Count() != Pools.Count)
            throw new QuotaException(FailureKind.Incompatible, "The quota response is incomplete.");
        foreach (var pool in Pools) pool.Validate();
        if (LifetimeTokens < 0) throw new QuotaException(FailureKind.Incompatible, "Invalid cloud counter.");
        return this;
    }
}
public sealed record QueryResult(Account Account, QuotaSnapshot Snapshot);
public sealed record SyncStatus(DateTimeOffset? LastSuccess = null, FailureKind? Failure = null, string? Message = null, DateTimeOffset? RetryAt = null);
public sealed record TokenUsage(long Input = 0, long CachedInput = 0, long Output = 0, long CacheWrite = 0)
{
    public long Total => Input + Output + CacheWrite;
    public TokenUsage Validate()
    {
        if (Input < 0 || CachedInput < 0 || CachedInput > Input || Output < 0 || CacheWrite < 0)
            throw new InvalidDataException("Invalid token counters.");
        _ = checked(Input + Output + CacheWrite);
        return this;
    }
    public static TokenUsage operator +(TokenUsage a, TokenUsage b) => new(checked(a.Input + b.Input),
        checked(a.CachedInput + b.CachedInput), checked(a.Output + b.Output), checked(a.CacheWrite + b.CacheWrite));
}
public sealed record UsageEvent(string Id, Provider Provider, string SourceId, string SessionId, DateTimeOffset At,
    string Model, string? Effort, TokenUsage Tokens);
public sealed record SessionSummary(string Id, Provider Provider, string SourceId, string Path, string Project,
    DateTimeOffset UpdatedAt, long Tokens, int Events, string Model);
public sealed record UsageBucket(string Label, long Tokens, int Events, decimal? ApiValue, int UnpricedEvents);
public sealed record TranscriptLine(string Role, string Text, DateTimeOffset? At);
public sealed record ActivitySummary(string Id, string Profile, string Project, DateTimeOffset? At, int? Steps);
public sealed record Price(string Model, decimal InputPerMillion, decimal CachedInputPerMillion, decimal OutputPerMillion, decimal CacheWritePerMillion = 0);
public static class Pricing
{
    // An exact catalog match is required. Never silently map an unknown model to a default price.
    public static decimal? Estimate(UsageEvent value, IEnumerable<Price> catalog)
    {
        var price = catalog.FirstOrDefault(x => string.Equals(x.Model, value.Model, StringComparison.OrdinalIgnoreCase));
        if (price is null) return null;
        value.Tokens.Validate();
        return ((value.Tokens.Input - value.Tokens.CachedInput) * price.InputPerMillion
            + value.Tokens.CachedInput * price.CachedInputPerMillion + value.Tokens.Output * price.OutputPerMillion
            + value.Tokens.CacheWrite * price.CacheWritePerMillion) / 1_000_000m;
    }
}

public static class JsonTools
{
    public static readonly JsonSerializerOptions Options = new(JsonSerializerDefaults.Web) { WriteIndented = true, MaxDepth = 48 };
    public static JsonElement Parse(string json) { using var doc = JsonDocument.Parse(json, new JsonDocumentOptions { MaxDepth = 48 }); return doc.RootElement.Clone(); }
    public static JsonElement At(this JsonElement root, params string[] path)
    {
        foreach (var key in path)
            if (root.ValueKind != JsonValueKind.Object || !root.TryGetProperty(key, out root)) return default;
        return root;
    }
    public static string? Text(this JsonElement value) => value.ValueKind == JsonValueKind.String ? value.GetString() : null;
    public static double? Number(this JsonElement value)
    {
        double n;
        if (value.ValueKind == JsonValueKind.Number && value.TryGetDouble(out n) && double.IsFinite(n)) return n;
        if (value.ValueKind == JsonValueKind.String && double.TryParse(value.GetString(), System.Globalization.NumberStyles.Float,
            System.Globalization.CultureInfo.InvariantCulture, out n) && double.IsFinite(n)) return n;
        return null;
    }
    public static long? Integer(this JsonElement value) => value.ValueKind == JsonValueKind.Number && value.TryGetInt64(out var n) ? n : null;
    public static DateTimeOffset? UnixDate(this JsonElement value)
    {
        var n = value.Number();
        if (n is null) return null;
        try { return DateTimeOffset.FromUnixTimeSeconds(checked((long)n.Value)); } catch (ArgumentOutOfRangeException) { return null; } catch (OverflowException) { return null; }
    }
    public static DateTimeOffset? Date(this JsonElement value) => DateTimeOffset.TryParse(value.Text(), System.Globalization.CultureInfo.InvariantCulture,
        System.Globalization.DateTimeStyles.AssumeUniversal, out var dt) ? dt : value.UnixDate();
    public static IEnumerable<JsonElement> Items(this JsonElement value) => value.ValueKind == JsonValueKind.Array ? value.EnumerateArray() : [];
    public static JsonElement JwtClaims(string? token)
    {
        try
        {
            var parts = (token ?? "").Split('.');
            if (parts.Length != 3 || parts[1].Length > 65536) return default;
            var text = parts[1].Replace('-', '+').Replace('_', '/');
            return Parse(Encoding.UTF8.GetString(Convert.FromBase64String(text.PadRight((text.Length + 3) / 4 * 4, '='))));
        }
        catch (Exception e) when (e is FormatException or JsonException) { return default; }
    }
    public static string Base64Url(byte[] data) => Convert.ToBase64String(data).TrimEnd('=').Replace('+', '-').Replace('/', '_');
}
