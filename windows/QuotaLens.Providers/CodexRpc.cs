using System.Collections.Concurrent;
using System.Diagnostics;
using System.Runtime.CompilerServices;
using System.Text;
using System.Text.Json;
using System.Threading.Channels;
using QuotaLens.Core;

namespace QuotaLens.Providers;

public sealed class RpcException(int code) : Exception($"Codex RPC returned error {code}.")
{
    public int Code { get; } = code;
}

/// <summary>One isolated app-server per operation/account. The caller owns the private CODEX_HOME.
/// Requests are correlated, bounded and cancellable; stdout and stderr are never mixed.</summary>
public sealed class CodexRpc : IAsyncDisposable
{
    private readonly Process process;
    private readonly string home;
    private readonly ConcurrentDictionary<long, TaskCompletionSource<JsonElement>> pending = new();
    private readonly SemaphoreSlim writer = new(1, 1);
    private readonly CancellationTokenSource lifetime = new();
    private readonly Channel<JsonElement> notifications = Channel.CreateBounded<JsonElement>(new BoundedChannelOptions(64) {
        FullMode = BoundedChannelFullMode.DropOldest, SingleReader = true, SingleWriter = true });
    private readonly Task outputTask;
    private readonly Task errorTask;
    private long requestId;
    private int disposed;

