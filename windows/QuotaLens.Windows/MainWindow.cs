using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using QuotaLens.Infrastructure;

namespace QuotaLens.Windows;

public sealed class MainWindow : Window
{
    private readonly TextBlock status = new() { Text = "正在初始化本地存储…", FontSize = 14, TextWrapping = TextWrapping.Wrap };
    private LocalDatabase? database;
    public MainWindow()
    {
        Title = "QuotaLens · Windows";
        AppWindow.Resize(new global::Windows.Graphics.SizeInt32(1240, 820));
        var root = new Grid(); root.Background = (Brush)Application.Current.Resources["CanvasBrush"];
        var stack = new StackPanel { Margin = new Thickness(36), Spacing = 18 };
        stack.Children.Add(new TextBlock { Text = "QuotaLens", FontSize = 32 });
        stack.Children.Add(new TextBlock { Text = "YOUR QUOTA, IN FOCUS", FontSize = 12 });
        stack.Children.Add(status); root.Children.Add(stack); Content = root;
        root.Loaded += async (_, _) => {
            try { database = new(SecureFiles.DefaultRoot); await database.InitializeAsync(); status.Text = "本地存储已就绪。"; }
            catch (Exception error) { status.Text = "本地存储无法初始化；已有文件未被覆盖。\n" + error.GetType().Name; }
        };
        Closed += (_, _) => database?.Dispose();
    }
}
