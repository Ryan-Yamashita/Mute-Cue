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
| `--dev-no-usb-capture --dev-fast-beacn-fallback --dev-beacn-timing` | Same fallback, with a Dev-only local timing CSV to identify why BEACN reads remain several seconds late |

Switches require a restart. Only one Dev instance can run at a time. The flags are case-insensitive. The `--dev-fast-beacn-fallback` switch is ignored unless `--dev-no-usb-capture` is also passed. It intentionally preserves the existing USB-off diagnostic behavior when not specified.

### Experimental USB-free BEACN fallback

Use this command to evaluate physical knob and Mute to Audience behavior **with Apex closed**, while keeping global hotkeys working:

```bat
"Build and Launch Mute Cue Dev.cmd" --dev-no-usb-capture --dev-fast-beacn-fallback
```

Exit Dev from the tray first. In the BEACN application, verify its normal mute UI reflects the changes; then try each physical knob and the Mute to Audience control. Leave a fader muted for several seconds, and time how long the overlay takes to appear and disappear. This path only refreshes the user's selected faders through BEACN's existing UI Automation controls, never reads the game process, and does not touch the USBPcap driver. The adaptive sweep aims to check each selected fader approximately once per second when BEACN UI Automation is fast, with backoff for expensive scans. It queues only when a scan is idle, and passive reads avoid screen hit-tests that could probe a game covering the BEACN window. These changes are **not yet hardware-tested**; watch for incorrect status, flickering, added CPU cost, or multi-second delays. If the status remains stale or CPU/UI performance suffers, exit Dev and revert to Stable. Do not start Apex to validate an unproven fallback.

**Important driver limitation:** `--dev-no-usb-capture` stops Mute Cue from launching USBPcapCMD.exe and initiating packet capture. It **does not unload or uninstall the USBPcap kernel filter driver**. If Event Viewer or Javelin names a USBPcap driver, handle that separately through official driver update/removal guidance, then reboot. Do not alter EA Javelin or game protections.

### Diagnose the remaining multi-second delay

The USB-free fallback still takes about four seconds on the user's BEACN hardware even after increasing the read cadence. Instead of increasing polling again, Dev now offers an **opt-in, local-only** timing trace:

```powershell
Set-Location "$HOME\Mute-Cue-Javelin-Test"
git pull --ff-only
& ".\Build and Launch Mute Cue Dev.cmd" --dev-no-usb-capture --dev-fast-beacn-fallback --dev-beacn-timing
```

Exit the prior Dev process from its tray icon before running this. **Keep Apex closed.**

1. In the BEACN app, leave the mixer window visibly open, and mute/unmute the same fader with the physical knob or Mute to Audience button. Note the approximate delay.
2. Move BEACN behind another ordinary application or minimize it, and repeat with the same controls. Note whether it becomes slower.
3. Press your BEACN keyboard hotkey once and check whether that remains immediate. Stop the Dev app after testing.
4. In PowerShell, display the recorded timeline:

```powershell
Import-Csv "$env:LOCALAPPDATA\MuteCue-Dev\Diagnostics\beacn-timing.csv" |
  Select-Object -Last 90 | Format-Table -AutoSize -Wrap
```

The output records UI Automation event notifications, when the polling request was queued, how long BEACN's read took, confirmed mute-state changes, the overlay transition, and scanner performance. Compare the timestamps to determine whether the delay originates before the accessibility event, during the scan/read, or after state publication. BEACN user-defined **fader names** may appear; review/redact names before sharing. The trace **does not** record microphone audio, USB packets, Discord tokens, or game information. It overwrites the preceding diagnostic file at startup and stops growing after about 256 KiB. It is off by default, exists only in Dev, and cannot be enabled in Stable.

This diagnostic trace is not a fix and does not promise compatibility with Javelin. No Apex testing is needed to characterize the four-second BEACN delay.

### BEACN-process-only Windows accessibility event experiment

Mix Create device inspection found no related HIDClass entry for its USB VID/PID. A separate opt-in Dev probe now tests whether BEACN's **own process** emits Windows accessibility change notifications when a physical knob or mute button changes.

```powershell
Set-Location "$HOME\Mute-Cue-Javelin-Test"
git pull --ff-only
& ".\Build and Launch Mute Cue Dev.cmd" --dev-no-usb-capture --dev-fast-beacn-fallback --dev-beacn-timing --dev-beacn-win-events
```

