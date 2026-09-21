using System.Text;
using System.Text.Json;

namespace QuotaLens.Core;

public sealed record ImportCandidate(Credential? Credential, string? Error);
public static class CredentialImport
{
    public const int MaximumBytes = 8 * 1024 * 1024;
    public const int MaximumItems = 200;
    public static IReadOnlyList<ImportCandidate> Parse(string input, Provider provider)
    {
        if (Encoding.UTF8.GetByteCount(input) > MaximumBytes) throw new InvalidDataException("Import exceeds 8 MB.");
        input = input.Trim();
        if (input.StartsWith("sk-", StringComparison.OrdinalIgnoreCase)) throw new InvalidDataException("API keys are not subscription credentials.");
        if (!input.StartsWith('{') && !input.StartsWith('['))
        {
            if (input.Length == 0 || input.Any(char.IsWhiteSpace)) throw new InvalidDataException("Invalid access token.");
            return [new(new Credential(provider, input), null)];
        }
        var root = JsonTools.Parse(input);
        var container = root.At("accounts");
        var items = (root.ValueKind == JsonValueKind.Array ? root.Items() : container.ValueKind == JsonValueKind.Array ? container.Items() : [root]).ToArray();
        if (items.Length is 0 or > MaximumItems) throw new InvalidDataException("Import must contain 1–200 accounts.");
        return items.Select(item =>
        {
            try { return new ImportCandidate(ParseOne(item, provider), null); }
            catch (Exception e) when (e is InvalidDataException or JsonException) { return new ImportCandidate(null, e.Message); }
        }).ToArray();
    }

    private static Credential ParseOne(JsonElement item, Provider provider)
    {
        var declared = item.At("provider").Text();
        if (declared is not null && !string.Equals(declared, provider.ToString(), StringComparison.OrdinalIgnoreCase))
            throw new InvalidDataException("The credential belongs to a different tool.");
        if (item.At("credential").ValueKind == JsonValueKind.Object) item = item.At("credential");
        if (item.At("claude_credentials_raw").Text() is { } raw) item = JsonTools.Parse(raw);
        foreach (var wrapper in new[] { "tokens", "claudeAiOauth", "token" })
            if (item.At(wrapper).ValueKind == JsonValueKind.Object) { item = item.At(wrapper); break; }
        string? Get(params string[] keys) => keys.Select(k => item.At(k).Text()).FirstOrDefault(v => !string.IsNullOrWhiteSpace(v));
        var access = Get("accessToken", "access_token") ?? "";
        var refresh = Get("refreshToken", "refresh_token");
        if (access.Length == 0 && refresh is null) throw new InvalidDataException("No supported OAuth credentials found.");
        if (access.StartsWith("sk-", StringComparison.OrdinalIgnoreCase)) throw new InvalidDataException("API keys are not subscription credentials.");
        if (access.Length > 128 * 1024 || refresh?.Length > 128 * 1024 || access.Contains('\r') || access.Contains('\n'))
            throw new InvalidDataException("Invalid token size or encoding.");
        DateTimeOffset? expiry = item.At("expiresAt").ValueKind == JsonValueKind.String ? item.At("expiresAt").Date() : null;
        var epoch = item.At("expiresAt").Number() ?? item.At("expires_at").Number() ?? item.At("expiry_timestamp").Number();
        if (epoch is { } timestamp)
        {
            try { expiry = timestamp > 10_000_000_000 ? DateTimeOffset.FromUnixTimeMilliseconds(checked((long)timestamp)) : DateTimeOffset.FromUnixTimeSeconds(checked((long)timestamp)); }
            catch (Exception e) when (e is OverflowException or ArgumentOutOfRangeException) { throw new InvalidDataException("Invalid expiry."); }
        }
        // Only allow these fields. Passwords, cookies, arbitrary endpoints, and source labels are discarded.
        return new(provider, access, refresh, expiry, Get("idToken", "id_token"), Get("clientId", "client_id", "oauthClientKey"),
            item.At("is_gcp_tos").ValueKind == JsonValueKind.True || item.At("isGcpTos").ValueKind == JsonValueKind.True);
    }
}
