using System.Collections.Concurrent;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using QuotaLens.Core;
using QuotaLens.Providers;

namespace QuotaLens.Infrastructure;

public sealed record AccountView(Account Account, QuotaSnapshot? Quota, SyncStatus Status,
    CodexExtendedSnapshot? Extended, SubscriptionInfo? Subscription);
public sealed record ImportResult(Account? Account, bool Changed, string? Message = null);
public sealed record ResetHistoryEvent(string Id, string Kind, DateTimeOffset OccurredAt);
public sealed record ResetHistoryPage(IReadOnlyList<ResetHistoryEvent> Events, DateTimeOffset AsOf, DateTimeOffset WindowStart, string? NextCursor);

/// <summary>Query-account lifecycle. The UI selection is never used to change a third-party tool login.
/// A provider gate serializes refresh-token rotation, imports and removal. Different providers may run concurrently.</summary>
public sealed class AccountService(LocalDatabase database, ICredentialVault vault, ProviderClient client, Func<AppSettings> settings)
{
    private readonly ConcurrentDictionary<string, Account> accounts = new();
    private readonly ConcurrentDictionary<string, Credential> liveCredentials = new();
    private readonly ConcurrentDictionary<string, Credential> rotatedImports = new();
    private readonly ConcurrentDictionary<string, QuotaSnapshot> snapshots = new();
    private readonly ConcurrentDictionary<string, SyncStatus> statuses = new();
    private readonly ConcurrentDictionary<string, CodexExtendedSnapshot> extended = new();
    private readonly ConcurrentDictionary<string, SubscriptionInfo> subscriptions = new();
    private readonly ConcurrentDictionary<Provider, LocalIdentity> localIdentities = new();
    private readonly Dictionary<Provider, SemaphoreSlim> gates = Enum.GetValues<Provider>().ToDictionary(x => x, _ => new SemaphoreSlim(1, 1));
    public event Action? Changed;
    public ProviderClient Client => client;
    public IReadOnlyList<AccountView> Views => accounts.Values.OrderBy(x => x.Provider).ThenBy(x => x.DisplayName, StringComparer.OrdinalIgnoreCase)
        .Select(x => new AccountView(x, snapshots.GetValueOrDefault(x.Key), statuses.GetValueOrDefault(x.Key) ?? new(),
            extended.GetValueOrDefault(x.Key), subscriptions.GetValueOrDefault(x.Key))).ToArray();
    public AccountView? View(string? key) => key is not null ? Views.FirstOrDefault(x => x.Account.Key == key) : null;
    public string? ActualAccountKey(Provider provider) => localIdentities.TryGetValue(provider, out var value) && accounts.ContainsKey(value.AccountKey) ? value.AccountKey : null;
    public bool IsEnabled(Provider provider) => settings().EnabledTools.Contains(provider);
    private void Notify() => Changed?.Invoke();
    private void RequireEnabled(Provider provider)
    { if (!IsEnabled(provider)) throw new QuotaException(FailureKind.NotConnected, "Enable this tool before querying its accounts."); }