Completely exit any running Dev instance first; keep Apex **closed**. The additional flag records accessible events originating **only from the BEACN process**. It uses Microsoft's `SetWinEventHook` with `WINEVENT_OUTOFCONTEXT` and a nonzero BEACN process ID; it does **not** inject a DLL, read game windows, capture USB traffic, hook all processes, or change mute states. Without the flag, the probe is not created. The app must be restarted to switch it off.

With the BEACN mixer window visible, toggle one or two physical knobs and Mute to Audience buttons. Repeat once with BEACN behind another ordinary window. Exit Dev and examine:

```powershell
Import-Csv "$env:LOCALAPPDATA\MuteCue-Dev\Diagnostics\beacn-timing.csv" |
    Where-Object { $_.event -in 'win-hook', 'win-event', 'uia-output-event', 'uia-row-event', 'observed-state' } |
    Select-Object -Last 70 | Format-Table -AutoSize -Wrap
```

An event row tagged `win-event` is evidence of an accessibility event but **not proof it identifies the particular fader, mode, or final mute state**. If no relevant event is emitted by the BEACN App, this route cannot provide a reliable hardware trigger. Do not implement event-triggered state updates until the identity and event reliability are established. The event hook is for BEACN only, but anti-cheat compatibility is not guaranteed: **do not test this probe with Apex running**.

### Check whether BEACN exposes a fast, fader-specific output edge

The first Windows event test **successfully recorded** BEACN-process-scoped
`value` notifications near physical Mic and System mute transitions. The
`object=N` identifiers increased across events; they do **not** prove a
stable identity for the affected fader.

For a safer next experiment, one more opt-in Dev flag asks the existing scanner
worker to sample **cached BEACN output-toggle controls** when a value event
arrives. It is observational: the sampled values are recorded **only for
diagnostics** and cannot alter the overlay, invoke mute/unmute, or infer
independent All/Audience state. It does not open or intercept USB traffic.
One pass is rate-limited/coalesced and stops after approximately 900 ms of
elapsed provider calls; a single blocking Windows accessibility call cannot be
forcibly interrupted.

With Apex closed, exit Dev from the tray and run:

```powershell
Set-Location "$HOME\Mute-Cue-Javelin-Test"
git pull --ff-only
& ".\Build and Launch Mute Cue Dev.cmd" --dev-no-usb-capture --dev-fast-beacn-fallback --dev-beacn-timing --dev-beacn-win-events --dev-beacn-output-probe
```

With BEACN visible, mute/unmute **Mic**, then **System**, then use a
**Mute to Audience** button; repeat with the BEACN window behind another
ordinary application. Close Dev. Inspect the timestamped diagnostic:

```powershell
Import-Csv "$env:LOCALAPPDATA\MuteCue-Dev\Diagnostics\beacn-timing.csv" |
  Where-Object { $_.event -in @('win-hook','win-event','output-edge','output-probe-summary','observed-state') } |
  Select-Object -Last 100 | Format-Table -AutoSize -Wrap
```

An `output-edge` row naming a fader would indicate that BEACN's *cached*
personal/audience output toggle controls can identify that fader without
reading every All/Audience action row. `output-probe-summary` reports how
many controls were read, whether any changed, and the time spent. The next
design would still need the real All/Audience action rows for authoritative
confirmation; Windows endpoint mute status is not an adequate substitute.
This diagnostics-only experiment is **not** a production solution, and must
not be tested with Apex running. No changes to Stable.

### Event-prioritized authoritative mute verification (Dev experiment)

The latest user hardware test confirmed the `output-edge` diagnostic identified
**Mic, System, and Link In**, including changes induced by both physical
**Mute to All** and **Mute to Audience** controls. Sampling all seven faders
typically took 2–6 ms (one sample took 45 ms), but normal round-robin action
verification still sometimes delayed the overlay by 2–3 seconds.

The new **`--dev-beacn-event-refresh`** flag activates a narrow optimization:
after a BEACN-only Windows accessibility value notification, read the
cached, fast personal/audience output controls to identify the changed fader.
Give **that named fader** priority for a *BEACN action-row read of both mute modes*
instead of waiting through seven periodic reads. An independent follow-up read
allows JUCE's action rows time to settle. The background round-robin scan remains
enabled to reconcile missed events and unknown states, but is lower priority.

