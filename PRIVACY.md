# Privacy

Mute Cue is a local Windows application. It has no Mute Cue server, analytics service, advertising SDK, or telemetry upload.

## What stays on the device

- Overlay preferences and selected BEACN sources
- Optional Discord authorization after the user chooses **Connect Discord**
- Local application state required for startup and window placement

Discord authorization is protected for the current Windows account using Windows DPAPI. Choosing **Forget authorization** removes Mute Cue's saved authorization.

## What Mute Cue reads

- Visible BEACN desktop-client state required to render selected mute indicators
- BEACN's local Knob Mute mapping file for configured gestures
- Optional local Mix Create USB activity through USBPcap
- Optional Discord self-mute and self-deafen state after consent

Mute Cue does not read Discord messages, server lists, contacts, or voice audio. It does not transmit BEACN state, Discord state, credentials, or diagnostics to a Mute Cue service.

## Sharing support information

Never share settings files, Discord authorization files, packet captures, certificates, BEACN profiles, or files copied from local application-data directories. When reporting a problem, provide only product versions and reproduction steps unless a maintainer requests a specific privacy-safe value.

This document describes the application released from this repository and is not legal advice.
