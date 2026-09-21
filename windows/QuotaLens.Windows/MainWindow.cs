using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using QuotaLens.Core;
using QuotaLens.Infrastructure;
using QuotaLens.Windows.Platform;
using QuotaLens.Windows.UI;

namespace QuotaLens.Windows;

public sealed partial class MainWindow : Window
{
    private readonly AppEngine engine;
    private readonly Grid root = new();
    private readonly StackPanel sidebar = new() { Spacing = 12, Padding = new Thickness(16) };
    private readonly ContentControl pageHost = new() { HorizontalContentAlignment = HorizontalAlignment.Stretch, VerticalContentAlignment = VerticalAlignment.Stretch };
    private readonly InfoBar message = new() { IsOpen = false, IsClosable = true };
    private readonly TextBlock footer = new() { FontSize = 12, Margin = new Thickness(24, 8, 24, 8) };
    private readonly ComboBox contextPicker = new() { HorizontalAlignment = HorizontalAlignment.Stretch };
    private readonly ListView navigation = new() { SelectionMode = ListViewSelectionMode.Single, IsItemClickEnabled = true };
    private readonly DispatcherQueueTimer repaint;
    private readonly CancellationTokenSource lifetime = new();
    private CancellationTokenSource pageCancellation = new();
    private CancellationTokenSource? actionCancellation;
    private Task activeAction = Task.CompletedTask;
    private readonly Button cancelButton;
    private readonly Button refreshButton;
    private readonly ToggleSwitch displaySwitch;
    private TrayService? tray;
    private ForegroundTracker? foreground;
    private CompactWindow? trayPanel;
    private CompactWindow? overlay;
    private bool ready, closing, rebuildingNavigation;
    private long pageGeneration;
    private string context = "overview", page = "summary";
    private readonly string? smokeDirectory;
    private Provider? SelectedProvider => Enum.TryParse<Provider>(context, out var provider) ? provider : null;
    private string? SelectedKey => SelectedProvider is { } provider ? engine.ViewingKey(provider) : null;
    private IntPtr Handle => WinRT.Interop.WindowNative.GetWindowHandle(this);
    private string T(string zh, string en) => Ui.T(zh, en);

