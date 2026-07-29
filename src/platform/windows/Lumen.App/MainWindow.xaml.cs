using Microsoft.UI;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Shapes;

namespace Lumen.App;

public sealed class MainWindow : Window
{
    private readonly LumenControlClient _client = new();
    private NavigationView _navigation = null!;
    private Border _connectionBadge = null!;
    private TextBlock _connectionBadgeText = null!;
    private StackPanel _contentPanel = null!;
    private Grid _busyOverlay = null!;
    private ManagementSnapshot? _snapshot;
    private string _page = "overview";
    private bool _updating;

    public MainWindow()
    {
        Title = "Lumen";
        BuildShell();
        ConfigureNavigationItems();
        Activated += async (_, _) => await RefreshAsync();
    }

    private void BuildShell()
    {
        _navigation = new NavigationView
        {
            PaneDisplayMode = NavigationViewPaneDisplayMode.Left,
            IsBackButtonVisible = NavigationViewBackButtonVisible.Collapsed,
            IsSettingsVisible = false,
            IsPaneToggleButtonVisible = true
        };
        _navigation.SelectionChanged += Navigation_SelectionChanged;

        _connectionBadgeText = new TextBlock { Text = "Connecting", FontSize = 11 };
        _connectionBadge = new Border
        {
            CornerRadius = new CornerRadius(10),
            Padding = new Thickness(8, 3, 8, 3),
            Margin = new Thickness(8, 0, 0, 0),
            Background = ResourceBrush(
                "ControlFillColorDefaultBrush",
                new SolidColorBrush(ColorHelper.FromArgb(28, 127, 127, 127))),
            Child = _connectionBadgeText
        };
        var header = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 10 };
        header.Children.Add(new FontIcon
        {
            Glyph = "\uE7F4",
            FontSize = 18,
            Foreground = AccentBrush()
        });
        header.Children.Add(new TextBlock
        {
            Text = "Lumen",
            FontSize = 15,
            FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
            VerticalAlignment = VerticalAlignment.Center
        });
        header.Children.Add(_connectionBadge);
        _navigation.Header = header;

        _contentPanel = new StackPanel
        {
            Padding = new Thickness(32, 24, 32, 48),
            Spacing = 16,
            MaxWidth = 980,
            HorizontalAlignment = HorizontalAlignment.Stretch
        };
        var content = new Grid();
        content.Children.Add(new ScrollViewer
        {
            VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
            Content = _contentPanel
        });
        var busyContent = new StackPanel
        {
            HorizontalAlignment = HorizontalAlignment.Center,
            VerticalAlignment = VerticalAlignment.Center,
            Spacing = 12
        };
        busyContent.Children.Add(new ProgressRing { IsActive = true, Width = 36, Height = 36 });
        busyContent.Children.Add(new TextBlock { Text = "Connecting to the Lumen host…" });
        _busyOverlay = new Grid
        {
            Background = ResourceBrush(
                "AcrylicInAppFillColorDefaultBrush",
                new SolidColorBrush(ColorHelper.FromArgb(235, 30, 30, 30)))
        };
        _busyOverlay.Children.Add(busyContent);
        content.Children.Add(_busyOverlay);
        _navigation.Content = content;

