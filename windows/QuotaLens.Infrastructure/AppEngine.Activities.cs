using QuotaLens.Core;

namespace QuotaLens.Infrastructure;

public sealed partial class AppEngine
{
    private readonly SemaphoreSlim activityGate = new(1, 1);
    private async Task<ScanReport> ScanAntigravityAsync(CancellationToken ct)
    {
        using var linked = CancellationTokenSource.CreateLinkedTokenSource(ct, lifetime.Token);
        await activityGate.WaitAsync(linked.Token).ConfigureAwait(false);
        try {
            int found = 0, updated = 0, failed = 0; long tasks = 0;
            foreach (var path in ActivitySources.Candidates(Settings)) {
                linked.Token.ThrowIfCancellationRequested(); if (!File.Exists(path)) continue; found++;
                try {
                    var records = await AntigravityActivityReader.ReadAsync(path, linked.Token).ConfigureAwait(false);
                    // Profile identity is local-source scoped, never the current query account.
                    string profile = "windows-" + UsageParser.Hash(Path.GetFullPath(path).ToUpperInvariant())[..16];
                    await Database.SaveActivitiesAsync(profile, records.Select(x => x with { Profile = profile }).ToArray(), linked.Token).ConfigureAwait(false);
                    tasks += records.Count; updated++;
                } catch (Exception error) when (error is not OperationCanceledException) {
                    failed++; Warning = "Antigravity: " + SafeErrors.Describe(error).Message;
                }
            }
            if (found == 0) throw new QuotaException(FailureKind.NotConnected,
                "No Antigravity state database was found. Choose state.vscdb in Tool settings. Previous activity was retained.");
            lastScan[Provider.Antigravity] = DateTimeOffset.UtcNow; dirty.TryRemove(Provider.Antigravity, out _);
            ScanProgress = $"Antigravity: {updated} profiles updated · {failed} unavailable"; Changed?.Invoke();
            return new(found, updated, 0, failed, tasks, DateTimeOffset.UtcNow,
                failed == 0 ? null : "Unavailable profiles retained their previous activity.");
        } finally { activityGate.Release(); }
    }
}
