using System.Security.AccessControl;
using System.Security.Principal;

namespace QuotaLens.Infrastructure;

public static class SecureFiles
{
    public static string DefaultRoot => Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "QuotaLens");
    private static SecurityIdentifier User => WindowsIdentity.GetCurrent().User ?? throw new UnauthorizedAccessException("No current Windows identity.");
    public static void CreateDirectory(string path)
    {
        path = LocalPath(path); RejectReparseChain(Path.GetDirectoryName(path)!);
        var security = new DirectorySecurity(); security.SetOwner(User); security.SetAccessRuleProtection(true, false);
        security.AddAccessRule(new FileSystemAccessRule(User, FileSystemRights.FullControl,
            InheritanceFlags.ContainerInherit | InheritanceFlags.ObjectInherit, PropagationFlags.None, AccessControlType.Allow));
        security.AddAccessRule(new FileSystemAccessRule(new SecurityIdentifier(WellKnownSidType.LocalSystemSid, null), FileSystemRights.FullControl,
            InheritanceFlags.ContainerInherit | InheritanceFlags.ObjectInherit, PropagationFlags.None, AccessControlType.Allow));
        var directory = new DirectoryInfo(path);
        if (!directory.Exists) directory.Create(security);
        RejectReparseChain(path); directory.SetAccessControl(security);
    }
    public static FileStream CreateRestricted(string path)
    {
        path = LocalPath(path); RejectReparseChain(Path.GetDirectoryName(path)!);
        var security = new FileSecurity(); security.SetOwner(User); security.SetAccessRuleProtection(true, false);
        security.AddAccessRule(new FileSystemAccessRule(User, FileSystemRights.FullControl, AccessControlType.Allow));
        security.AddAccessRule(new FileSystemAccessRule(new SecurityIdentifier(WellKnownSidType.LocalSystemSid, null), FileSystemRights.FullControl, AccessControlType.Allow));
        return new FileInfo(path).Create(FileMode.CreateNew, FileSystemRights.FullControl, FileShare.None, 4096, FileOptions.WriteThrough, security);
    }
    public static void AtomicWrite(string path, ReadOnlySpan<byte> data)
    {
        path = LocalPath(path); RejectReparseChain(Path.GetDirectoryName(path)!);
        if (File.Exists(path)) RequireRegularFile(path);
        string temporary = Path.Combine(Path.GetDirectoryName(path)!, ".ql-write-" + Guid.NewGuid().ToString("N"));
        try
        {
            using (var stream = CreateRestricted(temporary)) { stream.Write(data); stream.Flush(flushToDisk: true); }
            File.Move(temporary, path, overwrite: true);
        }
        finally { if (File.Exists(temporary)) File.Delete(temporary); }
    }
    public static string LocalPath(string path)
    {
        if (string.IsNullOrWhiteSpace(path) || !Path.IsPathFullyQualified(path)) throw new InvalidDataException("An absolute local path is required.");
        var full = Path.GetFullPath(path);
        if (full.StartsWith("\\\\", StringComparison.Ordinal)) throw new InvalidDataException("Network and WSL paths are not enabled in this Windows build.");
        return full;
    }
    public static void RejectReparseChain(string path)
    {
        for (string? current = LocalPath(path); current is not null; current = Path.GetDirectoryName(current))
        {
            if (!File.Exists(current) && !Directory.Exists(current)) continue;
            if ((File.GetAttributes(current) & FileAttributes.ReparsePoint) != 0)
                throw new InvalidDataException("Linked or redirected filesystem entries are not supported for this operation.");
        }
    }
    public static string RequireRegularFile(string path)
    {
        path = LocalPath(path); RejectReparseChain(path);
        var attributes = File.GetAttributes(path);
        if ((attributes & (FileAttributes.ReparsePoint | FileAttributes.Directory)) != 0) throw new InvalidDataException("A regular local file is required.");
        return path;
    }
    public static bool IsWithin(string path, string root)
    {
        var normalized = Path.TrimEndingDirectorySeparator(LocalPath(root)) + Path.DirectorySeparatorChar;
        return LocalPath(path).StartsWith(normalized, StringComparison.OrdinalIgnoreCase);
    }
}
