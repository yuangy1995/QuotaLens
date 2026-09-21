using System.Collections.Concurrent;
using System.Reflection;
using QuotaLens.Core;
using QuotaLens.Providers;

namespace QuotaLens.Infrastructure;

/// <summary>Application lifetime and scheduling, separate from the UI and account lifecycle.
/// Disk scans and network queries run independently; neither blocks first paint.</summary>
public sealed partial class AppEngine : IAsyncDisposable
{
    private AppSettings currentSettings = new();
    private readonly CancellationTokenSource lifetime = new();
    private readonly SemaphoreSlim settingsGate = new(1, 1);
    private readonly List<FileSystemWatcher> watchers = [];
    private readonly ConcurrentDictionary<Provider, DateTimeOffset> dirty = new();
    private readonly ConcurrentDictionary<Provider, DateTimeOffset> lastScan = new();
    private readonly ConcurrentDictionary<Provider, DateTimeOffset> lastDiscovery = new();
    private readonly ConcurrentDictionary<string, DateTimeOffset> lastRefresh = new();
    private readonly ConcurrentDictionary<string, QuotaSnapshot> previousNotifications = new();
    private CancellationTokenSource background = new();
    private Task? networkTask;
    private Task? scanTask;
    private int started;
    public AppSettings Settings => Volatile.Read(ref currentSettings);
    public CancellationToken Cancellation => lifetime.Token;
    public LocalDatabase Database { get; }
    public CredentialVault Vault { get; }
    public ProviderClient Client { get; }
    public AccountService Accounts { get; }
    public UsageIndexer Indexer { get; }
    public RecoveryService Recovery { get; }
    public string Version { get; }
    public string? Warning { get; private set; }
    public string ScanProgress { get; private set; } = "";
    public IReadOnlyList<Price> Prices { get; } = StandardPriceCatalog.Entries;
    public event Action? Changed;
    public event Action<string, string>? NotificationRequested;

