# Changelog

All notable changes to Mute Cue are recorded here.

## Unreleased

## 0.6.0 - 2026-07-15

- Replaced the PowerShell runtime with one self-contained native WPF executable.
- Added native BEACN accessibility discovery and independent All/Audience action monitoring.
- Added native Mix Create USB capture, locked-fader mapping, hardware pages, and automatic recalibration.
- Added native BEACN Knob Mute hotkey parsing and live mapping reloads.
- Added native Discord local RPC authorization, token refresh, and DPAPI storage.
- Restored the transparent icon-based overlay and per-fader mute presentation.
- Added immediate guarded feedback for known desktop, hotkey, and physical actions.
- Added isolated Stable and Dev channels with a fixed local Dev build workflow.
- Added a native-only installer gate that rejects PowerShell files and legacy runtime directories.
- Added a GitHub release gate requiring tagged commits to already be contained in `main`.
- Reopening an already-running app now restores its settings window from the system tray.
- Added the icon-only Mute Cue logo to the native taskbar window and system tray.
- Restored the Close to system tray setting; normal close now follows it, while tray Exit fully terminates the app and immediate relaunch waits safely for shutdown cleanup.
- Removed the redundant Discord UI Automation polling loop that could grow memory during long sessions.
- Native upgrades now remove obsolete launcher/runtime files and repair an existing startup shortcut.
- Stable now installs under `C:\Program Files\Mute Cue`; the one-time migration removes the previous per-user application copy while preserving user data.

## Beta release policy

Community beta releases are built from a tag contained in `main`, smoke-tested from the exact installer, published with a SHA-256 checksum, and documented with their supported setup. Releases remain unsigned until Authenticode signing is configured. See [RELEASE_CHECKLIST.md](RELEASE_CHECKLIST.md).
