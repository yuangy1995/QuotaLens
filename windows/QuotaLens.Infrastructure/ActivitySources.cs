namespace QuotaLens.Infrastructure;

/// <summary>Local aggregate task sources only. This does not discover credentials.</summary>
public static class ActivitySources
{
    public static IReadOnlyList<string> Candidates(AppSettings settings)
    {
        if (!string.IsNullOrWhiteSpace(settings.AntigravityStateFile))
            return [SecureFiles.LocalPath(settings.AntigravityStateFile)];
        string roaming = Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData);
        return [Path.Combine(roaming, "Antigravity IDE", "User", "globalStorage", "state.vscdb"),
            Path.Combine(roaming, "Antigravity", "User", "globalStorage", "state.vscdb")];
    }
}
