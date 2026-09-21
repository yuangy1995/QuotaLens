using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace QuotaLens.Core;

public enum ToolId { Codex, Claude, Antigravity }
public enum DataStatus { NotConnected, Loading, Available, Offline, RateLimited, Unauthorized, Incompatible, Error, Disabled }
public enum CredentialOrigin { LocalImport, FileImport, Browser }
public enum PageId { Summary, Resources, Distribution, Quota, Forecast, Usage, History, Sessions, ResetCards, ToolSettings, AppSettings, About }

public static class ToolCatalog
{
    public static IReadOnlyList<ToolId> All { get; } = Enum.GetValues<ToolId>();
    public static IReadOnlyList<PageId> Pages(ToolId tool) => tool switch
    {
        ToolId.Codex => [PageId.Quota, PageId.Forecast, PageId.Usage, PageId.History, PageId.Sessions, PageId.ResetCards, PageId.ToolSettings],
        ToolId.Claude => [PageId.Quota, PageId.Usage, PageId.History, PageId.Sessions, PageId.ToolSettings],
        _ => [PageId.Quota, PageId.Usage, PageId.Sessions, PageId.ToolSettings]
    };
    public static string Key(ToolId tool) => tool.ToString().ToLowerInvariant();
}

public static class JsonData
{
    public static JsonSerializerOptions Options { get; } = Create();
    private static JsonSerializerOptions Create()
    {
        var options = new JsonSerializerOptions(JsonSerializerDefaults.Web) { MaxDepth = 64, WriteIndented = false };
        options.Converters.Add(new JsonStringEnumConverter(JsonNamingPolicy.CamelCase));
        return options;
    }
    public static string Encode<T>(T value) => JsonSerializer.Serialize(value, Options);
    public static T Decode<T>(string value) => JsonSerializer.Deserialize<T>(value, Options) ?? throw new JsonException("Empty document.");
}

public static class StableId
{
    public static string Hash(string value) => Convert.ToHexStringLower(SHA256.HashData(Encoding.UTF8.GetBytes(value)));
    // Provider and organization/workspace are part of the identity. Emails are labels, never keys.
    public static string Account(ToolId tool, string subject, string? workspace = null)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(subject);
        return Hash(JsonData.Encode(new[] { ToolCatalog.Key(tool), subject, workspace ?? "" }));
    }
}

public sealed record AccountRecord(string Key, ToolId Tool, string Subject, string? Workspace,
    string DisplayName, string? Email, CredentialOrigin Origin, DateTimeOffset VerifiedAt,
    string? LocalSource = null);

public sealed record CredentialEnvelope(ToolId Tool, string? AccessToken, string? RefreshToken,
    string? IdToken, DateTimeOffset? ExpiresAt, string? AccountId = null, string? ClientId = null,
    string? Email = null, string? ProjectId = null, string? WorkspaceId = null);

public sealed record QuotaPool(string Id, string Label, double UsedPercent, int? WindowMinutes,
    DateTimeOffset? ResetsAt, string? Group = null)
{
    public bool IsValid => double.IsFinite(UsedPercent) && UsedPercent is >= 0 and <= 100;
    public double RemainingPercent => Math.Clamp(100 - UsedPercent, 0, 100);
    public bool IsCurrent(DateTimeOffset now) => IsValid && (ResetsAt is null || ResetsAt > now);
}

public sealed record ResetCredit(string Id, string ResetType, string Status, DateTimeOffset? GrantedAt,
    DateTimeOffset? ExpiresAt, string? Title, string? Description);
public sealed record SubscriptionInfo(string? Plan, string? Status, DateTimeOffset? StartsAt, DateTimeOffset? EndsAt);
public sealed record QuotaSnapshot(ToolId Tool, string AccountKey, DateTimeOffset CapturedAt,
    IReadOnlyList<QuotaPool> Pools, string? Plan = null, long? LifetimeTokens = null,
    int? AvailableResetCredits = null, IReadOnlyList<ResetCredit>? ResetCredits = null,
    SubscriptionInfo? Subscription = null);

