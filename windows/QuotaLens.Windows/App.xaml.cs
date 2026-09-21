using System.Security.Principal;
using Microsoft.UI.Xaml;
using QuotaLens.Windows.UI;

namespace QuotaLens.Windows;

public partial class App : Application
{
    internal static Window? CurrentWindow { get; private set; }
    private MainWindow? window;
    private Mutex? singleton;
    private EventWaitHandle? activation;
    private RegisteredWaitHandle? activationWait;
    public App() { InitializeComponent(); Resources = ThemeResources.Create(); }
    protected override void OnLaunched(LaunchActivatedEventArgs args)
    {
        var arguments = Environment.GetCommandLineArgs();
        int smokeIndex = Array.IndexOf(arguments, "--smoke-test");
        string? smoke = smokeIndex >= 0 && arguments.Length > smokeIndex + 1 ? Path.GetFullPath(arguments[smokeIndex + 1]) : null;
        if (smoke is null) {
            string name = @"Local\QuotaLens.Native." + WindowsIdentity.GetCurrent().User!.Value;
            singleton = new Mutex(false, name); bool acquired;
            try { acquired = singleton.WaitOne(0); } catch (AbandonedMutexException) { acquired = true; }
            if (!acquired) {
                try { using var wake = EventWaitHandle.OpenExisting(name + ".Activate"); wake.Set(); } catch (WaitHandleCannotBeOpenedException) { }
                singleton.Dispose(); singleton = null; Exit(); return;
            }
            activation = new EventWaitHandle(false, EventResetMode.AutoReset, name + ".Activate");
        } else {
            Directory.CreateDirectory(smoke);
            UnhandledException += (_, e) => { File.WriteAllText(Path.Combine(smoke, "failure.txt"), e.Exception.ToString()); Environment.Exit(1); };
        }
        window = new MainWindow(smoke is null ? null : Path.Combine(Path.GetTempPath(), "QuotaLens-ui-test-" + Guid.NewGuid().ToString("N")), smoke);
        CurrentWindow = window;
        if (activation is not null) activationWait = ThreadPool.RegisterWaitForSingleObject(activation,
            (_, _) => window.DispatcherQueue.TryEnqueue(window.ShowMain), null, Timeout.Infinite, false);
        window.Closed += (_, _) => {
            activationWait?.Unregister(null); activation?.Dispose(); CurrentWindow = null;
            if (singleton is not null) { singleton.ReleaseMutex(); singleton.Dispose(); singleton = null; }
        };
        window.Activate();
    }
}
