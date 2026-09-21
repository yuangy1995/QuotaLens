using System.Text;
using System.Text.Json;
using QuotaLens.Core;
using QuotaLens.Providers;

namespace QuotaLens.Infrastructure;

public sealed record RuntimeManifest(string? AccountKey, DateTimeOffset CreatedAt);

/// <summary>A private, access-restricted runtime directory. Never writes the real tool's CODEX_HOME.</summary>
public sealed class PrivateCodexHome
{
    public string Path { get; }
    private readonly string runtimeRoot;
    private PrivateCodexHome(string root, string path) { runtimeRoot = root; Path = path; }
    public static Task<PrivateCodexHome> CreateAsync(string appRoot, string? accountKey, Credential? credential, CancellationToken ct) => Task.Run(() => {
        ct.ThrowIfCancellationRequested();
        string root = System.IO.Path.Combine(appRoot, "Runtime"); SecureFiles.CreateDirectory(root);
        string path = System.IO.Path.Combine(root, Guid.NewGuid().ToString("N")); SecureFiles.CreateDirectory(path);
        var home = new PrivateCodexHome(root, path);
        try
        {
            SecureFiles.AtomicWrite(System.IO.Path.Combine(path, "manifest.json"), JsonSerializer.SerializeToUtf8Bytes(new RuntimeManifest(accountKey, DateTimeOffset.UtcNow), JsonTools.Options));
            SecureFiles.AtomicWrite(System.IO.Path.Combine(path, "config.toml"), "cli_auth_credentials_store = \"file\"\n"u8);
            if (credential is not null) home.WriteCredential(credential);
            return home;
        }
        catch { home.Delete(); throw; }
    }, ct);
    private void WriteCredential(Credential credential)
    {
        if (credential.Provider != Provider.Codex) throw new ArgumentException("Codex authorization required.");
        var tokens = new Dictionary<string, string> { ["access_token"] = credential.AccessToken };
        if (credential.RefreshToken is { } refresh) tokens["refresh_token"] = refresh;
        if (credential.IdToken is { } id) tokens["id_token"] = id;
        byte[] data = JsonSerializer.SerializeToUtf8Bytes(new { auth_mode = "chatgpt", tokens });
        try { SecureFiles.AtomicWrite(System.IO.Path.Combine(Path, "auth.json"), data); }
        finally { System.Security.Cryptography.CryptographicOperations.ZeroMemory(data); }
    }
    public async Task<Credential?> ReadCredentialAsync(CancellationToken ct)
    {
        var file = System.IO.Path.Combine(Path, "auth.json");
        if (!File.Exists(file)) return null;
        SecureFiles.RequireRegularFile(file);
        if (new FileInfo(file).Length > CredentialImport.MaximumBytes) throw new InvalidDataException("Private authorization exceeds size limit.");
        var candidates = CredentialImport.Parse(await File.ReadAllTextAsync(file, ct).ConfigureAwait(false), Provider.Codex);
        return candidates.Count == 1 ? candidates[0].Credential : null;
    }
    public void Delete()
    {
        if (!SecureFiles.IsWithin(Path, runtimeRoot) || !Directory.Exists(Path)) return;
        SecureFiles.RejectReparseChain(Path);
        // The directory is app-created and private. Reject unexpected links before recursive removal.
        foreach (var entry in Directory.EnumerateFileSystemEntries(Path, "*", SearchOption.AllDirectories))
            if ((File.GetAttributes(entry) & FileAttributes.ReparsePoint) != 0) throw new InvalidDataException("A runtime directory contains a linked entry; cleanup was stopped.");
        Directory.Delete(Path, recursive: true);
    }
    public static async Task<int> RecoverAsync(string appRoot, IReadOnlyList<Account> accounts, ICredentialVault vault, CancellationToken ct)
    {
        var root = System.IO.Path.Combine(appRoot, "Runtime");
        if (!Directory.Exists(root)) return 0;
        SecureFiles.RejectReparseChain(root); int remaining = 0;
        foreach (var path in Directory.EnumerateDirectories(root))
        {
            ct.ThrowIfCancellationRequested();
            if (!Guid.TryParseExact(System.IO.Path.GetFileName(path), "N", out _)) continue;
            var home = new PrivateCodexHome(root, path);
            try
            {
                var manifestPath = SecureFiles.RequireRegularFile(System.IO.Path.Combine(path, "manifest.json"));
                if (new FileInfo(manifestPath).Length > 16384) { remaining++; continue; }
                var manifest = JsonSerializer.Deserialize<RuntimeManifest>(await File.ReadAllTextAsync(manifestPath, ct).ConfigureAwait(false), JsonTools.Options);
                var account = accounts.FirstOrDefault(x => x.Key == manifest?.AccountKey && x.Provider == Provider.Codex);
                var credential = await home.ReadCredentialAsync(ct).ConfigureAwait(false);
                if (account is not null && credential is not null)
                {
                    string? identity = JsonTools.JwtClaims(credential.AccessToken).At("https://api.openai.com/auth", "chatgpt_account_id").Text();
                    if (identity != account.ProviderId) { remaining++; continue; }
                    var saved = await vault.LoadAsync<Credential>(account.Key, ct).ConfigureAwait(false);
                    // Only rescue a newer access token; never overwrite a more recently rotated credential.
                    if (saved is null || credential.EffectiveExpiry > saved.EffectiveExpiry)
                        await vault.SaveAsync(account.Key, credential, ct).ConfigureAwait(false);
                }
                home.Delete();
            }
            catch (Exception error) when (error is IOException or UnauthorizedAccessException or InvalidDataException or JsonException or System.Security.Cryptography.CryptographicException)
            { remaining++; }
        }
        return remaining;
    }
}