public sealed record AccountResult(AccountRecord Account, CredentialEnvelope Credential, QuotaSnapshot Snapshot);
public sealed record AccountState(AccountRecord Account, QuotaSnapshot? Snapshot, DataStatus Status,
    string? Message = null, DateTimeOffset? RetryAt = null)
{
    // A failed refresh keeps its last good snapshot. Missing/expired values never become zero.
    public AccountState Failure(ProviderException error) => this with
    { Status = error.Status, Message = error.SafeMessage, RetryAt = error.RetryAt };
}

public sealed class ProviderException(DataStatus status, string safeMessage, DateTimeOffset? retryAt = null)
    : Exception(safeMessage)
{
    public DataStatus Status { get; } = status;
    public string SafeMessage { get; } = safeMessage;
    public DateTimeOffset? RetryAt { get; } = retryAt;
}

public sealed record UsageEvent(string Key, ToolId Tool, string SourceKey, string SessionId,
    DateTimeOffset Timestamp, string Model, long InputTokens, long CachedInputTokens,
    long OutputTokens, long CacheCreationTokens = 0, string? Reasoning = null,
    string? AccountKey = null, decimal? ApiEquivalentUsd = null)
{
    // Cached input is a subset of input; reasoning is a subset of output, not an extra charge.
    public long TotalTokens => checked(InputTokens + OutputTokens + CacheCreationTokens);
}
public sealed record LocalSession(string Key, ToolId Tool, string SourceKey, string SessionId,
    string SourcePath, string Project, DateTimeOffset StartedAt, DateTimeOffset UpdatedAt,
    long TotalTokens, string Model, string? ParentSessionId = null, int? TaskCount = null, int? StepCount = null);
public sealed record UsageSummary(long Tokens, long InputTokens, long CachedInputTokens,
    long OutputTokens, long Sessions, decimal KnownApiEquivalentUsd, long UnpricedEvents);
public sealed record UsageBucket(string Label, long Tokens, decimal KnownApiEquivalentUsd, long UnpricedEvents);
public sealed record ConversationMessage(string Role, string Text, DateTimeOffset? Timestamp);
public sealed record SearchHit(string SessionKey, string SessionId, string Excerpt, long ByteOffset);
public sealed record DiagnosticSummary(int SchemaVersion, DateTimeOffset ExportedAt, int Accounts,
    long Sessions, long Events, long UnpricedEvents, int Sources, int FailedSources, string Platform);

public sealed record ToolPreferences(bool Enabled = false, string? HomePath = null, string? BinaryPath = null,
    bool OverlayEnabled = false, bool AutoDiscover = false, string? SelectedAccountKey = null);
public sealed record AppPreferences
{
    public int SchemaVersion { get; init; } = 1;
    public string Theme { get; init; } = "system";
    public string Language { get; init; } = "zh-Hans";
    public bool ShowRemaining { get; init; } = true;
    public bool CloseToTray { get; init; } = true;
    public bool NotifyRecovery { get; init; } = true;
    public int RefreshSeconds { get; init; } = 60;
    public bool Paused { get; init; }
    public ToolId? PinnedOverlayTool { get; init; }
    public double? OverlayX { get; init; }
    public double? OverlayY { get; init; }
    public Dictionary<ToolId, ToolPreferences> Tools { get; init; } = ToolCatalog.All.ToDictionary(x => x, _ => new ToolPreferences());
    public ToolPreferences For(ToolId tool) => Tools.GetValueOrDefault(tool) ?? new();
}

public interface ICredentialStore
{
    Task SaveAsync(string key, CredentialEnvelope credential, CancellationToken cancellationToken = default);
    Task<CredentialEnvelope> LoadAsync(string key, CancellationToken cancellationToken = default);
    Task RemoveAsync(string key, CancellationToken cancellationToken = default);
}
public interface IQuotaProvider
{
    ToolId Tool { get; }
    Task<AccountResult> VerifyAsync(CredentialEnvelope credential, CredentialOrigin origin,
        CancellationToken cancellationToken);
    Task<AccountResult> RefreshAsync(AccountRecord account, CredentialEnvelope credential,
        CancellationToken cancellationToken);
}
