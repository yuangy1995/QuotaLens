using System.Security.Cryptography;
using System.Text;
using QuotaLens.Core;

namespace QuotaLens.Infrastructure;

public sealed record LocalImport(Credential Credential, string Fingerprint, string Path);
public sealed record LocalIdentity(string AccountKey, string Fingerprint, DateTimeOffset VerifiedAt);

public static class LocalSources
{
    private static string Home => Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
    public static string CodexHome(AppSettings settings) => SecureFiles.LocalPath(settings.CodexHome ??
        Environment.GetEnvironmentVariable("CODEX_HOME") ?? Path.Combine(Home, ".codex"));
    public static string ClaudeHome(AppSettings settings) => SecureFiles.LocalPath(settings.ClaudeHome ??
        Environment.GetEnvironmentVariable("CLAUDE_CONFIG_DIR") ?? Path.Combine(Home, ".claude"));
    public static IReadOnlyList<string> UsageRoots(Provider provider, AppSettings settings) => provider switch {
        Provider.Codex => [Path.Combine(CodexHome(settings), "sessions"), Path.Combine(CodexHome(settings), "archived_sessions")],
        Provider.Claude => new[] { Path.Combine(ClaudeHome(settings), "projects"), Path.Combine(Home, ".config", "claude", "projects") }
            .Distinct(StringComparer.OrdinalIgnoreCase).ToArray(),
        _ => [] };
    public static IReadOnlyList<string> CredentialCandidates(Provider provider, AppSettings settings) => provider switch {
        Provider.Codex => [Path.Combine(CodexHome(settings), "auth.json")],
        Provider.Claude => new[] { Path.Combine(ClaudeHome(settings), ".credentials.json"), Path.Combine(Home, ".config", "claude", ".credentials.json") }
            .Distinct(StringComparer.OrdinalIgnoreCase).ToArray(),
        _ => [] };

    /// <summary>Only call after the user enables local discovery for this tool.
    /// These are the tool's own documented files, never browser cookies or OS credential stores.</summary>
    public static Task<LocalImport> ReadCredentialAsync(Provider provider, AppSettings settings, CancellationToken ct) => Task.Run(() => {
        if (provider == Provider.Antigravity) throw new QuotaException(FailureKind.NotConnected,
            "Use explicit JSON/token import or independent Google authorization for Antigravity in this build.");
        foreach (var path in CredentialCandidates(provider, settings))
        {
            ct.ThrowIfCancellationRequested(); if (!File.Exists(path)) continue;
            SecureFiles.RequireRegularFile(path);
            using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
            if (stream.Length > CredentialImport.MaximumBytes) throw new InvalidDataException("The tool authorization file exceeds 8 MB.");
            byte[] bytes = new byte[checked((int)stream.Length)]; stream.ReadExactly(bytes);
            try
            {
                var entries = CredentialImport.Parse(new UTF8Encoding(false, true).GetString(bytes), provider);
                if (entries.Count != 1 || entries[0].Credential is not { } credential)
                    throw new QuotaException(FailureKind.NotConnected, "The local tool file has no supported subscription authorization.");
                return new LocalImport(credential, Convert.ToHexStringLower(SHA256.HashData(bytes)), path);
            }
            finally { CryptographicOperations.ZeroMemory(bytes); }
        }
        throw new QuotaException(FailureKind.NotConnected, "No supported local authorization file was found. Sign in to the tool or import credentials explicitly.");
    }, ct);

    public static string? FindCodexExecutable(AppSettings settings)
    {
        if (!string.IsNullOrWhiteSpace(settings.CodexBinary)) return ValidateExecutable(settings.CodexBinary);
        var candidates = new List<string>();
        foreach (var directory in (Environment.GetEnvironmentVariable("PATH") ?? "").Split(Path.PathSeparator))
        {
            var trimmed = directory.Trim().Trim('"');
            if (Path.IsPathFullyQualified(trimmed) && !trimmed.StartsWith("\\\\", StringComparison.Ordinal)) candidates.Add(Path.Combine(trimmed, "codex.exe"));
        }
        string npm = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "npm", "node_modules", "@openai");
        string[] roots = [Path.Combine(npm, "codex"), Path.Combine(npm, "codex-win32-x64")];
        foreach (var root in roots)
        {
            candidates.Add(Path.Combine(root, "vendor", "x86_64-pc-windows-msvc", "codex", "codex.exe"));
            candidates.Add(Path.Combine(root, "bin", "codex.exe"));
        }
        candidates.Add(Path.Combine(Home, ".local", "bin", "codex.exe"));
        foreach (var path in candidates.Distinct(StringComparer.OrdinalIgnoreCase))
        {
            if (!File.Exists(path)) continue;
            try { return ValidateExecutable(path); }
            catch (Exception error) when (error is IOException or UnauthorizedAccessException or InvalidDataException) { }
        }
        return null;
    }
    private static string ValidateExecutable(string path)
    {
        path = SecureFiles.RequireRegularFile(path);
        if (!path.EndsWith(".exe", StringComparison.OrdinalIgnoreCase)) throw new InvalidDataException("Choose the native codex.exe, not a command script.");
        using var stream = File.OpenRead(path);
        if (stream.ReadByte() != 'M' || stream.ReadByte() != 'Z') throw new InvalidDataException("The selected file is not a Windows executable.");
        return path;
    }
}