    public AppEngine(string? root = null, string? version = null)
    {
        Version = version ?? Assembly.GetEntryAssembly()?.GetName().Version?.ToString(3) ?? "1.1.1";
        Database = new(root ?? SecureFiles.DefaultRoot); Vault = new(Path.Combine(Database.Root, "EncryptedCredentials"));
        Client = new() { ApplicationVersion = Version };
        Accounts = new(Database, Vault, Client, () => Settings);
        Indexer = new(Database); Recovery = new(Database, Indexer);
        Accounts.Changed += OnAccountChanged;
        Indexer.Progress += message => { ScanProgress = message; Changed?.Invoke(); };
    }
    public async Task InitializeAsync(bool startBackground = true, CancellationToken ct = default)
    {
        await Database.InitializeAsync(ct).ConfigureAwait(false);
        try { currentSettings = (await Database.GetMetadataAsync<AppSettings>("settings", ct).ConfigureAwait(false) ?? new()).Normalize(); }
        catch (Exception error) when (error is not OperationCanceledException)
        { Warning = "Saved preferences could not be read. Monitoring remains disabled until you save Settings. " + SafeErrors.Describe(error).Message; }
        await Accounts.InitializeAsync(ct).ConfigureAwait(false);
        int retained = await PrivateCodexHome.RecoverAsync(Database.Root, Accounts.Views.Select(x => x.Account).ToArray(), Vault, ct).ConfigureAwait(false);
        if (retained > 0) Warning = "Some private Codex runtime files require recovery. They were retained to avoid losing rotated authorization.";
        await Recovery.RecoverAsync(ct).ConfigureAwait(false);
        Changed?.Invoke();
        if (startBackground) Start();
    }
    private void Start()
    {
        if (Interlocked.Exchange(ref started, 1) != 0) return;
        ConfigureWatchers();
        networkTask = Task.Run(NetworkLoopAsync);
        scanTask = Task.Run(ScanLoopAsync);
    }
    public Task SaveSettingsAsync(AppSettings value, CancellationToken ct = default) => UpdateSettingsAsync(_ => value, ct);
    public async Task UpdateSettingsAsync(Func<AppSettings, AppSettings> change, CancellationToken ct = default)
    {
        ArgumentNullException.ThrowIfNull(change);
        await settingsGate.WaitAsync(ct).ConfigureAwait(false);
        try
        {
            // Apply the callback inside the gate, so navigation and settings never lose a concurrent update.
            var value = change(Settings).Normalize();
            await Database.PutMetadataAsync("settings", value, ct).ConfigureAwait(false);
            var old = Settings; Volatile.Write(ref currentSettings, value);
            bool monitoringChanged = old.Paused != value.Paused || !old.EnabledTools.SequenceEqual(value.EnabledTools) ||
                !old.DiscoverLocalTools.SequenceEqual(value.DiscoverLocalTools) || old.CodexHome != value.CodexHome || old.ClaudeHome != value.ClaudeHome || old.AntigravityStateFile != value.AntigravityStateFile;
            if (monitoringChanged)
            {
                var replacement = CancellationTokenSource.CreateLinkedTokenSource(lifetime.Token);
                var cancelled = Interlocked.Exchange(ref background, replacement); cancelled.Cancel();
                retiredSources.Add(cancelled); lastDiscovery.Clear(); lastRefresh.Clear(); lastScan.Clear();
                ConfigureWatchers();
            }
            Changed?.Invoke();
        }
        finally { settingsGate.Release(); }
    }
    private readonly List<CancellationTokenSource> retiredSources = [];
    public string? ViewingKey(Provider provider)
    {
        var selected = Settings.ViewingAccounts.GetValueOrDefault(provider.ToString());
        return Accounts.Views.Any(x => x.Account.Key == selected && x.Account.Provider == provider) ? selected :
            Accounts.Views.FirstOrDefault(x => x.Account.Provider == provider)?.Account.Key;
    }
    public async Task SelectAccountAsync(Provider provider, string key, CancellationToken ct = default)
    {
        if (Accounts.View(key)?.Account.Provider != provider) return;
        await UpdateSettingsAsync(s => s with {
            ViewingAccounts = new Dictionary<string, string>(s.ViewingAccounts) { [provider.ToString()] = key }
        }, ct).ConfigureAwait(false);
    }
    public async Task RefreshAsync(Provider? provider = null, CancellationToken ct = default)
    {
        using var linked = CancellationTokenSource.CreateLinkedTokenSource(ct, lifetime.Token);
        var enabled = Settings.EnabledTools.Where(x => provider is null || x == provider);
        var keys = enabled.SelectMany(x => new[] { ViewingKey(x), Accounts.ActualAccountKey(x) }).OfType<string>().Distinct().ToArray();
        await Task.WhenAll(keys.Select(key => Accounts.RefreshAsync(key, true, linked.Token))).ConfigureAwait(false);
    }
    public async Task<ScanReport> ScanAsync(Provider provider, bool rebuild = false, CancellationToken ct = default)
    {
        if (!Settings.EnabledTools.Contains(provider)) throw new QuotaException(FailureKind.NotConnected, "Enable the tool before scanning its local records.");
        if (provider == Provider.Antigravity) return await ScanAntigravityAsync(ct).ConfigureAwait(false);
        using var linked = CancellationTokenSource.CreateLinkedTokenSource(ct, lifetime.Token);
        var result = await Indexer.ScanAsync(provider, LocalSources.UsageRoots(provider, Settings), rebuild, linked.Token).ConfigureAwait(false);
        lastScan[provider] = DateTimeOffset.UtcNow; dirty.TryRemove(provider, out _); Changed?.Invoke(); return result;
    }
    public void ClearWarning() { Warning = null; Changed?.Invoke(); }
    private async Task NetworkLoopAsync()
    {
        DateTimeOffset lastRenewal = DateTimeOffset.MinValue;
        using var timer = new PeriodicTimer(TimeSpan.FromSeconds(10));
        do
        {
            try
            {
                if (Settings.Paused) continue;
                var ct = background.Token;
                foreach (var provider in Settings.EnabledTools)
                {
                    ct.ThrowIfCancellationRequested();
                    if (Settings.DiscoverLocalTools.Contains(provider) && DateTimeOffset.UtcNow - lastDiscovery.GetValueOrDefault(provider) >= TimeSpan.FromMinutes(1))
                    {
                        lastDiscovery[provider] = DateTimeOffset.UtcNow;
                        try { await Accounts.ImportLocalAsync(provider, false, ct).ConfigureAwait(false); }
                        catch (Exception error) when (error is not OperationCanceledException)
                        { Warning = provider + ": " + SafeErrors.Describe(error).Message; Changed?.Invoke(); }
                    }
                }
                if (DateTimeOffset.UtcNow - lastRenewal >= TimeSpan.FromMinutes(1))
                {
                    lastRenewal = DateTimeOffset.UtcNow;
                    await Accounts.RenewExpiringAsync(ct).ConfigureAwait(false);
                }
                var keys = Settings.EnabledTools.SelectMany(provider => new[] { ViewingKey(provider), Accounts.ActualAccountKey(provider) })
                    .OfType<string>().Distinct().Where(key => DateTimeOffset.UtcNow - lastRefresh.GetValueOrDefault(key) >= TimeSpan.FromSeconds(Settings.RefreshSeconds)).ToArray();
                foreach (var key in keys) lastRefresh[key] = DateTimeOffset.UtcNow;
                await Task.WhenAll(keys.Select(key => Accounts.RefreshAsync(key, false, ct))).ConfigureAwait(false);
            }
            catch (OperationCanceledException) { if (lifetime.IsCancellationRequested) break; }
            catch (Exception error) { Warning = SafeErrors.Describe(error).Message; Changed?.Invoke(); }
        } while (await NextTickAsync(timer).ConfigureAwait(false));
    }
    private async Task ScanLoopAsync()
    {
        using var timer = new PeriodicTimer(TimeSpan.FromSeconds(5));
        do
        {
            try
            {
                if (Settings.Paused) continue;
                var ct = background.Token;
                foreach (var provider in Settings.EnabledTools)
                {
                    ct.ThrowIfCancellationRequested();
                    bool changed = dirty.TryGetValue(provider, out var changedAt) && DateTimeOffset.UtcNow - changedAt >= TimeSpan.FromSeconds(2);
                    var elapsed = DateTimeOffset.UtcNow - lastScan.GetValueOrDefault(provider);
                    if (elapsed >= TimeSpan.FromMinutes(5) || changed && elapsed >= TimeSpan.FromSeconds(15))
                    {
                        try { await ScanAsync(provider, ct: ct).ConfigureAwait(false); }
                        catch (Exception error) when (error is not OperationCanceledException) {
                            Warning = provider + ": " + SafeErrors.Describe(error).Message; Changed?.Invoke();
                        }
                        finally { lastScan[provider] = DateTimeOffset.UtcNow; }
                    }
                }
            }
            catch (OperationCanceledException) { if (lifetime.IsCancellationRequested) break; }
            catch (Exception error) { Warning = SafeErrors.Describe(error).Message; Changed?.Invoke(); }
        } while (await NextTickAsync(timer).ConfigureAwait(false));
    }
    private async Task<bool> NextTickAsync(PeriodicTimer timer)
    {
        try { return await timer.WaitForNextTickAsync(lifetime.Token).ConfigureAwait(false); }
        catch (OperationCanceledException) { return false; }
    }
    private void ConfigureWatchers()
    {
        lock (watchers)
        {
            foreach (var watcher in watchers) watcher.Dispose(); watchers.Clear();
            if (Settings.Paused || started == 0) return;
            foreach (var provider in Settings.EnabledTools)
            {
                var sources = provider == Provider.Antigravity ? ActivitySources.Candidates(Settings) : LocalSources.UsageRoots(provider, Settings);
                foreach (var source in sources)
                {
                    try
                    {
                        string? root = provider == Provider.Antigravity ? Path.GetDirectoryName(source) : source;
                        if (root is null) continue;
                        SecureFiles.RejectReparseChain(root); if (!Directory.Exists(root)) continue;
                        var watcher = new FileSystemWatcher(root, provider == Provider.Antigravity ? Path.GetFileName(source) + "*" : "*.jsonl") { IncludeSubdirectories = provider != Provider.Antigravity,
                            NotifyFilter = NotifyFilters.LastWrite | NotifyFilters.Size | NotifyFilters.FileName | NotifyFilters.DirectoryName };
                        watcher.Changed += (_, _) => dirty[provider] = DateTimeOffset.UtcNow;
                        watcher.Created += (_, _) => dirty[provider] = DateTimeOffset.UtcNow;
                        watcher.Deleted += (_, _) => dirty[provider] = DateTimeOffset.UtcNow;
                        watcher.Renamed += (_, _) => dirty[provider] = DateTimeOffset.UtcNow;
                        watcher.Error += (_, _) => dirty[provider] = DateTimeOffset.UtcNow;
                        watcher.EnableRaisingEvents = true; watchers.Add(watcher);
                    }
                    catch (Exception error) when (error is IOException or UnauthorizedAccessException or InvalidDataException) { dirty[provider] = DateTimeOffset.UtcNow; }
                }
            }
        }
    }
    private void OnAccountChanged()
    {
        Changed?.Invoke();
        foreach (var view in Accounts.Views)
        {
            if (view.Quota is not { } snapshot) continue;
            var previous = previousNotifications.GetValueOrDefault(view.Account.Key);
            previousNotifications[view.Account.Key] = snapshot;
            if (!Settings.Notifications || previous is null || snapshot.ObservedAt <= previous.ObservedAt ||
                Accounts.ActualAccountKey(view.Account.Provider) != view.Account.Key || view.Status.Failure is not null) continue;
            foreach (var pool in snapshot.Pools.Where(x => x.WindowMinutes == 10080 && x.IsCurrent(DateTimeOffset.UtcNow) && x.UsedPercent == 0))
            {
                if (previous.Pools.FirstOrDefault(x => x.Id == pool.Id)?.UsedPercent > 0)
                    _ = SendRecoveryNotificationAsync(view.Account.Provider, snapshot.AccountKey, pool);
            }
        }
    }
    private async Task SendRecoveryNotificationAsync(Provider provider, string account, QuotaPool pool)
    {
        try
        {
            if (await Database.MarkNotificationAsync($"{account}:{pool.Id}:{pool.ResetsAt:O}", lifetime.Token).ConfigureAwait(false))
                NotificationRequested?.Invoke("QuotaLens · " + provider, "周额度已恢复。Weekly quota is available again.");
        }
        catch (Exception error) when (error is OperationCanceledException or Microsoft.Data.Sqlite.SqliteException or InvalidOperationException) { }
    }
    public async ValueTask DisposeAsync()
    {
        lifetime.Cancel(); background.Cancel();
        lock (watchers) { foreach (var watcher in watchers) watcher.Dispose(); watchers.Clear(); }
        try { await Task.WhenAll(new[] { networkTask, scanTask }.OfType<Task>()).ConfigureAwait(false); }
        catch (OperationCanceledException) { }
        Accounts.Changed -= OnAccountChanged;
        Client.Dispose(); Vault.Dispose(); Database.Dispose();
        activityGate.Dispose(); background.Dispose(); foreach (var source in retiredSources) source.Dispose(); lifetime.Dispose(); settingsGate.Dispose();
    }
}
