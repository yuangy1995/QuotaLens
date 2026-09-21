using Microsoft.UI;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Windows.UI.ViewManagement;

namespace QuotaLens.Windows.UI;

/// <summary>Registers named application palettes before the first native visual is constructed.
/// Code-created surfaces and XAML controls share the same resources.</summary>
internal static class ThemeResources
{
    private static readonly UISettings Settings = new();
    public static ResourceDictionary Create()
    {
        var root = new ResourceDictionary();
        root.MergedDictionaries.Add(new XamlControlsResources());
        root.ThemeDictionaries["Light"] = Palette(false);
        root.ThemeDictionaries["Default"] = Palette(true);
        root.ThemeDictionaries["Dark"] = Palette(true);
        var contrast = new ResourceDictionary();
        foreach (var name in new[] { "CanvasBrush", "SidebarBrush", "CardBrush", "LineBrush", "TextBrush", "MutedBrush", "AccentBrush", "SelectionBrush" }) {
            var kind = name is "CanvasBrush" or "SidebarBrush" or "CardBrush" ? UIColorType.Background
                : name is "AccentBrush" or "SelectionBrush" ? UIColorType.Accent : UIColorType.Foreground;
            contrast[name] = new SolidColorBrush(Settings.GetColorValue(kind));
        }
        root.ThemeDictionaries["HighContrast"] = contrast;
        return root;
    }
    private static ResourceDictionary Palette(bool dark)
    {
        var resources = new ResourceDictionary();
        var values = new Dictionary<string, uint> {
            ["CanvasBrush"] = dark ? 0x101925u : 0xF6F9FCu,
            ["SidebarBrush"] = dark ? 0x14202Du : 0xEAF1F7u,
            ["CardBrush"] = dark ? 0x192637u : 0xFFFFFFu,
            ["LineBrush"] = dark ? 0x2B3B50u : 0xDEE7F0u,
            ["TextBrush"] = dark ? 0xE8EFF7u : 0x19283Bu,
            ["MutedBrush"] = dark ? 0x9AAEC5u : 0x60758Du,
            ["AccentBrush"] = dark ? 0x3ABED1u : 0x078EA4u,
            ["SelectionBrush"] = dark ? 0x1B3948u : 0xE0F3F7u
        };
        foreach (var pair in values) {
            uint rgb = pair.Value;
            resources[pair.Key] = new SolidColorBrush(ColorHelper.FromArgb(255, (byte)(rgb >> 16), (byte)(rgb >> 8), (byte)rgb));
        }
        return resources;
    }
}