    public async Task InitializeAsync(CancellationToken ct)
    {
        var saved = await database.AccountsAsync(ct).ConfigureAwait(false);
        foreach (var account in saved)
        {
            accounts[account.Key] = account;
            try
            {
                if (await database.LatestQuotaAsync(account.Key, ct).ConfigureAwait(false) is { } quota) snapshots[account.Key] = quota;
                if (await database.GetMetadataAsync<CodexExtendedSnapshot>("extended_" + account.Key, ct).ConfigureAwait(false) is { } extra && extra.Quota.AccountKey == account.Key)
                    extended[account.Key] = extra;
                if (await database.GetMetadataAsync<SubscriptionInfo>("subscription_" + account.Key, ct).ConfigureAwait(false) is { } subscription && subscription.AccountKey == account.Key)
                    subscriptions[account.Key] = subscription;
                statuses[account.Key] = new(snapshots.GetValueOrDefault(account.Key)?.ObservedAt, Message: "Cached data. Waiting for refresh.");
            }
            catch (Exception error) when (error is not OperationCanceledException) { SetFailure(account.Key, error); }
        }
        // Actual tool identity is deliberately revalidated from an explicitly enabled local import.
        // A previous main-window selection is never treated as the current tool's account.
        client.GoogleConfiguration = await vault.LoadAsync<GoogleOAuthConfiguration>("google_oauth_client", ct).ConfigureAwait(false);
        Notify();
    }
    public async Task SetGoogleConfigurationAsync(GoogleOAuthConfiguration? configuration, CancellationToken ct)
    {
        await gates[Provider.Antigravity].WaitAsync(ct).ConfigureAwait(false);
        try
        {
            if (configuration is null) await vault.RemoveAsync("google_oauth_client", ct).ConfigureAwait(false);
            else await vault.SaveAsync("google_oauth_client", configuration, ct).ConfigureAwait(false);
            client.GoogleConfiguration = configuration;
        }
        finally { gates[Provider.Antigravity].Release(); }
    }
    private void SetFailure(string key, Exception error)
    {
        var safe = SafeErrors.Describe(error);
        if (safe.Kind == FailureKind.Cancelled) return;
        statuses[key] = new(snapshots.GetValueOrDefault(key)?.ObservedAt, safe.Kind, safe.Message, safe.RetryAt);
        Notify();
    }
    private async Task<Credential> LoadAsync(Account account, CancellationToken ct)
    {
        if (liveCredentials.TryGetValue(account.Key, out var value)) return value;
        value = await vault.LoadAsync<Credential>(account.Key, ct).ConfigureAwait(false)
            ?? throw new QuotaException(FailureKind.NotConnected, "The saved credential is missing. Import or authorize this account again.");
        if (value.Provider != account.Provider) throw new QuotaException(FailureKind.Identity, "The credential provider does not match this account.");
        return value;
    }
    private async Task SaveRotatedAsync(Account account, Credential credential, CancellationToken ct)
    {
        if (account.Provider != credential.Provider) throw new QuotaException(FailureKind.Identity, "The returned credential belongs to another tool.");
        if (account.Provider == Provider.Codex)
        {
            var identity = JsonTools.JwtClaims(credential.AccessToken).At("https://api.openai.com/auth", "chatgpt_account_id").Text();
            if (identity != account.ProviderId) throw new QuotaException(FailureKind.Identity, "The returned Codex credential belongs to another account.");
        }
        // Keep the new token in memory before disk I/O. A failed save must never cause old-token rotation again.
        liveCredentials[account.Key] = credential;
        await vault.SaveAsync(account.Key, credential, ct).ConfigureAwait(false);
    }
    private async Task<Credential> FreshAsync(Account account, Credential credential, CancellationToken ct, bool force = false)
    {
        if (!force && !credential.NeedsRefresh(DateTimeOffset.UtcNow)) return credential;
        if (credential.RefreshToken is null)
        {
            if (!force && credential.AccessToken.Length > 0 && (credential.EffectiveExpiry is null || credential.EffectiveExpiry > DateTimeOffset.UtcNow)) return credential;
            throw new QuotaException(FailureKind.Expired, "This account requires authorization again; no refresh token is available.");
        }
        if (credential.Provider == Provider.Antigravity && client.GoogleConfiguration is null && !force &&
            credential.AccessToken.Length > 0 && (credential.EffectiveExpiry is null || credential.EffectiveExpiry > DateTimeOffset.UtcNow)) return credential;
        var updated = await client.RefreshAsync(credential, ct).ConfigureAwait(false);
        await SaveRotatedAsync(account, updated, ct).ConfigureAwait(false);
        return updated;
    }
    private async Task<(QueryResult Result, Credential Credential)> QueryVerifiedAsync(Account expected, Credential credential, CancellationToken ct)
    {
        credential = await FreshAsync(expected, credential, ct).ConfigureAwait(false);
        QueryResult result;
        try { result = await client.QueryAsync(credential, ct).ConfigureAwait(false); }
        catch (QuotaException error) when (error.Kind == FailureKind.Expired && credential.RefreshToken is not null)
        {
            credential = await FreshAsync(expected, credential, ct, force: true).ConfigureAwait(false);
            result = await client.QueryAsync(credential, ct).ConfigureAwait(false);
        }
        if (result.Account.Key != expected.Key || result.Account.ProviderId != expected.ProviderId || result.Account.Provider != expected.Provider)
            throw new QuotaException(FailureKind.Identity, "The service returned another account. Its data was not saved under the selected identity.");
        return (result, credential);
    }

