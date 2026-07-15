using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Threading.Tasks;
using System.Windows.Threading;
using BeacnMuteOverlay;
using MuteCue.Desktop.Services;

namespace MuteCue.Desktop.NativeRuntime;

public sealed class NativeMuteCueRuntime : IDisposable
{
    internal static readonly string[] VerifiedAllActionLabels = ["Knob: Mute to All"];
    internal static readonly string[] VerifiedAudienceActionLabels = ["Mute to Audience"];

    private readonly NativeSettingsDocument _settings;
    private readonly NativeOverlayWindow _overlay;
    private readonly DiscordAuthorizationStore _discordAuthorizationStore = new();
    private readonly DiscordPublicClient _discordPublicClient;
    private readonly DispatcherTimer _monitorTimer;
    private readonly DispatcherTimer _inputTimer;
    private readonly MixCreateInputParser _mixCreateInput = new();
    private readonly BeacnHardwareMapper _hardwareMapper = new();
    private readonly Dictionary<string, PredictedBeacnState> _beacnPredictions = new(StringComparer.OrdinalIgnoreCase);
    private Dictionary<int, BeacnHotkeyBinding> _hotkeyBindings = [];
    private Task<BeacnFaderState[]>? _beacnScan;
    private Task<DiscordLocalState>? _discordScan;
    private Task<MixCreateUsbRoute>? _usbRouteDiscovery;
    private MixCreateUsbMonitor? _usbMonitor;
    private BeacnFaderState[] _beacnStates = [];
    private DiscordLocalState _discordState = new();
    private DiscordLocalState _discordRpcState = new();
    private bool _discordRpcStateKnown;
    private DiscordAuthorization _discordAuthorization;
    private DateTime _lastBeacnScanStarted = DateTime.MinValue;
    private DateTime _lastDiscordScanStarted = DateTime.MinValue;
    private DateTime _lastHotkeyReloadUtc = DateTime.MinValue;
    private DateTime _lastUsbDiscoveryStartedUtc = DateTime.MinValue;
    private DateTime _previewUntilUtc = DateTime.MinValue;
    private long _usbRequestId;
    private long _lastHardwareResultSequence;
    private bool _disposed;

    private sealed class PredictedBeacnState
    {
        internal required string Name { get; init; }
        internal required string Mode { get; init; }
        internal required bool ExpectedActive { get; init; }
        internal required long BaselineRevision { get; init; }
        internal required DateTime CreatedUtc { get; init; }
        internal long LastObservedRevision { get; set; }
        internal int MismatchedObservations { get; set; }
    }

    public event Action<string>? DiscordStatusChanged;
    public event Action<string>? BeacnStatusChanged;
    public string DiscordConnectionStatus { get; private set; }
    public string BeacnConnectionStatus { get; private set; } = "Discovering the BEACN mixer layout...";

