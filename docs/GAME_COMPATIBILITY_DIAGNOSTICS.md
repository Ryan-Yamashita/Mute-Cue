# Game compatibility investigation (Dev only)

Mute Cue does not intentionally hook, inject into, or inspect game processes. This diagnostic branch lets us isolate potential interactions with protected games without changing Stable or changing normal Dev behavior.

## Safety and scope

- **Stable is unchanged.** The new flags are ignored in Stable builds. Do not install a Dev build as Stable.
- **No anti-cheat bypass.** If the game's anti-cheat flags or stops a component, stop testing that component and report the issue to the vendor.
- **No automatic game detection.** The switches are intentionally manual: the crash cause is not yet confirmed.
- Exit Stable from its tray icon before Dev testing. Back up any important local settings.
- Keep the baseline Dev executable and source checkout available for rollback.

## Run diagnostics

From Command Prompt at the repository root, run the quoted launcher with an optional diagnostic flag. The launcher builds Dev and passes the flag through to the executable:

```bat
"Build and Launch Mute Cue Dev.cmd" --dev-no-usb-capture
```

To run a different test, **Exit** Mute Cue Dev from its tray icon first, then rerun the launcher with the new flags. The settings window identifies the active disabled components. To build only without launching, run `"Build and Launch Mute Cue Dev.cmd" --build-only`.

The available combinations are:

| Launch arguments | Expected difference |
| --- | --- |
| *(none)* | Baseline: original behavior |
| `--dev-no-usb-capture` | No USBPcap capture or route discovery. BEACN UI scanning, hotkeys, Discord and overlay remain; physical mixer presses may show with a delay |
| `--dev-no-global-hooks` | No global keyboard/mouse hook registration. USB button detection, BEACN UI scanning, Discord and overlay remain; click/hotkey predictions may show with a delay |
| `--dev-no-overlay` | The indicator window remains hidden. Mute detection continues, to isolate overlay rendering |
| `--dev-no-usb-capture --dev-no-global-hooks` | BEACN UI scanner + Discord + overlay only |
| `--dev-no-usb-capture --dev-fast-beacn-fallback` | **Experimental:** no USBPcap capture; rotate selected BEACN faders through cached UI Automation with an adaptive 125–500 ms scheduling interval (based on selected count and scan cost). The fallback does not use screen hit-testing; verify timing and correctness on hardware outside Apex first |

Switches require a restart. Only one Dev instance can run at a time. The flags are case-insensitive. The `--dev-fast-beacn-fallback` switch is ignored unless `--dev-no-usb-capture` is also passed. It intentionally preserves the existing USB-off diagnostic behavior when not specified.

### Experimental USB-free BEACN fallback

Use this command to evaluate physical knob and Mute to Audience behavior **with Apex closed**, while keeping global hotkeys working:

```bat
"Build and Launch Mute Cue Dev.cmd" --dev-no-usb-capture --dev-fast-beacn-fallback
```

Exit Dev from the tray first. In the BEACN application, verify its normal mute UI reflects the changes; then try each physical knob and the Mute to Audience control. Leave a fader muted for several seconds, and time how long the overlay takes to appear and disappear. This path only refreshes the user's selected faders through BEACN's existing UI Automation controls, never reads the game process, and does not touch the USBPcap driver. The adaptive sweep aims to check each selected fader approximately once per second when BEACN UI Automation is fast, with backoff for expensive scans. It queues only when a scan is idle, and passive reads avoid screen hit-tests that could probe a game covering the BEACN window. These changes are **not yet hardware-tested**; watch for incorrect status, flickering, added CPU cost, or multi-second delays. If the status remains stale or CPU/UI performance suffers, exit Dev and revert to Stable. Do not start Apex to validate an unproven fallback.

**Important driver limitation:** `--dev-no-usb-capture` stops Mute Cue from launching USBPcapCMD.exe and initiating packet capture. It **does not unload or uninstall the USBPcap kernel filter driver**. If Event Viewer or Javelin names a USBPcap driver, handle that separately through official driver update/removal guidance, then reboot. Do not alter EA Javelin or game protections.

## Controlled test sequence

1. Confirm **Apex launches normally with Mute Cue fully exited**, not merely its indicator hidden. In Event Viewer, check **Windows Logs → Application** for `EA Javelin Anticheat` around the crash, including **Event ID** and **ExitType**. Check **Windows Logs → System** for a nearby Service Control Manager event. Preserve the exact **General** message and timestamp, and redact any personally identifying paths or session tokens before sharing.
2. Reproduce with baseline Dev, then test **USB disabled only**.
3. If still reproducible, test **hooks disabled only**, then **both disabled**.
4. If still reproducible, test **overlay disabled**, initially with both other flags off.
5. For each run, note whether the game launches, crashes or disconnects, and whether clicking BEACN, mapped keyboard shortcuts, physical Mix Create mute buttons, Discord mute/deafen, and overlay rendering work.
6. If the game closes or Javelin raises an anti-cheat message, do not repeatedly provoke it or try to work around the protection. Preserve the error text and report it to the relevant vendor.

Do not assume a single successful launch proves compatibility. Only promote a narrowly justified fix after reproducing the result and running Windows CI plus a live hardware regression on a machine with the game and BEACN.

## Test commands

```powershell
dotnet run --project .\src\MuteCue.Desktop.Tests\MuteCue.Desktop.Tests.csproj --configuration Release -p:MuteCueChannel=Stable
dotnet run --project .\src\MuteCue.Desktop.Tests\MuteCue.Desktop.Tests.csproj --configuration Release -p:MuteCueChannel=Dev -- --expect-dev
```

This branch adds regression assertions for the isolation flags; Windows game and physical-hardware compatibility require user-side validation.

## Rollback

Exit Dev from the tray. Run the existing Stable application. No new flags or settings are saved and no Stable files are overwritten.
