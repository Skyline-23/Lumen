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
        Title = T("App.Title");
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

        _connectionBadgeText = new TextBlock { Text = T("Status.Connecting"), FontSize = 11 };
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
            Text = T("App.Title"),
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
        busyContent.Children.Add(new TextBlock { Text = T("Busy.Connecting") });
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

    private static string T(string key) => AppStrings.Get(key);

    private static string F(string key, params object[] values) => AppStrings.Format(key, values);

    private void ConfigureNavigationItems()
    {
        _navigation.MenuItems.Add(NavigationItem(T("Navigation.Overview"), "overview", Symbol.Home));
        _navigation.MenuItems.Add(NavigationItem(T("Navigation.Applications"), "applications", Symbol.AllApps));
        _navigation.MenuItems.Add(new NavigationViewItemHeader { Content = T("Navigation.Settings") });
        _navigation.MenuItems.Add(NavigationItem(T("Navigation.Security"), "security", Symbol.Permissions));
        _navigation.MenuItems.Add(NavigationItem(T("Navigation.General"), "general", Symbol.Setting));
        _navigation.MenuItems.Add(NavigationItem(T("Navigation.Streaming"), "streaming", Symbol.Video));
        _navigation.MenuItems.Add(NavigationItem(T("Navigation.Audio"), "audio", Symbol.Volume));
        _navigation.MenuItems.Add(NavigationItem(T("Navigation.Input"), "input", Symbol.Keyboard));
        _navigation.MenuItems.Add(NavigationItem(T("Navigation.Network"), "network", Symbol.World));
        _navigation.MenuItems.Add(NavigationItem(T("Navigation.Advanced"), "advanced", Symbol.Repair));
        _navigation.FooterMenuItems.Add(
            NavigationItem(T("Navigation.Diagnostics"), "diagnostics", Symbol.ReportHacked));
        _navigation.FooterMenuItems.Add(NavigationItem(T("Navigation.About"), "about", Symbol.Help));
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
        RenderError(T("Error.CouldNotContinue"), message);
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
            _connectionBadgeText.Text = T("Status.HostOnline");
            _connectionBadge.Background = new SolidColorBrush(ColorHelper.FromArgb(42, 0, 191, 175));
            Render();
        }
        catch (Exception error)
        {
            _snapshot = null;
            _connectionBadgeText.Text = T("Status.HostUnavailable");
            _connectionBadge.Background = new SolidColorBrush(ColorHelper.FromArgb(42, 224, 62, 62));
            RenderError(
                T("Error.HostUnavailable"),
                F("Error.HostUnavailableDetail", error.Message),
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
            snapshot.OwnerState == "setupRequired" ? T("Authentication.CreateOwnerAccount") : T("Authentication.SignInToLumen"),
            T("Authentication.ProtectedDescription"));
        var panel = new StackPanel { Spacing = 12, MaxWidth = 520, HorizontalAlignment = HorizontalAlignment.Left };
        var username = TextInput(T("Authentication.OwnerUsername"), snapshot.OwnerName ?? string.Empty);
        var password = PasswordInput(T("Authentication.OwnerPassword"));
        var confirmation = PasswordInput(T("Authentication.ConfirmPassword"));
        panel.Children.Add(username.Container);
        panel.Children.Add(password.Container);
        if (snapshot.OwnerState == "setupRequired")
        {
            panel.Children.Add(confirmation.Container);
        }
        var submit = PrimaryButton(snapshot.OwnerState == "setupRequired" ? T("Authentication.CreateAccount") : T("Authentication.SignIn"));
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
                await ShowDialogAsync(T("Authentication.Failed"), error.Message);
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
        AddPageHeader(T("Navigation.Overview"), T("Overview.Description"));
        var identity = new StackPanel { Spacing = 4 };
        identity.Children.Add(new TextBlock { Text = snapshot.HostName, FontSize = 24, FontWeight = Microsoft.UI.Text.FontWeights.SemiBold });
        identity.Children.Add(Muted(F("Overview.ControlEndpoint", snapshot.ControlPort)));
        identity.Children.Add(StatusLine(T("Overview.HostRuntime"), T("Status.Online"), true));
        identity.Children.Add(StatusLine(T("Navigation.Applications"), snapshot.Applications.Count.ToString(), true));
        _contentPanel.Children.Add(Card(identity));

        var actions = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 10 };
        actions.Children.Add(ActionButton(T("Overview.ReloadApplications"), "reloadApplications"));
        actions.Children.Add(ActionButton(T("Overview.ForceStopStream"), "forceStopStream"));
        actions.Children.Add(ActionButton(T("Overview.RestartHost"), "restartHost"));
        _contentPanel.Children.Add(Card(actions));
    }

    private void RenderApplications(ManagementSnapshot snapshot)
    {
        AddPageHeader(T("Navigation.Applications"), T("Applications.Description"));
        if (snapshot.Applications.Count == 0)
        {
            _contentPanel.Children.Add(Card(Muted(T("Applications.NoneConfigured"))));
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
            labels.Children.Add(Muted(F("Applications.Metadata", app.Id, T(app.HdrSupported ? "Common.Yes" : "Common.No"))));
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
        AddPageHeader(T("Navigation.Security"), T("Security.Description"));
        var panel = new StackPanel { Spacing = 14 };
        panel.Children.Add(StatusLine(T("Security.Owner"), snapshot.OwnerName ?? T("Common.Unavailable"), true));
        var logout = SecondaryButton(T("Security.LogOut"));
        logout.Click += async (_, _) => await ExecuteAsync(new { command = "logout" });
        panel.Children.Add(logout);
        _contentPanel.Children.Add(Card(panel));
    }

    private void RenderGeneral(ManagementSnapshot snapshot)
    {
        AddPageHeader(T("Navigation.General"), T("General.Description"));
        _contentPanel.Children.Add(SettingsCard(
            ToggleRow(T("General.NetworkDiscovery"), T("General.NetworkDiscoveryDetail"), snapshot.Settings.General.Discovery, 0),
            ToggleRow(T("General.PreReleaseNotifications"), T("General.PreReleaseNotificationsDetail"), snapshot.Settings.General.NotifyPreReleases, 1)));
    }

    private void RenderStreaming(ManagementSnapshot snapshot)
    {
        AddPageHeader(T("Navigation.Streaming"), T("Streaming.Description"));
        _contentPanel.Children.Add(SettingsCard(
            ValueRow(T("Streaming.GraphicsAdapter"), snapshot.Settings.Streaming.AdapterSelector),
            ValueRow(T("Streaming.Output"), snapshot.Settings.Streaming.OutputSelector),
            ValueRow(T("Streaming.FallbackDisplayMode"), snapshot.Settings.Streaming.FallbackDisplayMode),
            ValueRow(T("Streaming.WorkspacePolicy"), snapshot.Settings.Workspace.Policy)));
    }

    private void RenderAudio(ManagementSnapshot snapshot)
    {
        AddPageHeader(T("Navigation.Audio"), T("Audio.Description"));
        _contentPanel.Children.Add(SettingsCard(
            ToggleRow(T("Audio.StreamSystemAudio"), T("Audio.StreamSystemAudioDetail"), snapshot.Settings.Audio.StreamAudio, 2),
            ValueRow(T("Audio.Sink"), snapshot.Settings.Audio.Sink)));
    }

    private void RenderInput(ManagementSnapshot snapshot)
    {
        AddPageHeader(T("Navigation.Input"), T("Input.Description"));
        _contentPanel.Children.Add(SettingsCard(
            ToggleRow(T("Input.Keyboard"), T("Input.KeyboardDetail"), snapshot.Settings.Input.Keyboard, 3),
            ToggleRow(T("Input.Mouse"), T("Input.MouseDetail"), snapshot.Settings.Input.Mouse, 4),
            ToggleRow(T("Input.Controller"), T("Input.ControllerDetail"), snapshot.Settings.Input.Controller, 5),
            ToggleRow(T("Input.MapRightAlt"), T("Input.MapRightAltDetail"), snapshot.Settings.Input.MapRightAltToWindowsKey, 6),
            ToggleRow(T("Input.HighResolutionScrolling"), T("Input.HighResolutionScrollingDetail"), snapshot.Settings.Input.HighResolutionScrolling, 7),
            ToggleRow(T("Input.NativePenTouch"), T("Input.NativePenTouchDetail"), snapshot.Settings.Input.NativePenTouch, 8),
            ToggleRow(T("Input.RumbleForwarding"), T("Input.RumbleForwardingDetail"), snapshot.Settings.Input.RumbleForwarding, 9)));
    }

    private void RenderNetwork(ManagementSnapshot snapshot)
    {
        AddPageHeader(T("Navigation.Network"), T("Network.Description"));
        _contentPanel.Children.Add(SettingsCard(
            ValueRow(T("Network.AddressFamily"), snapshot.Settings.Network.AddressFamily),
            ValueRow(T("Network.BasePort"), snapshot.Settings.Network.Port.ToString()),
            ValueRow(T("Network.RemoteAccess"), snapshot.Settings.Network.RemoteAccessScope),
            ValueRow(T("Network.LanEncryption"), snapshot.Settings.Network.LanEncryption),
            ValueRow(T("Network.WanEncryption"), snapshot.Settings.Network.WanEncryption),
            ToggleRow(T("Network.Upnp"), T("Network.UpnpDetail"), snapshot.Settings.Network.Upnp, 10)));
    }

    private void RenderAdvanced(ManagementSnapshot snapshot)
    {
        AddPageHeader(T("Navigation.Advanced"), T("Advanced.Description"));
        _contentPanel.Children.Add(SettingsCard(
            ValueRow(T("Advanced.PingTimeout"), F("Advanced.Milliseconds", snapshot.Settings.Network.PingTimeoutMs)),
            ValueRow(T("Advanced.ForwardErrorCorrection"), F("Advanced.Percentage", snapshot.Settings.Network.FecPercentage)),
            ValueRow(T("Advanced.BackButtonTimeout"), snapshot.Settings.Input.BackButtonTimeoutMs < 0 ? T("Common.Disabled") : F("Advanced.Milliseconds", snapshot.Settings.Input.BackButtonTimeoutMs))));
    }

    private void RenderDiagnostics(ManagementSnapshot snapshot)
    {
        AddPageHeader(T("Navigation.Diagnostics"), T("Diagnostics.Description"));
        _contentPanel.Children.Add(SettingsCard(
            StatusLine(T("Diagnostics.ManagementProtocol"), F("Diagnostics.ProtocolVersion", snapshot.ProtocolVersion), true),
            StatusLine(T("Diagnostics.HostConnection"), T("Status.Online"), true),
            ValueRow(T("Diagnostics.LogLevel"), snapshot.Settings.Diagnostics.LogLevel)));
    }

    private void RenderAbout()
    {
        AddPageHeader(T("Navigation.About"), T("About.Description"));
        _contentPanel.Children.Add(Card(new TextBlock
        {
            Text = T("About.Product"),
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
            var button = PrimaryButton(T("Error.Retry"));
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
            await ShowDialogAsync(T("Error.CommandFailed"), error.Message);
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
            CloseButtonText = T("Common.Ok")
        };
        await dialog.ShowAsync();
    }
}