    public async Task<ImportResult> ImportAsync(Credential input, string source, bool explicitImport, string? localFingerprint, CancellationToken ct)
    {
        RequireEnabled(input.Provider);
        await gates[input.Provider].WaitAsync(ct).ConfigureAwait(false);
        try
        {
            string fingerprint = UsageParser.Hash(input.Provider + "|" + input.AccessToken + "|" + input.RefreshToken);
            var credential = rotatedImports.GetValueOrDefault(fingerprint) ?? input;
            if (credential.NeedsRefresh(DateTimeOffset.UtcNow) && credential.RefreshToken is not null &&
                !(credential.Provider == Provider.Antigravity && client.GoogleConfiguration is null && credential.AccessToken.Length > 0 &&
                    (credential.EffectiveExpiry is null || credential.EffectiveExpiry > DateTimeOffset.UtcNow)))
            {
                credential = await client.RefreshAsync(credential, ct).ConfigureAwait(false);
                rotatedImports[fingerprint] = credential;
            }
            QueryResult result;
            try { result = await client.QueryAsync(credential, ct).ConfigureAwait(false); }
            catch (QuotaException error) when (error.Kind == FailureKind.Expired && credential.RefreshToken is not null)
            {
                credential = await client.RefreshAsync(credential, ct).ConfigureAwait(false);
                rotatedImports[fingerprint] = credential;
                result = await client.QueryAsync(credential, ct).ConfigureAwait(false);
            }
            if (!explicitImport && await database.IsDiscoveryExcludedAsync(result.Account.Key, ct).ConfigureAwait(false))
                return new(null, false, "This account was previously removed. Explicit import is required to add it again.");
            var previous = accounts.GetValueOrDefault(result.Account.Key);
            bool preserveIndependent = source == "local" && previous?.Source == "independent";
            var account = result.Account with { Source = preserveIndependent ? previous!.Source : source, Alias = previous?.Alias };
            if (!preserveIndependent)
            {
                liveCredentials[account.Key] = credential;
                await vault.SaveAsync(account.Key, credential, ct).ConfigureAwait(false);
            }
            await database.SaveAccountAsync(account, explicitImport, ct).ConfigureAwait(false);
            await database.SaveQuotaAsync(result.Snapshot, ct: ct).ConfigureAwait(false);
            accounts[account.Key] = account; snapshots[account.Key] = result.Snapshot;
            statuses[account.Key] = new(result.Snapshot.ObservedAt, Message: preserveIndependent ? "Local identity verified; independent authorization was retained." : null);
            if (source == "local" && localFingerprint is not null)
            {
                var identity = new LocalIdentity(account.Key, localFingerprint, DateTimeOffset.UtcNow);
                localIdentities[account.Provider] = identity;
                await database.PutMetadataAsync("local_identity_" + account.Provider, identity, ct).ConfigureAwait(false);
            }
            rotatedImports.TryRemove(fingerprint, out _); Notify();
            return new(account, previous is null || !preserveIndependent, preserveIndependent ? "Existing independent authorization was preserved." : null);
        }
        finally { gates[input.Provider].Release(); }
    }
    public async Task<ImportResult> ImportLocalAsync(Provider provider, bool explicitImport, CancellationToken ct)
    {
        RequireEnabled(provider);
        if (!explicitImport && !settings().DiscoverLocalTools.Contains(provider)) return new(null, false);
        try
        {
            var local = await LocalSources.ReadCredentialAsync(provider, settings(), ct).ConfigureAwait(false);
            if (!explicitImport && localIdentities.TryGetValue(provider, out var saved) && saved.Fingerprint == local.Fingerprint && accounts.TryGetValue(saved.AccountKey, out var account))
                return new(account, false);
            return await ImportAsync(local.Credential, "local", explicitImport, local.Fingerprint, ct).ConfigureAwait(false);
        }
        catch
        {
            localIdentities.TryRemove(provider, out _); Notify(); throw;
        }
    }
    public async Task RefreshAsync(string key, bool force, CancellationToken ct)
    {
        if (!accounts.TryGetValue(key, out var account)) return;
        RequireEnabled(account.Provider);
        await gates[account.Provider].WaitAsync(ct).ConfigureAwait(false);
        try
        {
            if (!accounts.TryGetValue(key, out account)) return;
            var status = statuses.GetValueOrDefault(key);
            if (status?.RetryAt > DateTimeOffset.UtcNow) return;
            if (!force && snapshots.GetValueOrDefault(key)?.ObservedAt > DateTimeOffset.UtcNow.AddSeconds(-45)) return;
            var credential = await LoadAsync(account, ct).ConfigureAwait(false);
            var (result, fresh) = await QueryVerifiedAsync(account, credential, ct).ConfigureAwait(false);
            var quota = result.Snapshot; string? warning = null;
            if (account.Provider == Provider.Codex && settings().CollectCodexCloudUsage)
            {
                try
                {
                    var extra = await RunCodexLockedAsync(account, fresh, (rpc, token) => rpc.ReadExtendedAsync(account, token), ct).ConfigureAwait(false);
                    quota = extra.Quota; extended[key] = extra; warning = extra.Warning;
                    await database.PutMetadataAsync("extended_" + key, extra, ct).ConfigureAwait(false);
                }
                catch (Exception error) when (error is not OperationCanceledException) { warning = SafeErrors.Describe(error).Message; }
            }
            await database.SaveQuotaAsync(quota, subscriptions.GetValueOrDefault(key)?.Plan, ct).ConfigureAwait(false);
            snapshots[key] = quota;
            var verified = result.Account with { Source = account.Source, Alias = account.Alias };
            await database.SaveAccountAsync(verified, ct: ct).ConfigureAwait(false); accounts[key] = verified;
            statuses[key] = new(quota.ObservedAt, Message: warning); Notify();
        }
        catch (Exception error) when (error is not OperationCanceledException) { SetFailure(key, error); }
        finally { gates[account.Provider].Release(); }
    }
    public async Task RenewExpiringAsync(CancellationToken ct)
    {
        foreach (var account in accounts.Values.Where(x => IsEnabled(x.Provider)))
        {
            ct.ThrowIfCancellationRequested();
            if (statuses.GetValueOrDefault(account.Key)?.RetryAt > DateTimeOffset.UtcNow) continue;
            await gates[account.Provider].WaitAsync(ct).ConfigureAwait(false);
            try
            {
                if (!accounts.ContainsKey(account.Key)) continue;
                var credential = await LoadAsync(account, ct).ConfigureAwait(false);
                if (credential.RefreshToken is not null && credential.NeedsRefresh(DateTimeOffset.UtcNow))
                    await FreshAsync(account, credential, ct).ConfigureAwait(false);
                else if (liveCredentials.ContainsKey(account.Key))
                    await vault.SaveAsync(account.Key, credential, ct).ConfigureAwait(false);
            }
            catch (Exception error) when (error is not OperationCanceledException) { SetFailure(account.Key, error); }
            finally { gates[account.Provider].Release(); }
        }
    }
    public async Task RenameAsync(string key, string alias, CancellationToken ct)
    {
        if (!accounts.TryGetValue(key, out var account)) return;
        alias = alias.Trim(); if (alias.Length > 100) throw new InvalidDataException("Account notes are limited to 100 characters.");
        await gates[account.Provider].WaitAsync(ct).ConfigureAwait(false);
        try
        {
            if (!accounts.TryGetValue(key, out account)) return;
            var renamed = account with { Alias = alias.Length == 0 ? null : alias };
            await database.SaveAccountAsync(renamed, ct: ct).ConfigureAwait(false); accounts[key] = renamed; Notify();
        }
        finally { gates[account.Provider].Release(); }
    }
    public async Task RemoveAsync(string key, CancellationToken ct)
    {
        if (!accounts.TryGetValue(key, out var account)) return;
        await gates[account.Provider].WaitAsync(ct).ConfigureAwait(false);
        try
        {
            await vault.RemoveAsync(key, ct).ConfigureAwait(false); liveCredentials.TryRemove(key, out _);
            await database.RemoveAccountAsync(key, ct).ConfigureAwait(false);
            accounts.TryRemove(key, out _); statuses.TryRemove(key, out _);
            if (localIdentities.GetValueOrDefault(account.Provider)?.AccountKey == key) localIdentities.TryRemove(account.Provider, out _);
            Notify();
        }
        finally { gates[account.Provider].Release(); }
    }
    public async Task<string> ExportAsync(IEnumerable<string> keys, CancellationToken ct)
    {
        var exports = new List<object>();
        foreach (var key in keys.Distinct())
        {
            if (!accounts.TryGetValue(key, out var account)) continue;
            await gates[account.Provider].WaitAsync(ct).ConfigureAwait(false);
            try { exports.Add(new { provider = account.Provider.ToString(), credential = await LoadAsync(account, ct).ConfigureAwait(false) }); }
            finally { gates[account.Provider].Release(); }
        }
        return JsonSerializer.Serialize(new { format = "quotalens-credentials", version = 1, accounts = exports }, JsonTools.Options);
    }
    private async Task<T> RunCodexLockedAsync<T>(Account account, Credential credential, Func<CodexRpc, CancellationToken, Task<T>> action, CancellationToken ct)
    {
        var executable = LocalSources.FindCodexExecutable(settings()) ?? throw new QuotaException(FailureKind.NotConnected,
            "Codex quota is available through HTTPS. Select codex.exe to enable cloud counters and reset-card operations.");
        var home = await PrivateCodexHome.CreateAsync(database.Root, account.Key, credential, ct).ConfigureAwait(false);
        bool mayDelete = true; CodexRpc? rpc = null;
        try
        {
            rpc = await CodexRpc.StartAsync(executable, home.Path, client.ApplicationVersion, ct).ConfigureAwait(false);
            return await action(rpc, ct).ConfigureAwait(false);
        }
        finally
        {
            if (rpc is not null) await rpc.DisposeAsync().ConfigureAwait(false);
            try
            {
                if (await home.ReadCredentialAsync(CancellationToken.None).ConfigureAwait(false) is { } rotated &&
                    (rotated.AccessToken != credential.AccessToken || rotated.RefreshToken != credential.RefreshToken))
                    await SaveRotatedAsync(account, rotated, CancellationToken.None).ConfigureAwait(false);
            }
            catch (Exception error) { mayDelete = false; SetFailure(account.Key, error); }
            if (mayDelete) { try { home.Delete(); } catch (Exception error) { SetFailure(account.Key, error); } }
        }
    }
    public async Task<Credential> AuthorizeCodexAsync(Func<Uri, Task> openBrowser, CancellationToken ct)
    {
        RequireEnabled(Provider.Codex);
        var executable = LocalSources.FindCodexExecutable(settings()) ?? throw new QuotaException(FailureKind.NotConnected, "Install Codex and select its native executable before browser authorization.");
        var home = await PrivateCodexHome.CreateAsync(database.Root, null, null, ct).ConfigureAwait(false);
        CodexRpc? rpc = null;
        try
        {
            rpc = await CodexRpc.StartAsync(executable, home.Path, client.ApplicationVersion, ct).ConfigureAwait(false);
            await rpc.AuthorizeAsync(openBrowser, ct).ConfigureAwait(false);
            await rpc.DisposeAsync().ConfigureAwait(false); rpc = null;
            return await home.ReadCredentialAsync(ct).ConfigureAwait(false) ?? throw new QuotaException(FailureKind.NotConnected, "Codex did not save a supported file-based authorization.");
        }
        finally
        {
            if (rpc is not null) await rpc.DisposeAsync().ConfigureAwait(false);
            home.Delete();
        }
    }
    public async Task<CodexExtendedSnapshot> LoadCreditsAsync(string key, CancellationToken ct)
    {
        var account = accounts.GetValueOrDefault(key) ?? throw new QuotaException(FailureKind.NotConnected, "Choose a verified account.");
        RequireEnabled(account.Provider);
        if (account.Provider != Provider.Codex) throw new ArgumentException("Codex account required.");
        await gates[Provider.Codex].WaitAsync(ct).ConfigureAwait(false);
        try
        {
            var credential = await FreshAsync(account, await LoadAsync(account, ct).ConfigureAwait(false), ct).ConfigureAwait(false);
            var extra = await RunCodexLockedAsync(account, credential, (rpc, token) => rpc.ReadExtendedAsync(account, token), ct).ConfigureAwait(false);
            await database.PutMetadataAsync("extended_" + key, extra, ct).ConfigureAwait(false);
            await database.SaveQuotaAsync(extra.Quota, subscriptions.GetValueOrDefault(key)?.Plan, ct).ConfigureAwait(false);
            extended[key] = extra; snapshots[key] = extra.Quota; statuses[key] = new(extra.Quota.ObservedAt, Message: extra.Warning); Notify(); return extra;
        }
        finally { gates[Provider.Codex].Release(); }
    }
    public async Task<string> ConsumeCreditAsync(string key, string creditId, bool retryUncertain, CancellationToken ct)
    {
        var account = accounts.GetValueOrDefault(key) ?? throw new QuotaException(FailureKind.NotConnected, "Choose a verified account.");
        RequireEnabled(Provider.Codex);
        if (account.Provider != Provider.Codex) throw new ArgumentException("Codex account required.");
        await gates[Provider.Codex].WaitAsync(ct).ConfigureAwait(false);
        try
        {
            var credential = await FreshAsync(account, await LoadAsync(account, ct).ConfigureAwait(false), ct).ConfigureAwait(false);
            return await RunCodexLockedAsync(account, credential, async (rpc, token) => {
                var latest = await rpc.ReadExtendedAsync(account, token, includeUsage: false).ConfigureAwait(false);
                if (!retryUncertain && !latest.Credits.Any(x => x.Id == creditId && x.Available(DateTimeOffset.UtcNow)))
                    throw new QuotaException(FailureKind.Incompatible, "This reset credit is no longer available.");
                var request = await database.PrepareRedemptionAsync(key, creditId, token).ConfigureAwait(false);
                if (request.State is not ("pending" or "uncertain")) return request.State;
                try
                {
                    var outcome = await rpc.ConsumeAsync(account, request, retryUncertain, token).ConfigureAwait(false);
                    await database.SaveRedemptionAsync(request with { State = outcome }, CancellationToken.None).ConfigureAwait(false);
                    return outcome;
                }
                catch
                {
                    await database.SaveRedemptionAsync(request with { State = "uncertain" }, CancellationToken.None).ConfigureAwait(false);
                    throw;
                }
            }, ct).ConfigureAwait(false);
        }
        finally { gates[Provider.Codex].Release(); }
    }
    public async Task<SubscriptionInfo> SubscriptionAsync(string key, CancellationToken ct)
    {
        var account = accounts.GetValueOrDefault(key) ?? throw new QuotaException(FailureKind.NotConnected, "Choose a verified account.");
        RequireEnabled(account.Provider); await gates[account.Provider].WaitAsync(ct).ConfigureAwait(false);
        try
        {
            var credential = await FreshAsync(account, await LoadAsync(account, ct).ConfigureAwait(false), ct).ConfigureAwait(false);
            var value = await client.SubscriptionAsync(account, credential, ct).ConfigureAwait(false);
            await database.PutMetadataAsync("subscription_" + key, value, ct).ConfigureAwait(false); subscriptions[key] = value; Notify(); return value;
        }
        finally { gates[account.Provider].Release(); }
    }
    public async Task<ResetHistoryPage> ResetHistoryAsync(string key, string? cursor, CancellationToken ct)
    {
        var account = accounts.GetValueOrDefault(key) ?? throw new QuotaException(FailureKind.NotConnected, "Choose a verified account.");
        RequireEnabled(account.Provider); await gates[account.Provider].WaitAsync(ct).ConfigureAwait(false);
        try
        {
            var credential = await FreshAsync(account, await LoadAsync(account, ct).ConfigureAwait(false), ct).ConfigureAwait(false);
            var root = await client.ResetHistoryAsync(account, credential, cursor, ct).ConfigureAwait(false);
            if (root.At("events").ValueKind != JsonValueKind.Array) throw HttpTransport.FormatError();
            var rows = root.At("events").Items().Select(item => new ResetHistoryEvent(
                item.At("id").Text() ?? throw HttpTransport.FormatError(), item.At("kind").Text() ?? throw HttpTransport.FormatError(),
                ReadDate(item.At("occurred_at")) ?? throw HttpTransport.FormatError())).ToArray();
            var page = new ResetHistoryPage(rows, root.At("as_of").Date() ?? throw HttpTransport.FormatError(),
                root.At("window_start").Date() ?? throw HttpTransport.FormatError(), root.At("next_cursor").Text());
            if (cursor is null) await database.PutMetadataAsync("reset_history_" + key, page, ct).ConfigureAwait(false);
            return page;
        }
        finally { gates[account.Provider].Release(); }
    }
    private static DateTimeOffset? ReadDate(JsonElement value)
    {
        if (value.Number() is > 10_000_000_000 and < 253402300800000 and var milliseconds)
            return DateTimeOffset.FromUnixTimeMilliseconds((long)milliseconds.Value);
        return value.Date();
    }
}
