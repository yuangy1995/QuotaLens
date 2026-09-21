using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using QuotaLens.Windows.Platform;
using QuotaLens.Windows.UI;

namespace QuotaLens.Windows;

internal sealed class CompactWindow : Window
{
    private readonly bool overlay;
    private readonly Border root = new();
    private readonly StackPanel body = new() { Spacing = 12 };
    private readonly Border dragHandle;
    private bool dragging;
    private NativeMethods.Point dragOrigin;
    private NativeMethods.Rect windowOrigin;
    private readonly IntPtr handle;
    public new bool Visible { get; private set; }
    public event Action<int, int>? PositionChanged;
    public CompactWindow(bool overlay, Action openMain)
    {
        this.overlay = overlay; Title = overlay ? "QuotaLens Overlay" : "QuotaLens";
        handle = WinRT.Interop.WindowNative.GetWindowHandle(this);
        if (AppWindow.Presenter is OverlappedPresenter presenter) {
            presenter.SetBorderAndTitleBar(false, false); presenter.IsResizable = false;
            presenter.IsMaximizable = false; presenter.IsMinimizable = false; presenter.IsAlwaysOnTop = true;
        }
        dragHandle = new Border { Child = Ui.Text(overlay ? Ui.T("⠿  QuotaLens · 拖动移动", "⠿  QuotaLens · drag to move") : "QuotaLens", 14), Padding = new Thickness(4, 6, 4, 8), Background = Ui.Brush("CardBrush") };
        var content = Ui.Stack(dragHandle, body);
        if (!overlay) content.Children.Add(Ui.Button(Ui.T("打开主窗口", "Open dashboard"), openMain));
        root.Child = new ScrollViewer { Content = content, VerticalScrollBarVisibility = ScrollBarVisibility.Auto };
        root.Padding = new Thickness(18); root.CornerRadius = new CornerRadius(10); root.BorderThickness = new Thickness(1);
        Content = root;
        NativeMethods.MakeUtilityWindow(handle, overlay);
        if (overlay) {
            dragHandle.PointerPressed += (_, e) => {
                if (!e.GetCurrentPoint(dragHandle).Properties.IsLeftButtonPressed) return;
                dragging = NativeMethods.GetCursorPos(out dragOrigin) && NativeMethods.GetWindowRect(handle, out windowOrigin);
                if (dragging) { dragHandle.CapturePointer(e.Pointer); e.Handled = true; }
            };
            dragHandle.PointerMoved += (_, e) => {
                if (!dragging || !NativeMethods.GetCursorPos(out var cursor)) return;
                var location = NativeMethods.Clamp(new(windowOrigin.Left + cursor.X - dragOrigin.X, windowOrigin.Top + cursor.Y - dragOrigin.Y), windowOrigin.Width, windowOrigin.Height);
                NativeMethods.SetWindowPos(handle, NativeMethods.HwndTopMost, location.X, location.Y, 0, 0, NativeMethods.SwpNoSize | NativeMethods.SwpNoActivate); e.Handled = true;
            };
            dragHandle.PointerReleased += (_, e) => { FinishDrag(); dragHandle.ReleasePointerCaptures(); e.Handled = true; };
            dragHandle.PointerCaptureLost += (_, _) => FinishDrag();
        } else Activated += (_, e) => { if (e.WindowActivationState == WindowActivationState.Deactivated) Hide(); };
    }
    private void FinishDrag() {
        if (!dragging) return; dragging = false;
        if (NativeMethods.GetWindowRect(handle, out var rect)) PositionChanged?.Invoke(rect.Left, rect.Top);
    }
    public void Update(UIElement content, ElementTheme theme) {
        root.RequestedTheme = theme; root.Background = Ui.Brush("CardBrush"); root.BorderBrush = Ui.Brush("LineBrush");
        dragHandle.Background = Ui.Brush("CardBrush"); body.Children.Clear(); body.Children.Add(content);
    }
    public void ShowAt(int x, int y) {
        if (dragging) return;
        var scale = Math.Max(1, NativeMethods.GetDpiForWindow(handle) / 96.0);
        int width = (int)((overlay ? 300 : 390) * scale), height = (int)((overlay ? 240 : 560) * scale);
        var work = NativeMethods.WorkArea(new(x, y)); height = Math.Min(height, work.Height); width = Math.Min(width, work.Width);
        var location = NativeMethods.Clamp(new(x, y), width, height);
        NativeMethods.SetWindowPos(handle, NativeMethods.HwndTopMost, location.X, location.Y, width, height, NativeMethods.SwpNoActivate);
        NativeMethods.ShowWindow(handle, overlay ? 4 : 5); Visible = true;
        if (!overlay) { Activate(); NativeMethods.SetForegroundWindow(handle); }
    }
    public void Hide() { if (Visible) { NativeMethods.ShowWindow(handle, 0); Visible = false; } }
}

