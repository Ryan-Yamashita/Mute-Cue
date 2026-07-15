using System.Windows;
using System.Windows.Controls;
using System.Windows.Documents;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using MuteCue;
using MuteCue.Desktop.Services;
using WpfBrushes = System.Windows.Media.Brushes;
using WpfColor = System.Windows.Media.Color;
using WpfImage = System.Windows.Controls.Image;
using WpfFontFamily = System.Windows.Media.FontFamily;
using WpfOrientation = System.Windows.Controls.Orientation;
using WpfSize = System.Windows.Size;

namespace MuteCue.Desktop.NativeRuntime;

internal sealed class NativeOverlayWindow : Window
{
    private const int GwlExStyle = -20;
    private const int WsExTransparent = 0x20;
    private const int WsExLayered = 0x80000;
    private const int WsExToolWindow = 0x80;
    private readonly StackPanel _stack;
    private readonly StackPanel _logoRow;
    private readonly WpfImage _beacnLogo;
    private readonly WpfImage _discordLogo;
    private readonly TextBlock _headline;
    private readonly StackPanel _beacnMuteList;
    private readonly TextBlock _subtext;
    private double _contentScale = 1;
    private bool _clickThrough;

    internal NativeOverlayWindow(NativeSettingsDocument settings)
    {
        Title = AppChannel.ProductName;
        WindowStyle = WindowStyle.None;
        ResizeMode = ResizeMode.NoResize;
        AllowsTransparency = true;
        Background = WpfBrushes.Transparent;
        Topmost = true;
        ShowInTaskbar = false;
        Left = settings.GetInteger("X", 250, -100000, 100000);
        Top = settings.GetInteger("Y", 180, -100000, 100000);

        var root = new Grid { Background = WpfBrushes.Transparent };
        var border = new Border
        {
            Background = WpfBrushes.Transparent,
            BorderBrush = WpfBrushes.Transparent,
            BorderThickness = new Thickness(0),
            CornerRadius = new CornerRadius(0),
        };
        _stack = new StackPanel
        {
            HorizontalAlignment = System.Windows.HorizontalAlignment.Center,
            VerticalAlignment = System.Windows.VerticalAlignment.Center,
        };

        _beacnLogo = CreateLogo("beacn-logo.png");
        _discordLogo = CreateLogo("discord-logo.png");
        _discordLogo.Visibility = Visibility.Collapsed;
        _logoRow = new StackPanel
        {
            Orientation = WpfOrientation.Horizontal,
            HorizontalAlignment = System.Windows.HorizontalAlignment.Center,
            VerticalAlignment = System.Windows.VerticalAlignment.Center,
        };
        _logoRow.Children.Add(_beacnLogo);
        _logoRow.Children.Add(_discordLogo);

        _headline = new TextBlock
        {
            Text = "Muted",
            FontFamily = new WpfFontFamily("Segoe UI Semibold"),
            Foreground = WpfBrushes.White,
            HorizontalAlignment = System.Windows.HorizontalAlignment.Center,
            TextAlignment = TextAlignment.Center,
        };
        _beacnMuteList = new StackPanel
        {
            HorizontalAlignment = System.Windows.HorizontalAlignment.Stretch,
            VerticalAlignment = System.Windows.VerticalAlignment.Center,
            Visibility = Visibility.Collapsed,
        };
        _subtext = new TextBlock
        {
            Text = "Testing overlay",
            FontFamily = new WpfFontFamily("Segoe UI Semibold"),
            Foreground = WpfBrushes.White,
            Opacity = 0.88,
            HorizontalAlignment = System.Windows.HorizontalAlignment.Center,
            TextAlignment = TextAlignment.Center,
            TextWrapping = TextWrapping.Wrap,
            Visibility = Visibility.Collapsed,
        };

        _stack.Children.Add(_logoRow);
        _stack.Children.Add(_headline);
        _stack.Children.Add(_beacnMuteList);
        _stack.Children.Add(_subtext);
        border.Child = _stack;
        root.Children.Add(border);
        Content = root;

        PreviewMouseLeftButtonDown += (_, eventArgs) =>
        {
            if (!_clickThrough && eventArgs.ButtonState == MouseButtonState.Pressed)
            {
                DragMove();
                eventArgs.Handled = true;
            }
        };
        SourceInitialized += (_, _) => ApplyClickThrough(settings.GetBoolean("ClickThrough", false));
        ApplySettings(settings);
    }

