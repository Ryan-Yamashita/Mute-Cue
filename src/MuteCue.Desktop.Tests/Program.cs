using System;
using System.IO;
using System.Linq;
using BeacnMuteOverlay;
using MuteCue.Desktop;
using MuteCue.Desktop.NativeRuntime;
using MuteCue.Desktop.Services;

var directory = Path.Combine(Path.GetTempPath(), "MuteCue.Native.Tests", Guid.NewGuid().ToString("N"));
var settingsPath = Path.Combine(directory, "settings.json");
Directory.CreateDirectory(directory);
var expectedDevelopmentChannel = args.Contains("--expect-dev", StringComparer.OrdinalIgnoreCase);

try
{
    Assert(AppChannel.IsDevelopment == expectedDevelopmentChannel, "The compiled application channel must match the requested test channel.");
    Assert(AppChannel.ProductName == (expectedDevelopmentChannel ? "Mute Cue Dev" : "Mute Cue"), "The product name must identify the compiled channel.");
    Assert(AppChannel.ExecutableName == (expectedDevelopmentChannel ? "MuteCue-Dev.exe" : "MuteCue.exe"), "The executable name must identify the compiled channel.");
    Assert(AppChannel.DataDirectoryName == (expectedDevelopmentChannel ? "MuteCue-Dev" : "MuteCue"), "The data directory must identify the compiled channel.");
    Assert(StartupRegistrationService.IsSupported == !expectedDevelopmentChannel, "Only Stable builds may register themselves to run on startup.");
    Assert(AppPaths.DataDirectory.EndsWith(AppChannel.DataDirectoryName, StringComparison.OrdinalIgnoreCase), "Application paths must use the compiled channel identity.");
    Assert(AppPaths.DiscordAuthorizationPath.StartsWith(AppPaths.DataDirectory, StringComparison.OrdinalIgnoreCase), "Discord authorization must remain inside the current channel's data directory.");
    Assert(NativeMuteCueRuntime.VerifiedAllActionLabels.SequenceEqual(["Knob: Mute to All"]), "The native scanner must use BEACN's verified All action label.");
    Assert(NativeMuteCueRuntime.VerifiedAudienceActionLabels.SequenceEqual(["Mute to Audience"]), "The native scanner must use BEACN's verified Audience action label.");

    var stableSeedPath = Path.Combine(directory, "stable", "settings.json");
    var developmentSeedPath = Path.Combine(directory, "development", "settings.json");
    Directory.CreateDirectory(Path.GetDirectoryName(stableSeedPath)!);
    await File.WriteAllTextAsync(stableSeedPath, "{\"Source\":\"stable\"}");
    Assert(AppPaths.TrySeedDevelopmentSettings(stableSeedPath, developmentSeedPath), "The first Dev launch must be able to seed settings from Stable.");
    Assert(await File.ReadAllTextAsync(developmentSeedPath) == "{\"Source\":\"stable\"}", "The Dev seed must be an exact copy.");
    await File.WriteAllTextAsync(developmentSeedPath, "{\"Source\":\"development\"}");
    Assert(!AppPaths.TrySeedDevelopmentSettings(stableSeedPath, developmentSeedPath), "An existing Dev settings file must never be overwritten from Stable.");
    Assert(await File.ReadAllTextAsync(developmentSeedPath) == "{\"Source\":\"development\"}", "Dev settings must remain independent after first launch.");

    var stableCredentialPath = Path.Combine(directory, "stable", "discord-authorization.dat");
    var developmentCredentialPath = Path.Combine(directory, "development", "discord-authorization.dat");
    byte[] encryptedCredential = [1, 2, 3, 4];
    await File.WriteAllBytesAsync(stableCredentialPath, encryptedCredential);
    Assert(AppPaths.TrySeedDevelopmentFile(stableCredentialPath, developmentCredentialPath), "Dev must be able to seed an independent encrypted Discord authorization file.");
    Assert((await File.ReadAllBytesAsync(developmentCredentialPath)).SequenceEqual(encryptedCredential), "The encrypted Discord authorization seed must be an exact copy.");

    var discordClientPath = Path.Combine(directory, "MuteCue.DiscordPublicClient.json");
    await File.WriteAllTextAsync(discordClientPath, """
    {
      "schemaVersion": 1,
      "applicationId": "1234567890123456789",
      "redirectUri": "http://127.0.0.1:47891/mute-cue/"
    }
    """);
    var discordClient = DiscordPublicClient.Load(discordClientPath);
    Assert(discordClient.IsAvailable, "The public Discord client loader must accept the shipped camel-case JSON schema.");

    await File.WriteAllTextAsync(settingsPath, """
    {
      "SchemaVersion": 5,
      "Size": 500,
      "Opacity": 0.6,
      "BeacnFaderNames": "Mic, System, Mic",
      "FutureSetting": "must-survive"
    }
    """);

    var settings = NativeSettingsDocument.Load(settingsPath);
    Assert(settings.GetInteger("Size", 420, 220, 900) == 500, "The native settings layer must read existing sizes.");
    Assert(Math.Abs(settings.GetDouble("Opacity", 0.88, 0.25, 1.0) - 0.6) < 0.001, "The native settings layer must read existing opacity.");
    var faders = FaderSourceParser.Parse(settings.GetString("BeacnFaderNames", ""));
    Assert(faders.Count == 2 && faders[0] == "Mic" && faders[1] == "System", "Fader names must be trimmed and deduplicated.");

    settings.SetBoolean("BeacnDirectDetect", true);
    settings.SetString("BeacnAllFaderNames", "Mic");
    settings.SetString("BeacnAudienceFaderNames", "Mic");
    settings.SetBoolean("DiscordMicDetect", true);
    settings.SetBoolean("DiscordDeafenDetect", true);
    var activeSources = OverlaySourceComposer.Compose(
        settings,
        [new BeacnFaderState { Name = "Mic", AllActionStateKnown = true, AllActionActive = true, AudienceActionStateKnown = true, AudienceActionActive = true }],
        new DiscordLocalState { MicStateKnown = true, MicMuted = true, DeafenStateKnown = true, Deafened = true },
        showPreview: false);
    Assert(activeSources.Contains("BEACN Mic: muted to all"), "An authoritative selected BEACN All state must show the overlay.");
    Assert(activeSources.Contains("BEACN Mic: muted to audience"), "An authoritative selected BEACN Audience state must show the overlay.");
    Assert(activeSources.Contains("Discord: mic muted"), "An authoritative Discord mic state must show the overlay.");
    Assert(activeSources.Contains("Discord: deafened"), "An authoritative Discord deafen state must show the overlay.");
    Assert(OverlaySourceComposer.Compose(settings, [], new DiscordLocalState(), showPreview: true).Contains("Testing overlay"), "Overlay preview must bypass source detection without changing saved settings.");

    var hotkeys = BeacnHotkeyMappings.Parse("""
    <?xml version="1.0" encoding="UTF-8"?>
    <KEYMAPPINGS basedOnDefaults="0">
      <MAPPING commandId="1" description="Toggles Personal Mix Device" key="F23"/>
      <MAPPING commandId="53" description="Toggles The Knob Press Mute For Mic" key="F24"/>
    </KEYMAPPINGS>
    """, ["Mic"]);
    Assert(hotkeys.Count == 1, "Only BEACN fader mute commands should become native hotkey bindings.");
    Assert(hotkeys[0].GestureCode == 0x87 && hotkeys[0].Name == "Mic" && hotkeys[0].Mode == "All", "The native listener must preserve BEACN's F24 Mic mute mapping.");
    Assert(BeacnHotkeyMappings.TryConvertGesture("Ctrl + Shift + F12", out var combinedGesture) && combinedGesture == ((3 << 16) | 0x7B), "BEACN modifier gestures must map to the native keyboard listener format.");

    var usbParser = new MixCreateInputParser();
    var capturedAt = DateTime.UtcNow;
    var allPress = new byte[10];
    allPress[3] = 0x06;
    allPress[8] = 0x01;
    var allEvents = usbParser.Process(new UsbPacket(1, 0x83, allPress, capturedAt));
    Assert(allEvents.Count == 1 && allEvents[0].Mode == "All" && allEvents[0].Position == 0, "A physical BEACN knob press must resolve to its All row position.");
    Assert(usbParser.Process(new UsbPacket(1, 0x83, allPress, capturedAt)).Count == 0, "Held physical buttons must not retrigger until released.");
    var release = new byte[10];
    release[3] = 0x06;
    Assert(usbParser.Process(new UsbPacket(1, 0x83, release, capturedAt)).Count == 0, "Physical button release packets must only re-arm the next press.");
    var audiencePress = new byte[10];
    audiencePress[3] = 0x06;
    audiencePress[8] = 0x20;
    var audienceEvents = usbParser.Process(new UsbPacket(1, 0x83, audiencePress, capturedAt));
    Assert(audienceEvents.Count == 1 && audienceEvents[0].Mode == "Audience" && audienceEvents[0].Position == 1, "A physical BEACN audience press must resolve to its audience row position.");
    var pagePress = new byte[10];
    pagePress[3] = 0x06;
    pagePress[9] = 0x02;
    usbParser.Process(new UsbPacket(1, 0x83, pagePress, capturedAt));
    usbParser.Process(new UsbPacket(1, 0x83, pagePress, capturedAt));
    Assert(usbParser.MappingGeneration == 1, "A held BEACN page button must advance the mapping generation only once.");
    Assert(usbParser.LastPageDelta == 0, "A held BEACN page button must not repeatedly move the native page model.");

    var sevenUnlocked = Enumerable.Range(0, 7).Select(index => new BeacnFaderState
    {
        Order = index,
        Name = $"F{index + 1}",
        IsLocked = false,
        AllActionStateKnown = true,
        AudienceActionStateKnown = true,
    }).ToArray();
    var hardwareMapper = new BeacnHardwareMapper();
    hardwareMapper.UpdateStates(sevenUnlocked);
    var initialGuess = hardwareMapper.Resolve(0, stateFresh: true, geometryStable: true);
    Assert(initialGuess is not null && initialGuess.Name == "F1" && !initialGuess.MappingConfident, "An uncalibrated hardware page may provide a fast first-page hint but must not claim confidence.");
    hardwareMapper.ApplyConfirmation(0, "F4", hardwareMapper.MappingGeneration);
    var calibratedTarget = hardwareMapper.Resolve(3, stateFresh: true, geometryStable: true);
    Assert(hardwareMapper.CurrentPage == 1 && hardwareMapper.PageKnown && calibratedTarget is not null && calibratedTarget.Name == "F7" && calibratedTarget.MappingConfident, "A confirmed physical edge must calibrate the overlapping final BEACN page.");
    hardwareMapper.ApplyPageDelta(-1);
    var previousPageTarget = hardwareMapper.Resolve(0, stateFresh: true, geometryStable: true);
    Assert(hardwareMapper.CurrentPage == 0 && previousPageTarget is not null && previousPageTarget.Name == "F1" && previousPageTarget.MappingConfident, "A captured page button must move an already calibrated mapping without losing confidence.");

    var lockedMapper = new BeacnHardwareMapper();
    lockedMapper.UpdateStates([
        new BeacnFaderState { Order = 0, Name = "Mic", IsLocked = true },
        new BeacnFaderState { Order = 1, Name = "System" },
        new BeacnFaderState { Order = 2, Name = "Chat" },
        new BeacnFaderState { Order = 3, Name = "Game" },
        new BeacnFaderState { Order = 4, Name = "Hardware" },
    ]);
    var lockedTarget = lockedMapper.Resolve(0, stateFresh: true, geometryStable: true);
    Assert(lockedTarget is not null && lockedTarget.Name == "Mic" && lockedTarget.MappingConfident, "A locked BEACN fader position must be immediately deterministic on every page.");
    lockedMapper.UpdateStates([
        new BeacnFaderState { Order = 0, Name = "System", IsLocked = true },
        new BeacnFaderState { Order = 1, Name = "Mic" },
    ]);
    Assert(!lockedMapper.PageKnown && lockedMapper.MappingGeneration == 1, "Reordering or relocking BEACN faders must invalidate calibrated page state.");

    settings.SetBoolean("StartInSystemTray", true);
    settings.SetString("BeacnAllFaderNames", "Mic,System");
    settings.Save();
    var written = await File.ReadAllTextAsync(settingsPath);
    Assert(written.Contains("must-survive", StringComparison.Ordinal), "Unknown settings must survive native writes.");
    Assert(NativeSettingsDocument.Load(settingsPath).GetBoolean("StartInSystemTray", false), "Saved settings must round-trip.");
    Assert(FaderSourceParser.Merge("Mic,System", "System,Chat").SequenceEqual(["Mic", "System", "Chat"]), "Merged fader sources must preserve display order without duplicates.");
    Assert(
        FaderSourceParser.MergeWithDefaults("Mic").SequenceEqual(["Mic", "System", "Link In", "Game", "Link 2 In", "Chat", "Hardware"]),
        "The BEACN source catalog must remain complete when only Mic is saved.");
    Assert(
        FaderSourceParser.MergeWithDefaults("").SequenceEqual(FaderSourceParser.DefaultBeacnSources),
        "The BEACN source catalog must remain visible when every source is unchecked.");

    settings.SetString("BeacnAllFaderKeys", "profile:0,profile:1");
    settings.SetString("BeacnAudienceFaderKeys", "profile:0,profile:1");
    FaderSelectionSettings.Apply(settings, [], []);
    Assert(settings.GetString("BeacnAllFaderNames", "missing") == string.Empty, "Clearing All selections must persist an explicit empty list.");
    Assert(settings.GetString("BeacnAudienceFaderNames", "missing") == string.Empty, "Clearing Audience selections must persist an explicit empty list.");
    Assert(settings.GetString("BeacnAllFaderKeys", "missing") == string.Empty, "Native name selections must clear stale All stable keys.");
    Assert(settings.GetString("BeacnAudienceFaderKeys", "missing") == string.Empty, "Native name selections must clear stale Audience stable keys.");
    Assert(settings.GetInteger("BeacnFaderSelectionFormat", 0, 0, 3) == 2, "Native name selections must make names authoritative.");
    Console.WriteLine($"Native settings and {AppChannel.ProductName} channel tests: PASS");
    if (args.Contains("--live-beacn", StringComparer.OrdinalIgnoreCase))
    {
        await VerifyLiveBeacnAsync();
    }
    if (args.Contains("--live-usb", StringComparer.OrdinalIgnoreCase))
    {
        await VerifyLiveUsbAsync();
    }
}
finally
{
    if (Directory.Exists(directory))
    {
        Directory.Delete(directory, recursive: true);
    }
}

