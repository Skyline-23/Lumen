using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;

namespace Lumen.App;

internal enum LumenAssetIcon
{
    Overview,
    Applications,
    Application,
    Settings,
    Diagnostics,
    LocalCredentials,
    HostControls,
    RemoteAccess,
    CreateOwner,
    Unlock,
    CurrentStream,
    Workspace,
    Restart,
    Complete
}

internal static class LumenAssetIconView
{
    private const string IconRoot = "ms-appx:///Assets/icons/template/";
    private const string BrandUri = "ms-appx:///Assets/brand/icon.svg";

    internal static BitmapIcon Create(
        LumenAssetIcon icon,
        double size,
        Brush? foreground = null)
    {
        var image = new BitmapIcon
        {
            UriSource = new Uri($"{IconRoot}{Filename(icon)}.png"),
            Width = size,
            Height = size,
            HorizontalAlignment = HorizontalAlignment.Center,
            VerticalAlignment = VerticalAlignment.Center
        };
        if (foreground is not null)
        {
            image.Foreground = foreground;
        }
        return image;
    }

    internal static BitmapIcon Navigation(LumenAssetIcon icon, Brush? foreground = null) => new()
    {
        UriSource = new Uri($"{IconRoot}{Filename(icon)}.png"),
        Width = LumenTheme.NavigationIconSize,
        Height = LumenTheme.NavigationIconSize,
        Margin = new Thickness(
            (LumenTheme.NavigationIconSlotWidth - LumenTheme.NavigationIconSize) / 2,
            0,
            (LumenTheme.NavigationIconSlotWidth - LumenTheme.NavigationIconSize) / 2,
            0),
        HorizontalAlignment = HorizontalAlignment.Center,
        VerticalAlignment = VerticalAlignment.Center,
        Foreground = foreground
    };

    internal static Image BrandMark(double width, double height, double opacity = 1) => new()
    {
        Source = Svg(BrandUri),
        Width = width,
        Height = height,
        Opacity = opacity,
        Stretch = Stretch.Uniform
    };

    private static SvgImageSource Svg(string uri) => new()
    {
        UriSource = new Uri(uri)
    };

    private static string Filename(LumenAssetIcon icon) => icon switch
    {
        LumenAssetIcon.Overview => "overview",
        LumenAssetIcon.Applications => "applications",
        LumenAssetIcon.Application => "application",
        LumenAssetIcon.Settings => "settings",
        LumenAssetIcon.Diagnostics => "diagnostics",
        LumenAssetIcon.LocalCredentials => "local-credentials",
        LumenAssetIcon.HostControls => "host-controls",
        LumenAssetIcon.RemoteAccess => "remote-access",
        LumenAssetIcon.CreateOwner => "create-owner",
        LumenAssetIcon.Unlock => "unlock",
        LumenAssetIcon.CurrentStream => "current-stream",
        LumenAssetIcon.Workspace => "workspace",
        LumenAssetIcon.Restart => "restart",
        LumenAssetIcon.Complete => "complete",
        _ => throw new ArgumentOutOfRangeException(nameof(icon), icon, null)
    };
}
