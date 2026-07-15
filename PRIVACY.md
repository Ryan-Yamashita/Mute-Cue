# Privacy

Mute Cue is a local Windows application. It does not include a Mute Cue server or analytics service.

## What stays on the device

- Overlay preferences and BEACN source selections
- Local diagnostic and error logs
- Optional Discord authorization data, only after the user chooses **Connect Discord**

Discord authorization data is protected for the current Windows account using Windows DPAPI. Selecting **Forget authorization** removes Mute Cue’s saved local authorization.

## What Mute Cue reads

- Visible BEACN desktop-client state needed to render selected mute indicators
- Optional Discord self-mute and self-deafen state after consent
- Optional local USB hardware activity when USBPcap integration is enabled

Mute Cue does not read Discord messages, server lists, contacts, or voice audio. It does not transmit BEACN state, Discord state, or diagnostics to a Mute Cue service.

## Sharing diagnostics

The **Copy BEACN diagnostics** command creates a privacy-safe support report. Review it before sharing and never share settings files, packet captures, Discord authorization data, certificates, or BEACN profile files.

This document describes the application as released from this repository and is not legal advice.
