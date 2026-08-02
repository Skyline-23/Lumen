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
    private TextBlock _signedInOwnerText = null!;
    private StackPanel _contentPanel = null!;
    private StackPanel _authenticationContentPanel = null!;
    private Grid _authenticationSurface = null!;
    private Grid _busyOverlay = null!;
    private ManagementSnapshot? _snapshot;
    private string _page = "overview";
    private bool _updating;
    private bool _defaultViewportSized;
    private readonly Dictionary<NavigationViewItem, BitmapIcon> _navigationIcons = [];

    public MainWindow()
    {
        Title = T("App.Title");
        ConfigureWindow();
        BuildShell();
        ConfigureNavigationItems();
        Activated += async (_, _) =>
        {
            SizeDefaultViewportForCurrentDisplay();
            await RefreshAsync();
        };
    }

    private void ConfigureWindow()
    {
        if (!Microsoft.UI.Windowing.AppWindowTitleBar.IsCustomizationSupported())
        {
            return;
        }
        AppWindow.TitleBar.BackgroundColor = ColorHelper.FromArgb(255, 14, 15, 18);
        AppWindow.TitleBar.ForegroundColor = Colors.White;
        AppWindow.TitleBar.InactiveBackgroundColor = ColorHelper.FromArgb(255, 19, 18, 15);
        AppWindow.TitleBar.InactiveForegroundColor = ColorHelper.FromArgb(160, 255, 255, 255);
        // Transparent caption buttons fall back to the light system surface
        // for this unpackaged WinUI window. Keep their resting surface aligned
        // with the authentication form instead.
        AppWindow.TitleBar.ButtonBackgroundColor = ColorHelper.FromArgb(255, 14, 15, 18);
        AppWindow.TitleBar.ButtonInactiveBackgroundColor = ColorHelper.FromArgb(255, 19, 18, 15);
        AppWindow.TitleBar.ButtonForegroundColor = Colors.White;
        AppWindow.TitleBar.ButtonHoverBackgroundColor = ColorHelper.FromArgb(32, 255, 255, 255);
    }

    private void SizeDefaultViewportForCurrentDisplay()
    {
        if (_defaultViewportSized || Content.XamlRoot is not { } xamlRoot)
        {
            return;
        }

        // AppWindow.Resize is measured in physical pixels. The target auth
        // viewport is 960 × 620 logical pixels, so a high-DPI Windows display
        // needs the current XAML scale applied before the first layout.
        var scale = xamlRoot.RasterizationScale;
        AppWindow.Resize(new Windows.Graphics.SizeInt32(
            (int)Math.Round(960 * scale),
            (int)Math.Round(620 * scale)));
        _defaultViewportSized = true;
    }

    private void BuildShell()
    {
        _navigation = new NavigationView
        {
            PaneDisplayMode = NavigationViewPaneDisplayMode.Left,
            CompactPaneLength = 52,
            OpenPaneLength = LumenTheme.NavigationPaneWidth,
            IsBackButtonVisible = NavigationViewBackButtonVisible.Collapsed,
            IsSettingsVisible = false,
            IsPaneToggleButtonVisible = true,
            IsPaneOpen = true,
            AlwaysShowHeader = false,
            Background = LumenTheme.ManagementSurfaceBrush(),
            Foreground = LumenTheme.PrimaryTextBrush()
        };
        _navigation.SelectionChanged += Navigation_SelectionChanged;

        _connectionBadgeText = new TextBlock
        {
            Text = T("Status.Connecting"),
            FontSize = 11,
            Foreground = LumenTheme.PrimaryTextBrush()
        };
        _connectionBadge = new Border
        {
            CornerRadius = new CornerRadius(10),
            Padding = new Thickness(8, 3, 8, 3),
            Margin = new Thickness(0, 0, 0, 8),
            Background = LumenTheme.CardBrush(),
            BorderBrush = LumenTheme.CardBorderBrush(),
            BorderThickness = new Thickness(1),
            Child = _connectionBadgeText
        };
        var header = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 10 };
        header.Children.Add(LumenAssetIconView.BrandMark(19, 19));
        header.Children.Add(new TextBlock
        {
            Text = T("App.Title"),
            FontSize = 15,
            FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
            Foreground = LumenTheme.PrimaryTextBrush(),
            VerticalAlignment = VerticalAlignment.Center
        });
        _navigation.PaneHeader = header;

        var signedInFooter = new StackPanel
        {
            Spacing = 3,
            Padding = new Thickness(12, 10, 12, 12)
        };
        signedInFooter.Children.Add(_connectionBadge);
        signedInFooter.Children.Add(new TextBlock
        {
            Text = T("Account.SignedInAs"),
            FontSize = 11,
            Foreground = LumenTheme.Brush("LumenTertiaryTextBrush", 0x6EFFFFFF)
        });
        _signedInOwnerText = new TextBlock
        {
            FontSize = 12,
            FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
            Foreground = LumenTheme.PrimaryTextBrush(),
            TextTrimming = TextTrimming.CharacterEllipsis
        };
        signedInFooter.Children.Add(_signedInOwnerText);
        _navigation.PaneFooter = signedInFooter;

        _contentPanel = new StackPanel
        {
            Padding = LumenTheme.PagePadding,
            Spacing = 18,
            MaxWidth = LumenTheme.ContentMaxWidth,
            HorizontalAlignment = HorizontalAlignment.Stretch
        };
        var managementContent = new Grid { Background = LumenTheme.ManagementSurfaceBrush() };
        managementContent.Children.Add(new ScrollViewer
        {
            VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
            Content = _contentPanel
        });
        _navigation.Content = managementContent;

        _authenticationSurface = BuildAuthenticationSurface();

        var busyContent = new StackPanel
        {
            HorizontalAlignment = HorizontalAlignment.Center,
            VerticalAlignment = VerticalAlignment.Center,
            Spacing = 12
        };
        busyContent.Children.Add(new ProgressRing
        {
            IsActive = true,
            Width = 40,
            Height = 40,
            Foreground = LumenTheme.AccentBrush()
        });
        busyContent.Children.Add(new TextBlock
        {
            Text = T("Busy.Connecting"),
            Foreground = LumenTheme.PrimaryTextBrush()
        });
        _busyOverlay = new Grid
        {
            Background = new SolidColorBrush(ColorHelper.FromArgb(226, 14, 15, 18))
        };
        _busyOverlay.Children.Add(busyContent);

        var root = new Grid
        {
            Background = LumenTheme.ManagementSurfaceBrush()
        };
        root.Children.Add(_navigation);
        root.Children.Add(_authenticationSurface);
        root.Children.Add(_busyOverlay);
        Content = root;
    }

    private Grid BuildAuthenticationSurface()
    {
        var shell = new Grid { Visibility = Visibility.Collapsed };
        shell.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(340) });
        shell.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });

        var hero = new Grid { Background = LumenTheme.Brush("LumenAuthenticationHeroBrush", 0xFF13120F) };
        var glowCanvas = AuthenticationGlowCanvas();
        hero.SizeChanged += (_, args) =>
        {
            glowCanvas.Clip = new RectangleGeometry
            {
                Rect = new Windows.Foundation.Rect(0, 0, args.NewSize.Width, args.NewSize.Height)
            };
        };
        hero.Children.Add(glowCanvas);
        var heroContent = new StackPanel
        {
            Padding = new Thickness(38, 32, 34, 30),
            Spacing = 0
        };
        var brand = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 11 };
        brand.Children.Add(LumenAssetIconView.BrandMark(27, 27));
        brand.Children.Add(new TextBlock
        {
            Text = T("App.Title").ToUpperInvariant(),
            CharacterSpacing = 240,
            FontSize = 17,
            FontWeight = Microsoft.UI.Text.FontWeights.Bold,
            Foreground = LumenTheme.PrimaryTextBrush(),
            VerticalAlignment = VerticalAlignment.Center
        });
        heroContent.Children.Add(brand);
        heroContent.Children.Add(new Border { Height = 92 });
        heroContent.Children.Add(new TextBlock
        {
            Text = T("Authentication.HeroTitle"),
            FontSize = 34,
            FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
            LineHeight = 40,
            TextWrapping = TextWrapping.Wrap,
            Foreground = LumenTheme.PrimaryTextBrush()
        });
        heroContent.Children.Add(new TextBlock
        {
            Text = T("Authentication.HeroDescription"),
            FontSize = 14,
            LineHeight = 20,
            Margin = new Thickness(0, 14, 0, 22),
            TextWrapping = TextWrapping.Wrap,
            Foreground = LumenTheme.SecondaryTextBrush()
        });
        heroContent.Children.Add(AuthenticationFeature(T("Authentication.FeatureLocal"), LumenAssetIcon.LocalCredentials));
        heroContent.Children.Add(AuthenticationFeature(T("Authentication.FeatureControls"), LumenAssetIcon.HostControls));
        heroContent.Children.Add(AuthenticationFeature(T("Authentication.FeatureRemote"), LumenAssetIcon.RemoteAccess));
        heroContent.Children.Add(new TextBlock
        {
            Text = T("Authentication.CredentialsNotice"),
            FontSize = 11,
            Margin = new Thickness(0, 28, 0, 0),
            TextWrapping = TextWrapping.Wrap,
            Foreground = LumenTheme.Brush("LumenTertiaryTextBrush", 0x6EFFFFFF)
        });
        hero.Children.Add(heroContent);
        Grid.SetColumn(hero, 0);
        shell.Children.Add(hero);

        _authenticationContentPanel = new StackPanel
        {
            Spacing = 16,
            MaxWidth = LumenTheme.AuthenticationFormMaxWidth,
            HorizontalAlignment = HorizontalAlignment.Stretch,
            VerticalAlignment = VerticalAlignment.Center,
            Margin = new Thickness(46, 36, 46, 36)
        };
        var form = new Grid
        {
            Background = LumenTheme.Brush("LumenFormBrush", 0xFF0E0F12)
        };
        form.Children.Add(new ScrollViewer
        {
            VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
            Content = _authenticationContentPanel
        });
        Grid.SetColumn(form, 1);
        shell.Children.Add(form);
        return shell;
    }

    private static Canvas AuthenticationGlowCanvas()
    {
        var canvas = new Canvas { IsHitTestVisible = false };
        AddGlow(canvas, 330, "LumenAmberGlowBrush", -120, 0);
        AddGlow(canvas, 240, "LumenCoralGlowBrush", 205, 110);
        AddGlow(canvas, 280, "LumenMintGlowBrush", 185, 505);

        var watermark = LumenAssetIconView.BrandMark(390, 390, 0.075);
        watermark.RenderTransformOrigin = new Windows.Foundation.Point(0.5, 0.5);
        watermark.RenderTransform = new RotateTransform { Angle = 14 };
        Canvas.SetLeft(watermark, 65);
        Canvas.SetTop(watermark, 325);
        canvas.Children.Add(watermark);
        return canvas;
    }

    private static void AddGlow(Canvas canvas, double size, string brush, double left, double top)
    {
        var glow = new Ellipse
        {
            Width = size,
            Height = size,
            Fill = LumenTheme.Brush(brush, 0x00FFFFFF)
        };
        Canvas.SetLeft(glow, left);
        Canvas.SetTop(glow, top);
        canvas.Children.Add(glow);
    }

    private static FrameworkElement AuthenticationFeature(string text, LumenAssetIcon asset)
    {
        var row = new Grid { Height = 34, ColumnSpacing = 12 };
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(LumenTheme.NavigationIconSlotWidth) });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        var icon = LumenAssetIconView.Create(
            asset,
            17,
            LumenTheme.SecondaryTextBrush());
        var label = new TextBlock
        {
            Text = text,
            FontSize = 13,
            Foreground = LumenTheme.SecondaryTextBrush(),
            VerticalAlignment = VerticalAlignment.Center
        };
        Grid.SetColumn(label, 1);
        row.Children.Add(icon);
        row.Children.Add(label);
        return row;
    }

    private static string T(string key) => AppStrings.Get(key);

    private static string F(string key, params object[] values) => AppStrings.Format(key, values);

    private void ConfigureNavigationItems()
    {
        var overview = NavigationItem(T("Navigation.Overview"), "overview", LumenAssetIcon.Overview);
        _navigation.MenuItems.Add(overview);
        _navigation.MenuItems.Add(NavigationItem(T("Navigation.Applications"), "applications", LumenAssetIcon.Applications));
        _navigation.MenuItems.Add(LumenNavigationComponents.Header(T("Navigation.Settings")));
        _navigation.MenuItems.Add(NavigationItem(T("Navigation.Security"), "security", LumenAssetIcon.Unlock));
        _navigation.MenuItems.Add(NavigationItem(T("Navigation.General"), "general", LumenAssetIcon.Settings));
        _navigation.MenuItems.Add(NavigationItem(T("Navigation.Streaming"), "streaming", LumenAssetIcon.CurrentStream));
        _navigation.MenuItems.Add(NavigationItem(T("Navigation.Audio"), "audio", LumenAssetIcon.HostControls));
        _navigation.MenuItems.Add(NavigationItem(T("Navigation.Input"), "input", LumenAssetIcon.LocalCredentials));
        _navigation.MenuItems.Add(NavigationItem(T("Navigation.Network"), "network", LumenAssetIcon.Workspace));
        _navigation.MenuItems.Add(NavigationItem(T("Navigation.Advanced"), "advanced", LumenAssetIcon.Restart));
        _navigation.FooterMenuItems.Add(
            NavigationItem(T("Navigation.Diagnostics"), "diagnostics", LumenAssetIcon.Diagnostics));
        _navigation.FooterMenuItems.Add(NavigationItem(T("Navigation.About"), "about", LumenAssetIcon.Application));
        _navigation.SelectedItem = overview;
        UpdateNavigationIconColors(overview);
    }

    private NavigationViewItem NavigationItem(string label, string tag, LumenAssetIcon asset)
    {
        var entry = LumenNavigationComponents.Item(label, tag, asset);
        _navigationIcons.Add(entry.Item, entry.Icon);
        return entry.Item;
    }

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
            UpdateNavigationIconColors(args.SelectedItemContainer as NavigationViewItem);
            Render();
        }
    }

    private void UpdateNavigationIconColors(NavigationViewItem? selectedItem)
    {
        foreach (var (item, icon) in _navigationIcons)
        {
            icon.Foreground = ReferenceEquals(item, selectedItem)
                ? LumenTheme.AccentBrush()
                : LumenTheme.SecondaryTextBrush();
        }
    }

    private void Render()
    {
        _contentPanel.Children.Clear();
        _authenticationContentPanel.Children.Clear();
        if (_snapshot is null)
        {
            return;
        }
        if (_snapshot.OwnerState != "authenticated")
        {
            ShowAuthenticationSurface(true);
            RenderAuthentication(_snapshot);
            return;
        }
        _signedInOwnerText.Text = _snapshot.OwnerName ?? T("Common.Unavailable");
        ShowAuthenticationSurface(false);
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

    private void ShowAuthenticationSurface(bool isAuthentication)
    {
        _authenticationSurface.Visibility = isAuthentication ? Visibility.Visible : Visibility.Collapsed;
        _navigation.Visibility = isAuthentication ? Visibility.Collapsed : Visibility.Visible;
    }

    private void RenderAuthentication(ManagementSnapshot snapshot)
    {
        var setupRequired = snapshot.OwnerState == "setupRequired";
        var heading = new StackPanel { Spacing = 5 };
        var iconHeader = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 13 };
        var authenticationIcon = LumenAssetIconView.Create(
            setupRequired ? LumenAssetIcon.CreateOwner : LumenAssetIcon.Unlock,
            25,
            LumenTheme.AccentBrush());
        authenticationIcon.Width = 34;
        iconHeader.Children.Add(authenticationIcon);
        iconHeader.Children.Add(new TextBlock
        {
            Text = setupRequired ? T("Authentication.CreateOwnerAccount") : T("Authentication.SignInToLumen"),
            FontSize = 27,
            FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
            Foreground = LumenTheme.PrimaryTextBrush(),
            VerticalAlignment = VerticalAlignment.Center,
            TextWrapping = TextWrapping.Wrap
        });
        heading.Children.Add(iconHeader);
        heading.Children.Add(new TextBlock
        {
            Text = T("Authentication.ProtectedDescription"),
            FontSize = 14,
            LineHeight = 20,
            Margin = new Thickness(47, 0, 0, 6),
            TextWrapping = TextWrapping.Wrap,
            Foreground = LumenTheme.SecondaryTextBrush()
        });
        _authenticationContentPanel.Children.Add(heading);

        var panel = new StackPanel { Spacing = 14, HorizontalAlignment = HorizontalAlignment.Stretch };
        var username = TextInput(T("Authentication.OwnerUsername"), snapshot.OwnerName ?? string.Empty);
        var password = PasswordInput(T("Authentication.OwnerPassword"));
        var confirmation = PasswordInput(T("Authentication.ConfirmPassword"));
        if (setupRequired)
        {
            panel.Children.Add(username.Container);
        }
        else
        {
            panel.Children.Add(AccountCompletionRow(T("Authentication.OwnerUsername"), snapshot.OwnerName ?? string.Empty));
        }
        panel.Children.Add(password.Container);
        if (setupRequired)
        {
            panel.Children.Add(confirmation.Container);
        }
        var submit = PrimaryButton(setupRequired ? T("Authentication.CreateAccount") : T("Authentication.SignIn"));
        async Task SubmitAuthenticationAsync()
        {
            try
            {
                _snapshot = setupRequired
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
        _authenticationContentPanel.Children.Add(panel);
    }

    private static FrameworkElement AccountCompletionRow(string title, string value)
    {
        var row = new Grid
        {
            MinHeight = 58,
            Padding = new Thickness(14, 8, 12, 8),
            ColumnSpacing = 12,
            Background = LumenTheme.Brush("LumenInputBrush", 0xFF17181C)
        };
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var labels = new StackPanel { Spacing = 2, VerticalAlignment = VerticalAlignment.Center };
        labels.Children.Add(LumenTheme.MutedText(title, 11));
        labels.Children.Add(new TextBlock
        {
            Text = value,
            FontSize = 14,
            Foreground = LumenTheme.PrimaryTextBrush()
        });
        var complete = LumenAssetIconView.Create(
            LumenAssetIcon.Complete,
            18,
            LumenTheme.Brush("LumenTealBrush", 0xFF35C7AE));
        Grid.SetColumn(complete, 1);
        row.Children.Add(labels);
        row.Children.Add(complete);
        return new Border
        {
            CornerRadius = new CornerRadius(12),
            BorderBrush = LumenTheme.CardBorderBrush(),
            BorderThickness = new Thickness(1),
            Child = row
        };
    }

    private void RenderOverview(ManagementSnapshot snapshot)
    {
        AddPageHeader(T("Navigation.Overview"), T("Overview.Description"));
        var identity = new StackPanel { Spacing = 6 };
        identity.Children.Add(new TextBlock
        {
            Text = snapshot.HostName,
            FontSize = 24,
            FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
            Foreground = LumenTheme.PrimaryTextBrush()
        });
        identity.Children.Add(Muted(F("Overview.ControlEndpoint", snapshot.ControlPort)));
        identity.Children.Add(LumenSettingsComponents.StatusRow(
            T("Overview.HostRuntime"),
            T("Status.Online"),
            true));
        identity.Children.Add(LumenSettingsComponents.StatusRow(
            T("Navigation.Applications"),
            snapshot.Applications.Count.ToString(),
            true));
        _contentPanel.Children.Add(Card(identity));

        var actions = new Grid { ColumnSpacing = 10 };
        actions.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        actions.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        actions.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        var reload = ActionButton(T("Overview.ReloadApplications"), "reloadApplications");
        var endSession = ActionButton(T("Overview.ForceStopStream"), "forceStopStream");
        var restart = ActionButton(T("Overview.RestartHost"), "restartHost");
        Grid.SetColumn(endSession, 1);
        Grid.SetColumn(restart, 2);
        actions.Children.Add(reload);
        actions.Children.Add(endSession);
        actions.Children.Add(restart);
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
        var list = new StackPanel { Spacing = LumenTheme.SectionContentSpacing };
        foreach (var app in snapshot.Applications)
        {
            var row = new Grid
            {
                MinHeight = 52,
                Padding = new Thickness(
                    LumenTheme.RowHorizontalPadding,
                    LumenTheme.RowVerticalPadding,
                    LumenTheme.RowHorizontalPadding,
                    LumenTheme.RowVerticalPadding),
                ColumnSpacing = 12
            };
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            var icon = LumenAssetIconView.Navigation(
                LumenAssetIcon.Application,
                LumenTheme.AccentBrush());
            Grid.SetColumn(icon, 0);
            var labels = new StackPanel { Spacing = 2 };
            labels.Children.Add(new TextBlock
            {
                Text = app.Title,
                FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
                Foreground = LumenTheme.PrimaryTextBrush()
            });
            labels.Children.Add(Muted(F("Applications.Metadata", app.Id, T(app.HdrSupported ? "Common.Yes" : "Common.No"))));
            Grid.SetColumn(labels, 1);
            row.Children.Add(icon);
            row.Children.Add(labels);
            list.Children.Add(LumenSettingsComponents.ContentRow(row));
        }
        _contentPanel.Children.Add(Card(list));
    }

    private void RenderSecurity(ManagementSnapshot snapshot)
    {
        AddPageHeader(T("Navigation.Security"), T("Security.Description"));
        var panel = new StackPanel { Spacing = 14 };
        panel.Children.Add(LumenSettingsComponents.StatusRow(
            T("Security.Owner"),
            snapshot.OwnerName ?? T("Common.Unavailable"),
            true));
        var logout = SecondaryButton(T("Security.LogOut"));
        logout.Click += async (_, _) => { await ExecuteAsync(new { command = "logout" }); };
        panel.Children.Add(logout);
        _contentPanel.Children.Add(Card(panel));
    }

    private void RenderGeneral(ManagementSnapshot snapshot)
    {
        AddPageHeader(T("Navigation.General"), T("General.Description"));
        _contentPanel.Children.Add(LumenSettingsComponents.Card(
            ToggleRow(T("General.NetworkDiscovery"), T("General.NetworkDiscoveryDetail"), snapshot.Settings.General.Discovery, 0),
            ToggleRow(T("General.PreReleaseNotifications"), T("General.PreReleaseNotificationsDetail"), snapshot.Settings.General.NotifyPreReleases, 1)));
    }

    private void RenderStreaming(ManagementSnapshot snapshot)
    {
        AddPageHeader(T("Navigation.Streaming"), T("Streaming.Description"));
        _contentPanel.Children.Add(LumenSettingsComponents.Card(
            LumenSettingsComponents.ValueRow(T("Streaming.GraphicsAdapter"), snapshot.Settings.Streaming.AdapterSelector),
            LumenSettingsComponents.ValueRow(T("Streaming.Output"), snapshot.Settings.Streaming.OutputSelector),
            LumenSettingsComponents.ValueRow(T("Streaming.FallbackDisplayMode"), snapshot.Settings.Streaming.FallbackDisplayMode),
            LumenSettingsComponents.ValueRow(T("Streaming.WorkspacePolicy"), snapshot.Settings.Workspace.Policy)));
    }

    private void RenderAudio(ManagementSnapshot snapshot)
    {
        AddPageHeader(T("Navigation.Audio"), T("Audio.Description"));
        _contentPanel.Children.Add(LumenSettingsComponents.Card(
            ToggleRow(T("Audio.StreamSystemAudio"), T("Audio.StreamSystemAudioDetail"), snapshot.Settings.Audio.StreamAudio, 2),
            LumenSettingsComponents.ValueRow(T("Audio.Sink"), snapshot.Settings.Audio.Sink)));
    }

    private void RenderInput(ManagementSnapshot snapshot)
    {
        AddPageHeader(T("Navigation.Input"), T("Input.Description"));
        _contentPanel.Children.Add(LumenSettingsComponents.Card(
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
        _contentPanel.Children.Add(LumenSettingsComponents.Card(
            LumenSettingsComponents.ValueRow(T("Network.AddressFamily"), snapshot.Settings.Network.AddressFamily),
            LumenSettingsComponents.ValueRow(T("Network.BasePort"), snapshot.Settings.Network.Port.ToString()),
            LumenSettingsComponents.ValueRow(T("Network.RemoteAccess"), snapshot.Settings.Network.RemoteAccessScope),
            LumenSettingsComponents.ValueRow(T("Network.LanEncryption"), snapshot.Settings.Network.LanEncryption),
            LumenSettingsComponents.ValueRow(T("Network.WanEncryption"), snapshot.Settings.Network.WanEncryption),
            ToggleRow(T("Network.Upnp"), T("Network.UpnpDetail"), snapshot.Settings.Network.Upnp, 10)));
    }

    private void RenderAdvanced(ManagementSnapshot snapshot)
    {
        AddPageHeader(T("Navigation.Advanced"), T("Advanced.Description"));
        _contentPanel.Children.Add(LumenSettingsComponents.Card(
            LumenSettingsComponents.ValueRow(T("Advanced.PingTimeout"), F("Advanced.Milliseconds", snapshot.Settings.Network.PingTimeoutMs)),
            LumenSettingsComponents.ValueRow(T("Advanced.ForwardErrorCorrection"), F("Advanced.Percentage", snapshot.Settings.Network.FecPercentage)),
            LumenSettingsComponents.ValueRow(T("Advanced.BackButtonTimeout"), snapshot.Settings.Input.BackButtonTimeoutMs < 0 ? T("Common.Disabled") : F("Advanced.Milliseconds", snapshot.Settings.Input.BackButtonTimeoutMs))));
    }

    private void RenderDiagnostics(ManagementSnapshot snapshot)
    {
        AddPageHeader(T("Navigation.Diagnostics"), T("Diagnostics.Description"));
        _contentPanel.Children.Add(LumenSettingsComponents.Card(
            LumenSettingsComponents.StatusRow(T("Diagnostics.ManagementProtocol"), F("Diagnostics.ProtocolVersion", snapshot.ProtocolVersion), true),
            LumenSettingsComponents.StatusRow(T("Diagnostics.HostConnection"), T("Status.Online"), true),
            LumenSettingsComponents.ValueRow(T("Diagnostics.LogLevel"), snapshot.Settings.Diagnostics.LogLevel)));
    }

    private void RenderAbout()
    {
        AddPageHeader(T("Navigation.About"), T("About.Description"));
        _contentPanel.Children.Add(Card(new TextBlock
        {
            Text = T("About.Product"),
            FontSize = 18,
            Foreground = LumenTheme.PrimaryTextBrush(),
            TextWrapping = TextWrapping.Wrap
        }));
    }

    private void RenderError(string title, string message, bool retry = false)
    {
        ShowAuthenticationSurface(false);
        _contentPanel.Children.Clear();
        AddPageHeader(title, message);
        if (retry)
        {
            var button = PrimaryButton(T("Error.Retry"));
            button.Click += async (_, _) => await RefreshAsync();
            _contentPanel.Children.Add(button);
        }
    }

    private async Task<bool> ExecuteAsync(object command)
    {
        try
        {
            _snapshot = await _client.SendAsync(command);
            Render();
            return true;
        }
        catch (Exception error)
        {
            await ShowDialogAsync(T("Error.CommandFailed"), error.Message);
            return false;
        }
    }

    private Button ActionButton(string label, string command)
    {
        var button = SecondaryButton(label);
        button.Click += async (_, _) => { await ExecuteAsync(new { command }); };
        return button;
    }

    private FrameworkElement ToggleRow(string title, string detail, bool enabled, int setting)
    {
        return LumenSettingsComponents.ToggleRow(
            title,
            detail,
            enabled,
            value => ExecuteAsync(new { command = "updateBoolean", setting, enabled = value }));
    }

    private static Border Card(UIElement content) => LumenTheme.Card(content);

    private void AddPageHeader(string title, string subtitle)
    {
        _contentPanel.Children.Add(LumenTheme.PageHeader(title, subtitle));
    }

    private static TextBlock Muted(string text) => LumenTheme.MutedText(text);

    private static Button PrimaryButton(string label) => LumenTheme.PrimaryButton(label);

    private static Button SecondaryButton(string label) => LumenTheme.SecondaryButton(label);

    private static (StackPanel Container, TextBox Input) TextInput(string label, string value)
    {
        var input = new TextBox { Text = value, Header = label };
        LumenTheme.Apply(input);
        return (new StackPanel { Children = { input } }, input);
    }

    private static (StackPanel Container, PasswordBox Input) PasswordInput(string label)
    {
        var input = new PasswordBox { Header = label, PasswordRevealMode = PasswordRevealMode.Peek };
        LumenTheme.Apply(input);
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
