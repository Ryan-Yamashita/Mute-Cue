# BEACN Mix Create event source feasibility — October 18, 2026

## Goal

Preserve Mute Cue's responsive, authoritative per-fader **Mute to All** and **Mute to Audience** indicators across every selected BEACN Mix Create fader while keeping the overlay independent of protected games. Do not attempt to bypass Javelin, inspect protected game processes, or introduce invasive USB interception.

## Verified user-side findings

1. With USBPcap capture active and Mute Cue running, Apex repeatedly terminated after several minutes; Windows Event Viewer reported `EA Javelin Anticheat`, Application Event ID 1000, and opaque `ExitType` codes. With Mute Cue Dev's **active USB capture disabled**, Apex ran for approximately five minutes without a crash. This strongly suggests a compatibility issue but **does not prove USBPcap as root cause**, nor exclude a system/driver issue.
2. Disabling global mouse/keyboard hooks while leaving active USB capture running caused Apex to terminate again; hardware changes worked but mapped keyboard hotkey notifications took around 10 seconds.
3. With both input hooks enabled and active USB capture disabled, the selected BEACN controls could eventually be detected through WPF/UI Automation. Seven selected sources caused roughly four-second delays.
4. Timing trace of seven sequential `BEACN` UI Automation subtree reads showed 325–436 ms per selected source, around 3.5 s to revisit the same source. The overlay displayed changes within the same event-loop tick after publication. Restricting Dev's selected sources to only Mic significantly reduced visual delay.
5. A read-only Windows Plug and Play inventory found BEACN Mix Create with `VID_33AE&PID_0007` and BEACN Studio with `VID_33AE&PID_0003`, with **no matching device entries in the HIDClass device category** for either ID. Mix Create exposed named `BEACN Mix Create` and `BEACN Mix Create Ctrl` interfaces. This inventory does not absolutely prove no HID interface exists, but there is **no evidence that Windows Raw Input can receive Mix Create button events**.

## External documentation / compatibility constraints

- BEACN says the Mix Create requires the **BEACN App** for hardware communication: https://support.beacn.com/en-US/does-beacn-mix-create-work-without-the-beacn-app-running-282028
- Mute modes are source-specific routes (All, Audience, Self, Chat), not simply Windows microphone endpoint master-mute flags: https://support.beacn.com/en-US/what-is-a-mute-mode-and-how-do-i-set-it-up-282048
- Virtual Windows audio endpoints correspond to input/output routing; checking a Windows device's global mute bit cannot necessarily distinguish all per-fader Audience/All modes: https://support.beacn.com/en-US/why-are-there-several-new-usb-audio-devices-on-my-system-282036
- BEACN's developer API requests have appeared on its feature board with status *Not Right Now* (historical; not definitive current developer policy): https://ideas.beacn.com
- EA confirms Javelin can close games when it encounters conflicting or outdated software: https://help.ea.com/en/articles/platforms/pc-ea-anticheat/

No public, supported and documented BEACN Mix Create mute-state subscription SDK/API was verified in this research.

## Decision

**Do not implement Windows Raw Input, WinUSB/libusb, a shared USBPcap interception workaround, arbitrary Windows endpoint mute callbacks, or parallel unrestricted UI Automation polling as a purported complete fix.** None has been demonstrated to offer all faders' authoritative mute modes with safe concurrent access to the BEACN App.

**Keep Stable unchanged and leave the compatibility PR in draft.** Further code changes need a validated source of change events.

## Highest-value next actions

1. Ask BEACN support/engineering whether their Windows app exposes a **documented read-only** per-fader mixer-state subscription or a notification/event channel for physical knob/button presses, mute modes, and active hardware page. Ask specifically for a method that does not require installing another kernel driver, tapping USB traffic, or injecting into their process.
2. If BEACN supplies a supported API, prototype its subscription **in Dev only**, keep existing UIA authority as reconciliation, and run automated tests plus physical hardware acceptance and a guarded Apex test.
3. In the absence of a documented BEACN API, a Dev-only, opt-in **BEACN-process-scoped** out-of-context Windows accessibility event probe is now available behind `--dev-beacn-win-events` (also requires all three USB-free/timing flags). It records only event types and accessibility object/child identifiers; it does not change mute detection or inspect protected game processes. Test it **outside Apex** to determine whether BEACN exposes useful, timely change notifications. Existing UI Automation output and row subscriptions did not emit events in the shared diagnostic excerpt, so success remains uncertain. Microsoft documentation: https://learn.microsoft.com/en-us/windows/desktop/api/winuser/nf-winuser-setwineventhook
4. Until then, provide the honest UX compromise: priority for selected critical faders (e.g. Mic) with slower periodic reconciliation for others. Make latency expectations explicit; do **not** silently advertise full instant all-fader monitoring.
5. Separately correlate Javelin crash information (Event ID / ExitType / services), and review any compatibility messages with EA. No further anti-cheat shutdown experiments until a supported source is established.

## Suggested vendor technical questions

Is there a supported read-only API, documented IPC mechanism, or callback in the BEACN Windows App to subscribe to each Mix Create fader's **Mute to All** and **Mute to Audience** state changes, including physical knob/button presses and current hardware page? Does this event channel work in the background while the BEACN App owns the hardware and another game is foreground, without a third-party USB filter or raw USB capture? Are there licensing or compatibility conditions for a community overlay? We only need mute **state**, not audio contents or permission to control the device.
