# Mute Cue architecture

## Runtime model

Mute Cue v0.6.0 is one self-contained native WPF application. The installed runtime does not contain or launch PowerShell.

```text
BEACN desktop UI Automation ----> authoritative fader action state ----\
Desktop clicks / mapped hotkeys -> targeted refresh + guarded preview ---+-> WPF overlay
Mix Create USB packets ----------> page-aware refresh + guarded preview --/
Discord local RPC ---------------> confirmed self mute/deafen state -----/
```

BEACN's independent **Mute to All** and **Mute to Audience** action rows are the source of truth. Input signals accelerate a named read; they do not permanently decide state.

## Native components

- `NativeMuteCueRuntime` owns timers, bounded input consumption, provider coordination, and overlay composition.
- `BeacnAppScanner` discovers BEACN faders and performs targeted UI Automation reads on background tasks.
- `KeyboardInput` installs bounded low-level mouse and keyboard hooks and retains only configured gestures.
- `BeacnHotkeyMappings` securely parses BEACN's mapping XML and reloads it without restarting Mute Cue.
- `MixCreateUsbMonitor` owns the USBPcap child process through a Windows job object and publishes bounded packets.
- `BeacnHardwareMapper` maps locked faders and paged physical positions, invalidating confidence after layout changes.
- `DiscordRpcMonitor` communicates only with Discord's local named pipe and local OAuth endpoints.
- `DiscordAuthorizationStore` encrypts authorization with Windows DPAPI in CurrentUser scope.
- `NativeOverlayWindow` renders the transparent icon and per-fader state presentation.

## State and responsiveness

The scanner publishes complete fader snapshots with per-fader action revisions. The UI keeps the latest authoritative snapshot while a targeted confirmation is in flight.

When a click, hotkey, or hardware position is known and current, Mute Cue may display the expected toggle immediately. That prediction is short-lived and is removed when a newer authoritative observation confirms it, contradicts it repeatedly, or reaches its expiry. Unknown pages never receive a confident prediction.

Physical mapping follows BEACN's locked and paged layout:

- up to three locked faders retain deterministic positions on every page;
- remaining positions page through unlocked faders;
- the final page overlaps earlier entries when needed to fill four physical positions;
- page-button packets advance the mapping generation;
- a confirmed physical edge calibrates an initially unknown page;
- reorder, rename, add/remove, or lock changes invalidate page confidence.

Input queues, USB packets, hardware requests, Discord events, and scanner refreshes are bounded. The dispatcher consumes lightweight input frequently while expensive UI Automation work remains asynchronous.

## Stable and Dev channels

The channel is compiled into the executable.

| Concern | Stable | Dev |
| --- | --- | --- |
| Executable | `MuteCue.exe` | `MuteCue-Dev.exe` |
| Data root | `%LOCALAPPDATA%\MuteCue` | `%LOCALAPPDATA%\MuteCue-Dev` |
| Single-instance identity | Stable | Dev |
| Startup registration | Available | Disabled |
| Distribution | Installer | Local fixed artifact |

Dev may seed existing Stable settings and encrypted Discord authorization once, but the two destinations remain independent afterward.

## Persistence and security

- Mutable data is stored under the current user's local application data, never beside installed binaries.
- Settings writes preserve unknown fields and use a backup generation.
- Discord authorization is DPAPI-protected and can be forgotten from the UI.
- The public Discord configuration contains an application ID and loopback redirect only; no client secret is used.
- USBPcap is optional and fails softly when unavailable.
- The application runs at normal user privilege and is per-monitor DPI aware.
- Generated releases exclude settings, tokens, logs, profiles, packet captures, and signing material.

## Installation and releases

The Inno Setup installer writes Stable application files beneath `%LOCALAPPDATA%\Programs\MuteCue`. User data remains separate under `%LOCALAPPDATA%\MuteCue`.

`Build-MuteCueExeRelease.ps1` publishes the explicit Stable channel, injects the approved public Discord application ID, rejects legacy runtime folders and PowerShell files, creates the installer and SHA-256 checksum, installs the exact generated installer into a temporary location, launches it, and verifies that it does not spawn PowerShell.

GitHub publishes only tags that match the manifest version and whose commit is already contained in `main`. Release assets are immutable and unsigned until Authenticode signing is configured.

## Verification

The native test executable covers channel identity, settings compatibility, Discord configuration, overlay source composition, hotkey parsing, USB edge parsing, hardware page mapping, and optional live BEACN/USB acceptance.

The PowerShell suite under `Overlay/Tests` is retained to protect migration-era algorithms, privacy boundaries, packaging assumptions, and compatibility behavior while the native release matures.
