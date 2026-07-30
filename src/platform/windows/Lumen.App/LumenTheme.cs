using Microsoft.UI;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;

namespace Lumen.App;

internal static class LumenTheme
{
    internal const double NavigationIconSlotWidth = 22;
    internal const double NavigationIconSize = 17;
    internal const double NavigationPaneWidth = 210;
    internal const double ContentMaxWidth = 820;
    internal const double AuthenticationFormMaxWidth = 440;
    internal const double SectionContentSpacing = 10;
    internal const double SectionPadding = 16;
    internal const double RowHorizontalPadding = 12;
    internal const double RowVerticalPadding = 10;
    internal const double PanelCornerRadius = 14;
    internal const double RowCornerRadius = 10;
    internal static readonly Thickness PagePadding = new(30, 24, 30, 36);

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
    internal static Brush ManagementSurfaceBrush() => Brush("LumenWindowBrush", 0xFF0E0F12);
    internal static Brush CardBrush() => Brush("LumenCardBrush", 0x14FFFFFF);
    internal static Brush CardBorderBrush() => Brush("LumenCardBorderBrush", 0x24FFFFFF);
    internal static Brush RowBrush() => Brush("LumenRowBrush", 0x38000000);
    internal static Brush RowBorderBrush() => Brush("LumenRowBorderBrush", 0x24FFFFFF);

    internal static Border Card(UIElement content, Thickness? padding = null) => new()
    {
        Padding = padding ?? new Thickness(SectionPadding),
        CornerRadius = new CornerRadius(PanelCornerRadius),
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

    internal static StackPanel PageHeader(string title, string subtitle)
    {
        var header = new StackPanel { Spacing = 4 };
        header.Children.Add(new TextBlock
        {
            Text = title,
            FontSize = 34,
            FontWeight = Microsoft.UI.Text.FontWeights.Bold,
            CharacterSpacing = -16,
            Foreground = PrimaryTextBrush(),
            TextWrapping = TextWrapping.Wrap
        });
        header.Children.Add(new TextBlock
        {
            Text = subtitle,
            FontSize = 14,
            LineHeight = 20,
            TextWrapping = TextWrapping.Wrap,
            Foreground = SecondaryTextBrush()
        });
        return header;
    }

    internal static void Apply(TextBox input) => input.Style = Style("LumenTextBoxStyle");
    internal static void Apply(PasswordBox input) => input.Style = Style("LumenPasswordBoxStyle");
}
