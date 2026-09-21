using System.Text.Json;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using QuotaLens.Core;
using QuotaLens.Infrastructure;
using QuotaLens.Windows.Platform;
using QuotaLens.Windows.UI;

namespace QuotaLens.Windows;

public sealed partial class MainWindow
{
    private async Task RunSmokeAsync(string destination)
    {
        var completed = new List<string>();
        try {
            // Empty-state rendering first. Production startup has no example or preview data.
            foreach (var theme in new[] { "light", "dark" }) {
                await engine.UpdateSettingsAsync(s => s with { Theme = theme, EnabledTools = [], DiscoverLocalTools = [] }); ApplySettings();
                context = "overview";
                foreach (var route in new[] { "summary", "accounts", "distribution", "settings", "desktop", "sessions", "recovery", "about" }) {
                    page = route; BuildNavigation(); await RenderPageAsync(); root.UpdateLayout();
                    completed.Add(theme + "/empty/" + route);
                }
            }
            // Synthetic identities are confined to the command-line test's isolated temporary database.
            var accounts = new List<Account>();
            foreach (var tool in Enum.GetValues<Provider>()) {
                var account = new Account(Account.KeyFor(tool, "ui-test"), tool, "ui-test", "synthetic@example.invalid", "test-only", DateTimeOffset.UtcNow);
                await engine.Database.SaveAccountAsync(account); accounts.Add(account);
                var quota = new QuotaSnapshot(account.Key, tool, DateTimeOffset.UtcNow, "Synthetic test", [
                    new("primary", "5-hour quota", 25, 300, DateTimeOffset.UtcNow.AddHours(2)),
                    new("weekly", "7-day quota", 70, 10080, DateTimeOffset.UtcNow.AddDays(2))]);
                await engine.Database.SaveQuotaAsync(quota);
            }
            await engine.Accounts.InitializeAsync(CancellationToken.None);
            foreach (var theme in new[] { "light", "dark" }) {
                await engine.UpdateSettingsAsync(s => s with { Theme = theme, EnabledTools = Enum.GetValues<Provider>(), DiscoverLocalTools = [] }); ApplySettings();
                foreach (var tool in Enum.GetValues<Provider>()) {
                    context = tool.ToString();
                    foreach (var route in new[] { "quota", "usage", "history", "sessions", "accounts", "tool-settings", "forecast", "credits" }) {
                        page = route; BuildNavigation(); await RenderPageAsync(); root.UpdateLayout();
                        completed.Add(theme + "/" + tool + "/" + route);
                    }
                }
                context = "overview"; page = "summary"; BuildNavigation(); await RenderPageAsync(); root.UpdateLayout();
                // RenderTargetBitmap inspects this app only, never captures the user's desktop.
                var bitmap = new Microsoft.UI.Xaml.Media.Imaging.RenderTargetBitmap(); await bitmap.RenderAsync(root);
                var pixels = await bitmap.GetPixelsAsync();
                if (bitmap.PixelWidth == 0 || bitmap.PixelHeight == 0 || pixels.Length == 0) throw new InvalidOperationException("The native UI rendered no pixels.");
                using var stream = new global::Windows.Storage.Streams.InMemoryRandomAccessStream();
                var encoder = await global::Windows.Graphics.Imaging.BitmapEncoder.CreateAsync(global::Windows.Graphics.Imaging.BitmapEncoder.PngEncoderId, stream);
                var bytes = new byte[pixels.Length]; using (var reader = global::Windows.Storage.Streams.DataReader.FromBuffer(pixels)) reader.ReadBytes(bytes);
                encoder.SetPixelData(global::Windows.Graphics.Imaging.BitmapPixelFormat.Bgra8, global::Windows.Graphics.Imaging.BitmapAlphaMode.Premultiplied,
                    (uint)bitmap.PixelWidth, (uint)bitmap.PixelHeight, 96, 96, bytes); await encoder.FlushAsync();
                stream.Seek(0); var png = new byte[(int)stream.Size]; using (var reader = new global::Windows.Storage.Streams.DataReader(stream)) { await reader.LoadAsync((uint)png.Length); reader.ReadBytes(png); }
                await File.WriteAllBytesAsync(Path.Combine(destination, "native-overview-" + theme + ".png"), png);
            }
            using (var temporaryTray = new TrayService(Handle)) {
                if (!temporaryTray.IsAdded) throw new InvalidOperationException("Native tray registration failed.");
                completed.Add("native-tray-registration");
            }
            var widget = new CompactWindow(true, ShowMain);
            widget.Update(Ui.Text("Synthetic UI test"), ElementTheme.Light);
            IntPtr before = NativeMethods.GetForegroundWindow(); widget.ShowAt(40, 40); await Task.Delay(150);
            if (NativeMethods.GetForegroundWindow() != before) throw new InvalidOperationException("The overlay stole the input focus.");
            widget.Hide(); widget.Close(); completed.Add("non-activating-overlay");
            await File.WriteAllTextAsync(Path.Combine(destination, "smoke.json"), JsonSerializer.Serialize(new { passed = completed.Count, checks = completed, liveNetwork = false, dataRoot = "isolated-temporary-directory" }, JsonTools.Options));
        } catch (Exception error) { await File.WriteAllTextAsync(Path.Combine(destination, "failure.txt"), error.ToString()); }
        finally { await ShutdownAsync(); }
    }
}
