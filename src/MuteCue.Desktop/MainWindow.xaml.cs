using System;
using System.ComponentModel;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Threading;
using Forms = System.Windows.Forms;
using MuteCue.Desktop.Services;
using MuteCue.Desktop.NativeRuntime;

namespace MuteCue.Desktop;

public partial class MainWindow : Window
{
    private readonly NativeSettingsDocument _settings;
    private readonly NativeMuteCueRuntime _runtime;
    private readonly Forms.NotifyIcon _trayIcon;
    private readonly List<FaderSelectionRow> _faderRows = [];
    private readonly DispatcherTimer _faderSaveTimer;
    private bool _isLoading = true;
    private bool _allowClose;

    public MainWindow(NativeSettingsDocument settings, NativeMuteCueRuntime runtime, bool startInTray)
    {
        InitializeComponent();
        Title = $"{AppChannel.ProductName} Settings";
        DevBadge.Visibility = AppChannel.IsDevelopment ? Visibility.Visible : Visibility.Collapsed;
        _settings = settings;
        _runtime = runtime;
        _runtime.DiscordStatusChanged += Runtime_OnDiscordStatusChanged;
        _runtime.BeacnStatusChanged += Runtime_OnBeacnStatusChanged;
        _trayIcon = CreateTrayIcon();
        _faderSaveTimer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(120) };
        _faderSaveTimer.Tick += (_, _) =>
        {
            _faderSaveTimer.Stop();
            SaveFaderSelections();
        };
        LoadSettings();
        _isLoading = false;
        StatusText.Text = $"{AppChannel.ProductName} is monitoring BEACN and Discord locally.";
        SelectTab("Discord");