    internal void ApplySettings(NativeSettingsDocument settings)
    {
        Width = settings.GetInteger("Size", 420, 220, 900);
        Height = Width * 0.68;
        Opacity = settings.GetDouble("Opacity", 0.88, 0.25, 1.0);
        UpdateContentScale();
        ApplyClickThrough(settings.GetBoolean("ClickThrough", false));
    }

    internal void ShowSources(IReadOnlyList<string> sources)
    {
        if (sources.Count == 0)
        {
            if (IsVisible)
            {
                Hide();
            }

            return;
        }

        var preview = sources.Any(source => source.Equals("Testing overlay", StringComparison.OrdinalIgnoreCase));
        var beacnSources = sources.Where(source => source.StartsWith("BEACN ", StringComparison.OrdinalIgnoreCase)).ToArray();
        var discordSources = sources.Where(source => source.StartsWith("Discord:", StringComparison.OrdinalIgnoreCase)).ToArray();
        var hasBeacn = beacnSources.Length > 0;
        var hasDiscord = discordSources.Length > 0;

        if (preview && !hasBeacn && !hasDiscord)
        {
            _logoRow.Visibility = Visibility.Collapsed;
            _beacnMuteList.Visibility = Visibility.Collapsed;
            _headline.Visibility = Visibility.Visible;
            _headline.Text = "Overlay Preview";
            _subtext.Visibility = Visibility.Visible;
            _subtext.Text = "Mute Cue is ready";
        }
        else
        {
            _logoRow.Visibility = Visibility.Visible;
            _beacnLogo.Visibility = hasBeacn ? Visibility.Visible : Visibility.Collapsed;
            _discordLogo.Visibility = hasDiscord ? Visibility.Visible : Visibility.Collapsed;
            _subtext.Visibility = Visibility.Collapsed;
            _beacnMuteList.Visibility = hasBeacn ? Visibility.Visible : Visibility.Collapsed;
            if (hasBeacn)
            {
                UpdateBeacnRows(beacnSources);
            }

            if (hasBeacn && hasDiscord)
            {
                _headline.Text = "Discord: Muted";
                _headline.Visibility = Visibility.Visible;
            }
            else if (hasDiscord)
            {
                _headline.Text = discordSources.Contains("Discord: deafened", StringComparer.OrdinalIgnoreCase)
                    ? "Deafened"
                    : "Muted";
                _headline.Visibility = Visibility.Visible;
            }
            else
            {
                _headline.Visibility = Visibility.Collapsed;
            }
        }

        UpdateDynamicHeight();
        if (!IsVisible)
        {
            EnsureVisiblePosition();
            Show();
        }
    }

    internal void CenterOnPrimaryScreen()
    {
        var workingArea = SystemParameters.WorkArea;
        Left = workingArea.Left + Math.Max(0, (workingArea.Width - Width) / 2);
        Top = workingArea.Top + Math.Max(0, (workingArea.Height - Height) / 2);
    }

    internal void SavePosition(NativeSettingsDocument settings)
    {
        settings.SetInteger("X", (int)Math.Round(Left));
        settings.SetInteger("Y", (int)Math.Round(Top));
        settings.Save();
    }

