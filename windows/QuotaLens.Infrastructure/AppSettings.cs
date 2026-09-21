using QuotaLens.Core;

namespace QuotaLens.Infrastructure;

public sealed record AppSettings
{
    public string Theme { get; init; } = "system";
    public string Language { get; init; } = "system";
    public bool ShowRemaining { get; init; } = true;
    public bool CloseToTray { get; init; } = true;
    public bool StartMinimized { get; init; }
    public bool Notifications { get; init; } = true;
    public bool Paused { get; init; }
    public int RefreshSeconds { get; init; } = 300;
    public Provider[] EnabledTools { get; init; } = [];
    public Provider[] DiscoverLocalTools { get; init; } = [];
    public string? CodexBinary { get; init; }
    public string? CodexHome { get; init; }
    public string? ClaudeHome { get; init; }
    public string? AntigravityStateFile { get; init; }
    public bool CollectCodexCloudUsage { get; init; } = true;
    public bool OverlayEnabled { get; init; }
    public string OverlayTool { get; init; } = "auto";
    public double? OverlayX { get; init; }
    public double? OverlayY { get; init; }
    public Dictionary<string, string> ViewingAccounts { get; init; } = new();
    public string Context { get; init; } = "overview";
    public string Page { get; init; } = "summary";
    public AppSettings Normalize() => this with {
        Theme = Theme is "system" or "light" or "dark" ? Theme : "system",
        Language = Language is "system" or "zh-CN" or "en" ? Language : "system",
        RefreshSeconds = Math.Clamp(RefreshSeconds, 60, 3600),
        EnabledTools = (EnabledTools ?? []).Where(Enum.IsDefined).Distinct().ToArray(),
        DiscoverLocalTools = (DiscoverLocalTools ?? []).Where(x => Enum.IsDefined(x) && x != Provider.Antigravity).Distinct().ToArray(),
        ViewingAccounts = ViewingAccounts is null ? new() : new(ViewingAccounts),
        OverlayX = OverlayX is { } x && double.IsFinite(x) ? x : null,
        OverlayY = OverlayY is { } y && double.IsFinite(y) ? y : null,
        OverlayTool = OverlayTool is "auto" or "Codex" or "Claude" or "Antigravity" ? OverlayTool : "auto"
    };
}

public sealed record SourceCheckpoint(string Id, Provider Provider, string Path, long Offset, long Length, long LastWriteTicks,
    long CreationTicks, int HeadLength, string HeadHash, string TailHash, string ParserState);
public sealed record ScanReport(int Discovered, int Updated, int Unchanged, int Failed, long Events, DateTimeOffset CompletedAt, string? Message = null);
public sealed record UsageReport(long Tokens, long Input, long Cached, long Output, long CacheWrite, int Sessions,
    decimal? ApiValue, int UnpricedEvents, IReadOnlyList<UsageBucket> Days, IReadOnlyList<UsageBucket> Models, IReadOnlyList<UsageBucket> Efforts);
public sealed record TranscriptPage(IReadOnlyList<TranscriptLine> Lines, long? NextOffset);
public sealed record SearchHit(string SourceId, string SessionId, string Path, string Preview, long Offset);
public sealed record TrashEntry(string Id, string SourceId, string SessionId, string OriginalPath, string StoredPath, DateTimeOffset CreatedAt, string State);
