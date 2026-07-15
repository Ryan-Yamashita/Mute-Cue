# Contributing to Mute Cue

Thanks for helping test and improve Mute Cue.

## Before opening an issue

1. Reproduce the problem with current source and the BEACN desktop app running at the same Windows privilege level.
2. Record the Windows version, BEACN version, affected fader, mute mode, and exact input path.
3. Describe whether the issue occurs with a desktop click, mapped hotkey, or physical Mix Create control.

Do not attach settings, Discord authorization, packet captures, certificates, BEACN profiles, or local `Program`/`Settings` directories.

## Verification

Run both native channels:

```powershell
dotnet run --project .\src\MuteCue.Desktop.Tests\MuteCue.Desktop.Tests.csproj --configuration Release -p:MuteCueChannel=Stable
dotnet run --project .\src\MuteCue.Desktop.Tests\MuteCue.Desktop.Tests.csproj --configuration Release -p:MuteCueChannel=Dev -- --expect-dev
```

Run the retained compatibility suite when changing BEACN state, packaging, or migration behavior:

```powershell
.\Overlay\Tests\Run-All.ps1
```

## Development workflow

- Use `Build and Launch Mute Cue Dev.cmd` for normal local iteration.
- Keep unrelated formatting out of focused changes.
- Preserve bounded queues, authoritative confirmation, and fail-closed mapping behavior.
- Update user-facing documentation with behavior or support changes.
- Test BEACN changes with window movement, page changes, and mixed display scaling when possible.
- Never commit generated EXEs, local Discord configuration, credentials, packet captures, or signing material.

Release assets are built only by the tagged GitHub workflow. Do not publish manually assembled installers.
