# Beta testing Mute Cue

Thank you for testing Mute Cue with your BEACN setup.

## Supported environment

Mute Cue currently targets Windows 10 and Windows 11 with the English BEACN desktop app 1.2.x. Run BEACN and Mute Cue at the same Windows privilege level. A BEACN Mix Create is needed to test physical buttons; USBPcap is optional and only improves how quickly physical presses wake the overlay.

## Quick test

1. Start the BEACN desktop app and Mute Cue.
2. In the **BEACN** tab, confirm the fader sources are discovered and choose the mute states to show.
3. Test a desktop-client mute change, a hardware knob/button press, and a BEACN Knob Mute hotkey if you use one.
4. Move or resize the BEACN window and repeat a state change.
5. If you use Discord, test connect, mute, deafen, disconnect, and restart Discord.

## Reporting a problem

Use **Copy BEACN diagnostics** in the BEACN tab, then open a bug report with:

- Windows version and display scaling
- BEACN version and device model
- Whether USBPcap is installed
- Which control or hotkey was used
- Exact expected and actual results
- The copied diagnostic text

Never attach packet captures, `settings.json`, Discord authorization data, certificates, or BEACN profile exports. These may be private or machine-specific.

## Known beta limits

- The BEACN compatibility contract currently covers version 1.2.x. Other versions may work, but should be reported as compatibility testing rather than assumed supported.
- The app uses the visible BEACN desktop client, so labels, accessibility structure, language, and Windows privilege level can affect discovery.
- Releases use a Windows launcher today. A fully native EXE host is a planned follow-up, not a claim this beta makes.
