# Game compatibility investigation (Dev only)

Mute Cue does not intentionally hook, inject into, or inspect game processes. This diagnostic branch lets us isolate potential interactions with protected games without changing Stable or changing normal Dev behavior.

## Safety and scope

- **Stable is unchanged.** The new flags are ignored in Stable builds. Do not install a Dev build as Stable.
- **No anti-cheat bypass.** If the game's anti-cheat flags or stops a component, stop testing that component and report the issue to the vendor.
- **No automatic game detection.** The switches are intentionally manual: the crash cause is not yet confirmed.
- Exit Stable from its tray icon before Dev testing. Back up any important local settings.
- Keep the baseline Dev executable and source checkout available for rollback.

## Run diagnostics

Build the current branch using `Build and Launch Mute Cue Dev.cmd --build-only` from Command Prompt (or run the launcher once and exit Dev).

Then start `artifacts\dev\MuteCue-Dev.exe` from Command Prompt using one of the following:

| Launch arguments | Expected difference |
| --- | --- |
| *(none)* | Baseline: original behavior |
| `--dev-no-usb-capture` | No USBPcap capture or route discovery. BEACN UI scanning, hotkeys, Discord and overlay remain; physical mixer presses may show with a delay |
| `--dev-no-global-hooks` | No global keyboard/mouse hook registration. USB button detection, BEACN UI scanning, Discord and overlay remain; click/hotkey predictions may show with a delay |
| `--dev-no-overlay` | The indicator window remains hidden. Mute detection continues, to isolate overlay rendering |
| `--dev-no-usb-capture --dev-no-global-hooks` | BEACN UI scanner + Discord + overlay only |

Switches require a restart. Only one Dev instance can run at a time. The flags are case-insensitive.

## Controlled test sequence

1. Confirm **Apex launches normally with Mute Cue fully exited**, not merely its indicator hidden. Record the exact error and Windows Reliability Monitor event.
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
