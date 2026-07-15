# Mute Cue

Mute Cue is a native Windows overlay that shows BEACN Mix Create and Discord mute states without keeping mixer controls open on screen.

Mute Cue is available under the [MIT License](LICENSE).

> **Community beta.** Mute Cue is actively tested with the BEACN desktop app. The Windows installer is currently unsigned, so Windows may show an unknown-publisher or SmartScreen warning.

## Download

Download the newest installer and its SHA-256 checksum from [GitHub Releases](https://github.com/Ryan-Yamashita/Mute-Cue/releases/latest).

Use only release assets published by this repository. Each release contains:

- `MuteCue-<version>-Setup.exe`
- `MuteCue-<version>-Setup.exe.sha256`

The installer runs for the current Windows user and places the application under `%LOCALAPPDATA%\Programs\MuteCue`. Settings and encrypted Discord authorization remain under `%LOCALAPPDATA%\MuteCue` when the application is updated or uninstalled.

## Requirements

- Windows 10 or Windows 11 on x64
- The BEACN desktop app for authoritative per-fader mute state
- A BEACN Mix Create for physical knob-button monitoring
- [USBPcap](https://desowin.org/usbpcap/) for immediate physical-button response (optional but recommended)
- Discord desktop if Discord mute/deafen monitoring is enabled

The release is a self-contained native .NET WPF application. Users do not need to install .NET, Windows PowerShell, or any Mute Cue scripts.

## Features

- Transparent, click-through-capable BEACN and Discord overlay
- Independent BEACN **Mute to All** and **Mute to Audience** monitoring
- Native Mix Create USB button and page tracking
- Native support for BEACN Knob Mute hotkeys, including live mapping-file reloads
- Native Discord local RPC authorization and mute/deafen monitoring
- Per-user encrypted Discord authorization using Windows DPAPI
- System tray, run-on-startup, overlay positioning, opacity, and size controls
- Separate Stable and Dev channels for safe local testing

BEACN's displayed action rows remain authoritative. Mouse clicks, mapped hotkeys, and USB packets request immediate targeted reads and may show a short guarded prediction only when the fader and hardware mapping are already known.

## Local data and privacy

Mute Cue is local-only and has no analytics or Mute Cue server. It reads the minimum local state needed to render the overlay and does not read Discord messages, contacts, server lists, or voice audio.

Never share settings files, Discord authorization files, packet captures, certificates, or BEACN profile data. See [Privacy](PRIVACY.md) and [Security](SECURITY.md).

## Local development

Double-click [`Build and Launch Mute Cue Dev.cmd`](Build%20and%20Launch%20Mute%20Cue%20Dev.cmd) to replace and launch the fixed local Dev executable without installing or publishing anything. Dev uses `%LOCALAPPDATA%\MuteCue-Dev` and cannot change Stable startup registration.

See [Local development](docs/LOCAL_DEVELOPMENT.md) and [Architecture](ARCHITECTURE.md).

## Verification

Run the native Stable and Dev checks:

```powershell
dotnet run --project .\src\MuteCue.Desktop.Tests\MuteCue.Desktop.Tests.csproj --configuration Release -p:MuteCueChannel=Stable
dotnet run --project .\src\MuteCue.Desktop.Tests\MuteCue.Desktop.Tests.csproj --configuration Release -p:MuteCueChannel=Dev -- --expect-dev
```

The retained compatibility suite can also be run on Windows:

```powershell
.\Overlay\Tests\Run-All.ps1
```

## Reporting problems

Open a GitHub issue with your Windows version, BEACN version, affected fader and mute mode, and exact reproduction steps. Do not attach private runtime files or raw USB captures.

The PowerShell implementation remains in `Overlay` as compatibility-test and migration reference material. It is not included in the native installer.
