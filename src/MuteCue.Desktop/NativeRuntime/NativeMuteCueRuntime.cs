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
    private readonly CompatibilityDiagnostics _compatibility;
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
    private Task<MixCreateUsbRoute>? _usbRouteDiscovery;
    private MixCreateUsbMonitor? _usbMonitor;
    private BeacnWinEventProbe? _beacnWinEventProbe;
    private BeacnFaderState[] _beacnStates = [];
    private static readonly DiscordLocalState UnknownDiscordState = new();
    private DiscordLocalState _discordRpcState = new();
    private bool _discordRpcStateKnown;
    private DiscordAuthorization _discordAuthorization;
    private DateTime _lastBeacnScanStarted = DateTime.MinValue;
    private DateTime _lastHotkeyReloadUtc = DateTime.MinValue;
    private DateTime _lastUsbDiscoveryStartedUtc = DateTime.MinValue;
    private DateTime _lastUsbFreeFallbackRefreshUtc = DateTime.MinValue;
    private int _nextUsbFreeFallbackFaderIndex;
    private DateTime _previewUntilUtc = DateTime.MinValue;
    private DateTime _lastTraceFlushUtc = DateTime.MinValue;
    private string _lastTracedBeacnOverlay = string.Empty;
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
    internal string CompatibilityStatus => _compatibility.StatusDescription;

    internal NativeMuteCueRuntime(NativeSettingsDocument settings, CompatibilityDiagnostics compatibility = default)
    {
        _settings = settings;
        _compatibility = compatibility;
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
        BeacnTimingTrace.Start(_compatibility.EnableBeacnTiming);
        if (_compatibility.EnableBeacnWinEvents)
        {
            _beacnWinEventProbe = new BeacnWinEventProbe();
            _ = _beacnWinEventProbe.EnsureStarted();
        }
        ConfigureBeacnScanner();
        BeacnAppScanner.ConfigureEventPrioritizedRefresh(_compatibility.EnableBeacnEventRefresh);
        if (!_compatibility.DisableGlobalHooks)
        {
            KeyboardInput.StartMouseListener();
        }
        ReloadHotkeyMappings(force: true);
        if (!_compatibility.DisableUsbCapture)
        {
            StartUsbRouteDiscovery();
        }
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
        _ = _beacnWinEventProbe?.EnsureStarted();
        if (_compatibility.EnableBeacnOutputProbe &&
            _beacnWinEventProbe?.TryConsumeValueSignal() == true)
        {
            BeacnAppScanner.RequestWinEventOutputProbe();
        }
        ProcessHardwareResult();
        CompleteUsbRouteDiscovery();
        ReloadHotkeyMappings(force: false);
        PublishBeacnStatus();
        ProcessDiscordRpcEvents();
        ScheduleUsbFreeFallbackRefresh();
        StartDueScans();
        UpdateOverlay();
        if (BeacnTimingTrace.Enabled &&
            (DateTime.UtcNow - _lastTraceFlushUtc).TotalSeconds >= 1)
        {
            _lastTraceFlushUtc = DateTime.UtcNow;
            BeacnTimingTrace.Record("scanner", "", $"scanMs={BeacnAppScanner.LastScanMilliseconds:0};pending={BeacnAppScanner.HasPendingChanges};geometrySettling={BeacnAppScanner.GeometryRefreshInProgress};faders={_beacnStates.Length};lastEvent={BeacnAppScanner.LastActionEventSummary}");
            BeacnTimingTrace.Flush();
        }
    }

    private void CompleteScans()
    {
        if (_beacnScan is { IsCompleted: true })
        {
            try
            {
                var previous = _beacnStates;
                _beacnStates = _beacnScan.GetAwaiter().GetResult().OrderBy(state => state.Order).ToArray();
                TraceChangedFaderStates(previous, _beacnStates);
                _hardwareMapper.UpdateStates(_beacnStates);
                ReconcileBeacnPredictions();
            }
            catch { /* BEACN can rebuild its accessibility tree during a redraw. */ }
            finally { _beacnScan = null; }
        }
    }

    private static void TraceChangedFaderStates(
        IReadOnlyList<BeacnFaderState> previous,
        IReadOnlyList<BeacnFaderState> current)
    {
        if (!BeacnTimingTrace.Enabled)
        {
            return;
        }

        foreach (var state in current)
        {
            var before = previous.FirstOrDefault(item => string.Equals(
                item.Name, state.Name, StringComparison.OrdinalIgnoreCase));
            if (before is null)
            {
                continue;
            }

            if (state.AllActionStateKnown != before.AllActionStateKnown ||
                (state.AllActionStateKnown && state.AllActionActive != before.AllActionActive))
            {
                BeacnTimingTrace.Record("observed-state", state.Name,
                    $"All={state.AllActionActive};known={state.AllActionStateKnown};revision={state.ActionRevision}");
            }

            if (state.AudienceActionStateKnown != before.AudienceActionStateKnown ||
                (state.AudienceActionStateKnown && state.AudienceActionActive != before.AudienceActionActive))
            {
                BeacnTimingTrace.Record("observed-state", state.Name,
                    $"Audience={state.AudienceActionActive};known={state.AudienceActionStateKnown};revision={state.ActionRevision}");
            }
        }
    }

    private void ScheduleUsbFreeFallbackRefresh()
    {
        // Dev-only diagnostic: exercise the existing BEACN UI Automation path
        // without active USB packet capture. Never touches a game process.
        if (!_compatibility.DisableUsbCapture || !_compatibility.EnableFastBeacnFallback ||
            _beacnStates.Length == 0)
        {
            return;
        }

        // Never stack diagnostic reads behind an already-running scanner task.
        if (_beacnScan is not null || BeacnAppScanner.GeometryRefreshInProgress)
        {
            return;
        }

        var selectedFaders = FaderSourceParser.Merge(
            _settings.GetString("BeacnAllFaderNames", "Mic"),
            _settings.GetString("BeacnAudienceFaderNames", "Mic"));
        if (selectedFaders.Count == 0)
        {
            return;
        }

        // Target a roughly one-second sweep regardless of how many faders are
        // selected. Back off if the BEACN accessibility provider is expensive.
        var intervalMilliseconds = CalculateUsbFreeFallbackIntervalMilliseconds(
            selectedFaders.Count, BeacnAppScanner.LastScanMilliseconds);
        var now = DateTime.UtcNow;
        if ((now - _lastUsbFreeFallbackRefreshUtc).TotalMilliseconds < intervalMilliseconds)
        {
            return;
        }

        // Reconcile one selected fader per interval to avoid an unbounded UIA
        // storm when users select many sources. Queueing is coalesced by the scanner.
        for (var attempted = 0; attempted < selectedFaders.Count; attempted++)
        {
            var index = _nextUsbFreeFallbackFaderIndex % selectedFaders.Count;
            _nextUsbFreeFallbackFaderIndex = (index + 1) % selectedFaders.Count;
            var name = selectedFaders[index];
            if (!_beacnStates.Any(state => string.Equals(state.Name, name, StringComparison.OrdinalIgnoreCase)))
            {
                continue;
            }

            _lastUsbFreeFallbackRefreshUtc = now;
            BeacnTimingTrace.Record("probe-queued", name, "All+Audience");
            BeacnAppScanner.RequestPassiveFaderRefresh(name);
            break;
        }
    }

    internal static double CalculateUsbFreeFallbackIntervalMilliseconds(int selectedFaderCount, double lastScanMilliseconds)
    {
        var baseline = Math.Clamp(1000d / Math.Max(1, selectedFaderCount), 125d, 250d);
        if (!double.IsFinite(lastScanMilliseconds) || lastScanMilliseconds < 0)
        {
            return 500d;
        }

        // Keep provider calls bounded even if the last scan was slow.
        return Math.Clamp(Math.Max(baseline, lastScanMilliseconds * 2d), baseline, 500d);
    }

    private void StartDueScans()
    {
        var now = DateTime.UtcNow;
        if (_beacnScan is null && (now - _lastBeacnScanStarted).TotalMilliseconds >= (BeacnAppScanner.HasPendingChanges ? 15 : 100))
        {
            _lastBeacnScanStarted = now;
            _beacnScan = BeacnAppScanner.ScanAsync();
        }
    }

    private void InputTick()
    {
        while (!_compatibility.DisableGlobalHooks && KeyboardInput.ConsumeLeftClick(out var x, out var y))
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

        while (!_compatibility.DisableGlobalHooks && KeyboardInput.ConsumeKeyGesture(out var gestureCode))
        {
            if (_hotkeyBindings.TryGetValue(gestureCode, out var binding))
            {
                BeacnTimingTrace.Record("hotkey", binding.Name, binding.Mode);
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
            if (!_compatibility.DisableGlobalHooks)
            {
                KeyboardInput.StartKeyboardListener(_hotkeyBindings.Keys.ToArray());
            }
        }
    }

    private void StartUsbRouteDiscovery()
    {
        if (_disposed || _compatibility.DisableUsbCapture || _usbMonitor is not null || _usbRouteDiscovery is not null)
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
        if (_compatibility.DisableOverlay)
        {
            _overlay.ShowSources([]);
            return;
        }

        var discordState = _discordRpcStateKnown ? _discordRpcState : UnknownDiscordState;
        var sources = OverlaySourceComposer.Compose(
            _settings,
            GetDisplayedBeacnStates(),
            discordState,
            DateTime.UtcNow < _previewUntilUtc);
        if (BeacnTimingTrace.Enabled)
        {
            var beacnOverlay = string.Join(" | ", sources.Where(
                source => source.StartsWith("BEACN ", StringComparison.OrdinalIgnoreCase)));
            if (!string.Equals(_lastTracedBeacnOverlay, beacnOverlay, StringComparison.Ordinal))
            {
                _lastTracedBeacnOverlay = beacnOverlay;
                BeacnTimingTrace.Record("overlay", "", beacnOverlay.Length == 0 ? "clear" : beacnOverlay);
            }
        }
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
        _beacnWinEventProbe?.Dispose();
        _beacnWinEventProbe = null;
        BeacnTimingTrace.Flush();
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
