# Mute Cue release checklist

## Automated gate

- Run `Overlay\Build-MuteCueRelease.ps1 -DiscordApplicationId <approved application ID> -RequireDiscordPublicClient`; do not assemble public release archives by hand.
- Run `Overlay\Tests\Run-All.ps1` in Windows PowerShell 5.1.
- Confirm the accessibility assembly reports the release version, contract 1, matching source hash, and a valid SHA-256 digest.
- Confirm the isolated precompiled-runtime startup gate remains below its 750 ms P95 budget.
- Confirm the simulated 4/7/8/13-fader, lock, page, reorder, and mixed-coordinate production matrix passes.
- Confirm the deterministic locked-reader and concurrent snapshot IPC tests pass without worker termination, malformed JSON, or leftover temporary files.
- Run `Overlay\Invoke-MuteCueHardwareAcceptance.ps1 -DiscoveryOnly` and keep cold authoritative discovery below 30 seconds.
- Confirm every release-manifest file exists and no settings, credentials, logs, or packet captures are packaged.
- Install twice into a clean per-user location and verify atomic version switching and rollback retention.
- Confirm the release builder's exact-archive smoke installation passes; do not publish a zip that was not the tested artifact.
- Uninstall and verify user data is preserved by default.

## Clean-machine matrix

- Windows 10 and Windows 11 with a standard user account.
- Display scaling at 100%, 125%, 150%, and 200%.
- Single-monitor and mixed-DPI multi-monitor layouts, including negative coordinates.
- Supported BEACN versions and the structural fallback warning on an unknown version.
- Four, seven, eight, and thirteen faders; add, remove, rename, reorder, lock, and page transitions.
- BEACN moved, minimized, restarted, upgraded, and running at a different privilege level.
- Mix Create disconnect/reconnect, sleep/resume, USBPcap present, absent, and unavailable to the current user.
- Rapid alternating All/Audience presses and desktop-app changes while the hardware page moves.
- Configure a non-F24 BEACN Knob Mute shortcut for a non-Mic fader and verify Mute Cue targets that fader's Mute All row without any separate Mute Cue binding. Change the assignment while Mute Cue is running, then repeat once while the BEACN window is settling after a move.
- From a fresh launch with an unknown hardware page, press an unlocked non-Mic knob and verify the overlay responds without a multi-row seconds-long stall. Confirm that zero or multiple output deltas still fall back safely and never guess a page.
- Verify a configured shortcut previews within one 50 ms UI tick while fresh/Ready, then converges to two matching authoritative reads; stale or synchronizing state must not preview.
- Run `Overlay\Run Mute Cue Hardware Acceptance.cmd` in Full scope and retain the generated acceptance JSON with the release record.

## Distribution gate

- Configure the protected GitHub `production` environment documented in `DISCORD_RELEASE.md`, then publish by pushing the matching `v<manifest-version>` tag.
- Build the versioned release directory and zip from `Overlay\MuteCue.ReleaseManifest.json` with the release script.
- Verify `MuteCue.ReleaseFiles.json` and the external `.sha256` file against the exact downloadable archive.
- Confirm `MuteCue.ReleaseFiles.json` reports `signed: false` and no signer thumbprint.
- Publish checksums and a prominent unsigned-download warning with the verified BEACN compatibility range.
- Keep the previous release available for rollback.
- Run the clean-machine smoke test from the exact downloadable artifact, not the source workspace.

## Discord public-client gate

- Create one Mute Cue Discord application under the Mute Cue Developer Team; do not ask customers for an application ID, redirect URI, or client secret.
- Enable Discord Public Client and register `http://127.0.0.1:47891/mute-cue/` before building the release.
- Build with `-DiscordApplicationId <Mute Cue application ID>` and confirm the source placeholder was not shipped.
- Obtain Discord RPC approval for the released scope and keep the review demo, privacy policy, and support contact current.
- Verify Connect, cancel, reconnect, token refresh, Disconnect, Forget authorization, revoked consent, Discord restart, and sleep/resume on a clean Windows account.
