# Mute Cue

Mute Cue is a Windows overlay that shows BEACN Mix Create and Discord mute states without covering the screen with mixer controls.

> **Community beta.** Mute Cue is actively being tested with the BEACN desktop app. Please review the supported setup below and report reproducible problems using the included diagnostics rather than sharing settings, packet captures, or credentials.

## Requirements

- Windows PowerShell 5.1 and .NET Framework 4.8
- The BEACN desktop app for authoritative per-fader state
- A BEACN Mix Create for physical fader-button monitoring
- [USBPcap](https://desowin.org/usbpcap/) for immediate hardware-button wakeups (optional, but recommended)

BEACN application binaries, drivers, personal profiles, packet captures, settings, and credentials are deliberately excluded from source control. Install BEACN and USBPcap from their official distributions.

## Install (recommended)

Double-click [`Overlay/Install Mute Cue.cmd`](Overlay/Install%20Mute%20Cue.cmd). Mute Cue installs for the current Windows user, starts without administrator privileges, and can start automatically after sign-in. Application releases are stored as immutable version directories so an update can switch versions atomically and retain the previous release for rollback.

Settings, credentials, logs, and worker files live under `%LOCALAPPDATA%\MuteCue`; application binaries live under `%LOCALAPPDATA%\Programs\MuteCue`. Uninstall preserves settings by default.

## Portable run

Open [`Overlay/Start Beacn Mute Overlay.cmd`](Overlay/Start%20Beacn%20Mute%20Overlay.cmd). Mute Cue starts with normal Windows permissions. The compact top tabs open **Discord** by default, put mixer monitoring and the always-visible **Fader Sources** list under **BEACN**, and put overlay and startup behavior under **Settings**. In **BEACN**, enable **Monitor BEACN hardware** and select which **Mute to All** and **Mute to Audience** states should appear.

The BEACN section reports live compatibility, computer readiness, discovered fader count, BEACN version, and whether optional USB fast response is active. Fader order, lock state, active-profile changes, worker recovery, and window movement are handled automatically. Mute Cue follows BEACN's own Knob Mute assignments, so a shortcut such as F24 mapped to Mic gets an immediate guarded preview and an urgent Mic / Mute All reread without a second Mute Cue binding. BEACN's displayed row remains authoritative and confirms or retracts that preview. First-time hardware presses on an unknown page use a cheap output-edge locator before the authoritative row read instead of immediately scanning every fader. Use **Copy BEACN diagnostics** for a privacy-safe health report.

Under **Settings**, **Run on startup** controls the current user's Windows sign-in shortcut. When it is enabled, **Start in system tray** becomes available and hides the settings window only for sign-in launches; opening Mute Cue manually still shows the window.

Settings and Discord authorization remain local to the current Windows account. Authorization tokens are protected with Windows DPAPI; Mute Cue never stores a Discord client secret.

For a public Discord release, Mute Cue uses one built-in public client and users never enter Discord developer credentials. See [DISCORD_RELEASE.md](DISCORD_RELEASE.md) for the approval and release handoff.

## Verification

Run the complete local test suite from Windows PowerShell:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Overlay\Tests\Run-All.ps1
```

See [ARCHITECTURE.md](ARCHITECTURE.md) for the state model, failure boundaries, security model, and platform constraints.

## Supported beta setup

- Windows 10 or Windows 11, standard user account
- BEACN desktop app version 1.2.x, in English, at the same Windows privilege level as Mute Cue
- BEACN Mix Create (hardware monitoring is optional, but required for physical-control feedback)
- Any normal display layout, including multiple monitors and high-DPI scaling

Mute Cue reads the live desktop client as its source of truth. The optional USBPcap integration only helps the overlay wake immediately after a physical hardware press; it is not required for correct state.

## Help test the beta

Start with [Beta testing](docs/BETA_TESTING.md). Before opening an issue, use **Copy BEACN diagnostics** in the app and include the resulting text along with your Windows version, BEACN version, and the exact steps that caused the problem. Do not include personal settings files, Discord authorization files, packet captures, or code-signing certificates.

## Privacy and security

Read [Privacy](PRIVACY.md) for the local-data model and [Security](SECURITY.md) for how to report a vulnerability privately.
