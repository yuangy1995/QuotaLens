using System.Net;
using System.Text;
using System.Text.Json;
using QuotaLens.Core;

namespace QuotaLens.Providers;

/// <summary>Bounded, cancellable HTTP with no credential forwarding through redirects.</summary>
public sealed class HttpTransport : IDisposable
{
    private readonly HttpClient client;
    public HttpTransport(HttpMessageHandler? handler = null)
    {
        client = new HttpClient(handler ?? new SocketsHttpHandler {
            AllowAutoRedirect = false, AutomaticDecompression = DecompressionMethods.All,
            PooledConnectionLifetime = TimeSpan.FromMinutes(5), ConnectTimeout = TimeSpan.FromSeconds(10)
        }) { Timeout = Timeout.InfiniteTimeSpan };
    }
    public async Task<JsonElement> SendAsync(HttpRequestMessage request, CancellationToken ct, bool tokenExchange = false)
    {
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(ct);
        timeout.CancelAfter(TimeSpan.FromSeconds(25));
        try
        {
            using var response = await client.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, timeout.Token).ConfigureAwait(false);
            if (response.StatusCode == HttpStatusCode.TooManyRequests)
            {
                var next = response.Headers.RetryAfter?.Date ?? DateTimeOffset.UtcNow.Add(response.Headers.RetryAfter?.Delta ?? TimeSpan.FromMinutes(1));
                throw new QuotaException(FailureKind.RateLimited, "Refresh is temporarily rate limited.", next);
            }
            if (response.StatusCode == HttpStatusCode.Unauthorized) throw new QuotaException(FailureKind.Expired, "Access token was rejected. Renew or authorize this account again.");
            if (response.StatusCode == HttpStatusCode.Forbidden) throw new QuotaException(FailureKind.Forbidden, "The account or OAuth scope cannot access this endpoint.");
            if ((int)response.StatusCode >= 500) throw new QuotaException(FailureKind.Offline, "The service is temporarily unavailable.");
            if ((int)response.StatusCode is >= 300 and < 400) throw new QuotaException(FailureKind.Incompatible, "The endpoint redirected. Credentials were not forwarded.");
            const int maximum = 8 * 1024 * 1024;
            if (response.Content.Headers.ContentLength > maximum) throw FormatError();
            await using var stream = await response.Content.ReadAsStreamAsync(timeout.Token).ConfigureAwait(false);
            using var buffer = new MemoryStream();
            byte[] bytes = new byte[8192];
            while (true)
            {
                int count = await stream.ReadAsync(bytes, timeout.Token).ConfigureAwait(false);
                if (count == 0) break;
                if (buffer.Length + count > maximum) throw FormatError();
                buffer.Write(bytes, 0, count);
            }
            JsonElement root;
            try { root = JsonTools.Parse(Encoding.UTF8.GetString(buffer.ToArray())); }
            catch (JsonException) { throw FormatError(); }
            if (tokenExchange && root.At("error").Text() == "invalid_grant")
                throw new QuotaException(FailureKind.Revoked, "The service rejected the refresh grant. Authorize this account again.");
            if (!response.IsSuccessStatusCode) throw new QuotaException(FailureKind.Incompatible, $"The endpoint returned HTTP {(int)response.StatusCode}.");
            return root;
        }
        catch (HttpRequestException) { throw new QuotaException(FailureKind.Offline, "Network connection failed. Previous data was retained."); }
        catch (OperationCanceledException) when (!ct.IsCancellationRequested) { throw new QuotaException(FailureKind.Offline, "Request timed out. Previous data was retained."); }
    }
    public static QuotaException FormatError() => new(FailureKind.Incompatible, "The upstream response is incomplete or its format changed. Previous data was retained.");
    public void Dispose() => client.Dispose();
}
