using System.Diagnostics;
using Microsoft.Win32;
using QuotaLens.Infrastructure;
using global::Windows.Storage.Pickers;

namespace QuotaLens.Windows.Platform;

internal static class DesktopActions
{
    private const string StartupPath = @"Software\Microsoft\Windows\CurrentVersion\Run";
    public static bool StartupRegistered()
    {
        using var key = Registry.CurrentUser.OpenSubKey(StartupPath);
        return key?.GetValue("QuotaLens") is string value && value.Contains(Environment.ProcessPath ?? "QuotaLens.exe", StringComparison.OrdinalIgnoreCase);
    }
    public static void SetStartup(bool enabled)
    {
        using var key = Registry.CurrentUser.CreateSubKey(StartupPath, writable: true);
        if (enabled)
        {
            var executable = Environment.ProcessPath ?? throw new InvalidOperationException("Executable path unavailable.");
            key.SetValue("QuotaLens", "\"" + executable + "\" --background", RegistryValueKind.String);
        }
        else key.DeleteValue("QuotaLens", throwOnMissingValue: false);
    }
    public static Task OpenBrowserAsync(Uri uri)
    {
        if (uri.Scheme != "https" || uri.UserInfo.Length != 0) throw new InvalidDataException("Only HTTPS browser destinations are allowed.");
        Process.Start(new ProcessStartInfo(uri.AbsoluteUri) { UseShellExecute = true }); return Task.CompletedTask;
    }
    public static void RevealFile(string path)
    {
        path = SecureFiles.RequireRegularFile(path);
        Process.Start(new ProcessStartInfo("explorer.exe", "/select,\"" + path + "\"") { UseShellExecute = false });
    }
    public static async Task<string?> OpenFileAsync(IntPtr owner, params string[] extensions)
    {
        var picker = new FileOpenPicker { SuggestedStartLocation = PickerLocationId.DocumentsLibrary };
        foreach (var extension in extensions) picker.FileTypeFilter.Add(extension);
        WinRT.Interop.InitializeWithWindow.Initialize(picker, owner); return (await picker.PickSingleFileAsync())?.Path;
    }
    public static async Task<string?> OpenFolderAsync(IntPtr owner)
    {
        var picker = new FolderPicker { SuggestedStartLocation = PickerLocationId.DocumentsLibrary };
        picker.FileTypeFilter.Add("*"); WinRT.Interop.InitializeWithWindow.Initialize(picker, owner); return (await picker.PickSingleFolderAsync())?.Path;
    }
    public static async Task<string?> SaveFileAsync(IntPtr owner, string name, string extension, string description)
    {
        var picker = new FileSavePicker { SuggestedFileName = name, SuggestedStartLocation = PickerLocationId.DocumentsLibrary };
        picker.FileTypeChoices.Add(description, [extension]); WinRT.Interop.InitializeWithWindow.Initialize(picker, owner); return (await picker.PickSaveFileAsync())?.Path;
    }
}
