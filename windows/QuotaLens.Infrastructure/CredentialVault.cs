using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using QuotaLens.Core;

namespace QuotaLens.Infrastructure;

public interface ICredentialVault
{
    Task SaveAsync<T>(string id, T value, CancellationToken ct = default);
    Task<T?> LoadAsync<T>(string id, CancellationToken ct = default) where T : class;
    Task RemoveAsync(string id, CancellationToken ct = default);
}

/// <summary>AES-256-GCM, authenticated record IDs, and a DPAPI CurrentUser protected master key.
/// Same-user processes are not an isolation boundary. Missing or mismatched keys never replace ciphertext.</summary>
public sealed class CredentialVault(string root) : ICredentialVault, IDisposable
{
    private readonly SemaphoreSlim gate = new(1, 1);
    private static readonly byte[] Entropy = Encoding.ASCII.GetBytes("QuotaLens.Windows.MasterKey.v1");
    private const int Maximum = 8 * 1024 * 1024;
    public string Root { get; } = SecureFiles.LocalPath(root);
    private string RecordPath(string id)
    {
        if (id.Length is 0 or > 180 || id.Any(c => !char.IsAsciiLetterOrDigit(c) && c != '-' && c != '_'))
            throw new QuotaException(FailureKind.Storage, "Invalid credential record identifier.");
        return Path.Combine(Root, id + ".qcred");
    }
    private async Task<T> LockedAsync<T>(Func<T> action, CancellationToken ct)
    {
        await gate.WaitAsync(ct).ConfigureAwait(false);
        try
        {
            return await Task.Run(() => {
                ct.ThrowIfCancellationRequested(); SecureFiles.CreateDirectory(Root);
                var lockPath = Path.Combine(Root, ".lock");
                if (File.Exists(lockPath)) SecureFiles.RequireRegularFile(lockPath);
                FileStream? fileLock = null;
                for (int attempt = 0; attempt < 100; attempt++)
                {
                    ct.ThrowIfCancellationRequested();
                    try { fileLock = new FileStream(lockPath, FileMode.OpenOrCreate, FileAccess.ReadWrite, FileShare.None); break; }
                    catch (IOException) when (attempt < 99) { Thread.Sleep(50); }
                }
                using (fileLock) { ct.ThrowIfCancellationRequested(); return action(); }
            }, ct).ConfigureAwait(false);
        }
        finally { gate.Release(); }
    }
    private byte[] MasterKey(bool create)
    {
        var path = Path.Combine(Root, "master.key.dpapi");
        if (File.Exists(path))
        {
            SecureFiles.RequireRegularFile(path);
            if (new FileInfo(path).Length > 65536) throw new CryptographicException("Invalid protected master key.");
            var key = ProtectedData.Unprotect(File.ReadAllBytes(path), Entropy, DataProtectionScope.CurrentUser);
            if (key.Length != 32) { CryptographicOperations.ZeroMemory(key); throw new CryptographicException("Invalid master key length."); }
            if (create)
            {
                try
                {
                    var existing = Directory.EnumerateFiles(Root, "*.qcred").FirstOrDefault();
                    if (existing is not null)
                    {
                        byte[] verified = Decrypt(existing, key, Path.GetFileNameWithoutExtension(existing));
                        CryptographicOperations.ZeroMemory(verified);
                    }
                }
                catch { CryptographicOperations.ZeroMemory(key); throw; }
            }
            return key;
        }
        if (!create || Directory.EnumerateFiles(Root, "*.qcred").Any())
            throw new QuotaException(FailureKind.Storage, "The credential master key is missing. Existing encrypted records were not modified.");
        var generated = RandomNumberGenerator.GetBytes(32);
        try
        {
            byte[] protectedKey = ProtectedData.Protect(generated, Entropy, DataProtectionScope.CurrentUser);
            using var stream = SecureFiles.CreateRestricted(path); stream.Write(protectedKey); stream.Flush(flushToDisk: true);
            return generated;
        }
        catch { CryptographicOperations.ZeroMemory(generated); throw; }
    }
    private static byte[] Decrypt(string path, byte[] key, string id)
    {
        SecureFiles.RequireRegularFile(path);
        var size = new FileInfo(path).Length;
        if (size is < 32 or > Maximum + 32) throw new CryptographicException("Invalid credential envelope.");
        byte[] envelope = File.ReadAllBytes(path);
        if (!envelope.AsSpan(0, 4).SequenceEqual("QLW1"u8)) throw new CryptographicException("Unsupported credential format.");
        byte[] plain = new byte[envelope.Length - 32];
        try
        {
            using var aes = new AesGcm(key, 16);
            aes.Decrypt(envelope.AsSpan(4, 12), envelope.AsSpan(32), envelope.AsSpan(16, 16), plain, Encoding.UTF8.GetBytes(id));
            return plain;
        }
        catch { CryptographicOperations.ZeroMemory(plain); throw; }
    }
    public Task SaveAsync<T>(string id, T value, CancellationToken ct = default)
    {
        var path = RecordPath(id);
        return LockedAsync(() => {
            byte[] plain = JsonSerializer.SerializeToUtf8Bytes(value, JsonTools.Options); byte[]? key = null;
            try
            {
                if (plain.Length > Maximum) throw new InvalidDataException("Credential record exceeds limit.");
                key = MasterKey(create: true);
                if (File.Exists(path)) { var old = Decrypt(path, key, id); CryptographicOperations.ZeroMemory(old); }
                byte[] envelope = new byte[32 + plain.Length];
                Encoding.ASCII.GetBytes("QLW1").CopyTo(envelope, 0); RandomNumberGenerator.Fill(envelope.AsSpan(4, 12));
                using var aes = new AesGcm(key, 16);
                aes.Encrypt(envelope.AsSpan(4, 12), plain, envelope.AsSpan(32), envelope.AsSpan(16, 16), Encoding.UTF8.GetBytes(id));
                SecureFiles.AtomicWrite(path, envelope); return true;
            }
            finally { if (key is not null) CryptographicOperations.ZeroMemory(key); CryptographicOperations.ZeroMemory(plain); }
        }, ct);
    }
    public Task<T?> LoadAsync<T>(string id, CancellationToken ct = default) where T : class
    {
        var path = RecordPath(id);
        return LockedAsync<T?>(() => {
            if (!File.Exists(path)) return null;
            byte[] key = MasterKey(create: false); byte[]? plain = null;
            try
            {
                plain = Decrypt(path, key, id);
                return JsonSerializer.Deserialize<T>(plain, JsonTools.Options) ?? throw new CryptographicException("Empty credential record.");
            }
            finally { CryptographicOperations.ZeroMemory(key); if (plain is not null) CryptographicOperations.ZeroMemory(plain); }
        }, ct);
    }
    public Task RemoveAsync(string id, CancellationToken ct = default)
    {
        var path = RecordPath(id);
        return LockedAsync(() => { if (File.Exists(path)) { SecureFiles.RequireRegularFile(path); File.Delete(path); } return true; }, ct);
    }
    public void Dispose() => gate.Dispose();
}
