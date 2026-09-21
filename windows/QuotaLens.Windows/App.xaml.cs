using System.Security.Principal;
using Microsoft.UI.Xaml;

namespace QuotaLens.Windows;

public partial class App : Application
{
    internal static Window? CurrentWindow { get; private set; }
    private MainWindow? window;
    private Mutex? singleton;
    private EventWaitHandle? activation;
    private RegisteredWaitHandle? activationWait;
    public App()
    {
        if (StartupDiagnostics.TestDirectory is not null) {
            UnhandledException += (_, e) => { StartupDiagnostics.Failure(e.Exception); Environment.Exit(1); };
            AppDomain.CurrentDomain.UnhandledException += (_, e) => StartupDiagnostics.Failure(e.ExceptionObject as Exception ?? new Exception("Unhandled native application error"));
        }
        try {
            StartupDiagnostics.Trace("app constructor");
            // App.xaml owns the merged WinUI resources and theme dictionaries.
            // Do not replace that dictionary during XAML application construction.
            InitializeComponent();
            StartupDiagnostics.Trace("XAML initialized");
        } catch (Exception error) { StartupDiagnostics.Failure(error); throw; }
    }
    protected override void OnLaunched(LaunchActivatedEventArgs args)
    {
        StartupDiagnostics.Trace("OnLaunched");
        string? smoke = StartupDiagnostics.TestDirectory;
        if (smoke is null) {
            string name = @"Local\QuotaLens.Native." + WindowsIdentity.GetCurrent().User!.Value;
            singleton = new Mutex(false, name); bool acquired;
            try { acquired = singleton.WaitOne(0); } catch (AbandonedMutexException) { acquired = true; }
            if (!acquired) {
                try { using var wake = EventWaitHandle.OpenExisting(name + ".Activate"); wake.Set(); } catch (WaitHandleCannotBeOpenedException) { }
                singleton.Dispose(); singleton = null; Exit(); return;
            }
            activation = new EventWaitHandle(false, EventResetMode.AutoReset, name + ".Activate");
        }
        window = new MainWindow(smoke is null ? null : Path.Combine(Path.GetTempPath(), "QuotaLens-ui-test-" + Guid.NewGuid().ToString("N")), smoke);
        StartupDiagnostics.Trace("main window constructed"); CurrentWindow = window;
        if (activation is not null) activationWait = ThreadPool.RegisterWaitForSingleObject(activation,
            (_, _) => window.DispatcherQueue.TryEnqueue(window.ShowMain), null, Timeout.Infinite, false);
        window.Closed += (_, _) => {
            activationWait?.Unregister(null); activation?.Dispose(); CurrentWindow = null;
            if (singleton is not null) { singleton.ReleaseMutex(); singleton.Dispose(); singleton = null; }
        };
        window.Activate(); StartupDiagnostics.Trace("main window activated");
    }
}