    private CodexRpc(Process process, string home)
    {
        this.process = process; this.home = home;
        outputTask = ReadOutputAsync();
        errorTask = DrainErrorsAsync();
    }
    public static async Task<CodexRpc> StartAsync(string executable, string home, string version, CancellationToken ct)
    {
        if (!Path.IsPathFullyQualified(executable) || !File.Exists(executable))
            throw new QuotaException(FailureKind.NotConnected, "Choose the installed Codex executable in Settings.");
        if (!Directory.Exists(home)) throw new DirectoryNotFoundException("Private Codex home is missing.");
        var info = new ProcessStartInfo(executable) { UseShellExecute = false, CreateNoWindow = true,
            RedirectStandardInput = true, RedirectStandardOutput = true, RedirectStandardError = true,
            StandardOutputEncoding = new UTF8Encoding(false, true), StandardErrorEncoding = Encoding.UTF8,
            WorkingDirectory = home };
        // Current app-server defaults to stdio. Do not depend on the legacy --stdio alias.
        info.ArgumentList.Add("app-server"); info.ArgumentList.Add("-c"); info.ArgumentList.Add("cli_auth_credentials_store=\"file\"");
        foreach (var key in new[] { "OPENAI_API_KEY", "CODEX_API_KEY", "CODEX_ACCESS_TOKEN", "CODEX_AUTH_JSON", "CODEX_REMOTE_TOKEN" }) info.Environment.Remove(key);
        info.Environment["CODEX_HOME"] = home;
        var process = new Process { StartInfo = info };
        try { if (!process.Start()) throw new IOException("Could not start Codex."); }
        catch { process.Dispose(); throw; }
        var connection = new CodexRpc(process, home);
        try
        {
            await connection.CallAsync("initialize", new { clientInfo = new { name = "QuotaLens", version }, capabilities = new { } }, ct).ConfigureAwait(false);
            await connection.NotifyAsync("initialized", new { }, ct).ConfigureAwait(false);
            return connection;
        }
        catch { await connection.DisposeAsync().ConfigureAwait(false); throw; }
    }
    public async Task<JsonElement> CallAsync(string method, object parameters, CancellationToken ct, TimeSpan? timeout = null)
    {
        ObjectDisposedException.ThrowIf(disposed != 0, this);
        long id = Interlocked.Increment(ref requestId);
        var completion = new TaskCompletionSource<JsonElement>(TaskCreationOptions.RunContinuationsAsynchronously);
        pending[id] = completion;
        using var linked = CancellationTokenSource.CreateLinkedTokenSource(ct, lifetime.Token);
        linked.CancelAfter(timeout ?? TimeSpan.FromSeconds(20));
        try
        {
            await WriteAsync(new { jsonrpc = "2.0", id, method, @params = parameters }, linked.Token).ConfigureAwait(false);
            return await completion.Task.WaitAsync(linked.Token).ConfigureAwait(false);
        }
        catch (OperationCanceledException) when (!ct.IsCancellationRequested && !lifetime.IsCancellationRequested)
        { throw new QuotaException(FailureKind.Offline, "Codex request timed out; an operation already sent may have completed."); }
        finally { pending.TryRemove(id, out _); }
    }
    private Task NotifyAsync(string method, object parameters, CancellationToken ct) => WriteAsync(new { jsonrpc = "2.0", method, @params = parameters }, ct);
    private async Task WriteAsync(object value, CancellationToken ct)
    {
        var json = JsonSerializer.Serialize(value);
        await writer.WaitAsync(ct).ConfigureAwait(false);
        try
        {
            await process.StandardInput.WriteLineAsync(json.AsMemory(), ct).ConfigureAwait(false);
            await process.StandardInput.FlushAsync(ct).ConfigureAwait(false);
        }
        finally { writer.Release(); }
    }
    private async Task ReadOutputAsync()
    {
        Exception failure = new QuotaException(FailureKind.Offline, "Codex disconnected.");
        try
        {
            await foreach (var line in ReadLinesAsync(process.StandardOutput, lifetime.Token).ConfigureAwait(false))
            {
                if (string.IsNullOrWhiteSpace(line)) continue;
                var message = JsonTools.Parse(line);
                var id = message.At("id").Integer();
                if (id is { } request && pending.TryRemove(request, out var completion))
                {
                    if (message.At("error").ValueKind == JsonValueKind.Object)
                        completion.TrySetException(new RpcException((int)(message.At("error", "code").Integer() ?? -32000)));
                    else if (message.At("result").ValueKind != JsonValueKind.Undefined) completion.TrySetResult(message.At("result").Clone());
                    else completion.TrySetException(HttpTransport.FormatError());
                }
                else if (message.At("method").Text() is not null && id is null) notifications.Writer.TryWrite(message);
                else if (message.At("method").Text() is not null && id is { } serverRequest)
                    await WriteAsync(new { jsonrpc = "2.0", id = serverRequest, error = new { code = -32601, message = "Client method not supported" } }, lifetime.Token).ConfigureAwait(false);
            }
        }
        catch (OperationCanceledException) { failure = new OperationCanceledException(); }
        catch (Exception error) when (error is IOException or JsonException or InvalidDataException or DecoderFallbackException)
        { failure = new QuotaException(FailureKind.Incompatible, "The Codex protocol stream was interrupted or malformed."); }
        finally
        {
            foreach (var entry in pending) if (pending.TryRemove(entry.Key, out var completion)) completion.TrySetException(failure);
            notifications.Writer.TryComplete(failure);
        }
    }
    private async Task DrainErrorsAsync()
    {
        // Third-party diagnostics can contain tokens, commands and paths. Drain, but never persist or display them.
        char[] buffer = new char[4096];
        try { while (await process.StandardError.ReadAsync(buffer.AsMemory(), lifetime.Token).ConfigureAwait(false) > 0) { } }
        catch (Exception error) when (error is OperationCanceledException or IOException or ObjectDisposedException) { }
    }
    private static async IAsyncEnumerable<string> ReadLinesAsync(StreamReader reader, [EnumeratorCancellation] CancellationToken ct)
    {
        char[] buffer = new char[8192]; var line = new StringBuilder();
        while (true)
        {
            int count = await reader.ReadAsync(buffer.AsMemory(), ct).ConfigureAwait(false);
            if (count == 0) { if (line.Length > 0) throw new InvalidDataException("Incomplete protocol frame."); yield break; }
            int start = 0;
            for (int i = 0; i < count; i++)
            {
                if (buffer[i] != '\n') continue;
                line.Append(buffer, start, i - start);
                if (line.Length > 4 * 1024 * 1024) throw new InvalidDataException("Protocol frame exceeds limit.");
                yield return line.ToString().TrimEnd('\r'); line.Clear(); start = i + 1;
            }
            line.Append(buffer, start, count - start);
            if (line.Length > 4 * 1024 * 1024) throw new InvalidDataException("Protocol frame exceeds limit.");
        }
    }
    public async Task AuthorizeAsync(Func<Uri, Task> openBrowser, CancellationToken ct)
    {
        var start = await CallAsync("account/login/start", new { type = "chatgpt" }, ct).ConfigureAwait(false);
        var authUrl = Any(start, "authUrl", "auth_url").Text();
        if (!Uri.TryCreate(authUrl, UriKind.Absolute, out var uri) || uri.Scheme != "https" || uri.UserInfo.Length != 0 ||
            !new[] { "auth.openai.com", "chatgpt.com", "auth.chatgpt.com" }.Contains(uri.Host, StringComparer.OrdinalIgnoreCase))
            throw HttpTransport.FormatError();
        var loginId = Any(start, "loginId", "login_id").Text();
        await openBrowser(uri).ConfigureAwait(false);
        using var wait = CancellationTokenSource.CreateLinkedTokenSource(ct, lifetime.Token); wait.CancelAfter(TimeSpan.FromMinutes(10));
        await foreach (var item in notifications.Reader.ReadAllAsync(wait.Token).ConfigureAwait(false))
        {
            if (item.At("method").Text() != "account/login/completed") continue;
            var payload = item.At("params"); var returnedId = Any(payload, "loginId", "login_id").Text();
            if (loginId is not null && returnedId != loginId) continue;
            if (payload.At("success").ValueKind != JsonValueKind.True) throw new QuotaException(FailureKind.Expired, "Codex authorization was not completed.");
            return;
        }
        throw new QuotaException(FailureKind.Offline, "Codex closed before authorization completed.");
    }
    public async Task VerifyIdentityAsync(Account account, CancellationToken ct)
    {
        var root = await CallAsync("account/read", new { }, ct).ConfigureAwait(false);
        var current = root.At("account");
        if (!string.Equals(current.At("type").Text(), "chatgpt", StringComparison.OrdinalIgnoreCase))
            throw new QuotaException(FailureKind.Identity, "Codex is not using a ChatGPT account.");
        var id = Any(current, "accountId", "account_id", "id").Text();
        var raw = await ReadPrivateCredentialAsync(ct).ConfigureAwait(false);
        var localId = JsonTools.JwtClaims(raw.AccessToken).At("https://api.openai.com/auth", "chatgpt_account_id").Text();
        if (localId != account.ProviderId || id is not null && id != account.ProviderId)
            throw new QuotaException(FailureKind.Identity, "Codex returned another account. The result was not saved.");
        if (id is null && !string.Equals(current.At("email").Text(), account.Name, StringComparison.OrdinalIgnoreCase))
            throw new QuotaException(FailureKind.Identity, "Codex account identity could not be confirmed.");
    }
    public async Task<Credential> ReadPrivateCredentialAsync(CancellationToken ct)
    {
        var path = Path.Combine(home, "auth.json");
        if (!File.Exists(path) || new FileInfo(path).Length > CredentialImport.MaximumBytes) throw new QuotaException(FailureKind.NotConnected, "Codex did not save file-based authorization.");
        var items = CredentialImport.Parse(await File.ReadAllTextAsync(path, ct).ConfigureAwait(false), Provider.Codex);
        return items.Count == 1 && items[0].Credential is { } value ? value : throw HttpTransport.FormatError();
    }
    public async Task<CodexExtendedSnapshot> ReadExtendedAsync(Account account, CancellationToken ct, bool includeUsage = true)
    {
        await VerifyIdentityAsync(account, ct).ConfigureAwait(false);
        var limits = await CallAsync("account/rateLimits/read", new { }, ct).ConfigureAwait(false);
        long? lifetimeTokens = null; string? warning = null;
        if (includeUsage)
        {
            try
            {
                var usage = await CallAsync("account/usage/read", new { }, ct, TimeSpan.FromSeconds(5)).ConfigureAwait(false);
                lifetimeTokens = Any(usage.At("summary"), "lifetimeTokens", "lifetime_tokens").Integer();
                if (lifetimeTokens < 0) lifetimeTokens = null;
            }
            catch (RpcException) { warning = "This CLI does not expose a usable cloud token counter. Capacity estimation is waiting for data."; }
            catch (QuotaException) { warning = "Cloud token counter is unavailable. The last capacity estimate was retained."; }
        }
        await VerifyIdentityAsync(account, ct).ConfigureAwait(false);
        return DecodeExtended(limits, account, lifetimeTokens, DateTimeOffset.UtcNow, warning);
    }
    public static CodexExtendedSnapshot DecodeExtended(JsonElement root, Account account, long? lifetimeTokens, DateTimeOffset now, string? warning = null)
    {
        var groups = new Dictionary<string, JsonElement>(StringComparer.Ordinal);
        var map = Any(root, "rateLimitsByLimitId", "rate_limits_by_limit_id");
        if (map.ValueKind == JsonValueKind.Object) foreach (var item in map.EnumerateObject()) groups[item.Name] = item.Value;
        var primary = Any(root, "rateLimits", "rate_limits");
        if (primary.ValueKind == JsonValueKind.Object) groups.TryAdd(Any(primary, "limitId", "limit_id").Text() ?? "codex", primary);
        var pools = new List<QuotaPool>(); string? plan = null;
        foreach (var group in groups)
        {
            plan ??= Any(group.Value, "planType", "plan_type").Text();
            foreach (var slot in new[] { "primary", "secondary" })
            {
                var window = group.Value.At(slot);
                if (window.ValueKind is JsonValueKind.Null or JsonValueKind.Undefined) continue;
                var used = Any(window, "usedPercent", "used_percent").Number() ?? throw HttpTransport.FormatError();
                var minutes = Any(window, "windowDurationMins", "window_duration_mins", "windowMinutes", "window_minutes").Integer();
                var reset = Any(window, "resetsAt", "resets_at").UnixDate();
                pools.Add(new QuotaPool(group.Key + ":" + slot + "_window", Any(group.Value, "limitName", "limit_name").Text() ?? group.Key,
                    used, minutes is > 0 and <= int.MaxValue ? (int)minutes.Value : null, reset).Validate());
            }
        }
        var creditObject = Any(root, "rateLimitResetCredits", "rate_limit_reset_credits");
        var credits = new List<ResetCredit>();
        foreach (var item in creditObject.At("credits").Items())
        {
            var id = Any(item, "id", "creditId", "credit_id").Text();
            if (id is null) continue;
            credits.Add(new(id, Any(item, "status", "state").Text(), Any(item, "expiresAt", "expires_at", "deadline", "resetsAt", "resets_at").Date(),
                Any(item, "grantedAt", "granted_at", "createdAt", "created_at").Date()));
        }
        var count = Any(creditObject, "availableCount", "available_count").Integer();
        return new(new QuotaSnapshot(account.Key, Provider.Codex, now, plan, pools, lifetimeTokens).Validate(), credits,
            count is >= 0 and <= int.MaxValue ? (int)count.Value : null, creditObject.ValueKind == JsonValueKind.Object, warning);
    }
    public async Task<string> ConsumeAsync(Account account, PendingRedemption redemption, bool retryUncertain, CancellationToken ct)
    {
        if (redemption.AccountKey != account.Key || string.IsNullOrWhiteSpace(redemption.CreditId) || string.IsNullOrWhiteSpace(redemption.IdempotencyKey))
            throw new QuotaException(FailureKind.Identity, "Reset request identity is invalid.");
        var latest = await ReadExtendedAsync(account, ct, includeUsage: false).ConfigureAwait(false);
        var credit = latest.Credits.FirstOrDefault(x => x.Id == redemption.CreditId);
        if (!retryUncertain && (credit is null || !credit.Available(DateTimeOffset.UtcNow)))
            throw new QuotaException(FailureKind.Incompatible, "This reset credit is no longer available.");
        // Caller must durably save this exact key before calling. Never retry with another key or credit.
        var response = await CallAsync("account/rateLimitResetCredit/consume", new { creditId = redemption.CreditId,
            idempotencyKey = redemption.IdempotencyKey }, ct).ConfigureAwait(false);
        var outcome = response.At("outcome").Text();
        return outcome is "reset" or "nothingToReset" or "noCredit" or "alreadyRedeemed" ? outcome :
            throw new QuotaException(FailureKind.Incompatible, "The reset result is uncertain. Refresh and retry only with the saved request key.");
    }
    public static JsonElement Any(JsonElement value, params string[] names)
    {
        foreach (var name in names) if (value.At(name).ValueKind is not (JsonValueKind.Undefined or JsonValueKind.Null)) return value.At(name);
        return default;
    }
    public async ValueTask DisposeAsync()
    {
        if (Interlocked.Exchange(ref disposed, 1) != 0) return;
        lifetime.Cancel();
        try { process.StandardInput.Close(); if (!process.HasExited) process.Kill(entireProcessTree: true); }
        catch (Exception error) when (error is InvalidOperationException or System.ComponentModel.Win32Exception or IOException) { }
        try { await Task.WhenAll(outputTask, errorTask).WaitAsync(TimeSpan.FromSeconds(3)).ConfigureAwait(false); }
        catch (Exception error) when (error is OperationCanceledException or TimeoutException or IOException) { }
        process.Dispose(); lifetime.Dispose(); writer.Dispose();
    }
}
