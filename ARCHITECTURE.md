# Mute Cue architecture

## Operating model

Mute Cue separates input signals, authoritative state, and presentation:

```text
BEACN desktop client -> isolated UI Automation worker -> ordered coordinator -> WPF overlay
Mix Create USB ------> bounded wake-up hints -----------^
Discord local RPC ---> bounded confirmed events -------------------------------> overlay
```

The BEACN desktop client is authoritative. Mouse clicks, configured knob-mute shortcuts, and Mix Create packets request faster rereads; they never decide the final mute state. Mute Cue reads BEACN's own global Knob Mute assignments, listens only for those exact gestures, and gives the mapped All row an urgent rendered-first reread. When the existing state is fresh and fully authoritative, a shortcut may show the same short-lived expected-result preview used by confident hardware presses; two matching real BEACN reads replace or retract it. While those reads are pending, the last committed state remains the stable rendering base and only the same fader's unexpired preview may accept another ordered press. Authority is withheld during confirmation without inserting an artificial unknown frame. The pass-through listener retains no unrelated keystrokes, bounds its event queue, suppresses key-repeat until release, and keeps the last valid assignment snapshot during a transient BEACN file rewrite.

## Process boundaries

The overlay UI and BEACN accessibility provider run in separate processes. The worker owns all long-running BEACN UI Automation calls and publishes complete JSON snapshots through a private per-run directory under the current user's local application data.

After the overlay obtains single-instance ownership, it launches the worker immediately. Cold BEACN discovery overlaps compilation and construction of unrelated overlay subsystems, reducing startup latency without exposing partial state.

The shared accessibility provider is built once into `MuteCue.Accessibility.dll`. Both processes validate its assembly name, versioned runtime contract, SHA-256 digest, and exact embedded-source revision before loading it. Installed releases do not compile the provider at startup; a source fallback is permitted only from an explicit development checkout or opt-in environment flag. This removes duplicate cold compilation while making stale or partially updated binaries fail closed.

The protocol has these guarantees:

- a random session token authenticates commands and snapshots;
- every worker has a unique instance ID;
- every snapshot carries a monotonically increasing sequence number and UTC capture time;
- every fader carries its own monotonic action-observation revision, so a cache-only scan or a read of another fader cannot satisfy its confirmation gate;
- writes use a same-directory temporary file and atomic replacement;
- snapshot readers open with read/write/delete sharing so atomic replacement cannot be blocked by the overlay; publication uses unique same-directory temporary and backup paths plus bounded retries for antivirus or legacy-reader contention, preventing an IPC collision from terminating the worker;
- command and event directories are bounded;
- stale, duplicate, out-of-order, oversized, and malformed snapshots are rejected;
- scan execution is asynchronous from the worker heartbeat, so one slow JUCE/UI Automation call cannot erase readiness or force an unnecessary cold restart;
- the worker keeps publishing its last complete immutable state while a scan is in flight and self-recycles only after a bounded 30-second scan deadline;
- the watchdog replaces a stopped worker without restarting the overlay;
- cold discovery and steady-state reads have separate bounded deadlines.

The overlay retains its last authoritative immutable snapshot while a replacement worker performs a clean discovery. A transient empty snapshot caused by minimize, redraw, or restart cannot erase confirmed state immediately.

## State coordination

Only the WPF dispatcher submits provider snapshots to the coordinator. This gives all provider results a single ordered commit path even though input hooks, USB capture, UI Automation callbacks, and Discord operate concurrently.

Two generations are tracked independently:

- **Layout generation:** fader identity, order, or lock topology changed.
- **Geometry generation:** the same controls moved or resized on screen.

Moving the BEACN window does not invalidate the hardware map or perform full structural discovery. Native window bounds detect the move without traversing UI Automation, and cached action rectangles are translated immediately into the new window coordinate space. UI Automation reads pause during a short settling window; movement-generated row notifications are discarded because they do not represent mute changes. Normal named events and bounded safety reads resume afterward. A real add, remove, reorder, profile switch, or lock-topology change must be confirmed twice and then publishes atomically.

The worker polls native bounds independently from accessibility scans. Every scan and full discovery is fenced by a native geometry generation; work that spans a move is discarded and cannot publish a mixture of pre-move and post-move control state.

Independent `Knob: Mute to All` and `Mute to Audience` action rows are confirmed separately. Missing action rows, duplicate names, or incomplete compatibility never become authoritative and are never reconstructed from ambiguous aggregate output controls.

## Fader identity and compatibility

The visible fader name is presentation data. When the active BEACN profile is readable, internal state and saved selections use `profile:<mixer id>` identities. A fader rename therefore preserves the action tracker and user selection. Dynamically discovered controls without a profile ID fall back to a normalized name.