        if (startInTray)
        {
            Loaded += (_, _) => HideToTray();
        }
    }

    private Forms.NotifyIcon CreateTrayIcon()
    {
        var icon = new Forms.NotifyIcon
        {
            Icon = System.Drawing.SystemIcons.Application,
            Text = AppChannel.ProductName,
            Visible = true,
        };
        icon.DoubleClick += (_, _) => RestoreFromTray();
        icon.ContextMenuStrip = new Forms.ContextMenuStrip();
        icon.ContextMenuStrip.Items.Add($"Show {AppChannel.ProductName}", null, (_, _) => RestoreFromTray());
        icon.ContextMenuStrip.Items.Add("Exit", null, (_, _) =>
        {
            _allowClose = true;
            Close();
        });
        return icon;
    }

    private void LoadSettings()
    {
        OverlaySize.Value = _settings.GetInteger("Size", 420, 220, 900);
        OverlayOpacity.Value = _settings.GetDouble("Opacity", 0.88, 0.25, 1.0);
        OverlaySizeValue.Text = $"{OverlaySize.Value:0}px";
        OverlayOpacityValue.Text = $"{OverlayOpacity.Value:P0}";
        ClickThrough.IsChecked = _settings.GetBoolean("ClickThrough", false);
        RunOnStartup.IsChecked = StartupRegistrationService.IsRegistered();
        RunOnStartup.IsEnabled = StartupRegistrationService.IsSupported;
        RunOnStartupLabel.Text = StartupRegistrationService.IsSupported ? "Run on startup" : "Run on startup (Stable only)";
        StartInTray.IsChecked = StartupRegistrationService.IsSupported && _settings.GetBoolean("StartInSystemTray", false);
        StartInTray.IsEnabled = StartupRegistrationService.IsSupported && RunOnStartup.IsChecked == true;
        DiscordMicDetect.IsChecked = _settings.GetBoolean("DiscordMicDetect", true);
        DiscordDeafenDetect.IsChecked = _settings.GetBoolean("DiscordDeafenDetect", true);
        DiscordStatus.Text = _runtime.DiscordConnectionStatus;
        BeacnStatus.Text = _runtime.BeacnConnectionStatus;

        LoadFaderSelections();
    }

    private void OverlaySize_OnValueChanged(object sender, RoutedPropertyChangedEventArgs<double> e)
    {
        OverlaySizeValue.Text = $"{e.NewValue:0}px";
        SaveSettingsIfReady();
    }

    private void OverlayOpacity_OnValueChanged(object sender, RoutedPropertyChangedEventArgs<double> e)
    {
        OverlayOpacityValue.Text = $"{e.NewValue:P0}";
        SaveSettingsIfReady();
    }

    private void Setting_OnChanged(object sender, RoutedEventArgs e) => SaveSettingsIfReady();

    private void RunOnStartup_OnChanged(object sender, RoutedEventArgs e)
    {
        if (_isLoading)
        {
            return;
        }

        var enabled = RunOnStartup.IsChecked == true;
        StartupRegistrationService.SetRegistered(enabled);
        StartInTray.IsEnabled = enabled;
        if (!enabled)
        {
            StartInTray.IsChecked = false;
        }

        SaveSettings();
    }

    private void Save_OnClick(object sender, RoutedEventArgs e)
    {
        _faderSaveTimer.Stop();
        SaveFaderSelections();
        SaveSettings();
    }

    private void Close_OnClick(object sender, RoutedEventArgs e) => HideToTray();

    private void ConnectDiscord_OnClick(object sender, RoutedEventArgs e) => _runtime.ConnectDiscord();

    private void DisconnectDiscord_OnClick(object sender, RoutedEventArgs e) => _runtime.DisconnectDiscord();

    private void ForgetDiscord_OnClick(object sender, RoutedEventArgs e) => _runtime.ForgetDiscordAuthorization();

    private void PreviewOverlay_OnClick(object sender, RoutedEventArgs e) => _runtime.PreviewOverlay(centerOnPrimaryScreen: false);

    private void CenterOverlay_OnClick(object sender, RoutedEventArgs e) => _runtime.PreviewOverlay(centerOnPrimaryScreen: true);

    private void DiscordTab_OnClick(object sender, RoutedEventArgs e) => SelectTab("Discord");

    private void BeacnTab_OnClick(object sender, RoutedEventArgs e) => SelectTab("BEACN");

    private void SettingsTab_OnClick(object sender, RoutedEventArgs e) => SelectTab("Settings");

    private void SelectTab(string selectedTab)
    {
        SetTabState(DiscordTab, DiscordTabLabel, DiscordPage, selectedTab == "Discord");
        SetTabState(BeacnTab, BeacnTabLabel, BeacnPage, selectedTab == "BEACN");
        SetTabState(SettingsTab, SettingsTabLabel, SettingsPage, selectedTab == "Settings");
    }

    private static void SetTabState(System.Windows.Controls.Button button, TextBlock label, UIElement page, bool selected)
    {
        page.Visibility = selected ? Visibility.Visible : Visibility.Collapsed;
        button.Background = new SolidColorBrush((System.Windows.Media.Color)System.Windows.Media.ColorConverter.ConvertFromString(selected ? "#392329" : "#1B1D22"));
        button.BorderBrush = new SolidColorBrush((System.Windows.Media.Color)System.Windows.Media.ColorConverter.ConvertFromString(selected ? "#FF4352" : "#2F3138"));
        button.BorderThickness = selected ? new Thickness(1, 1, 1, 3) : new Thickness(1);
        label.Foreground = new SolidColorBrush((System.Windows.Media.Color)System.Windows.Media.ColorConverter.ConvertFromString(selected ? "#F2F3F5" : "#9EA3AC"));
    }

    private void SaveSettingsIfReady()
    {
        if (!_isLoading)
        {
            SaveSettings();
        }
    }

    private void SaveSettings()
    {
        _settings.SetInteger("Size", (int)Math.Round(OverlaySize.Value));
        _settings.SetDouble("Opacity", OverlayOpacity.Value);
        _settings.SetBoolean("ClickThrough", ClickThrough.IsChecked == true);
        _settings.SetBoolean("DiscordMicDetect", DiscordMicDetect.IsChecked == true);
        _settings.SetBoolean("DiscordDeafenDetect", DiscordDeafenDetect.IsChecked == true);
        _settings.SetBoolean("StartInSystemTray", StartInTray.IsChecked == true && RunOnStartup.IsChecked == true);
        _settings.Save();
        _runtime.ApplySettings();
        StatusText.Text = "Settings saved.";
    }

    private void LoadFaderSelections()
    {
        var allSources = FaderSourceParser.Parse(_settings.GetString("BeacnAllFaderNames", ""));
        var audienceSources = FaderSourceParser.Parse(_settings.GetString("BeacnAudienceFaderNames", ""));
        var staleAllKeys = FaderSourceParser.Parse(_settings.GetString("BeacnAllFaderKeys", ""));
        var staleAudienceKeys = FaderSourceParser.Parse(_settings.GetString("BeacnAudienceFaderKeys", ""));
        var selectionFormat = _settings.GetInteger("BeacnFaderSelectionFormat", 1, 1, 3);
        var sources = FaderSourceParser.MergeWithDefaults(
            _settings.GetString("BeacnFaderNames", ""),
            _settings.GetString("BeacnAllFaderNames", ""),
            _settings.GetString("BeacnAudienceFaderNames", ""));

        foreach (var source in sources)
        {
            AddFaderSelectionRow(source, allSources.Contains(source, StringComparer.OrdinalIgnoreCase), audienceSources.Contains(source, StringComparer.OrdinalIgnoreCase));
        }

        if (selectionFormat >= 3 && allSources.Count == 0 && audienceSources.Count == 0 &&
            (staleAllKeys.Count > 0 || staleAudienceKeys.Count > 0))
        {
            // Repair the mismatch produced by the first native preview: it cleared
            // visible names but accidentally retained hidden stable-key selections.
            FaderSelectionSettings.Apply(_settings, [], []);
            _settings.Save();
        }
    }

    private void AddFaderSelectionRow(string source, bool allChecked, bool audienceChecked)
    {
        var row = new Grid { Height = 32 };
        row.ColumnDefinitions.Add(new ColumnDefinition());
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(92) });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(112) });

        var label = new TextBlock { Text = source, FontSize = 14, VerticalAlignment = System.Windows.VerticalAlignment.Center, Foreground = (System.Windows.Media.Brush)FindResource("ForegroundBrush") };
        var allToggle = CreateFaderToggle(allChecked, "Show the overlay when this source is muted to all mixes.");
        var audienceToggle = CreateFaderToggle(audienceChecked, "Show the overlay when this source is muted to your audience.");
        Grid.SetColumn(allToggle, 1);
        Grid.SetColumn(audienceToggle, 2);
        row.Children.Add(label);
        row.Children.Add(allToggle);
        row.Children.Add(audienceToggle);
        FaderSources.Children.Add(row);
        _faderRows.Add(new FaderSelectionRow(source, allToggle, audienceToggle));
    }

    private System.Windows.Controls.CheckBox CreateFaderToggle(bool isChecked, string toolTip)
    {
        var toggle = new System.Windows.Controls.CheckBox
        {
            IsChecked = isChecked,
            ToolTip = toolTip,
            Style = (Style)FindResource("MuteCueToggle"),
            HorizontalAlignment = System.Windows.HorizontalAlignment.Center,
            VerticalAlignment = System.Windows.VerticalAlignment.Center,
        };
        toggle.Checked += FaderSelection_OnChanged;
        toggle.Unchecked += FaderSelection_OnChanged;
        return toggle;
    }

    private void FaderSelection_OnChanged(object sender, RoutedEventArgs e)
    {
        if (_isLoading)
        {
            return;
        }

        _faderSaveTimer.Stop();
        _faderSaveTimer.Start();
    }

    private void SaveFaderSelections()
    {
        var allSources = _faderRows.Where(row => row.AllToggle.IsChecked == true).Select(row => row.Source).ToArray();
        var audienceSources = _faderRows.Where(row => row.AudienceToggle.IsChecked == true).Select(row => row.Source).ToArray();
        FaderSelectionSettings.Apply(_settings, allSources, audienceSources);
        _settings.Save();
        StatusText.Text = "BEACN fader selections saved.";
    }

    protected override void OnClosing(CancelEventArgs e)
    {
        if (!_allowClose)
        {
            e.Cancel = true;
            HideToTray();
            return;
        }

        if (_faderSaveTimer.IsEnabled)
        {
            _faderSaveTimer.Stop();
            SaveFaderSelections();
        }
        _trayIcon.Visible = false;
        _trayIcon.Dispose();
        _runtime.DiscordStatusChanged -= Runtime_OnDiscordStatusChanged;
        _runtime.BeacnStatusChanged -= Runtime_OnBeacnStatusChanged;
        _runtime.SaveOverlayPosition();
        base.OnClosing(e);
    }

    private void HideToTray()
    {
        Hide();
        _trayIcon.ShowBalloonTip(1000, AppChannel.ProductName, $"{AppChannel.ProductName} is running in the system tray.", Forms.ToolTipIcon.Info);
    }

    private void RestoreFromTray()
    {
        Show();
        WindowState = WindowState.Normal;
        Activate();
    }

    private void Runtime_OnDiscordStatusChanged(string status)
    {
        DiscordStatus.Text = status;
    }

    private void Runtime_OnBeacnStatusChanged(string status)
    {
        BeacnStatus.Text = status;
    }

    private sealed record FaderSelectionRow(string Source, System.Windows.Controls.CheckBox AllToggle, System.Windows.Controls.CheckBox AudienceToggle);
}