    private static WpfImage CreateLogo(string assetName)
    {
        var assemblyName = typeof(NativeOverlayWindow).Assembly.GetName().Name
            ?? throw new InvalidOperationException("The Mute Cue assembly name is unavailable.");
        var source = new Uri($"pack://application:,,,/{assemblyName};component/Assets/{assetName}", UriKind.Absolute);
        return new WpfImage
        {
            Source = new BitmapImage(source),
            Stretch = Stretch.Uniform,
            HorizontalAlignment = System.Windows.HorizontalAlignment.Center,
        };
    }

    private void UpdateContentScale()
    {
        var scale = Math.Clamp(Width / 405d, 0.55, 2.2);
        _contentScale = Math.Min(1.65, scale);
        var padding = Math.Round(18 * scale);
        var gap = Math.Round(4 * scale);
        _stack.Margin = new Thickness(padding);
        _beacnLogo.Width = Math.Round(90 * scale);
        _beacnLogo.Height = Math.Round(96 * scale);
        _beacnLogo.Margin = new Thickness(0, 0, gap, 0);
        _discordLogo.Width = Math.Round(98 * scale);
        _discordLogo.Height = Math.Round(86 * scale);
        _discordLogo.Margin = new Thickness(0);
        _logoRow.Margin = new Thickness(0, 0, 0, gap);
        _headline.FontSize = Math.Round(30 * scale);
        _subtext.FontSize = Math.Round(14 * scale);
        _subtext.Margin = new Thickness(0, Math.Round(6 * scale), 0, 0);
        _beacnMuteList.Width = Math.Max(180, Width - (2 * padding));
    }

    private void UpdateBeacnRows(IEnumerable<string> sources)
    {
        var order = new List<string>();
        var states = new Dictionary<string, List<string>>(StringComparer.OrdinalIgnoreCase);
        foreach (var source in sources)
        {
            const string prefix = "BEACN ";
            const string marker = ": muted to ";
            var markerIndex = source.LastIndexOf(marker, StringComparison.OrdinalIgnoreCase);
            if (!source.StartsWith(prefix, StringComparison.OrdinalIgnoreCase) || markerIndex <= prefix.Length)
            {
                continue;
            }

            var name = source[prefix.Length..markerIndex];
            var modeText = source[(markerIndex + marker.Length)..];
            var mode = modeText.Equals("all", StringComparison.OrdinalIgnoreCase) ? "All" :
                modeText.Equals("audience", StringComparison.OrdinalIgnoreCase) ? "Audience" : string.Empty;
            if (mode.Length == 0)
            {
                continue;
            }

            if (!states.TryGetValue(name, out var modes))
            {
                modes = [];
                states[name] = modes;
                order.Add(name);
            }

            if (!modes.Contains(mode, StringComparer.OrdinalIgnoreCase))
            {
                modes.Add(mode);
            }
        }

        _beacnMuteList.Children.Clear();
        var stateBrush = new SolidColorBrush(WpfColor.FromArgb(209, 255, 255, 255));
        foreach (var name in order)
        {
            var modes = states[name];
            if (modes.Count <= 1)
            {
                var line = new TextBlock
                {
                    HorizontalAlignment = System.Windows.HorizontalAlignment.Center,
                    VerticalAlignment = System.Windows.VerticalAlignment.Center,
                    TextAlignment = TextAlignment.Center,
                    MinHeight = Math.Round(42 * _contentScale),
                    Margin = new Thickness(0, Math.Round(2 * _contentScale), 0, 0),
                };
                line.Inlines.Add(new Run($"{name}: ")
                {
                    FontFamily = new WpfFontFamily("Segoe UI Semibold"),
                    FontSize = Math.Round(28 * _contentScale),
                    Foreground = WpfBrushes.White,
                });
                line.Inlines.Add(new Run(modes.Count == 1 ? modes[0] : "Muted")
                {
                    FontFamily = new WpfFontFamily("Segoe UI Semibold"),
                    FontSize = Math.Round(17 * _contentScale),
                    Foreground = stateBrush,
                });
                _beacnMuteList.Children.Add(line);
                continue;
            }

            var row = new Grid
            {
                HorizontalAlignment = System.Windows.HorizontalAlignment.Center,
                VerticalAlignment = System.Windows.VerticalAlignment.Center,
                MinHeight = Math.Max(Math.Round(50 * _contentScale), modes.Count * Math.Round(23 * _contentScale)),
                Margin = new Thickness(0, Math.Round(3 * _contentScale), 0, 0),
            };
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            row.Children.Add(new TextBlock
            {
                Text = $"{name}:",
                FontFamily = new WpfFontFamily("Segoe UI Semibold"),
                FontSize = Math.Round(28 * _contentScale),
                Foreground = WpfBrushes.White,
                VerticalAlignment = System.Windows.VerticalAlignment.Center,
                TextAlignment = TextAlignment.Right,
            });
            var modeStack = new StackPanel
            {
                VerticalAlignment = System.Windows.VerticalAlignment.Center,
                Margin = new Thickness(Math.Round(18 * _contentScale), 0, 0, 0),
            };
            Grid.SetColumn(modeStack, 1);
            foreach (var mode in modes)
            {
                modeStack.Children.Add(new TextBlock
                {
                    Text = mode,
                    FontFamily = new WpfFontFamily("Segoe UI Semibold"),
                    FontSize = Math.Round(17 * _contentScale),
                    Foreground = stateBrush,
                    MinHeight = Math.Round(23 * _contentScale),
                });
            }

            row.Children.Add(modeStack);
            _beacnMuteList.Children.Add(row);
        }
    }

