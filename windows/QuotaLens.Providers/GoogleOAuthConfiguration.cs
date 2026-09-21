using System.Text;
using QuotaLens.Core;

namespace QuotaLens.Providers;

/// <summary>User-supplied installed application configuration. Store only in the encrypted vault.</summary>
public sealed record GoogleOAuthConfiguration(string ClientId, string ClientSecret)
{
    public override string ToString() => "GoogleOAuthConfiguration([REDACTED])";
    public static GoogleOAuthConfiguration Parse(string json)
    {
        if (Encoding.UTF8.GetByteCount(json) > 65536) throw new InvalidDataException("OAuth configuration exceeds 64 KB.");
        var root = JsonTools.Parse(json).At("installed");
        var id = root.At("client_id").Text(); var secret = root.At("client_secret").Text();
        if (string.IsNullOrWhiteSpace(id) || !id.EndsWith(".apps.googleusercontent.com", StringComparison.Ordinal)
            || id.Length > 256 || id.Any(char.IsWhiteSpace) || string.IsNullOrWhiteSpace(secret) || secret.Length > 4096)
            throw new InvalidDataException("Choose a Google OAuth Desktop client JSON file, not a service account or web client.");
        // Uploaded authorization URLs and token endpoints are deliberately ignored.
        return new(id, secret);
    }
}
