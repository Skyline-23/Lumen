using Microsoft.UI;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;

namespace Lumen.App;

internal static class LumenTheme
{
    internal const double NavigationIconSlotWidth = 22;
    internal const double ContentMaxWidth = 980;
    internal const double AuthenticationFormMaxWidth = 440;

    internal static Brush Brush(string key, uint fallbackArgb)
    {
        if (Application.Current.Resources.TryGetValue(key, out var value) && value is Brush brush)
        {
            return brush;
        }
        return new SolidColorBrush(ColorHelper.FromArgb(
            (byte)(fallbackArgb >> 24),
            (byte)(fallbackArgb >> 16),
            (byte)(fallbackArgb >> 8),
            (byte)fallbackArgb));
    }

    internal static Style Style(string key) =>
        Application.Current.Resources.TryGetValue(key, out var value) && value is Style style
            ? style
            : throw new InvalidOperationException($"Missing Lumen style resource: {key}");

    internal static Brush AccentBrush() => Brush("LumenAccentBrush", 0xFFFF6B33);
    internal static Brush PrimaryTextBrush() => Brush("LumenPrimaryTextBrush", 0xF0FFFFFF);
    internal static Brush SecondaryTextBrush() => Brush("LumenSecondaryTextBrush", 0xA8FFFFFF);
    internal static Brush CardBrush() => Brush("LumenCardBrush", 0x9917242D);
    internal static Brush CardBorderBrush() => Brush("LumenCardBorderBrush", 0x2FFFFFFF);

    internal static Border Card(UIElement content, Thickness? padding = null) => new()
    {
        Padding = padding ?? new Thickness(22),
        CornerRadius = new CornerRadius(16),
        BorderThickness = new Thickness(1),
        BorderBrush = CardBorderBrush(),
        Background = CardBrush(),
        Child = content
    };

    internal static Button PrimaryButton(string label) => new()
    {
        Content = label,
        Style = Style("LumenPrimaryButtonStyle")
    };

    internal static Button SecondaryButton(string label) => new()
    {
        Content = label,
        Style = Style("LumenSecondaryButtonStyle")
    };

    internal static TextBlock MutedText(string text, double fontSize = 13) => new()
    {
        Text = text,
        FontSize = fontSize,
        LineHeight = fontSize + 6,
        TextWrapping = TextWrapping.Wrap,
        Foreground = SecondaryTextBrush()
    };

    internal static void Apply(TextBox input) => input.Style = Style("LumenTextBoxStyle");
    internal static void Apply(PasswordBox input) => input.Style = Style("LumenPasswordBoxStyle");
}