`Overlay/BeacnCompatibility.json` is the versioned compatibility manifest. Known BEACN versions select a verified label profile. Unknown versions use a structural fallback that is clearly marked unverified in diagnostics; authority still requires complete independent action rows.

## Responsiveness and back-pressure

- Named UI Automation row and output events are the primary action signal. A desktop click is matched only against the worker's already-confirmed cached row bounds and schedules a bounded set of delayed targeted rereads; it never decides final state.
- Native window movement translates cached geometry immediately, pauses provider reads while JUCE settles, and requests geometry verification rather than structural discovery.
- Normal scans drain at most one named fader refresh. Explicit shortcut work has a separate coalescing urgent lane ahead of ordinary row notifications, while hardware requests retain their dedicated bounded queue. A lightweight 15 ms dispatcher pump consumes only mapped keyboard gestures; the heavier Discord/BEACN monitoring pass remains at 50 ms.
- A detected state edge schedules a second targeted UI Automation read on the worker's 15 ms confirmation cadence, so confirmation does not wait for the ordinary snapshot heartbeat.
- Hardware and resolved desktop-action predictions have a four-second lease, long enough to cover BEACN's slowest observed confirmation pass. They are allowed only while action authority, layout/page confidence, stable geometry, and the named row are current. Hardware results remain correlated by mapping generation and request ownership, so a completed or mismatched result retracts only the prediction it owns. Shortcut previews additionally require a healthy accessibility worker.
- USB, hardware refresh, global input, and Discord queues are bounded.
- USB work has a per-frame processing budget.
- The WPF dispatcher never performs a full BEACN tree walk.
- Explicit shortcut, hardware, desktop, and periodic safety reads try the validated rendered-row hit test first and fall back to the same named accessibility subtree when hidden or occluded. Periodic safety reads inspect only the stalest fader after a ten-second freshness lease. Their cadence is cost-aware: it starts at 750 ms but backs off to ten times the measured UI Automation cost, capped at five seconds.
- Desktop action hitboxes include BEACN's adjacent menu/status-button area, but overlapping candidates are ranked by direct containment and distance to the original named row. A neighboring fader or the other mute mode cannot win merely because its padded region was enumerated first.
- An unknown-page hardware press first compares the already tracked output toggles. One unique compatible edge selects exactly one authoritative row to inspect; zero or multiple edges retain the bounded serial fallback. Output edges are retained in a bounded, timestamped per-source record so an event arriving just before the worker command can be correlated. A row/output UI Automation event carries BEACN's exact fader identity, is promoted ahead of fallback, and forces a second real read. If that urgent read consumed the row delta first, a successful reread may calibrate the page only when the output candidate is still the single compatible time-correlated edge. Already-confident mappings use staged preferred-row-only retries and never walk unrelated faders.
- A requested shortcut target that is missing or temporarily unreadable survives one successful discovery generation, then either runs against the named fader or retires without an unbounded rediscovery loop. Retirement clears its deadline so a later independent gesture can make a fresh bounded attempt.
- Hardware results and their confirmation rereads remain local to the active scan until its final native-geometry fence passes. Reads invalidated by movement are requeued instead of publishing page confidence from discarded state.

## Persistence, diagnostics, and security

- Settings schema 5 is normalized, bounded, written atomically, and backed up one generation.
- Fader selections persist both display names and stable profile keys.
- The current user's `Mute Cue.lnk` in the Windows Startup folder is authoritative for **Run on startup**. Installer updates preserve a user-disabled shortcut, while owned legacy shortcuts are upgraded safely. `StartInSystemTray` is a separate presentation preference and suppresses the settings window only for launchers carrying the `/startup` marker.
- Discord credentials use Windows DPAPI with `CurrentUser` scope.
- Logs redact credential-like values, rotate at a fixed size, and cannot throw into the runtime.
- **Copy BEACN diagnostics** produces a privacy-safe report containing compatibility, worker, generation, timing, queue, and per-fader health without credentials.
- The default launcher runs with normal user permissions. USBPcap is optional and fails softly when capture permission is unavailable.
- Only one overlay instance runs per Windows session.
- Child processes are owned and cleaned up; the isolated worker also exits when its parent disappears.
- Mutable files live under `%LOCALAPPDATA%\MuteCue`, never beside installed application files. A copy-first, marker-backed migration preserves legacy portable settings and DPAPI data without overwriting newer destinations.
- The readiness model verifies Windows, PowerShell, .NET Framework, writable per-user data, BEACN version/profile, fader authority, independent action authority, and optional USB state.
- Worker telemetry publishes the accessibility runtime mode, version, contract, and integrity result. A failed component check blocks monitoring and appears in both the settings status and privacy-safe health report.

## Installation and updates

