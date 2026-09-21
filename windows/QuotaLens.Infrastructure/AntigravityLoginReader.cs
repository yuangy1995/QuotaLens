using System.Security.Cryptography;
using System.Text;
using Microsoft.Data.Sqlite;
using QuotaLens.Core;

namespace QuotaLens.Infrastructure;

/// <summary>Consent-only local import. Reads an access token from the configured tool's
/// state, never its refresh token or a third-party client secret. The original tool
/// remains responsible for renewing local authorization. Identity is verified by the
/// provider client before this result can become a query or tray account.</summary>
public static class AntigravityLoginReader
{
    private const int MaximumBytes = 4 * 1024 * 1024;
    private const string TokenKey = "antigravityUnifiedStateSync.oauthToken";
    public static Task<LocalImport> ReadAsync(AppSettings settings, CancellationToken ct) => Task.Run(() => {
        var paths = ActivitySources.Candidates(settings).Where(File.Exists).Distinct(StringComparer.OrdinalIgnoreCase).ToArray();
        if (paths.Length == 0) throw new QuotaException(FailureKind.NotConnected, "No Antigravity state file was found. Open the tool and sign in first.");
        if (paths.Length != 1) throw new QuotaException(FailureKind.Identity, "Multiple Antigravity profiles exist. Select the intended state file in Tool settings; QuotaLens will not guess the active identity.");
        string path = SecureFiles.RequireRegularFile(paths[0]);
        using var connection = new SqliteConnection(new SqliteConnectionStringBuilder {
            DataSource = path, Mode = SqliteOpenMode.ReadOnly, Pooling = false, DefaultTimeout = 2
        }.ToString());
        connection.Open(); using var command = connection.CreateCommand();
        command.CommandText = "SELECT length(value), value FROM ItemTable WHERE key = $key LIMIT 1";
        command.Parameters.AddWithValue("$key", TokenKey);
        using var cancellation = ct.Register(command.Cancel);
        ct.ThrowIfCancellationRequested(); using var reader = command.ExecuteReader();
        if (!reader.Read() || reader.IsDBNull(1)) throw new QuotaException(FailureKind.NotConnected, "Antigravity has no supported local authorization. Open the tool and sign in first.");
        if (reader.GetInt64(0) > MaximumBytes * 2) throw Invalid();
        string encoded = reader.GetString(1);
        var credential = Parse(encoded, ct);
        ct.ThrowIfCancellationRequested();
        return new LocalImport(credential, Convert.ToHexStringLower(SHA256.HashData(Encoding.UTF8.GetBytes(encoded))), path);
    }, ct);

    public static Credential Parse(string encoded, CancellationToken ct = default)
    {
        byte[] data = [], payload = [];
        try
        {
            if (encoded.Length > MaximumBytes * 2) throw Invalid();
            data = Convert.FromBase64String(encoded);
            if (data.Length > MaximumBytes) throw Invalid();
            bool found = false;
            foreach (var field in AntigravityActivityReader.Fields(data))
            {
                ct.ThrowIfCancellationRequested();
                if (field.Number != 1 || field.Wire != 2) continue;
                var entry = AntigravityActivityReader.Fields(field.Bytes).ToArray();
                var name = AntigravityActivityReader.StrictText(entry.SingleOrDefault(x => x.Number == 1 && x.Wire == 2).Bytes);
                if (name != "oauthTokenInfoSentinelKey") continue;
                if (found) throw Invalid(); found = true;
                var row = entry.SingleOrDefault(x => x.Number == 2 && x.Wire == 2).Bytes;
                var value = AntigravityActivityReader.Fields(row).SingleOrDefault(x => x.Number == 1 && x.Wire == 2);
                payload = Convert.FromBase64String(AntigravityActivityReader.StrictText(value.Bytes));
            }
            if (!found || payload.Length == 0 || payload.Length > MaximumBytes) throw Invalid();
            var fields = AntigravityActivityReader.Fields(payload).ToArray();
            var access = fields.SingleOrDefault(x => x.Number == 1 && x.Wire == 2);
            string token = AntigravityActivityReader.StrictText(access.Bytes);
            if (string.IsNullOrWhiteSpace(token) || token.Length > 65536) throw Invalid();
            var expiry = fields.SingleOrDefault(x => x.Number == 4 && x.Wire == 2);
            DateTimeOffset? expires = expiry.Bytes.IsEmpty ? null : AntigravityActivityReader.Timestamp(expiry.Bytes);
            bool gcp = fields.SingleOrDefault(x => x.Number == 6 && x.Wire == 0).Scalar != 0;
            // Field 3 is deliberately never decoded into a refresh-token string.
            return new Credential(Provider.Antigravity, token, ExpiresAt: expires, IsGcpTos: gcp);
        }
        catch (Exception error) when (error is FormatException or DecoderFallbackException or InvalidDataException or OverflowException or InvalidOperationException)
        { throw Invalid(); }
        finally { CryptographicOperations.ZeroMemory(data); CryptographicOperations.ZeroMemory(payload); }
    }
    private static QuotaException Invalid() => new(FailureKind.Incompatible, "Antigravity authorization format was not recognized. No source files were modified.");
}