    private void UpdateDynamicHeight()
    {
        var baseHeight = Width * 0.68;
        if (_beacnMuteList.Visibility != Visibility.Visible)
        {
            Height = baseHeight;
            return;
        }

        _beacnMuteList.Measure(new WpfSize(_beacnMuteList.Width, double.PositiveInfinity));
        var padding = Math.Round(18 * Math.Clamp(Width / 405d, 0.55, 2.2));
        var logoHeight = Math.Max(_beacnLogo.Height, _discordLogo.Height);
        var desired = (2 * padding) + logoHeight + Math.Round(8 * _contentScale) + _beacnMuteList.DesiredSize.Height;
        if (_headline.Visibility == Visibility.Visible)
        {
            desired += Math.Round(42 * _contentScale);
        }

        var maximumHeight = Math.Max(180, SystemParameters.VirtualScreenHeight - 24);
        Height = Math.Min(Math.Max(baseHeight, desired), maximumHeight);
        var virtualBottom = SystemParameters.VirtualScreenTop + SystemParameters.VirtualScreenHeight;
        if (Top + Height > virtualBottom)
        {
            Top = Math.Max(SystemParameters.VirtualScreenTop, virtualBottom - Height);
        }
    }

    private void ApplyClickThrough(bool enabled)
    {
        _clickThrough = enabled;
        var handle = new System.Windows.Interop.WindowInteropHelper(this).Handle;
        if (handle == IntPtr.Zero)
        {
            return;
        }

        var styles = NativeWindow.GetWindowLong(handle, GwlExStyle) | WsExToolWindow;
        styles = enabled ? styles | WsExTransparent | WsExLayered : styles & ~WsExTransparent;
        _ = NativeWindow.SetWindowLong(handle, GwlExStyle, styles);
    }

    private void EnsureVisiblePosition()
    {
        var virtualScreen = new Rect(
            SystemParameters.VirtualScreenLeft,
            SystemParameters.VirtualScreenTop,
            SystemParameters.VirtualScreenWidth,
            SystemParameters.VirtualScreenHeight);
        var windowBounds = new Rect(Left, Top, Math.Max(Width, 100), Math.Max(Height, 100));
        windowBounds.Intersect(virtualScreen);
        if (windowBounds.Width < 80 || windowBounds.Height < 80)
        {
            CenterOnPrimaryScreen();
        }
    }
}