The per-user installer writes immutable releases beneath `%LOCALAPPDATA%\Programs\MuteCue\versions`. It validates every PowerShell file in a staging directory, promotes the completed directory, then atomically replaces `current.txt`. The stable launcher resolves only that constrained release identifier. The prior marker and release remain available for rollback; an interrupted copy cannot become active.

Before staging, the installer validates the accessibility component against the exact overlay source being installed, then repeats that validation from the completed staging directory. `Build-MuteCueRelease.ps1` rebuilds the component, runs all automated gates, creates a file-by-file checksum index, and produces a zip plus an external SHA-256 checksum. Its public-release mode requires a certificate thumbprint, signs the compiled provider before its digest is recorded, signs the PowerShell/VBScript launch surface, and rejects any invalid signature. A developer may still create an explicitly unsigned engineering build. Repository hashes are consistency checks, not a substitute for the trusted signing certificate.

The release gate then extracts the exact zip, rejects missing, altered, unsafe, or unindexed files, validates the external archive checksum, and performs a clean per-user installation from the extracted artifact. The same end-to-end engineering release gate runs on Windows for repository changes.

Public signing validates the leaf certificate's Code Signing EKU, accessible private key, validity window, exact signer thumbprint, trusted Authenticode result, and CA timestamp. Public mode refuses a missing timestamp URL and accepts only HTTPS timestamp endpoints. Private keys and signing containers are excluded from source control. The isolated development probe never alters trusted-root stores: it verifies that signature bytes survive archiving and that the production validator rejects the intentionally untrusted signer.

The uninstaller verifies product metadata before deleting an install root and preserves `%LOCALAPPDATA%\MuteCue` unless removal of user data is explicitly requested. Code signing remains a release-pipeline responsibility because a signing identity cannot be stored in the repository.

## Recovery behavior

The health state is explicit: `Healthy`, `Synchronizing`, `Recovering`, `Unavailable`, or `WorkerStopped`. The runtime distinguishes:

- normal cold discovery;
- steady-state provider stalls;
- worker process crashes;
- transient empty layouts;
- unsupported BEACN versions;
- expired accessibility elements;
- actual layout changes;
- geometry-only movement;
- USB disconnect or route changes.

The settings connection card translates these internal phases into user-facing states: green `Ready`, red `Discovering`/`Unavailable`, and amber `Resyncing`. Brief multi-read confirmation work keeps the last green `Ready` presentation, so a normal button press does not look like a disconnect. A recovery condition that remains continuous for one second becomes amber; hard unavailable states bypass that grace period. During geometry resynchronization or a slow provider response, the last confirmed mute state remains protected.

The overlay fails closed when authority expires. It does not guess a fader or toggle state during recovery.

## Verification

`Overlay/Tests/Run-All.ps1` covers:

- settings normalization, schema migration, stable selection keys, atomic writes, and backup recovery;
- per-user path creation, copy-first legacy migration, and non-overwrite behavior;
- verified, unverified, limited, and invalid environment readiness states;
- staged per-user installation, atomic version switching, rollback retention, private-file exclusion, and safe uninstall;
- diagnostic redaction, rotation, and privacy-safe health reports;
- All/Audience transition order, optimistic request ownership, expiry, and performance;
- profile-backed identities and rename preservation;
- geometry versus layout generations;
- duplicate and out-of-order snapshot rejection;
- transient empty snapshots;
- rapid ordered toggle bursts;
- atomic reorder publication;
- isolated worker startup, authenticated commands, crash replacement, and shutdown;
- queue and runtime architecture invariants;
- compilation of every embedded C# subsystem.
- precompiled accessibility identity, source-revision, contract, missing-file, and corruption rejection;
- installed accessibility validation and release-manifest inclusion.
- simulated 4/7/8/13-fader layouts with zero through three locked faders, every independent All/Audience combination, page mapping, reorder fencing, and negative monitor coordinates;
- release-signing certificate policy, untrusted-signer rejection, and signature preservation through archive extraction.

`Invoke-MuteCueHardwareAcceptance.ps1` is the physical acceptance layer that automation cannot replace. It discovers the exact live fader order, records verified runtime provenance and cold-discovery timing, then guides and observes each hardware/desktop All/Audience action and restoration. It also verifies that moving BEACN between monitors advances geometry without changing authoritative mute state. Reports are privacy-safe and stored under `%LOCALAPPDATA%\MuteCue\Acceptance`.

Live Windows validation additionally verifies all named BEACN rows, controlled window movement, worker recovery, current-version compatibility, and response time with the actual desktop client.

## Platform constraint

BEACN does not currently provide a supported public state API used by this project. Mute Cue reads the structured Windows accessibility controls exposed by the desktop client, not screenshots or private process memory. A major BEACN accessibility redesign may require a new compatibility profile, but the isolated worker, fail-closed coordinator, and version manifest prevent an unknown layout from silently becoming authoritative.
