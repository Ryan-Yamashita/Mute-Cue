# Native EXE migration

The PowerShell-to-native migration is complete for the v0.6.0 application runtime.

`src/MuteCue.Desktop` now produces a self-contained WPF `MuteCue.exe` that does not launch `powershell.exe` or ship a legacy `Runtime` directory. The retained PowerShell implementation is source and regression-test material only.

## Ported runtime boundaries

- Native settings, tray, startup registration, overlay, and single-instance ownership
- Native BEACN UI Automation discovery and authoritative action-row reads
- Native desktop-click targeting and bounded refresh queues
- Native BEACN Knob Mute hotkey parsing and low-level keyboard input
- Native Mix Create USBPcap route discovery, button edges, hardware pages, and calibration
- Native Discord local RPC authorization, refresh, and DPAPI credential storage
- Stable/Dev compile-time channel isolation

## Acceptance completed

- Stable and Dev channel regression suites
- Warning-free self-contained `win-x64` publish
- Seven authoritative live BEACN faders
- Live Mix Create USB route and status packets
- Real Discord mute/deafen monitoring
- Real mapped F24 hotkey behavior
- Real locked-Mic knob mute/unmute behavior
- Transparent icon-based overlay behavior
- Installed EXE smoke test with no PowerShell child process

## Release boundary

The native installer contains only the self-contained executable and the public Discord client configuration. It must not contain `.ps1` files or a `Runtime` directory.

The release remains an unsigned community beta until an Authenticode signing identity is available. Every GitHub release includes a SHA-256 checksum and must be built from a tag already contained in `main`.

## Build locally

Use the repository-root Dev launcher for normal iteration:

```text
Build and Launch Mute Cue Dev.cmd
```

Build Stable directly when validating release behavior:

```powershell
dotnet publish .\src\MuteCue.Desktop\MuteCue.Desktop.csproj --configuration Release --runtime win-x64 --self-contained true -p:MuteCueChannel=Stable
```

See [Local development](LOCAL_DEVELOPMENT.md) and the root [Release checklist](../RELEASE_CHECKLIST.md).
