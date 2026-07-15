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

The public application ID is injected only into the release artifact:

```powershell
.\Overlay\Build-MuteCueRelease.ps1 -DiscordApplicationId <application-id> -RequireDiscordPublicClient
```

The source-tree JSON intentionally has no application ID. This prevents accidental public builds with a developer-owned or customer-provided Discord application.

For local testing from a Git checkout, copy `Overlay/MuteCue.DiscordPublicClient.local.example.json` to `Overlay/MuteCue.DiscordPublicClient.local.json` and replace the placeholder with a tester-enabled application ID. The local file is ignored by Git, honored only beside the repository’s `.git` directory, and excluded from the release manifest. Do not add a client secret.

Tagged production releases are published by `.github/workflows/publish-release.yml`. Configure a protected GitHub `production` environment with this secret before pushing the matching `v<manifest-version>` tag:

- `MUTE_CUE_DISCORD_APPLICATION_ID`: the approved public-client application ID.
The workflow rejects a tag/version mismatch, a missing Discord client, and any artifact that fails the exact-archive install and verification gate. It publishes only the verified zip and its SHA-256 file. The release is intentionally unsigned, so Windows may show an unknown-publisher or SmartScreen warning; users should download only from the official GitHub release and verify the published SHA-256 checksum.

## Privacy copy

“When you choose Connect Discord, Mute Cue asks Discord for permission to read your current self-mute and self-deafen state. The resulting authorization is encrypted for your current Windows account and is used only to display the overlay. Mute Cue does not collect or transmit Discord messages, server information, contacts, or voice audio. You can disconnect or choose Forget authorization at any time; Forget authorization deletes Mute Cue’s local saved authorization.”
