using System.Globalization;
using Microsoft.UI;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using QuotaLens.Core;

namespace QuotaLens.Windows.UI;

internal static class Ui
{
    private static readonly global::Windows.UI.ViewManagement.AccessibilitySettings Accessibility = new();
    public static bool Chinese { get; set; } = CultureInfo.CurrentUICulture.Name.StartsWith("zh", StringComparison.OrdinalIgnoreCase);
    public static string T(string zh, string en) => Chinese ? zh : en;
    public static Brush Brush(string key) {
        var theme = (App.CurrentWindow?.Content as FrameworkElement)?.ActualTheme ??
            (Application.Current.RequestedTheme == ApplicationTheme.Dark ? ElementTheme.Dark : ElementTheme.Light);
        string palette = Accessibility.HighContrast ? "HighContrast" : theme == ElementTheme.Dark ? "Default" : "Light";
        return (Brush)((ResourceDictionary)Application.Current.Resources.ThemeDictionaries[palette])[key];
    }
    public static TextBlock Text(string value, double size = 14, bool muted = false) => new() {
        Text = value, FontSize = size, TextWrapping = TextWrapping.Wrap,
        Foreground = Brush(muted ? "MutedBrush" : "TextBrush"), IsTextSelectionEnabled = true
    };
    public static TextBlock Heading(string value, double size = 22) {
        var text = Text(value, size); text.FontWeight = Microsoft.UI.Text.FontWeights.SemiBold; return text;
    }
    public static StackPanel Stack(params UIElement[] children) {
        var panel = new StackPanel { Spacing = 14 }; foreach (var child in children) panel.Children.Add(child); return panel;
    }
    public static StackPanel Row(params UIElement[] children) {
        var panel = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 10 };
        foreach (var child in children) panel.Children.Add(child); return panel;
    }
    public static Border Card(UIElement child) => new() {
        Child = child, Padding = new Thickness(20), CornerRadius = new CornerRadius(10),
        Background = Brush("CardBrush"), BorderBrush = Brush("LineBrush"), BorderThickness = new Thickness(1)
    };
    public static Button Button(string text, Action action) {
        var button = new Button { Content = text }; AutomationProperties.SetName(button, text);
        button.Click += (_, _) => action(); return button;
    }
    public static Border Empty(string title, string detail) => Card(Stack(Heading(title, 18), Text(detail, 14, true)));
    public static string Number(double value) => value >= 1_000_000 ? (value / 1_000_000).ToString("0.##", CultureInfo.CurrentCulture) + " M" :
        value >= 1000 ? (value / 1000).ToString("0.##", CultureInfo.CurrentCulture) + " K" : value.ToString("N0", CultureInfo.CurrentCulture);
    public static string Date(DateTimeOffset? value) => value?.ToLocalTime().ToString("g", CultureInfo.CurrentCulture) ?? T("未提供", "Not supplied");
    public static string Reset(DateTimeOffset? value) {
        if (value is null) return T("重置时间未提供", "Reset time not supplied");
        if (value <= DateTimeOffset.UtcNow) return T("快照窗口已过期，请刷新", "Snapshot window expired; refresh");
        return T("重置于 ", "Resets ") + Date(value);
    }
    public static Brush ProviderBrush(Provider provider) => Accessibility.HighContrast ? Brush("AccentBrush") : new SolidColorBrush(provider switch {
        Provider.Claude => ColorHelper.FromArgb(255, 185, 119, 80),
        Provider.Antigravity => ColorHelper.FromArgb(255, 133, 111, 215),
        _ => ColorHelper.FromArgb(255, 17, 149, 172)
    });
    public static UIElement Pool(QuotaPool pool, Provider provider, bool remaining, DateTimeOffset observedAt) {
        bool current = pool.IsCurrent(DateTimeOffset.UtcNow);
        double value = remaining ? pool.RemainingPercent : pool.UsedPercent;
        var title = Heading(pool.Title, 14);
        var metric = Heading(current ? value.ToString("0.#") + "%" : "—", 24);
        var progress = new ProgressBar { Minimum = 0, Maximum = 100, Value = current ? value : 0,
            Height = 6, Foreground = ProviderBrush(provider), IsEnabled = current };
        AutomationProperties.SetName(progress, pool.Title + " " + (current ? value.ToString("0.#") + "%" : T("已过期", "Expired")));
        return Stack(Row(title, metric), progress, Text(Reset(pool.ResetsAt), 12, true));
    }
    public static Grid Columns(IEnumerable<UIElement> children, int maximum = 3) {
        var grid = new Grid { ColumnSpacing = 14, RowSpacing = 14 };
        foreach (var child in children) grid.Children.Add(child);
        void Arrange(double width) {
            int columns = width < 560 ? 1 : width < 850 ? Math.Min(2, maximum) : maximum;
            int rows = (grid.Children.Count + columns - 1) / columns;
            grid.ColumnDefinitions.Clear(); grid.RowDefinitions.Clear();
            for (int i = 0; i < columns; i++) grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            for (int i = 0; i < rows; i++) grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
            for (int i = 0; i < grid.Children.Count; i++) {
                if (grid.Children[i] is FrameworkElement child) { Grid.SetColumn(child, i % columns); Grid.SetRow(child, i / columns); }
            }
        }
        Arrange(1000); grid.SizeChanged += (_, e) => { if (Math.Abs(e.NewSize.Width - e.PreviousSize.Width) > 1) Arrange(e.NewSize.Width); };
        return grid;
    }
    public static UIElement Buckets(string title, IReadOnlyList<UsageBucket> values) {
        var content = Stack(Heading(title, 17)); double max = values.Count == 0 ? 1 : Math.Max(1, values.Max(x => x.Tokens));
        foreach (var item in values.Take(30)) {
            var bar = new ProgressBar { Maximum = max, Value = item.Tokens, Height = 5, Foreground = Brush("AccentBrush") };
            AutomationProperties.SetName(bar, item.Label + ": " + Number(item.Tokens));
            content.Children.Add(Stack(Row(Text(item.Label), Text(Number(item.Tokens), 14, true)), bar));
        }
        if (values.Count == 0) content.Children.Add(Text(T("暂无已解析记录", "No parsed records yet"), 14, true));
        return Card(content);
    }
    public static ScrollViewer Scroll(UIElement content) => new() {
        Content = content, VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
        HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled, Padding = new Thickness(24)
    };
}