In the event-prioritized Dev mode only, the fallback's periodic UIA action-row
reconciliation now checks one selected fader **no more frequently than about
every 1.5 seconds** when no urgent verification is in progress **and the
BEACN-only event hook is attached**. If that listener is unavailable, it
reverts to the earlier faster background fallback. Previously it
could keep the accessibility worker almost continuously busy with ~300–390 ms
reads. BEACN-specific events still request immediate targeted, authoritative
verification; periodic reads are a lower-priority safeguard against missed
notifications. With seven faders, a completely missed event may take roughly
10 seconds or more to reconcile, so test both correctness and recovery before
shipping. This is an explicit **CPU/gaming-stability tradeoff**, not proof of
Javelin compatibility. Ordinary Dev behavior and Stable remain unchanged.

The output-toggle values **do not decide the overlay**; only BEACN's authoritative
Mute to All/Audience action rows do. This optimization never injects into BEACN,
never opens any game/USB process, and doesn't change the user's actual mute states.

Exit **Mute Cue Dev** from the system tray, close Apex, then run:

```powershell
Set-Location "$HOME\Mute-Cue-Javelin-Test"
git pull --ff-only
& ".\Build and Launch Mute Cue Dev.cmd" --dev-no-usb-capture --dev-fast-beacn-fallback --dev-beacn-timing --dev-beacn-win-events --dev-beacn-output-probe --dev-beacn-event-refresh
```

Enable the same seven faders in **Mute Cue Dev** again if they were disabled
during the Mic-only bottleneck test. BEACN's own mixer settings are unchanged.

With BEACN visible, mute/unmute Mic, System, and Link In with physical knobs,
including Mute to Audience. Repeat with BEACN behind a normal window. Check
whether the indicator appears and disappears correctly, and estimate delay.
The event probe is only process-scoped to BEACN, but **do not run Apex** during
this initial validation.

After exiting Dev, inspect the logs:

```powershell
Import-Csv "$env:LOCALAPPDATA\MuteCue-Dev\Diagnostics\beacn-timing.csv" |
    Where-Object { $_.event -in @('win-event','output-edge','output-probe-summary','event-verify-queued','probe-finished','observed-state','overlay') } |
    Select-Object -Last 100 | Format-Table -AutoSize -Wrap
```

If the log shows a fast `output-edge`, followed by `event-verify-queued`,
then a prompt `probe-finished` and the correct `observed-state`, event-driven
prioritization has been confirmed on the hardware. If it misses a mode, displays
the wrong fader, or lags, leave the draft PR unmerged and investigate. The
event-triggered read's background provider call can still block in BEACN; the
75 ms per-pass output sampler budget is soft and cannot interrupt an individual
Windows accessibility API call. This is **not yet a verified Apex fix**.

### Device-interface investigation after the mic-only control

The user confirmed that reducing the Dev fallback to only the Mic fader makes the indicator much faster. With seven faders, the BEACN/JUCE UI Automation subtree read takes approximately 325–436 ms per fader and Mute Cue checks the selected faders serially. Repeatedly increasing polling cadence is unlikely to solve all-seven-fader responsiveness.

Before choosing a new event-driven implementation, verify what **actual** device interfaces the Mix Create exposes. With BEACN running and Mix Create connected, this script only reads Windows Plug and Play inventory:

```powershell
Set-Location "$HOME\Mute-Cue-Javelin-Test"
git pull --ff-only
& ".\diagnostics\Inspect-BeacnDeviceInterfaces.ps1"
```

It prints any named BEACN devices and related Windows HID devices for matching USB vendor/product IDs; it does not open a device, intercept USB traffic, install or change drivers, or alter any anti-cheat service. Do not share raw output if device instance IDs include identifiers you'd prefer to keep private.

**Interpretation:** Finding a related HID interface is necessary but not sufficient for Windows Raw Input: we would still have to verify that its HID collection emits the relevant knob/button input reports and is accessible concurrently with the BEACN app. If no suitable HID path exists, use an explicitly supported BEACN application event/API if the vendor provides one, or reconsider the latency requirements. Do not claim generic USB interrupt transfers can be read through Raw Input.

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