public sealed partial class MainWindow
{
    private UIElement CompactContent(QuotaLens.Core.Provider provider)
    {
        var key = engine.Accounts.ActualAccountKey(provider);
        var view = engine.Accounts.View(key);
        var panel = Ui.Stack(Ui.Heading(provider.ToString(), 18));
        if (view is null) panel.Children.Add(Ui.Text(T("尚未确认本机工具身份。请导入并验证本机登录状态。", "Local tool identity is not verified. Import and verify its local authorization."), 13, true));
        else {
            panel.Children.Add(Ui.Text(view.Account.DisplayName, 12, true));
            if (view.Quota is { } quota) {
                panel.Children.Add(Ui.Text(T("本机工具 · ", "Local tool · ") + Ui.Date(quota.ObservedAt), 11, true));
                foreach (var pool in quota.Pools.Take(3)) panel.Children.Add(Ui.Pool(pool, provider, engine.Settings.ShowRemaining, quota.ObservedAt));
            } else panel.Children.Add(Ui.Text(T("暂无已验证额度", "No verified quota yet"), 13, true));
            if (view.Status.Message is { Length: > 0 } warning) panel.Children.Add(Ui.Text(warning, 11, true));
        }
        return panel;
    }
    private void ShowTrayPanel()
    {
        if (!ready || closing) return;
        trayPanel ??= new CompactWindow(false, ShowMain);
        if (trayPanel.Visible) { trayPanel.Hide(); return; }
        var panel = Ui.Stack();
        foreach (var trayTool in engine.Settings.EnabledTools) panel.Children.Add(Ui.Card(CompactContent(trayTool)));
        if (engine.Settings.EnabledTools.Length == 0) panel.Children.Add(Ui.Text(T("请先启用监控工具", "Enable a monitoring tool first")));
        trayPanel.Update(panel, root.RequestedTheme);
        NativeMethods.GetCursorPos(out var cursor); trayPanel.ShowAt(cursor.X - 390, cursor.Y - 550);
    }
    private void UpdateCompactWindows()
    {
        if (!ready || closing) return;
        if (trayPanel?.Visible == true) {
            var panel = Ui.Stack(); foreach (var trayTool in engine.Settings.EnabledTools) panel.Children.Add(Ui.Card(CompactContent(trayTool)));
            trayPanel.Update(panel, root.RequestedTheme);
        }
        if (!engine.Settings.OverlayEnabled || foreground is null) { overlay?.Hide(); return; }
        var current = foreground.Current;
        var toolSelected = Enum.TryParse<QuotaLens.Core.Provider>(engine.Settings.OverlayTool, out var pinned) ? pinned : current.Tool;
        bool automatic = engine.Settings.OverlayTool == "auto";
        if (toolSelected is not { } tool || !engine.Settings.EnabledTools.Contains(tool) || automatic && (current.Ambiguous || current.Window == IntPtr.Zero || NativeMethods.IsIconic(current.Window))) {
            overlay?.Hide(); return;
        }
        if (overlay is null) {
            overlay = new CompactWindow(true, ShowMain);
            overlay.PositionChanged += (x, y) => StartAction(ct => engine.UpdateSettingsAsync(s => s with { OverlayX = x, OverlayY = y }, ct), false);
        }
        overlay.Update(CompactContent(tool), root.RequestedTheme);
        NativeMethods.GetCursorPos(out var cursor);
        var work = NativeMethods.WorkArea(cursor);
        int x = work.Right - 330, y = work.Bottom - 270;
        if (automatic && NativeMethods.GetWindowRect(current.Window, out var rect)) { x = rect.Right - 320; y = rect.Top + 60; }
        if (engine.Settings.OverlayX is { } storedX && engine.Settings.OverlayY is { } storedY) { x = (int)storedX; y = (int)storedY; }
        overlay.ShowAt(x, y);
    }
}
