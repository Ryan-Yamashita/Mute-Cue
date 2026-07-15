# Discord public-release handoff

Mute Cue is one Windows application with optional Discord and BEACN features. It has one built-in Discord public client; users must never create a Discord application or enter a client secret.

## Developer Portal setup

1. Create the **Mute Cue** application under the Mute Cue Developer Team.
2. Enable **Public Client** in OAuth2 settings.
3. Register this exact redirect URI: `http://127.0.0.1:47891/mute-cue/`.
4. Request only the `identify` and `rpc` scopes. Do not enable a bot, privileged Gateway intents, message access, or server installation.
5. Submit the app for the required RPC approval, with a short demo showing the user consent prompt and the local mute/deafen overlay.

Suggested review description: “Mute Cue is a Windows overlay. With explicit user consent, it reads only the signed-in user’s current self-mute and self-deafen state through Discord’s local RPC connection so it can render that state locally. It does not read messages, server lists, contact lists, or voice data; it does not send Discord data to our servers.”

## Release build

The public application ID is injected only into the signed release artifact:

```powershell
.\Overlay\Build-MuteCueRelease.ps1 -RequireSigning -SigningCertificateThumbprint <thumbprint> -TimestampServer <timestamp-url> -DiscordApplicationId <application-id>
```

The source-tree JSON intentionally has no application ID. This prevents accidental public builds with a developer-owned or customer-provided Discord application.

## Privacy copy

“When you choose Connect Discord, Mute Cue asks Discord for permission to read your current self-mute and self-deafen state. The resulting authorization is encrypted for your current Windows account and is used only to display the overlay. Mute Cue does not collect or transmit Discord messages, server information, contacts, or voice audio. You can disconnect or choose Forget authorization at any time; Forget authorization deletes Mute Cue’s local saved authorization.”
