using System.Net;
using System.Net.Sockets;
using System.Security.Cryptography;
using System.Text;
using QuotaLens.Core;

namespace QuotaLens.Providers;

/// <summary>One explicit, time-bounded PKCE attempt. Google listens on IPv4 loopback only.</summary>
public sealed class OAuthSession : IDisposable
{
    public const string ClaudeRedirect = "https://platform.claude.com/oauth/code/callback";
    private readonly Provider provider;
    private readonly ProviderClient client;
    private readonly TcpListener? listener;
    private readonly string verifier = JsonTools.Base64Url(RandomNumberGenerator.GetBytes(48));
    private readonly string state = JsonTools.Base64Url(RandomNumberGenerator.GetBytes(32));
    private readonly DateTimeOffset expiresAt = DateTimeOffset.UtcNow.AddMinutes(10);
    private readonly CancellationTokenSource lifetime = new();
    private int completed;
    private int disposed;
    public string Redirect { get; }
    public Uri AuthorizationUri { get; }
    public OAuthSession(Provider provider, ProviderClient client)
    {
        if (provider == Provider.Codex) throw new ArgumentException("Use the Codex app-server authorization flow.");
        this.provider = provider; this.client = client;
        var clientId = client.AuthorizationClientId(provider);
        if (provider == Provider.Antigravity)
        {
            listener = new TcpListener(IPAddress.Loopback, 0); listener.Start(4);
            Redirect = $"http://127.0.0.1:{((IPEndPoint)listener.LocalEndpoint).Port}/oauth/callback";
        }
        else Redirect = ClaudeRedirect;
        var fields = new Dictionary<string, string> { ["response_type"] = "code", ["client_id"] = clientId,
            ["redirect_uri"] = Redirect, ["state"] = state, ["code_challenge"] = JsonTools.Base64Url(SHA256.HashData(Encoding.ASCII.GetBytes(verifier))),
            ["code_challenge_method"] = "S256" };
        if (provider == Provider.Claude) { fields["scope"] = "user:profile"; fields["code"] = "true"; }
        else { fields["scope"] = "openid https://www.googleapis.com/auth/cloud-platform https://www.googleapis.com/auth/userinfo.email https://www.googleapis.com/auth/userinfo.profile";
            fields["access_type"] = "offline"; fields["prompt"] = "consent select_account"; }
        var origin = provider == Provider.Claude ? "https://claude.com/cai/oauth/authorize" : "https://accounts.google.com/o/oauth2/v2/auth";
        AuthorizationUri = new Uri(origin + "?" + string.Join('&', fields.Select(x => Uri.EscapeDataString(x.Key) + "=" + Uri.EscapeDataString(x.Value))));
        lifetime.CancelAfter(TimeSpan.FromMinutes(10));
    }
    public async Task<Credential> ReceiveGoogleAsync(CancellationToken ct)
    {
        if (listener is null) throw new InvalidOperationException();
        using var linked = CancellationTokenSource.CreateLinkedTokenSource(ct, lifetime.Token);
        try
        {
            while (true)
            {
                using var connection = await listener.AcceptTcpClientAsync(linked.Token).ConfigureAwait(false);
                using var requestTimeout = CancellationTokenSource.CreateLinkedTokenSource(linked.Token);
                requestTimeout.CancelAfter(TimeSpan.FromSeconds(5));
                await using var stream = connection.GetStream();
                string? code = null;
                try
                {
                    using var data = new MemoryStream(); byte[] chunk = new byte[1024];
                    while (data.Length < 16384)
                    {
                        int count = await stream.ReadAsync(chunk, requestTimeout.Token).ConfigureAwait(false);
                        if (count == 0) break;
                        data.Write(chunk, 0, count);
                        var request = Encoding.ASCII.GetString(data.ToArray());
                        if (!request.Contains("\r\n\r\n", StringComparison.Ordinal)) continue;
                        var first = request.Split("\r\n", 2)[0].Split(' ');
                        code = first.Length == 3 && first[0] == "GET" ? CallbackCode(first[1], state) : null;
                        break;
                    }
                    var message = code is null ? "Invalid authorization callback." : "Authorization received. Return to QuotaLens.";
                    var response = $"HTTP/1.1 {(code is null ? "400 Bad Request" : "200 OK")}\r\nContent-Type: text/plain; charset=utf-8\r\nCache-Control: no-store\r\nConnection: close\r\nContent-Length: {Encoding.UTF8.GetByteCount(message)}\r\n\r\n{message}";
                    await stream.WriteAsync(Encoding.UTF8.GetBytes(response), requestTimeout.Token).ConfigureAwait(false);
                }
                catch (Exception error) when (error is IOException or OperationCanceledException) { linked.Token.ThrowIfCancellationRequested(); }
                if (code is not null) return await ExchangeOnceAsync(code, linked.Token).ConfigureAwait(false);
            }
        }
        finally { listener.Stop(); }
    }
    public Task<Credential> ExchangeClaudeAsync(string pasted, CancellationToken ct)
    {
        if (provider != Provider.Claude) throw new InvalidOperationException();
        var parts = pasted.Trim().Split('#');
        if (parts.Length is < 1 or > 2 || parts[0].Length == 0 || parts.Length == 2 && parts[1] != state)
            throw new QuotaException(FailureKind.Identity, "The authorization response does not match this sign-in attempt.");
        return ExchangeOnceAsync(parts[0], ct);
    }
    private async Task<Credential> ExchangeOnceAsync(string code, CancellationToken ct)
    {
        if (expiresAt <= DateTimeOffset.UtcNow || Interlocked.Exchange(ref completed, 1) != 0)
            throw new QuotaException(FailureKind.Expired, "This sign-in attempt expired or was already used.");
        using var linked = CancellationTokenSource.CreateLinkedTokenSource(ct, lifetime.Token);
        return await client.ExchangeAsync(provider, code, Redirect, state, verifier, linked.Token).ConfigureAwait(false);
    }
    public static string? CallbackCode(string target, string expectedState)
    {
        if (!target.StartsWith("/oauth/callback?", StringComparison.Ordinal) || target.Length > 16384 || target.Contains('#')) return null;
        try
        {
            var query = target[(target.IndexOf('?') + 1)..].Split('&').Select(part => part.Split('=', 2))
                .Where(p => p.Length == 2).Select(p => (Key: Uri.UnescapeDataString(p[0]), Value: Uri.UnescapeDataString(p[1].Replace('+', ' ')))).ToArray();
            var states = query.Where(x => x.Key == "state").ToArray(); var codes = query.Where(x => x.Key == "code").ToArray();
            bool matches = states.Length == 1 && CryptographicOperations.FixedTimeEquals(Encoding.UTF8.GetBytes(states[0].Value), Encoding.UTF8.GetBytes(expectedState));
            return matches && codes.Length == 1 && codes[0].Value.Length > 0 ? codes[0].Value : null;
        }
        catch (UriFormatException) { return null; }
    }
    public void Dispose()
    {
        if (Interlocked.Exchange(ref disposed, 1) != 0) return;
        lifetime.Cancel(); listener?.Stop(); lifetime.Dispose();
    }
}
