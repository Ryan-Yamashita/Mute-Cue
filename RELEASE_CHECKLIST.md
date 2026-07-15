# Mute Cue release checklist

## Source and version

- Start from a clean commit already merged into `main`.
- Keep `Overlay/MuteCue.ReleaseManifest.json`, project version, file version, assembly version, tag, installer name, and release title aligned.
- Use a new immutable version; never replace assets on an existing release.
- Confirm the native payload manifest contains only `MuteCue.exe` and `MuteCue.DiscordPublicClient.json`.

## Automated verification

- Run the Stable native suite.
- Run the Dev native suite with `--expect-dev`.
- Run `Overlay/Tests/Run-All.ps1` for retained compatibility coverage.
- Build the self-contained Stable installer with `Overlay/Build-MuteCueExeRelease.ps1`.
- Confirm the published and installed payload has no `Runtime` directory and no `.ps1` files.
- Confirm the exact installed `MuteCue.exe` remains running and has no PowerShell child process.
- Confirm the installer checksum matches the exact installer asset.

## Hardware acceptance

- Discover every expected BEACN fader with independent All and Audience authority.
- Verify desktop BEACN clicks, the configured Knob Mute hotkey, and physical knob mute/unmute.
- Verify locked faders, an unlocked page, page changes, final-page overlap, and layout recalibration.
- Verify USBPcap present, absent, reconnecting, and unavailable to the current user.
- Verify BEACN moved, minimized, restarted, and running on mixed-DPI monitors.
- Verify Discord connect, cancel, mute, deafen, token refresh, disconnect, forget authorization, and restart.
- Verify the transparent overlay at supported sizes and opacity values.

## Clean-machine acceptance

- Windows 10 and Windows 11 x64 using a standard user account.
- Install, launch, update, and uninstall the exact generated installer.
- Confirm settings and authorization survive an update and uninstall preserves user data by default.
- Confirm no .NET or PowerShell installation is required by the application.
- Confirm startup registration and start-in-tray behavior.
- Confirm Windows unsigned-publisher messaging is accurately disclosed.

## GitHub promotion

- Push the reviewed branch and merge it into `main` only after Windows verification succeeds.
- Create the matching `v<version>` tag from the merged `main` commit.
- Confirm the publish workflow succeeds and produces one installer plus one `.sha256` asset.
- Download both assets from GitHub and verify the checksum locally.
- Install and test the exact downloaded artifact before marking it as the primary download.
- Keep the previous release available for rollback.

## Discord public client

- Keep the protected GitHub `production` environment configured with `MUTE_CUE_DISCORD_APPLICATION_ID`.
- Confirm the Discord application remains a Public Client with `http://127.0.0.1:47891/mute-cue/` registered.
- Never package a Discord client secret or local development override.
- Keep the privacy policy, support route, and Discord approval material current.
