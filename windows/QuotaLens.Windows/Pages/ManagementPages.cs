using System.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using QuotaLens.Core;
using QuotaLens.Infrastructure;
using QuotaLens.Providers;
using QuotaLens.Windows.Platform;
using QuotaLens.Windows.UI;

namespace QuotaLens.Windows;

public sealed partial class MainWindow
{
    private UIElement AccountsPage(Provider? selectedProvider)
    {
        var content = Ui.Stack(Ui.Heading(T("账号管理", "Account management"), 28),
            Ui.Text(T("新增凭据先向服务端验证身份与额度，再加入账号目录。移除凭据不删除历史记录。", "New credentials are verified against the service before saving. Removing credentials does not delete history."), 13, true));
        foreach (var provider in engine.Settings.EnabledTools.Where(p => selectedProvider is null || p == selectedProvider)) {
            var card = Ui.Stack(Ui.Heading(provider.ToString(), 20));
            card.Children.Add(Ui.Row(
                Ui.Button(T("浏览器授权", "Browser sign-in"), () => StartAction(ct => AuthorizeAsync(provider, ct))),
                Ui.Button(T("导入文件", "Import file"), () => StartAction(ct => ImportFileAsync(provider, ct))),
                Ui.Button(T("粘贴 JSON / Token", "Paste JSON / token"), () => StartAction(ct => ImportTextAsync(provider, ct)))));
            if (provider != Provider.Antigravity) card.Children.Add(Ui.Button(T("从本机工具导入", "Import from local tool"), () => StartAction(async ct => {
                if (!await ConfirmAsync(T("导入本机登录状态", "Import local authorization"), T("仅读取此工具的登录文件并保存私有加密副本。续期可能轮换与原客户端共享的刷新令牌，但不会改写原工具文件。", "Reads this tool's login file and stores an encrypted private copy. Renewal may rotate a token shared with the original client, but never rewrites its files."), ct)) return;
                var result = await engine.Accounts.ImportLocalAsync(provider, true, ct); ShowNotice(result.Message ?? T("导入已完成", "Import completed"));
            })));
            foreach (var view in engine.Accounts.Views.Where(x => x.Account.Provider == provider)) {
                var account = view.Account;
                var row = Ui.Stack(Ui.Heading(account.DisplayName, 16),
                    Ui.Text(account.Source + " · " + T("验证于 ", "Verified ") + Ui.Date(account.VerifiedAt), 12, true),
                    Ui.Text(view.Status.Message ?? T("已保存", "Saved"), 12, true));
                if (engine.Accounts.ActualAccountKey(provider) == account.Key) row.Children.Add(Ui.Text(T("本机工具身份 · 托盘与挂件使用此身份", "Local tool identity · used by tray and overlay"), 12, true));
                row.Children.Add(Ui.Row(Ui.Button(T("刷新", "Refresh"), () => StartAction(ct => engine.Accounts.RefreshAsync(account.Key, true, ct))),
                    Ui.Button(T("备注", "Rename"), () => StartAction(ct => RenameAsync(account, ct))),
                    Ui.Button(T("导出", "Export"), () => StartAction(ct => ExportAsync([account.Key], ct))),
                    Ui.Button(T("移除凭据", "Remove credential"), () => StartAction(async ct => {
                        if (await ConfirmAsync(T("移除凭据？", "Remove credential?"), account.DisplayName + "\n" + T("仅移除此账号的本地凭据，保留额度与会话历史，并停止自动重新导入。", "Removes the local credential only, keeps history and excludes automatic re-import."), ct)) await engine.Accounts.RemoveAsync(account.Key, ct);
                    }))));
                card.Children.Add(Ui.Card(row));
            }
            content.Children.Add(Ui.Card(card));
        }
        if (engine.Settings.EnabledTools.Length == 0) content.Children.Add(Ui.Button(T("先启用监控工具", "Enable monitoring first"), () => Navigate("settings")));
        return Ui.Scroll(content);
    }
    private UIElement SettingsPage(Provider? tool)
    {
        var saved = engine.Settings;
        var content = Ui.Stack(Ui.Heading(tool is null ? T("应用设置", "App settings") : tool + " · " + T("工具设置", "Tool settings"), 28));
        var enabled = new Dictionary<Provider, CheckBox>(); var discovery = new Dictionary<Provider, CheckBox>();
        foreach (var provider in Enum.GetValues<Provider>().Where(p => tool is null || p == tool)) {
            var use = new CheckBox { Content = T("启用 ", "Enable ") + provider, IsChecked = saved.EnabledTools.Contains(provider) }; enabled[provider] = use;
            var local = new CheckBox { Content = T("自动发现本机登录文件（仅限此工具）", "Discover this tool's local login file automatically"), IsChecked = saved.DiscoverLocalTools.Contains(provider) };
            discovery[provider] = local;
            var group = Ui.Stack(use);
            if (provider != Provider.Antigravity) group.Children.Add(local);
            group.Children.Add(Ui.Text(T("只有启用的工具才会被查询和扫描。本机导入凭据可能与原客户端共享刷新链，续期可能影响原客户端后续刷新。", "Only enabled tools are queried and scanned. Imported credentials can share a refresh chain with the original client; renewal may affect its later refresh."), 12, true));
            content.Children.Add(Ui.Card(group));
        }
        var theme = Choice(T("外观", "Appearance"), [("system", T("跟随系统", "System")), ("light", T("浅色", "Light")), ("dark", T("深色", "Dark"))], saved.Theme);
        var language = Choice(T("语言", "Language"), [("system", T("跟随系统", "System")), ("zh-CN", "简体中文"), ("en", "English")], saved.Language);
        var interval = new NumberBox { Header = T("刷新间隔（秒）", "Refresh interval (seconds)"), Value = saved.RefreshSeconds, Minimum = 60, Maximum = 3600, SpinButtonPlacementMode = NumberBoxSpinButtonPlacementMode.Inline, Width = 230 };
        var notifications = new CheckBox { Content = T("周额度恢复通知", "Weekly quota recovery notifications"), IsChecked = saved.Notifications };
        var cloud = new CheckBox { Content = T("通过独立 Codex 进程采集云端累计 Token", "Collect cloud counters through an isolated Codex process"), IsChecked = saved.CollectCodexCloudUsage };
        var binary = new TextBox { Header = "codex.exe", Text = saved.CodexBinary ?? "", PlaceholderText = T("自动发现，或选择原生可执行文件", "Auto-discover, or choose the native executable") };
        var codexHome = new TextBox { Header = "CODEX_HOME", Text = saved.CodexHome ?? "", PlaceholderText = "%USERPROFILE%\\.codex" };
        var claudeHome = new TextBox { Header = "CLAUDE_CONFIG_DIR", Text = saved.ClaudeHome ?? "", PlaceholderText = "%USERPROFILE%\\.claude" };
        var gravity = new TextBox { Header = T("Antigravity 状态数据库", "Antigravity state database"), Text = saved.AntigravityStateFile ?? "", PlaceholderText = "state.vscdb" };
        if (tool is null) content.Children.Add(Ui.Card(Ui.Stack(Ui.Row(theme, language), interval, notifications)));
        if (tool is null || tool == Provider.Codex) content.Children.Add(Ui.Card(Ui.Stack(binary,
            Ui.Button(T("选择 codex.exe", "Choose codex.exe"), async () => { try { if (await DesktopActions.OpenFileAsync(Handle, ".exe") is { } path) binary.Text = path; } catch (Exception e) { ShowError(e); } }), codexHome, cloud)));
        if (tool is null || tool == Provider.Claude) content.Children.Add(Ui.Card(claudeHome));
        if (tool is null || tool == Provider.Antigravity) content.Children.Add(Ui.Card(Ui.Stack(gravity,
            Ui.Button(T("选择状态文件", "Choose state file"), async () => { try { if (await DesktopActions.OpenFileAsync(Handle, ".vscdb") is { } path) gravity.Text = path; } catch (Exception e) { ShowError(e); } }),
            Ui.Text(T("Google 独立授权需要你自己的 Desktop OAuth 客户端配置；不会内置或绕过第三方客户端密钥。", "Independent Google authorization requires your own Desktop OAuth client configuration. No third-party client secret is embedded or bypassed."), 12, true),
            Ui.Button(T("导入 Google OAuth 客户端配置", "Import Google OAuth client configuration"), () => StartAction(async ct => {
                if (await DesktopActions.OpenFileAsync(Handle, ".json") is not { } path) return;
                var configuration = GoogleOAuthConfiguration.Parse(await ReadBoundedAsync(path, 65536, ct));
                await engine.Accounts.SetGoogleConfigurationAsync(configuration, ct); ShowNotice(T("配置已加密保存在本机", "Configuration saved locally with encryption"));
            })), Ui.Button(T("移除 OAuth 客户端配置", "Remove OAuth client configuration"), () => StartAction(ct => engine.Accounts.SetGoogleConfigurationAsync(null, ct))))));
        string? Optional(string text) => string.IsNullOrWhiteSpace(text) ? null : text.Trim();
        content.Children.Add(Ui.Button(T("保存设置", "Save settings"), () => StartAction(async ct => {
            var tools = engine.Settings.EnabledTools.ToHashSet(); var discovered = engine.Settings.DiscoverLocalTools.ToHashSet();
            foreach (var pair in enabled) { if (pair.Value.IsChecked == true) tools.Add(pair.Key); else tools.Remove(pair.Key); }
            foreach (var pair in discovery) { if (pair.Value.IsChecked == true && pair.Key != Provider.Antigravity) discovered.Add(pair.Key); else discovered.Remove(pair.Key); }
            await engine.UpdateSettingsAsync(s => s with { EnabledTools = tools.Order().ToArray(), DiscoverLocalTools = discovered.Order().ToArray(),
                Theme = tool is null ? (string)((ComboBoxItem)theme.SelectedItem).Tag : s.Theme,
                Language = tool is null ? (string)((ComboBoxItem)language.SelectedItem).Tag : s.Language,
                RefreshSeconds = tool is null && double.IsFinite(interval.Value) ? (int)interval.Value : s.RefreshSeconds,
                Notifications = tool is null ? notifications.IsChecked == true : s.Notifications,
                CodexBinary = Optional(binary.Text), CodexHome = Optional(codexHome.Text), ClaudeHome = Optional(claudeHome.Text),
                AntigravityStateFile = Optional(gravity.Text), CollectCodexCloudUsage = cloud.IsChecked == true }, ct);
            ShowNotice(T("设置已保存", "Settings saved"));
        })));
        if (tool is { } scanTool) content.Children.Add(Ui.Button(T("重新扫描本机记录", "Rescan local records"), () => StartAction(async ct => {
            if (scanTool == Provider.Antigravity) await RefreshActivitiesAsync(ct); else await engine.ScanAsync(scanTool, true, ct);
        })));
        content.Children.Add(Ui.Text(T("首版支持 Windows 11 x64 本地路径。WSL、网络共享、符号链接目录不会被静默当成本地数据源。", "This release supports Windows 11 x64 local paths. WSL, network shares and linked directories are not silently treated as local sources."), 12, true));
        return Ui.Scroll(content);
    }
    private static ComboBox Choice(string title, (string Value, string Title)[] items, string selected) {
        var picker = new ComboBox { Header = title, MinWidth = 170 };
        foreach (var item in items) picker.Items.Add(new ComboBoxItem { Content = item.Title, Tag = item.Value });
        picker.SelectedItem = picker.Items.OfType<ComboBoxItem>().FirstOrDefault(x => (string)x.Tag == selected) ?? picker.Items[0]; return picker;
    }
    private UIElement DesktopPage()
    {
        var s = engine.Settings;
        var close = new CheckBox { Content = T("关闭主窗口时保留在托盘", "Keep running in tray when closing the window"), IsChecked = s.CloseToTray };
        var minimized = new CheckBox { Content = T("启动时不显示主窗口", "Start with the main window hidden"), IsChecked = s.StartMinimized };
        var startup = new CheckBox { Content = T("登录 Windows 时启动", "Start at Windows sign-in"), IsChecked = DesktopActions.StartupRegistered() };
        var showOverlay = new CheckBox { Content = T("显示非抢焦点悬浮挂件", "Show a non-activating quota overlay"), IsChecked = s.OverlayEnabled };
        var tool = Choice(T("挂件工具", "Overlay tool"), [("auto", T("跟随前台工具", "Follow foreground tool")), ("Codex", "Codex"), ("Claude", "Claude"), ("Antigravity", "Antigravity")], s.OverlayTool);
        return Ui.Scroll(Ui.Stack(Ui.Heading(T("托盘与挂件", "Tray & overlays"), 28), Ui.Card(Ui.Stack(close, minimized, startup)),
            Ui.Card(Ui.Stack(showOverlay, tool, Ui.Text(T("托盘与挂件只使用已验证的本机工具身份，不跟随主窗口查询账号。终端多工具或多标签页存在歧义时，请手动固定工具。", "Tray and overlay use the verified local tool identity, never the main window's viewing account. Pin a tool when terminal tabs or processes are ambiguous."), 13, true))),
            Ui.Button(T("保存桌面设置", "Save desktop settings"), () => StartAction(async ct => {
                DesktopActions.SetStartup(startup.IsChecked == true);
                await engine.UpdateSettingsAsync(value => value with { CloseToTray = close.IsChecked == true, StartMinimized = minimized.IsChecked == true,
                    OverlayEnabled = showOverlay.IsChecked == true, OverlayTool = (string)((ComboBoxItem)tool.SelectedItem).Tag }, ct);
            })), Ui.Button(T("重置挂件位置", "Reset overlay position"), () => StartAction(ct => engine.UpdateSettingsAsync(value => value with { OverlayX = null, OverlayY = null }, ct))),
            Ui.Button(T("打开托盘速览", "Open tray panel"), ShowTrayPanel)));
    }
    private UIElement AboutPage() => Ui.Scroll(Ui.Stack(Ui.Heading("QuotaLens", 32), Ui.Text("Windows · v" + engine.Version),
        Ui.Text(T("原生多工具额度看板。分析数据保存在本机，凭据使用 AES-256-GCM 和当前 Windows 用户 DPAPI 保护。", "A native multi-tool quota dashboard. Analytics stay local. Credentials use AES-256-GCM with current-user DPAPI protection."), 14, true),
        Ui.Button(T("检查更新", "Check for updates"), () => StartAction(CheckUpdatesAsync)),
        Ui.Button(T("导出隐私安全诊断", "Export privacy-safe diagnostics"), () => StartAction(async ct => {
            if (await DesktopActions.SaveFileAsync(Handle, "QuotaLens-diagnostics", ".json", "JSON") is { } path)
                await Task.Run(async () => SecureFiles.AtomicWrite(path, Encoding.UTF8.GetBytes(await engine.Database.DiagnosticsAsync(ct))), ct);
        })),
        Ui.Text(T("当前发布采用完整目录 ZIP。更新检查只打开此项目的 Release，不下载或执行未经签名验证的更新程序。", "Distribution uses a complete folder ZIP. Update checks only open this repository's release; no unverified updater is downloaded or executed."), 13, true),
        Ui.Button(T("项目主页", "Project home"), () => StartAction(_ => DesktopActions.OpenBrowserAsync(new Uri("https://github.com/yuangy1995/QuotaLens")), false))));
    private async Task CheckUpdatesAsync(CancellationToken ct)
    {
        using var client = new HttpClient(new HttpClientHandler { AllowAutoRedirect = false }) { Timeout = TimeSpan.FromSeconds(20), MaxResponseContentBufferSize = 2 * 1024 * 1024 };
        client.DefaultRequestHeaders.UserAgent.ParseAdd("QuotaLens/" + engine.Version);
        using var response = await client.GetAsync("https://api.github.com/repos/yuangy1995/QuotaLens/releases/latest", ct); response.EnsureSuccessStatusCode();
        var json = JsonTools.Parse(await response.Content.ReadAsStringAsync(ct)); var tag = json.At("tag_name").Text() ?? "";
        if (!Version.TryParse(tag.TrimStart('v'), out var latest) || !Version.TryParse(engine.Version, out var current)) throw new InvalidDataException("Unrecognized release version.");
        if (latest <= current) { ShowNotice(T("当前已是最新正式版本", "You have the latest stable version")); return; }
        var address = json.At("html_url").Text();
        if (!Uri.TryCreate(address, UriKind.Absolute, out var uri) || uri.Scheme != "https" || uri.Host != "github.com" || !uri.AbsolutePath.StartsWith("/yuangy1995/QuotaLens/releases/tag/", StringComparison.Ordinal)) throw new InvalidDataException("Unexpected release destination.");
        if (await ConfirmAsync(T("发现新版本 ", "New release ") + tag, T("在浏览器打开项目 Release，查看版本说明与对应 Windows 下载包。", "Open the project release in your browser to review notes and Windows downloads."), ct)) await DesktopActions.OpenBrowserAsync(uri);
    }
    private void ShowNotice(string text) { message.Title = "QuotaLens"; message.Message = text; message.Severity = InfoBarSeverity.Informational; message.IsOpen = true; }
}