static void Assert(bool condition, string message)
{
    if (!condition)
    {
        throw new InvalidOperationException(message);
    }
}

static async Task VerifyLiveBeacnAsync()
{
    BeacnAppScanner.ConfigureCompatibility(
        FaderSourceParser.DefaultBeacnSources.ToArray(),
        NativeMuteCueRuntime.VerifiedAllActionLabels,
        NativeMuteCueRuntime.VerifiedAudienceActionLabels);

    BeacnFaderState[] states = [];
    try
    {
        var deadline = DateTime.UtcNow.AddSeconds(20);
        while (DateTime.UtcNow < deadline)
        {
            states = await BeacnAppScanner.ScanAsync();
            if (states.Length > 0 && states.All(state => state.AllActionStateKnown && state.AudienceActionStateKnown))
            {
                break;
            }

            await Task.Delay(250);
        }

        Assert(states.Length > 0, $"Live BEACN discovery failed: {BeacnAppScanner.CompatibilityDetail}");
        Assert(states.All(state => state.AllActionStateKnown && state.AudienceActionStateKnown), $"Live BEACN action rows are incomplete: {BeacnAppScanner.CompatibilityDetail}");
        var layout = string.Join(", ", states.OrderBy(state => state.Order).Select(state => state.IsLocked ? $"{state.Name} [locked]" : state.Name));
        Console.WriteLine($"Live BEACN native discovery: PASS ({states.Length} authoritative faders: {layout})");
    }
    finally
    {
        BeacnAppScanner.Shutdown();
    }
}

