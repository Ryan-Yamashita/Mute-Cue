# Native EXE migration

Mute Cue is moving from a Windows PowerShell/WPF implementation to a native, self-contained .NET WPF executable. This is a compatibility-first migration: the stable PowerShell app remains the supported runtime until a native release meets the same functional and hardware acceptance gates.

## Why a staged migration

The existing app has non-trivial safety behavior around BEACN accessibility, physical hardware wakeups, global hotkeys, ordered snapshots, geometry changes, Discord authorization, and atomic settings. Wrapping the script in an EXE would not remove the PowerShell runtime or improve those boundaries. The native project therefore replaces components incrementally and keeps each boundary independently testable.

## Current native slice

- `src/MuteCue.Desktop` is a real WPF `MuteCue.exe` target for .NET 10 LTS.
- It is per-monitor DPI aware, single-instance, normal-user only, and has native system-tray/startup behavior.
- It reads and writes the existing `%LOCALAPPDATA%\MuteCue\settings.json` atomically, preserves unknown settings, and keeps the existing backup file.
- It provides the same compact Discord, BEACN, and Settings shell and reads saved fader sources.
- It intentionally does **not** enable BEACN or Discord monitoring yet. The stable app remains authoritative until those providers are ported and accepted.

## Next parity milestones

1. Move the precompiled accessibility scanner and authenticated snapshot protocol into native worker projects.
2. Port the ordered coordinator and geometry-generation fencing, then validate live BEACN desktop, move/resize, restart, and 4/7/8/13-fader cases.
3. Port hardware wakeups and mapped BEACN Knob Mute shortcuts with the current prediction/confirmation rules.
4. Port Discord local RPC and DPAPI authorization storage.
5. Build a self-contained signed `win-x64` release, run the exact-archive installation gate, and perform clean-machine beta acceptance before switching the default installer.

## Build locally

The project pins the .NET 10 SDK in `global.json`.

```powershell
dotnet build .\src\MuteCue.Desktop\MuteCue.Desktop.csproj --configuration Release
dotnet run --project .\src\MuteCue.Desktop.Tests\MuteCue.Desktop.Tests.csproj --configuration Release
dotnet publish .\src\MuteCue.Desktop\MuteCue.Desktop.csproj --configuration Release --runtime win-x64 --self-contained true
```

Do not distribute the native preview yet. A release must satisfy the parity and signing gates above.
