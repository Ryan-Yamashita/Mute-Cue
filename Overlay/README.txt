MUTE CUE

Recommended installation:
1. Double-click "Install Mute Cue.cmd".
2. Mute Cue installs for your Windows account and starts with normal permissions.
3. The installer adds sign-in startup unless it is run with -NoStartup. You can change this later under Settings > Startup.
4. Double-click "Uninstall Mute Cue.cmd" from the installed folder to remove the app. Settings and credentials are preserved unless -RemoveUserData is explicitly requested.

Portable start:
1. Double-click "Start Beacn Mute Overlay.cmd".
2. Discord opens by default. Connect it only if you want Discord mute/deafen monitoring.
3. Open the BEACN tab, turn on "Monitor BEACN hardware", expand "Faders", and choose the states to monitor.
4. Open Settings > Overlay, turn on "Preview overlay", place and size it, then turn Preview off. Changes save automatically.
5. Settings > Startup contains "Run on startup" and its dependent "Start in system tray" option. Manual launches still show the settings window.

The BEACN section shows whether this computer is ready, still validating, unverified, limited, or incompatible. Copy BEACN diagnostics includes the readiness result without including credentials.

Release builds use a versioned precompiled accessibility component. The overlay and worker verify its assembly identity, contract version, source revision, and SHA-256 digest before loading it. Installed copies never compile this component at startup and fail closed if either the DLL or its manifest is missing or altered. Source checkouts retain an explicitly development-only fallback.

Important:
The overlay can show multiple active mute states at once.
The Faders panel follows the live cards in the BEACN app and disables sources that are not currently present. Newly added sources become available, moved sources follow the new order, and selections stay attached to stable profile identities when available. BEACN's visible All and Audience action rows are authoritative. Mute Cue reads BEACN's own Knob Mute assignments; a matching shortcut gets an immediate guarded preview plus an urgent rendered-first All-row reread, with no separate Mute Cue binding. Two matching real reads confirm or retract the preview. USBPcap supplies immediate hardware-button wakeups, and an unknown-page press uses tracked output edges only to locate the one authoritative row to inspect. Request IDs and page generations prevent older results from overwriting newer presses.

A single state is displayed inline, such as "System: All". If both states are active, smaller All and Audience labels are stacked beside the centered fader name.

User data is stored under %LOCALAPPDATA%\MuteCue. Diagnostics are in its Logs folder, are size-limited, and redact credential-like values. Run Tests\Run-All.ps1 from the source download for the complete automated verification suite.

Maintainers build a distributable zip with Build-MuteCueRelease.ps1. It rebuilds the accessibility component, runs the full test suite, emits a per-file release index, and writes a SHA-256 checksum beside the archive.

Before publishing on new hardware, close the normal overlay and run "Run Mute Cue Hardware Acceptance.cmd". It observes real authoritative BEACN state changes for every detected fader and input path, verifies restoration and monitor movement, and saves a privacy-safe result under %LOCALAPPDATA%\MuteCue\Acceptance. Use `Invoke-MuteCueHardwareAcceptance.ps1 -Scope Quick` for a shorter four-fader check.
