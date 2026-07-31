using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;

namespace Lumen.App;

internal readonly record struct LumenNavigationEntry(
    NavigationViewItem Item,
    BitmapIcon Icon);

internal static class LumenNavigationComponents
{
    internal static LumenNavigationEntry Item(
        string label,
        string tag,
        LumenAssetIcon asset)
    {
        var icon = LumenAssetIconView.Navigation(asset, LumenTheme.SecondaryTextBrush());
        var item = new NavigationViewItem
        {
            Content = label,
            Tag = tag,
            Icon = icon,
            Foreground = LumenTheme.PrimaryTextBrush(),
            CornerRadius = new CornerRadius(LumenTheme.RowCornerRadius),
            Margin = new Thickness(6, 2, 6, 2),
            MinHeight = 42
        };
        AutomationProperties.SetName(item, label);
        return new LumenNavigationEntry(item, icon);
    }

    internal static NavigationViewItemHeader Header(string label) => new()
    {
        Content = label,
        Foreground = LumenTheme.Brush("LumenTertiaryTextBrush", 0x6EFFFFFF)
    };
}
