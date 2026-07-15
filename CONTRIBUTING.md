# Contributing to Mute Cue

Thanks for helping test and improve Mute Cue.

## Before opening an issue

1. Use the current source and run the full local verification suite:

   ```powershell
   powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Overlay\Tests\Run-All.ps1
   ```

2. Reproduce the issue with the BEACN desktop app and Mute Cue running at the same Windows privilege level.
3. In Mute Cue, select **Copy BEACN diagnostics** and include its text in the report.
4. Describe the exact button, knob, hotkey, or desktop action that triggered the result.

Do not attach `settings.json`, Discord authorization data, packet captures, certificates, BEACN profiles, or anything from the local `Program` or `Settings` folders. Those files are intentionally excluded from source control because they can contain personal or machine-specific information.

## Development workflow

- Make focused changes and keep unrelated formatting out of the same pull request.
- Run the full test suite above before requesting review.
- Update user-facing documentation when behavior or supported setup changes.
- Test new BEACN behavior with the application window moved, resized, and on a different monitor when possible.

The project’s release artifacts are built and signed separately. Do not publish manually assembled archives; follow [RELEASE_CHECKLIST.md](RELEASE_CHECKLIST.md).