static async Task VerifyLiveUsbAsync()
{
    var usbPcap = new[]
    {
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles), "USBPcap", "USBPcapCMD.exe"),
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFilesX86), "USBPcap", "USBPcapCMD.exe"),
    }.FirstOrDefault(File.Exists);
    if (usbPcap is null)
    {
        throw new InvalidOperationException("USBPcapCMD.exe is not installed.");
    }

    var route = await MixCreateUsbMonitor.DiscoverRouteAsync(usbPcap, timeoutPerDeviceMs: 700);
    if (route is null)
    {
        throw new InvalidOperationException("The native USB monitor could not discover the connected BEACN Mix Create route.");
    }
    using var monitor = new MixCreateUsbMonitor();
    monitor.Start(usbPcap, route.CaptureDevice, route.DeviceAddress, captureAllPackets: false, captureRootHub: false);
    var deadline = DateTime.UtcNow.AddSeconds(5);
    var receivedStatus = false;
    while (DateTime.UtcNow < deadline && !receivedStatus)
    {
        while (monitor.TryDequeue(out var packet))
        {
            var data = packet.Data;
            if (packet.Endpoint == 0x83 && data.Length >= 10 && data[0] == 0 && data[1] == 0 && data[2] == 0 && data[3] == 0x06)
            {
                receivedStatus = true;
                break;
            }
        }

        if (!receivedStatus)
        {
            await Task.Delay(20);
        }
    }

    Assert(receivedStatus, $"The BEACN USB route was found but no status packet arrived: {monitor.LastError}");
    Console.WriteLine($"Live BEACN native USB capture: PASS ({route.CaptureDevice}, device {route.DeviceAddress})");
}
