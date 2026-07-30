using Microsoft.UI;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;

namespace Lumen.App;

internal static class LumenSettingsComponents
{
    internal static Border Card(params FrameworkElement[] rows)
    {
        var panel = new StackPanel { Spacing = LumenTheme.SectionContentSpacing };
        foreach (var row in rows)
        {
            panel.Children.Add(row);
        }
        return LumenTheme.Card(panel);
    }

    internal static Border ContentRow(UIElement content) => new()
    {
        CornerRadius = new CornerRadius(LumenTheme.RowCornerRadius),
        BorderBrush = LumenTheme.RowBorderBrush(),
        BorderThickness = new Thickness(1),
        Background = LumenTheme.RowBrush(),
        Child = content
    };

    internal static FrameworkElement ToggleRow(
        string title,
        string detail,
        bool initialValue,
        Func<bool, Task<bool>> update)
    {
        var persistedValue = initialValue;
        var toggle = new ToggleSwitch
        {
            IsOn = initialValue,
            HorizontalAlignment = HorizontalAlignment.Right,
            VerticalAlignment = VerticalAlignment.Center,
            OnContent = string.Empty,
            OffContent = string.Empty
        };
        AutomationProperties.SetName(toggle, title);
        toggle.Toggled += async (_, _) =>
        {
            if (!toggle.IsEnabled || toggle.IsOn == persistedValue)
            {
                return;
            }

            toggle.IsEnabled = false;
            var accepted = await update(toggle.IsOn);
            if (accepted)
            {
                persistedValue = toggle.IsOn;
            }
            else
            {
                toggle.IsOn = persistedValue;
            }
            toggle.IsEnabled = true;
        };
        return LabeledRow(title, detail, toggle);
    }

    internal static FrameworkElement ValueRow(string title, string value) =>
        LabeledRow(title, null, new TextBlock
        {
            Text = value,
            Foreground = LumenTheme.SecondaryTextBrush(),
            VerticalAlignment = VerticalAlignment.Center,
            TextWrapping = TextWrapping.Wrap,
            TextAlignment = TextAlignment.Right,
            MaxWidth = 360
        });

    internal static FrameworkElement StatusRow(string title, string value, bool healthy)
    {
        var color = healthy
            ? ColorHelper.FromArgb(255, 53, 199, 174)
            : ColorHelper.FromArgb(255, 255, 104, 104);
        var badge = new Border
        {
            CornerRadius = new CornerRadius(10),
            Padding = new Thickness(9, 4, 9, 4),
            Background = new SolidColorBrush(ColorHelper.FromArgb(48, color.R, color.G, color.B)),
            BorderBrush = new SolidColorBrush(ColorHelper.FromArgb(80, color.R, color.G, color.B)),
            BorderThickness = new Thickness(1),
            Child = new TextBlock
            {
                Text = value,
                FontSize = 12,
                FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
                Foreground = new SolidColorBrush(color)
            }
        };
        return LabeledRow(title, null, badge);
    }

    internal static FrameworkElement LabeledRow(
        string title,
        string? detail,
        FrameworkElement trailing)
    {
        var row = new Grid
        {
            MinHeight = 52,
            Padding = new Thickness(
                LumenTheme.RowHorizontalPadding,
                LumenTheme.RowVerticalPadding,
                LumenTheme.RowHorizontalPadding,
                LumenTheme.RowVerticalPadding),
            ColumnSpacing = 16
        };
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });

        var labels = new StackPanel
        {
            Spacing = 3,
            VerticalAlignment = VerticalAlignment.Center
        };
        labels.Children.Add(new TextBlock
        {
            Text = title,
            FontSize = 14,
            FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
            Foreground = LumenTheme.PrimaryTextBrush(),
            TextWrapping = TextWrapping.Wrap
        });
        if (!string.IsNullOrWhiteSpace(detail))
        {
            labels.Children.Add(LumenTheme.MutedText(detail, 12));
        }

        Grid.SetColumn(trailing, 1);
        row.Children.Add(labels);
        row.Children.Add(trailing);

        return ContentRow(row);
    }
}
