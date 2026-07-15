using System;
using System.ComponentModel;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using Forms = System.Windows.Forms;
using MuteCue.Desktop.Services;

namespace MuteCue.Desktop;

public partial class MainWindow : Window
{
    private readonly NativeSettingsDocument _settings;
    private readonly Forms.NotifyIcon _trayIcon;
    private readonly List<FaderSelectionRow> _faderRows = [];
    private bool _isLoading = true;
    private bool _allowClose;

    public MainWindow(NativeSettingsDocument settings, bool startInTray)
    {
        InitializeComponent();
        _settings = settings;
        _trayIcon = CreateTrayIcon();
        LoadSettings();
        _isLoading = false;
        StatusText.Text = "Native preview ready. The stable app remains active until feature parity is verified.";
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
            Text = "Mute Cue Native Preview",
            Visible = true,
        };
        icon.DoubleClick += (_, _) => RestoreFromTray();
        icon.ContextMenuStrip = new Forms.ContextMenuStrip();
        icon.ContextMenuStrip.Items.Add("Show Mute Cue", null, (_, _) => RestoreFromTray());
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
        StartInTray.IsChecked = _settings.GetBoolean("StartInSystemTray", false);
        StartInTray.IsEnabled = RunOnStartup.IsChecked == true;

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

    private void Save_OnClick(object sender, RoutedEventArgs e) => SaveSettings();

    private void Close_OnClick(object sender, RoutedEventArgs e) => HideToTray();

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
        _settings.SetBoolean("StartInSystemTray", StartInTray.IsChecked == true && RunOnStartup.IsChecked == true);
        _settings.Save();
        StatusText.Text = "Settings saved using the shared Mute Cue settings file.";
    }

    private void LoadFaderSelections()
    {
        var allSources = FaderSourceParser.Parse(_settings.GetString("BeacnAllFaderNames", ""));
        var audienceSources = FaderSourceParser.Parse(_settings.GetString("BeacnAudienceFaderNames", ""));
        var sources = FaderSourceParser.Merge(
            _settings.GetString("BeacnFaderNames", ""),
            _settings.GetString("BeacnAllFaderNames", ""),
            _settings.GetString("BeacnAudienceFaderNames", ""));

        if (sources.Count == 0)
        {
            sources = new[] { "Mic", "System", "Link In", "Game", "Link 2 In", "Chat", "Hardware" };
        }

        foreach (var source in sources)
        {
            AddFaderSelectionRow(source, allSources.Contains(source, StringComparer.OrdinalIgnoreCase), audienceSources.Contains(source, StringComparer.OrdinalIgnoreCase));
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

        SaveFaderSelections();
    }

    private void SaveFaderSelections()
    {
        var allSources = _faderRows.Where(row => row.AllToggle.IsChecked == true).Select(row => row.Source).ToArray();
        var audienceSources = _faderRows.Where(row => row.AudienceToggle.IsChecked == true).Select(row => row.Source).ToArray();
        var selectedSources = _faderRows.Where(row => row.AllToggle.IsChecked == true || row.AudienceToggle.IsChecked == true).Select(row => row.Source).ToArray();
        _settings.SetString("BeacnAllFaderNames", string.Join(',', allSources));
        _settings.SetString("BeacnAudienceFaderNames", string.Join(',', audienceSources));
        _settings.SetString("BeacnFaderNames", string.Join(',', selectedSources));
        _settings.SetInteger("BeacnFaderSelectionFormat", 3);
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

        _trayIcon.Visible = false;
        _trayIcon.Dispose();
        base.OnClosing(e);
    }

    private void HideToTray()
    {
        Hide();
        _trayIcon.ShowBalloonTip(1000, "Mute Cue", "Mute Cue is running in the system tray.", Forms.ToolTipIcon.Info);
    }

    private void RestoreFromTray()
    {
        Show();
        WindowState = WindowState.Normal;
        Activate();
    }

    private sealed record FaderSelectionRow(string Source, System.Windows.Controls.CheckBox AllToggle, System.Windows.Controls.CheckBox AudienceToggle);
}