    internal NativeMuteCueRuntime(NativeSettingsDocument settings)
    {
        _settings = settings;
        _discordPublicClient = DiscordPublicClient.Load(System.IO.Path.Combine(AppContext.BaseDirectory, "MuteCue.DiscordPublicClient.json"));
        _discordAuthorization = _discordAuthorizationStore.Load();
        DiscordConnectionStatus = _discordPublicClient.IsAvailable ? "Connect to monitor Discord mute and deafen state." : _discordPublicClient.Detail;
        _overlay = new NativeOverlayWindow(settings);
        _monitorTimer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(50) };
        _monitorTimer.Tick += (_, _) => MonitorTick();
        _inputTimer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(15) };
        _inputTimer.Tick += (_, _) => InputTick();
    }

    internal void Start()
    {
        ConfigureBeacnScanner();
        KeyboardInput.StartMouseListener();
        ReloadHotkeyMappings(force: true);
        StartUsbRouteDiscovery();
        if (_discordPublicClient.IsAvailable &&
            (!string.IsNullOrWhiteSpace(_discordAuthorization.AccessToken) || !string.IsNullOrWhiteSpace(_discordAuthorization.RefreshToken)))
        {
            ConnectDiscord();
        }
        _monitorTimer.Start();
        _inputTimer.Start();
        StartImmediateBeacnScan();
    }

    internal void ApplySettings()
    {
        _overlay.ApplySettings(_settings);
        ConfigureBeacnScanner();
    }

    internal void SaveOverlayPosition() => _overlay.SavePosition(_settings);

    internal void PreviewOverlay(bool centerOnPrimaryScreen)
    {
        if (centerOnPrimaryScreen)
        {
            _overlay.CenterOnPrimaryScreen();
        }

        _previewUntilUtc = DateTime.UtcNow.AddSeconds(6);
        UpdateOverlay();
    }

    public void ConnectDiscord()
    {
        if (!_discordPublicClient.IsAvailable)
        {
            PublishDiscordStatus(_discordPublicClient.Detail);
            return;
        }
        PublishDiscordStatus(DiscordRpcMonitor.Start(_discordPublicClient.ApplicationId, _discordPublicClient.RedirectUri, _discordAuthorization.AccessToken, _discordAuthorization.RefreshToken, _discordAuthorization.ExpiresAtUnixSeconds));
    }

    public void DisconnectDiscord()
    {
        DiscordRpcMonitor.Stop();
        _discordRpcStateKnown = false;
        PublishDiscordStatus("Discord monitoring disconnected.");
    }

    public void ForgetDiscordAuthorization()
    {
        DisconnectDiscord();
        _discordAuthorizationStore.Forget();
        _discordAuthorization = DiscordAuthorization.Empty;
        PublishDiscordStatus("Discord authorization was removed from this Windows account.");
    }

    private void ConfigureBeacnScanner()
    {
        var selectedAll = FaderSourceParser.Parse(_settings.GetString("BeacnAllFaderNames", "Mic"));
        var selectedAudience = FaderSourceParser.Parse(_settings.GetString("BeacnAudienceFaderNames", "Mic"));
        var sources = FaderSourceParser.MergeWithDefaults(_settings.GetString("BeacnFaderNames", ""), string.Join(',', selectedAll), string.Join(',', selectedAudience));
        BeacnAppScanner.ConfigureCompatibility(sources.ToArray(), VerifiedAllActionLabels, VerifiedAudienceActionLabels);
    }

    private void MonitorTick()
    {
        if (_disposed) return;
        CompleteScans();
        ProcessHardwareResult();
        CompleteUsbRouteDiscovery();
        ReloadHotkeyMappings(force: false);
        PublishBeacnStatus();
        ProcessDiscordRpcEvents();
        StartDueScans();
        UpdateOverlay();
    }

    private void CompleteScans()
    {
        if (_beacnScan is { IsCompleted: true })
        {
            try
            {
                _beacnStates = _beacnScan.GetAwaiter().GetResult().OrderBy(state => state.Order).ToArray();
                _hardwareMapper.UpdateStates(_beacnStates);
                ReconcileBeacnPredictions();
            }
            catch { /* BEACN can rebuild its accessibility tree during a redraw. */ }
            finally { _beacnScan = null; }
        }
        if (_discordScan is { IsCompleted: true })
        {
            try { _discordState = _discordScan.GetAwaiter().GetResult(); }
            catch { /* Discord can rebuild its accessibility tree during a call change. */ }
            finally { _discordScan = null; }
        }
    }

    private void StartDueScans()
    {
        var now = DateTime.UtcNow;
        if (_beacnScan is null && (now - _lastBeacnScanStarted).TotalMilliseconds >= (BeacnAppScanner.HasPendingChanges ? 15 : 100))
        {
            _lastBeacnScanStarted = now;
            _beacnScan = BeacnAppScanner.ScanAsync();
        }
        if (_discordScan is null && (now - _lastDiscordScanStarted).TotalMilliseconds >= 200)
        {
            _lastDiscordScanStarted = now;
            _discordScan = DiscordMuteScanner.ScanAsync(_settings.GetBoolean("DiscordMicDetect", true), _settings.GetBoolean("DiscordDeafenDetect", true));
        }
    }

    private void InputTick()
    {
        while (KeyboardInput.ConsumeLeftClick(out var x, out var y))
        {
            var target = BeacnAppScanner.ResolveCachedActionAtPoint(x, y);
            if (target is not null)
            {
                RequestRenderedBeacnAction(target.Name, target.Mode);
            }
            else if (BeacnAppScanner.IsTrackedBeacnPoint(x, y))
            {
                BeacnAppScanner.RequestGeometryRefresh();
                StartImmediateBeacnScan();
            }
        }

        while (KeyboardInput.ConsumeKeyGesture(out var gestureCode))
        {
            if (_hotkeyBindings.TryGetValue(gestureCode, out var binding))
            {
                RequestRenderedBeacnAction(binding.Name, binding.Mode);
            }
        }

        if (_usbMonitor is not null)
        {
            for (var count = 0; count < 256 && _usbMonitor.TryDequeue(out var packet); count++)
            {
                var buttons = _mixCreateInput.Process(packet);
                if (_mixCreateInput.LastPageDelta != 0)
                {
                    _hardwareMapper.ApplyPageDelta(_mixCreateInput.LastPageDelta);
                }

                foreach (var button in buttons)
                {
                    var stateAge = DateTime.UtcNow - BeacnAppScanner.StateCapturedAtUtc;
                    var stateFresh = _beacnStates.Length > 0 && stateAge >= TimeSpan.Zero && stateAge <= TimeSpan.FromSeconds(2);
                    var target = _hardwareMapper.Resolve(button.Position, stateFresh, geometryStable: !BeacnAppScanner.GeometryRefreshInProgress);
                    var preferredName = target?.Name ?? string.Empty;
                    var mappingConfident = target?.MappingConfident ?? false;
                    if (mappingConfident)
                    {
                        AddBeacnPrediction(preferredName, button.Mode);
                    }

                    BeacnAppScanner.RequestHardwareRefresh(
                        preferredName,
                        button.Mode,
                        button.Position,
                        ++_usbRequestId,
                        _hardwareMapper.MappingGeneration,
                        mappingConfident,
                        button.CapturedAtUtcTicks);
                    StartImmediateBeacnScan();
                    if (mappingConfident)
                    {
                        UpdateOverlay();
                    }
                }
            }
        }
    }

    private void ProcessHardwareResult()
    {
        var sequence = BeacnAppScanner.HardwareResultSequence;
        if (sequence <= _lastHardwareResultSequence)
        {
            return;
        }

        _lastHardwareResultSequence = sequence;
        _hardwareMapper.ApplyConfirmation(
            BeacnAppScanner.LastHardwarePosition,
            BeacnAppScanner.LastHardwareChangedName,
            BeacnAppScanner.LastHardwareMappingGeneration);
    }

    private void RequestRenderedBeacnAction(string name, string mode)
    {
        AddBeacnPrediction(name, mode);
        BeacnAppScanner.RequestRenderedFaderRefresh(name, mode);
        StartImmediateBeacnScan();
        UpdateOverlay();
    }

    private void StartImmediateBeacnScan()
    {
        if (_disposed || _beacnScan is not null)
        {
            return;
        }

        _lastBeacnScanStarted = DateTime.UtcNow;
        _beacnScan = BeacnAppScanner.ScanAsync();
    }

    private void ReloadHotkeyMappings(bool force)
    {
        var now = DateTime.UtcNow;
        if (!force && (now - _lastHotkeyReloadUtc).TotalSeconds < 2)
        {
            return;
        }

        _lastHotkeyReloadUtc = now;
        var bindings = BeacnHotkeyMappings.Load(BeacnHotkeyMappings.DefaultPath, _beacnStates.Select(state => state.Name));
        var updated = bindings.ToDictionary(binding => binding.GestureCode);
        var gestureSetChanged = !_hotkeyBindings.Keys.Order().SequenceEqual(updated.Keys.Order());
        _hotkeyBindings = updated;
        if (force || gestureSetChanged)
        {
            KeyboardInput.StartKeyboardListener(_hotkeyBindings.Keys.ToArray());
        }
    }

    private void StartUsbRouteDiscovery()
    {
        if (_disposed || _usbMonitor is not null || _usbRouteDiscovery is not null)
        {
            return;
        }

        var executable = FindUsbPcapExecutable();
        if (executable is null)
        {
            return;
        }

        _lastUsbDiscoveryStartedUtc = DateTime.UtcNow;
        _usbRouteDiscovery = MixCreateUsbMonitor.DiscoverRouteAsync(executable, timeoutPerDeviceMs: 700);
    }

    private void CompleteUsbRouteDiscovery()
    {
        if (_usbMonitor is { IsRunning: false })
        {
            _usbMonitor.Dispose();
            _usbMonitor = null;
        }

        if (_usbRouteDiscovery is { IsCompleted: true })
        {
            try
            {
                var route = _usbRouteDiscovery.GetAwaiter().GetResult();
                if (route is not null)
                {
                    var executable = FindUsbPcapExecutable();
                    if (executable is not null)
                    {
                        var monitor = new MixCreateUsbMonitor();
                        monitor.Start(executable, route.CaptureDevice, route.DeviceAddress, captureAllPackets: false, captureRootHub: false);
                        _usbMonitor = monitor;
                    }
                }
            }
            catch
            {
                // USBPcap is optional. Normal BEACN desktop and hotkey monitoring continues.
            }
            finally
            {
                _usbRouteDiscovery = null;
            }
        }

        if (_usbMonitor is null && _usbRouteDiscovery is null && (DateTime.UtcNow - _lastUsbDiscoveryStartedUtc).TotalSeconds >= 15)
        {
            StartUsbRouteDiscovery();
        }
    }

    private static string? FindUsbPcapExecutable()
    {
        var candidates = new[]
        {
            Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles), "USBPcap", "USBPcapCMD.exe"),
            Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFilesX86), "USBPcap", "USBPcapCMD.exe"),
        };
        return candidates.FirstOrDefault(File.Exists);
    }

    private void ProcessDiscordRpcEvents()
    {
        while (DiscordRpcMonitor.TryDequeue(out var update))
        {
            if (string.Equals(update.Kind, "status", StringComparison.OrdinalIgnoreCase))
            {
                PublishDiscordStatus(update.Status);
            }
            else if (string.Equals(update.Kind, "state", StringComparison.OrdinalIgnoreCase))
            {
                _discordRpcStateKnown = update.Known;
                _discordRpcState = new DiscordLocalState { MicStateKnown = update.Known, MicMuted = update.MicMuted, DeafenStateKnown = update.Known, Deafened = update.Deafened };
            }
            else if (string.Equals(update.Kind, "credentials", StringComparison.OrdinalIgnoreCase))
            {
                _discordAuthorization = new DiscordAuthorization(update.AccessToken ?? string.Empty, update.RefreshToken ?? string.Empty, Math.Max(0, update.ExpiresAtUnixSeconds));
                _discordAuthorizationStore.Save(_discordAuthorization);
            }
        }
    }

    private void AddBeacnPrediction(string name, string mode)
    {
        var state = _beacnStates.FirstOrDefault(candidate => string.Equals(candidate.Name, name, StringComparison.OrdinalIgnoreCase));
        if (state is null)
        {
            return;
        }

        var known = string.Equals(mode, "All", StringComparison.OrdinalIgnoreCase)
            ? state.AllActionStateKnown
            : state.AudienceActionStateKnown;
        if (!known)
        {
            return;
        }

        var key = PredictionKey(name, mode);
        var current = _beacnPredictions.TryGetValue(key, out var existing)
            ? existing.ExpectedActive
            : string.Equals(mode, "All", StringComparison.OrdinalIgnoreCase) ? state.AllActionActive : state.AudienceActionActive;
        _beacnPredictions[key] = new PredictedBeacnState
        {
            Name = state.Name,
            Mode = mode,
            ExpectedActive = !current,
            BaselineRevision = state.ActionRevision,
            LastObservedRevision = state.ActionRevision,
            CreatedUtc = DateTime.UtcNow,
        };
    }

    private void ReconcileBeacnPredictions()
    {
        var now = DateTime.UtcNow;
        foreach (var entry in _beacnPredictions.ToArray())
        {
            var prediction = entry.Value;
            var state = _beacnStates.FirstOrDefault(candidate => string.Equals(candidate.Name, prediction.Name, StringComparison.OrdinalIgnoreCase));
            if (state is null || (now - prediction.CreatedUtc).TotalSeconds >= 2)
            {
                _beacnPredictions.Remove(entry.Key);
                continue;
            }

            var known = string.Equals(prediction.Mode, "All", StringComparison.OrdinalIgnoreCase)
                ? state.AllActionStateKnown
                : state.AudienceActionStateKnown;
            var active = string.Equals(prediction.Mode, "All", StringComparison.OrdinalIgnoreCase)
                ? state.AllActionActive
                : state.AudienceActionActive;
            if (known && state.ActionRevision > prediction.BaselineRevision && active == prediction.ExpectedActive)
            {
                _beacnPredictions.Remove(entry.Key);
            }
            else if (state.ActionRevision > prediction.LastObservedRevision)
            {
                prediction.LastObservedRevision = state.ActionRevision;
                prediction.MismatchedObservations++;
                if (prediction.MismatchedObservations >= 3 && (now - prediction.CreatedUtc).TotalMilliseconds >= 400)
                {
                    _beacnPredictions.Remove(entry.Key);
                }
            }
        }
    }

    private BeacnFaderState[] GetDisplayedBeacnStates()
    {
        if (_beacnPredictions.Count == 0)
        {
            return _beacnStates;
        }

        var now = DateTime.UtcNow;
        foreach (var expired in _beacnPredictions.Where(entry => (now - entry.Value.CreatedUtc).TotalSeconds >= 2).Select(entry => entry.Key).ToArray())
        {
            _beacnPredictions.Remove(expired);
        }

        return _beacnStates.Select(state =>
        {
            var displayed = CloneFaderState(state);
            if (_beacnPredictions.TryGetValue(PredictionKey(state.Name, "All"), out var all))
            {
                displayed.AllActionStateKnown = true;
                displayed.AllActionActive = all.ExpectedActive;
            }
            if (_beacnPredictions.TryGetValue(PredictionKey(state.Name, "Audience"), out var audience))
            {
                displayed.AudienceActionStateKnown = true;
                displayed.AudienceActionActive = audience.ExpectedActive;
            }
            return displayed;
        }).ToArray();
    }

    private static string PredictionKey(string name, string mode) => $"{name.Trim()}\0{mode.Trim()}";

    private static BeacnFaderState CloneFaderState(BeacnFaderState state) => new()
    {
        Order = state.Order,
        Name = state.Name,
        PersonalMuted = state.PersonalMuted,
        AudienceMuted = state.AudienceMuted,
        IsLocked = state.IsLocked,
        AllActionStateKnown = state.AllActionStateKnown,
        AllActionActive = state.AllActionActive,
        AudienceActionStateKnown = state.AudienceActionStateKnown,
        AudienceActionActive = state.AudienceActionActive,
        ActionRevision = state.ActionRevision,
        HasAllActionBounds = state.HasAllActionBounds,
        AllActionLeft = state.AllActionLeft,
        AllActionTop = state.AllActionTop,
        AllActionRight = state.AllActionRight,
        AllActionBottom = state.AllActionBottom,
        HasAudienceActionBounds = state.HasAudienceActionBounds,
        AudienceActionLeft = state.AudienceActionLeft,
        AudienceActionTop = state.AudienceActionTop,
        AudienceActionRight = state.AudienceActionRight,
        AudienceActionBottom = state.AudienceActionBottom,
    };

    private void UpdateOverlay()
    {
        var discordState = _discordRpcStateKnown ? _discordRpcState : _discordState;
        var sources = OverlaySourceComposer.Compose(
            _settings,
            GetDisplayedBeacnStates(),
            discordState,
            DateTime.UtcNow < _previewUntilUtc);
        _overlay.ShowSources(sources);
    }

    public void Dispose()
    {
        if (_disposed) return;
        _disposed = true;
        _monitorTimer.Stop();
        _inputTimer.Stop();
        KeyboardInput.StopMouseListener();
        KeyboardInput.StopKeyboardListener();
        _usbMonitor?.Dispose();
        _usbMonitor = null;
        DiscordRpcMonitor.Stop();
        BeacnAppScanner.Shutdown();
        _overlay.Close();
    }

    private void PublishDiscordStatus(string status)
    {
        DiscordConnectionStatus = status;
        DiscordStatusChanged?.Invoke(status);
    }

    private void PublishBeacnStatus()
    {
        string status;
        if (_beacnStates.Length > 0)
        {
            var authoritative = _beacnStates.Count(state => state.AllActionStateKnown && state.AudienceActionStateKnown);
            status = authoritative == _beacnStates.Length
                ? $"Ready — {_beacnStates.Length} BEACN faders detected."
                : $"Synchronizing — {authoritative} of {_beacnStates.Length} faders are ready.";
        }
        else
        {
            status = BeacnAppScanner.CompatibilityDetail;
        }

        if (string.Equals(BeacnConnectionStatus, status, StringComparison.Ordinal))
        {
            return;
        }

        BeacnConnectionStatus = status;
        BeacnStatusChanged?.Invoke(status);
    }
}