    public MainWindow(string? isolatedRoot = null, string? smokeDirectory = null)
    {
        this.smokeDirectory = smokeDirectory;
        engine = new AppEngine(isolatedRoot);
        Title = "QuotaLens";
        AppWindow.Resize(new global::Windows.Graphics.SizeInt32(1240, 860));
        root.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(238) });
        root.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        var sideScroll = new ScrollViewer { Content = sidebar, VerticalScrollBarVisibility = ScrollBarVisibility.Auto };
        root.Children.Add(sideScroll);
        var content = new Grid(); Grid.SetColumn(content, 1); root.Children.Add(content);
        foreach (var height in new[] { GridLength.Auto, GridLength.Auto, new GridLength(1, GridUnitType.Star), GridLength.Auto })
            content.RowDefinitions.Add(new RowDefinition { Height = height });
        refreshButton = Ui.Button(T("↻ 刷新", "↻ Refresh"), () => StartAction(ct => engine.RefreshAsync(SelectedProvider, ct)));
        cancelButton = Ui.Button(T("取消操作", "Cancel operation"), () => actionCancellation?.Cancel()); cancelButton.Visibility = Visibility.Collapsed;
        displaySwitch = new ToggleSwitch { Header = T("额度视角", "Quota display"), OnContent = T("可用", "Remaining"), OffContent = T("已用", "Used"), IsOn = true };
        displaySwitch.Toggled += (_, _) => { if (ready) StartAction(ct => engine.UpdateSettingsAsync(s => s with { ShowRemaining = displaySwitch.IsOn }, ct)); };
        var toolbar = Ui.Row(Ui.Text("QuotaLens  /  Windows", 13, true), displaySwitch, refreshButton, cancelButton);
        toolbar.Margin = new Thickness(24, 12, 24, 12); content.Children.Add(toolbar);
        Grid.SetRow(message, 1); content.Children.Add(message);
        Grid.SetRow(pageHost, 2); content.Children.Add(pageHost);
        Grid.SetRow(footer, 3); content.Children.Add(footer);
        Content = root;
        repaint = DispatcherQueue.CreateTimer(); repaint.Interval = TimeSpan.FromMilliseconds(450); repaint.IsRepeating = false;
        repaint.Tick += async (_, _) => {
            if (!ready || closing) return;
            UpdateStatus();
            if (page is "summary" or "quota" or "forecast" or "distribution") await RenderPageAsync();
        };
        contextPicker.SelectionChanged += (_, _) => {
            if (rebuildingNavigation || !ready || contextPicker.SelectedItem is not ComboBoxItem item) return;
            context = (string)item.Tag; page = context == "overview" ? "summary" : "quota";
            BuildNavigation(); _ = RenderPageAsync(); SaveRoute();
        };
        navigation.ItemClick += (_, e) => { if (e.ClickedItem is ListViewItem item) Navigate((string)item.Tag); };
        root.Loaded += async (_, _) => { if (!ready) await InitializeAsync(); };
        root.ActualThemeChanged += (_, _) => { if (ready && smokeDirectory is null) { ApplyPalette(); _ = RenderPageAsync(); } };
        root.SizeChanged += (_, e) => root.ColumnDefinitions[0].Width = new GridLength(e.NewSize.Width < 950 ? 196 : 238);
        AppWindow.Closing += (sender, args) => {
            if (closing) return;
            args.Cancel = true;
            if (ready && engine.Settings.CloseToTray && tray?.IsAdded == true && actionCancellation is null) HideMain();
            else _ = ShutdownAsync();
        };
        ApplyPalette(); pageHost.Content = Ui.Scroll(Ui.Empty(T("正在准备本地看板", "Preparing your local dashboard"), T("已有记录不会被覆盖。", "Existing records will not be overwritten.")));
    }
    private async Task InitializeAsync()
    {
        try {
            await engine.InitializeAsync(startBackground: smokeDirectory is null, lifetime.Token);
            ready = true; ApplySettings();
            context = engine.Settings.Context; page = engine.Settings.Page;
            engine.Changed += OnDataChanged;
            if (smokeDirectory is null) {
                try {
                    tray = new TrayService(Handle); tray.OpenRequested += ShowMain;
                    tray.PanelRequested += ShowTrayPanel; tray.RefreshRequested += () => StartAction(ct => engine.RefreshAsync(ct: ct));
                    tray.PauseRequested += () => StartAction(ct => engine.UpdateSettingsAsync(s => s with { Paused = !s.Paused }, ct));
                    tray.SettingsRequested += () => { ShowMain(); Navigate("settings"); }; tray.ExitRequested += () => _ = ShutdownAsync();
                    foreground = new ForegroundTracker(); foreground.Changed += OnForegroundChanged;
                    engine.NotificationRequested += OnNotification;
                } catch (Exception error) { ShowError(error); }
            }
            BuildNavigation(); await RenderPageAsync(); UpdateStatus();
            if (smokeDirectory is not null) await RunSmokeAsync(smokeDirectory);
            else if ((engine.Settings.StartMinimized || Environment.GetCommandLineArgs().Contains("--background")) && tray?.IsAdded == true) HideMain();
        } catch (Exception error) {
            if (smokeDirectory is not null) { Directory.CreateDirectory(smokeDirectory); await File.WriteAllTextAsync(Path.Combine(smokeDirectory, "failure.txt"), error.ToString()); }
            message.Title = T("无法初始化本地存储", "Local storage could not be initialized"); message.Message = SafeErrors.Describe(error).Message;
            message.Severity = InfoBarSeverity.Error; message.IsOpen = true;
            pageHost.Content = Ui.Scroll(Ui.Empty(T("已有文件已保留", "Existing files were retained"), T("请退出后检查磁盘空间与文件权限，再重新打开应用。", "Exit, check disk space and file permissions, then reopen the app.")));
        }
    }
    private void BuildNavigation()
    {
        rebuildingNavigation = true;
        try {
            sidebar.Children.Clear(); sidebar.Children.Add(Ui.Heading("◉  QuotaLens", 25));
            sidebar.Children.Add(Ui.Text("YOUR QUOTA, IN FOCUS", 10, true));
            contextPicker.Items.Clear();
            contextPicker.Items.Add(new ComboBoxItem { Content = T("总览 · 全部工具", "Overview · All tools"), Tag = "overview" });
            foreach (var tool in engine.Settings.EnabledTools) contextPicker.Items.Add(new ComboBoxItem { Content = tool.ToString(), Tag = tool.ToString() });
            var selected = contextPicker.Items.OfType<ComboBoxItem>().FirstOrDefault(x => (string)x.Tag == context);
            if (selected is null) { context = "overview"; page = "summary"; selected = (ComboBoxItem)contextPicker.Items[0]; }
            contextPicker.SelectedItem = selected; sidebar.Children.Add(contextPicker);
            navigation.Items.Clear();
            void Add(string id, string zh, string en) => navigation.Items.Add(new ListViewItem { Content = T(zh, en), Tag = id, HorizontalContentAlignment = HorizontalAlignment.Stretch });
            if (SelectedProvider is null) { Add("summary", "概况", "At a glance"); Add("accounts", "账号资源", "Account resources"); Add("distribution", "使用分布", "Usage distribution"); }
            else {
                Add("quota", "额度概览", "Quota overview");
                if (SelectedProvider == Provider.Codex) Add("forecast", "额度预测", "Quota forecast");
                Add("usage", "用量分析", "Usage analytics"); Add("history", "历史记录", "History"); Add("sessions", "会话明细", "Sessions");
                if (SelectedProvider == Provider.Codex) Add("credits", "重置卡", "Reset cards");
                Add("accounts", "账号管理", "Accounts"); Add("tool-settings", "工具设置", "Tool settings");
            }
            sidebar.Children.Add(navigation);
            sidebar.Children.Add(Ui.Button(T("应用设置", "App settings"), () => Navigate("settings")));
            sidebar.Children.Add(Ui.Button(T("托盘与挂件", "Tray & overlays"), () => Navigate("desktop")));
            sidebar.Children.Add(Ui.Button(T("恢复中心", "Recovery center"), () => Navigate("recovery")));
            sidebar.Children.Add(Ui.Button(T("关于", "About"), () => Navigate("about")));
            sidebar.Children.Add(Ui.Text(T("●  分析数据仅保存在本机", "●  Analytics stay on this computer"), 11, true));
            sidebar.Children.Add(Ui.Text("Windows 11 · v" + engine.Version, 11, true));
            navigation.SelectedItem = navigation.Items.OfType<ListViewItem>().FirstOrDefault(x => (string)x.Tag == page);
        } finally { rebuildingNavigation = false; }
    }
    private void Navigate(string destination) { page = destination; BuildNavigation(); _ = RenderPageAsync(); SaveRoute(); }
    private void SaveRoute() { if (actionCancellation is null) StartAction(ct => engine.UpdateSettingsAsync(s => s with { Context = context, Page = page }, ct), false); }
    private void ApplySettings() {
        Ui.Chinese = engine.Settings.Language == "zh-CN" || engine.Settings.Language == "system" && System.Globalization.CultureInfo.CurrentUICulture.Name.StartsWith("zh", StringComparison.OrdinalIgnoreCase);
        root.RequestedTheme = engine.Settings.Theme switch { "light" => ElementTheme.Light, "dark" => ElementTheme.Dark, _ => ElementTheme.Default };
        bool old = ready; ready = false; displaySwitch.IsOn = engine.Settings.ShowRemaining; ready = old;
        ApplyPalette();
    }
    private void ApplyPalette() { root.Background = Ui.Brush("CanvasBrush"); sidebar.Background = Ui.Brush("SidebarBrush"); footer.Foreground = Ui.Brush("MutedBrush"); }
    private void OnDataChanged() => DispatcherQueue.TryEnqueue(() => { if (!closing && ready && smokeDirectory is null) { repaint.Stop(); repaint.Start(); } });
    private void UpdateStatus() {
        footer.Text = (engine.Settings.Paused ? T("自动刷新已暂停", "Automatic refresh paused") : T("云端额度与本机记录分开统计", "Cloud quota and local usage are separate")) + "  ·  " + engine.ScanProgress;
        if (!string.IsNullOrEmpty(engine.Warning) && actionCancellation is null) { message.Title = T("需要关注", "Attention"); message.Message = engine.Warning; message.Severity = InfoBarSeverity.Warning; message.IsOpen = true; }
        if (tray is not null) { tray.Chinese = Ui.Chinese; tray.Paused = engine.Settings.Paused; tray.Update("QuotaLens · " + (foreground?.LastTool?.ToString() ?? T("额度看板", "Quota dashboard"))); }
        UpdateCompactWindows();
    }
    private void StartAction(Func<CancellationToken, Task> action, bool render = true) {
        if (!ready || closing || actionCancellation is not null) return;
        activeAction = ExecuteActionAsync(action, render);
    }
    private async Task ExecuteActionAsync(Func<CancellationToken, Task> action, bool render) {
        using var cancellation = CancellationTokenSource.CreateLinkedTokenSource(lifetime.Token); actionCancellation = cancellation;
        refreshButton.IsEnabled = false; cancelButton.Visibility = Visibility.Visible;
        try { await action(cancellation.Token); if (!closing) { ApplySettings(); if (render) { BuildNavigation(); await RenderPageAsync(); } UpdateStatus(); } }
        catch (OperationCanceledException) { }
        catch (Exception error) { if (!closing) ShowError(error); }
        finally { actionCancellation = null; refreshButton.IsEnabled = true; cancelButton.Visibility = Visibility.Collapsed; }
    }
    private void ShowError(Exception error) {
        if (smokeDirectory is not null) { Directory.CreateDirectory(smokeDirectory); File.WriteAllText(Path.Combine(smokeDirectory, "failure.txt"), error.ToString()); }
        message.Title = T("操作未完成", "Operation did not complete"); message.Message = SafeErrors.Describe(error).Message; message.Severity = InfoBarSeverity.Warning; message.IsOpen = true;
    }
    public void ShowMain() { if (closing) return; AppWindow.Show(); Activate(); NativeMethods.SetForegroundWindow(Handle); }
    private void HideMain() { trayPanel?.Hide(); AppWindow.Hide(); }
    private void OnNotification(string title, string text) => DispatcherQueue.TryEnqueue(() => tray?.Notify(title, text));
    private void OnForegroundChanged(ForegroundState state) => DispatcherQueue.TryEnqueue(UpdateCompactWindows);
    private async Task ShutdownAsync() {
        if (closing) return; closing = true; lifetime.Cancel(); pageCancellation.Cancel(); actionCancellation?.Cancel(); repaint.Stop();
        engine.Changed -= OnDataChanged; engine.NotificationRequested -= OnNotification;
        foreground?.Dispose(); tray?.Dispose(); trayPanel?.Close(); overlay?.Close();
        try { await activeAction; await engine.DisposeAsync(); } catch (Exception) { }
        pageCancellation.Dispose(); lifetime.Dispose(); Close(); Application.Current.Exit();
    }
}
