namespace QuotaLens.Windows;

internal static class StartupDiagnostics
{
    internal static string? TestDirectory {
        get {
            var args = Environment.GetCommandLineArgs(); int index = Array.IndexOf(args, "--smoke-test");
            return index >= 0 && args.Length > index + 1 ? Path.GetFullPath(args[index + 1]) : null;
        }
    }
    internal static void Trace(string stage) {
        if (TestDirectory is not { } directory) return;
        Directory.CreateDirectory(directory);
        File.AppendAllText(Path.Combine(directory, "startup.log"), DateTimeOffset.UtcNow.ToString("O") + " " + stage + Environment.NewLine);
    }
    internal static void Failure(Exception error) {
        if (TestDirectory is not { } directory) return;
        Directory.CreateDirectory(directory); File.WriteAllText(Path.Combine(directory, "failure.txt"), error.ToString());
    }
}
