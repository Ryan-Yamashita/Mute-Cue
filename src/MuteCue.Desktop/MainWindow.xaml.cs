using System;
using System.ComponentModel;
using System.Drawing;
using System.Windows;
using System.Windows.Controls;
using Forms = System.Windows.Forms;
using MuteCue.Desktop.Services;

namespace MuteCue.Desktop;

public partial class MainWindow : Window
{
    private readonly NativeSettingsDocument _settings;
    private readonly Forms.NotifyIcon _trayIcon;
    private bool _isLoading = true;
    private bool _allowClose;

    public MainWindow(NativeSettingsDocument settings, bool startInTray)
    {
        InitializeComponent();
        _settings = settings;
        _trayIcon = CreateTrayIcon();
        LoadSettings();
        _isLoading = false;
        StatusText.Text = "Native shell is ready. Live BEACN monitoring remains in the proven PowerShell app until parity tests pass.";

        if (startInTray)
        {
            Loaded += (_, _) => HideToTray();
        }
    }

    private Forms.NotifyIcon CreateTrayIcon()
    {
        var icon = new Forms.NotifyIcon
        {
            Icon = SystemIcons.Application,
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
        ClickThrough.IsChecked = _settings.GetBoolean("ClickThrough", false);
        RunOnStartup.IsChecked = StartupRegistrationService.IsRegistered();
        StartInTray.IsChecked = _settings.GetBoolean("StartInSystemTray", false);
        StartInTray.IsEnabled = RunOnStartup.IsChecked == true;

        foreach (var source in FaderSourceParser.Parse(_settings.GetString("BeacnFaderNames", "Mic")))
        {
            FaderSources.Items.Add(source);
        }
    }

    private void OverlaySize_OnValueChanged(object sender, RoutedPropertyChangedEventArgs<double> e) => SaveSettingsIfReady();

    private void OverlayOpacity_OnValueChanged(object sender, RoutedPropertyChangedEventArgs<double> e) => SaveSettingsIfReady();

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
}