        var root = new Grid
        {
            Background = ResourceBrush(
                "ApplicationPageBackgroundThemeBrush",
                new SolidColorBrush(Colors.Transparent))
        };
        root.Children.Add(_navigation);
        Content = root;
    }

    private static Brush ResourceBrush(string key, Brush fallback) =>
        Application.Current.Resources.TryGetValue(key, out var value) && value is Brush brush
            ? brush
            : fallback;

    private static Brush AccentBrush() => ResourceBrush(
        "LumenAccentBrush",
        new SolidColorBrush(ColorHelper.FromArgb(255, 255, 107, 51)));

    private void ConfigureNavigationItems()
    {
        _navigation.MenuItems.Add(NavigationItem("Overview", "overview", Symbol.Home));
        _navigation.MenuItems.Add(NavigationItem("Applications", "applications", Symbol.AllApps));
        _navigation.MenuItems.Add(new NavigationViewItemHeader { Content = "Settings" });
        _navigation.MenuItems.Add(NavigationItem("Security", "security", Symbol.Permissions));
        _navigation.MenuItems.Add(NavigationItem("General", "general", Symbol.Setting));
        _navigation.MenuItems.Add(NavigationItem("Streaming", "streaming", Symbol.Video));
        _navigation.MenuItems.Add(NavigationItem("Audio", "audio", Symbol.Volume));
        _navigation.MenuItems.Add(NavigationItem("Input", "input", Symbol.Keyboard));
        _navigation.MenuItems.Add(NavigationItem("Network", "network", Symbol.World));
        _navigation.MenuItems.Add(NavigationItem("Advanced", "advanced", Symbol.Repair));
        _navigation.FooterMenuItems.Add(
            NavigationItem("Diagnostics", "diagnostics", Symbol.ReportHacked));
        _navigation.FooterMenuItems.Add(NavigationItem("About", "about", Symbol.Help));
    }

    private static NavigationViewItem NavigationItem(string label, string tag, Symbol symbol) =>
        new()
        {
            Content = label,
            Tag = tag,
            Icon = new SymbolIcon(symbol)
        };

    public void ShowFatalError(string message)
    {
        _busyOverlay.Visibility = Visibility.Collapsed;
        RenderError("Lumen could not continue", message);
    }

    private async Task RefreshAsync()
    {
        if (_updating)
        {
            return;
        }
        _updating = true;
        _busyOverlay.Visibility = Visibility.Visible;
        try
        {
            _snapshot = await _client.SendAsync(new { command = "snapshot" });
            _connectionBadgeText.Text = "Host online";
            _connectionBadge.Background = new SolidColorBrush(ColorHelper.FromArgb(42, 0, 191, 175));
            Render();
        }
        catch (Exception error)
        {
            _snapshot = null;
            _connectionBadgeText.Text = "Host unavailable";
            _connectionBadge.Background = new SolidColorBrush(ColorHelper.FromArgb(42, 224, 62, 62));
            RenderError(
                "Lumen host unavailable",
                $"The background host is not ready. {error.Message}",
                retry: true);
        }
        finally
        {
            _busyOverlay.Visibility = Visibility.Collapsed;
            _updating = false;
        }
    }

    private void Navigation_SelectionChanged(NavigationView sender, NavigationViewSelectionChangedEventArgs args)
    {
        if (args.SelectedItemContainer?.Tag is string tag)
        {
            _page = tag;
            Render();
        }
    }

    private void Render()
    {
        _contentPanel.Children.Clear();
        if (_snapshot is null)
        {
            return;
        }
        if (_snapshot.OwnerState != "authenticated")
        {
            RenderAuthentication(_snapshot);
            return;
        }
        switch (_page)
        {
            case "applications": RenderApplications(_snapshot); break;
            case "security": RenderSecurity(_snapshot); break;
            case "general": RenderGeneral(_snapshot); break;
            case "streaming": RenderStreaming(_snapshot); break;
            case "audio": RenderAudio(_snapshot); break;
            case "input": RenderInput(_snapshot); break;
            case "network": RenderNetwork(_snapshot); break;
            case "advanced": RenderAdvanced(_snapshot); break;
            case "diagnostics": RenderDiagnostics(_snapshot); break;
            case "about": RenderAbout(); break;
            default: RenderOverview(_snapshot); break;
        }
    }

    private void RenderAuthentication(ManagementSnapshot snapshot)
    {
        AddPageHeader(
            snapshot.OwnerState == "setupRequired" ? "Create owner account" : "Sign in to Lumen",
            "Host settings and enrolled devices are protected by the local owner account.");
        var panel = new StackPanel { Spacing = 12, MaxWidth = 520, HorizontalAlignment = HorizontalAlignment.Left };
        var username = TextInput("Owner username", snapshot.OwnerName ?? string.Empty);
        var password = PasswordInput("Owner password");
        var confirmation = PasswordInput("Confirm password");
        panel.Children.Add(username.Container);
        panel.Children.Add(password.Container);
        if (snapshot.OwnerState == "setupRequired")
        {
            panel.Children.Add(confirmation.Container);
        }
        var submit = PrimaryButton(snapshot.OwnerState == "setupRequired" ? "Create account" : "Sign in");
        async Task SubmitAuthenticationAsync()
        {
            try
            {
                _snapshot = snapshot.OwnerState == "setupRequired"
                    ? await _client.SendAsync(new
                    {
                        command = "createOwner",
                        username = username.Input.Text,
                        password = password.Input.Password,
                        confirmation = confirmation.Input.Password
                    })
                    : await _client.SendAsync(new { command = "login", password = password.Input.Password });
                Render();
            }
            catch (Exception error)
            {
                await ShowDialogAsync("Authentication failed", error.Message);
            }
        }
        submit.Click += async (_, _) => await SubmitAuthenticationAsync();
        password.Input.KeyDown += async (_, args) =>
        {
            if (args.Key == Windows.System.VirtualKey.Enter)
            {
                args.Handled = true;
                await SubmitAuthenticationAsync();
            }
        };
        panel.Children.Add(submit);
        _contentPanel.Children.Add(Card(panel));
    }

    private void RenderOverview(ManagementSnapshot snapshot)
    {
        AddPageHeader("Overview", "Host health and the actions that affect the running service.");
        var identity = new StackPanel { Spacing = 4 };
        identity.Children.Add(new TextBlock { Text = snapshot.HostName, FontSize = 24, FontWeight = Microsoft.UI.Text.FontWeights.SemiBold });
        identity.Children.Add(Muted($"Control endpoint · HTTPS {snapshot.ControlPort}"));
        identity.Children.Add(StatusLine("Host runtime", "Online", true));
        identity.Children.Add(StatusLine("Applications", snapshot.Applications.Count.ToString(), true));
        _contentPanel.Children.Add(Card(identity));

        var actions = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 10 };
        actions.Children.Add(ActionButton("Reload applications", "reloadApplications"));
        actions.Children.Add(ActionButton("Force stop stream", "forceStopStream"));
        actions.Children.Add(ActionButton("Restart host", "restartHost"));
        _contentPanel.Children.Add(Card(actions));
    }

    private void RenderApplications(ManagementSnapshot snapshot)
    {
        AddPageHeader("Applications", "Desktop and application entries available to connected clients.");
        if (snapshot.Applications.Count == 0)
        {
            _contentPanel.Children.Add(Card(Muted("No applications are configured.")));
            return;
        }
        var list = new StackPanel { Spacing = 0 };
        foreach (var app in snapshot.Applications)
        {
            var row = new Grid { Padding = new Thickness(4, 14, 4, 14), ColumnSpacing = 12 };
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            var icon = new SymbolIcon(Symbol.AllApps) { Foreground = AccentBrush() };
            Grid.SetColumn(icon, 0);
            var labels = new StackPanel { Spacing = 2 };
            labels.Children.Add(new TextBlock { Text = app.Title, FontWeight = Microsoft.UI.Text.FontWeights.SemiBold });
            labels.Children.Add(Muted($"App ID {app.Id} · HDR {(app.HdrSupported ? "Yes" : "No")}"));
            Grid.SetColumn(labels, 1);
            row.Children.Add(icon);
            row.Children.Add(labels);
            list.Children.Add(row);
            list.Children.Add(new Rectangle { Height = 1, Fill = new SolidColorBrush(ColorHelper.FromArgb(35, 127, 127, 127)) });
        }
        _contentPanel.Children.Add(Card(list));
    }

    private void RenderSecurity(ManagementSnapshot snapshot)
    {
        AddPageHeader("Security", "Owner authentication protects host configuration and device enrollment.");
        var panel = new StackPanel { Spacing = 14 };
        panel.Children.Add(StatusLine("Owner", snapshot.OwnerName ?? "Unavailable", true));
        var logout = SecondaryButton("Log out");
        logout.Click += async (_, _) => await ExecuteAsync(new { command = "logout" });
        panel.Children.Add(logout);
        _contentPanel.Children.Add(Card(panel));
    }

    private void RenderGeneral(ManagementSnapshot snapshot)
    {
        AddPageHeader("General", "Discovery and update behavior for this host.");
        _contentPanel.Children.Add(SettingsCard(
            ToggleRow("Network discovery", "Advertise this host to supported clients.", snapshot.Settings.General.Discovery, 0),
            ToggleRow("Pre-release notifications", "Notify this host about beta releases.", snapshot.Settings.General.NotifyPreReleases, 1)));
    }

    private void RenderStreaming(ManagementSnapshot snapshot)
    {
        AddPageHeader("Streaming", "Display adapter and fallback mode selected by the host runtime.");
        _contentPanel.Children.Add(SettingsCard(
            ValueRow("Graphics adapter", snapshot.Settings.Streaming.AdapterSelector),
            ValueRow("Output", snapshot.Settings.Streaming.OutputSelector),
            ValueRow("Fallback display mode", snapshot.Settings.Streaming.FallbackDisplayMode),
            ValueRow("Workspace policy", snapshot.Settings.Workspace.Policy)));
    }

    private void RenderAudio(ManagementSnapshot snapshot)
    {
        AddPageHeader("Audio", "System audio capture and negotiated client playback.");
        _contentPanel.Children.Add(SettingsCard(
            ToggleRow("Stream system audio", "Capture audio for connected clients.", snapshot.Settings.Audio.StreamAudio, 2),
            ValueRow("Audio sink", snapshot.Settings.Audio.Sink)));
    }

    private void RenderInput(ManagementSnapshot snapshot)
    {
        AddPageHeader("Input", "Remote keyboard, pointer, gamepad, pen, and scrolling behavior.");
        _contentPanel.Children.Add(SettingsCard(
            ToggleRow("Keyboard", "Accept remote keyboard input.", snapshot.Settings.Input.Keyboard, 3),
            ToggleRow("Mouse", "Accept remote pointer input.", snapshot.Settings.Input.Mouse, 4),
            ToggleRow("Controller", "Accept remote gamepad input.", snapshot.Settings.Input.Controller, 5),
            ToggleRow("Map Right Alt to Windows", "Use Right Alt as the Windows key.", snapshot.Settings.Input.MapRightAltToWindowsKey, 6),
            ToggleRow("High-resolution scrolling", "Preserve precision trackpad and wheel deltas.", snapshot.Settings.Input.HighResolutionScrolling, 7),
            ToggleRow("Native pen and touch", "Forward native pen and touch contacts.", snapshot.Settings.Input.NativePenTouch, 8),
            ToggleRow("Rumble forwarding", "Forward gamepad rumble to the client.", snapshot.Settings.Input.RumbleForwarding, 9)));
    }

    private void RenderNetwork(ManagementSnapshot snapshot)
    {
        AddPageHeader("Network", "Listener, encryption, discovery, and remote access policy.");
        _contentPanel.Children.Add(SettingsCard(
            ValueRow("Address family", snapshot.Settings.Network.AddressFamily),
            ValueRow("Base port", snapshot.Settings.Network.Port.ToString()),
            ValueRow("Remote access", snapshot.Settings.Network.RemoteAccessScope),
            ValueRow("LAN encryption", snapshot.Settings.Network.LanEncryption),
            ValueRow("WAN encryption", snapshot.Settings.Network.WanEncryption),
            ToggleRow("UPnP", "Request router mappings for configured listeners.", snapshot.Settings.Network.Upnp, 10)));
    }

    private void RenderAdvanced(ManagementSnapshot snapshot)
    {
        AddPageHeader("Advanced", "Session-independent runtime controls.");
        _contentPanel.Children.Add(SettingsCard(
            ValueRow("Ping timeout", $"{snapshot.Settings.Network.PingTimeoutMs} ms"),
            ValueRow("Forward error correction", $"{snapshot.Settings.Network.FecPercentage}%"),
            ValueRow("Back button timeout", snapshot.Settings.Input.BackButtonTimeoutMs < 0 ? "Disabled" : $"{snapshot.Settings.Input.BackButtonTimeoutMs} ms")));
    }

    private void RenderDiagnostics(ManagementSnapshot snapshot)
    {
        AddPageHeader("Diagnostics", "Current runtime diagnostics configuration.");
        _contentPanel.Children.Add(SettingsCard(
            StatusLine("Management protocol", $"v{snapshot.ProtocolVersion}", true),
            StatusLine("Host connection", "Online", true),
            ValueRow("Log level", snapshot.Settings.Diagnostics.LogLevel)));
    }

    private void RenderAbout()
    {
        AddPageHeader("About", "Lumen remote desktop host for Windows.");
        _contentPanel.Children.Add(Card(new TextBlock
        {
            Text = "Lumen\nOpen-source · Self-hosted · Native Windows host",
            FontSize = 18,
            TextWrapping = TextWrapping.Wrap
        }));
    }

    private void RenderError(string title, string message, bool retry = false)
    {
        _contentPanel.Children.Clear();
        AddPageHeader(title, message);
        if (retry)
        {
            var button = PrimaryButton("Retry");
            button.Click += async (_, _) => await RefreshAsync();
            _contentPanel.Children.Add(button);
        }
    }

    private async Task ExecuteAsync(object command)
    {
        try
        {
            _snapshot = await _client.SendAsync(command);
            Render();
        }
        catch (Exception error)
        {
            await ShowDialogAsync("Lumen command failed", error.Message);
        }
    }

    private Button ActionButton(string label, string command)
    {
        var button = SecondaryButton(label);
        button.Click += async (_, _) => await ExecuteAsync(new { command });
        return button;
    }

    private FrameworkElement ToggleRow(string title, string detail, bool enabled, int setting)
    {
        var toggle = new ToggleSwitch { IsOn = enabled, VerticalAlignment = VerticalAlignment.Center };
        toggle.Toggled += async (_, _) =>
        {
            if (_updating || toggle.IsOn == enabled)
            {
                return;
            }
            await ExecuteAsync(new { command = "updateBoolean", setting, enabled = toggle.IsOn });
        };
        return LabeledRow(title, detail, toggle);
    }

    private static FrameworkElement ValueRow(string title, string value) =>
        LabeledRow(title, null, new TextBlock { Text = value, Foreground = new SolidColorBrush(Colors.Gray), VerticalAlignment = VerticalAlignment.Center });

    private static FrameworkElement StatusLine(string title, string value, bool healthy)
    {
        var badge = new Border
        {
            CornerRadius = new CornerRadius(10),
            Padding = new Thickness(9, 4, 9, 4),
            Background = new SolidColorBrush(healthy ? ColorHelper.FromArgb(40, 0, 191, 175) : ColorHelper.FromArgb(40, 224, 62, 62)),
            Child = new TextBlock { Text = value, FontSize = 12 }
        };
        return LabeledRow(title, null, badge);
    }

    private static FrameworkElement LabeledRow(string title, string? detail, FrameworkElement trailing)
    {
        var row = new Grid { Padding = new Thickness(4, 13, 4, 13), ColumnSpacing = 16 };
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var labels = new StackPanel { Spacing = 2 };
        labels.Children.Add(new TextBlock { Text = title, FontWeight = Microsoft.UI.Text.FontWeights.SemiBold });
        if (!string.IsNullOrWhiteSpace(detail))
        {
            labels.Children.Add(Muted(detail));
        }
        Grid.SetColumn(labels, 0);
        Grid.SetColumn(trailing, 1);
        row.Children.Add(labels);
        row.Children.Add(trailing);
        return row;
    }

    private static Border SettingsCard(params FrameworkElement[] rows)
    {
        var panel = new StackPanel { Spacing = 0 };
        for (var index = 0; index < rows.Length; index++)
        {
            panel.Children.Add(rows[index]);
            if (index + 1 < rows.Length)
            {
                panel.Children.Add(new Rectangle { Height = 1, Fill = new SolidColorBrush(ColorHelper.FromArgb(35, 127, 127, 127)) });
            }
        }
        return Card(panel);
    }

    private static Border Card(UIElement content) => new()
    {
        Padding = new Thickness(20),
        CornerRadius = new CornerRadius(12),
        BorderThickness = new Thickness(1),
        BorderBrush = new SolidColorBrush(ColorHelper.FromArgb(45, 127, 127, 127)),
        Background = new SolidColorBrush(ColorHelper.FromArgb(24, 127, 127, 127)),
        Child = content
    };

    private void AddPageHeader(string title, string subtitle)
    {
        _contentPanel.Children.Add(new TextBlock { Text = title, FontSize = 32, FontWeight = Microsoft.UI.Text.FontWeights.SemiBold });
        _contentPanel.Children.Add(new TextBlock { Text = subtitle, TextWrapping = TextWrapping.Wrap, Foreground = new SolidColorBrush(Colors.Gray), Margin = new Thickness(0, -8, 0, 8) });
    }

    private static TextBlock Muted(string text) => new()
    {
        Text = text,
        FontSize = 12,
        TextWrapping = TextWrapping.Wrap,
        Foreground = new SolidColorBrush(Colors.Gray)
    };

    private static Button PrimaryButton(string label) => new()
    {
        Content = label,
        Padding = new Thickness(22, 9, 22, 9),
        HorizontalAlignment = HorizontalAlignment.Left,
        Background = AccentBrush(),
        Foreground = new SolidColorBrush(Colors.White),
        CornerRadius = new CornerRadius(16)
    };

    private static Button SecondaryButton(string label) => new()
    {
        Content = label,
        Padding = new Thickness(16, 8, 16, 8),
        CornerRadius = new CornerRadius(14)
    };

    private static (StackPanel Container, TextBox Input) TextInput(string label, string value)
    {
        var input = new TextBox { Text = value, Header = label };
        return (new StackPanel { Children = { input } }, input);
    }

    private static (StackPanel Container, PasswordBox Input) PasswordInput(string label)
    {
        var input = new PasswordBox { Header = label };
        return (new StackPanel { Children = { input } }, input);
    }

    private async Task ShowDialogAsync(string title, string message)
    {
        var dialog = new ContentDialog
        {
            XamlRoot = _contentPanel.XamlRoot,
            Title = title,
            Content = message,
            CloseButtonText = "OK"
        };
        await dialog.ShowAsync();
    }
}
