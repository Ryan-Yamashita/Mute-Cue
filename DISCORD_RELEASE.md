# Discord public-release handoff

Mute Cue has one built-in Discord public client. Users never create a Discord application or enter a client secret.

## Developer Portal setup

1. Create the **Mute Cue** application under the Mute Cue Developer Team.
2. Enable **Public Client** in OAuth2 settings.
3. Register `http://127.0.0.1:47891/mute-cue/` exactly.
4. Request only the `identify` and `rpc` scopes.
5. Do not enable a bot, privileged Gateway intents, message access, or server installation.
6. Maintain any Discord approval required for local RPC access.

Suggested review description:

> Mute Cue is a local Windows overlay. With explicit user consent, it reads only the signed-in user's current self-mute and self-deafen state through Discord's local RPC connection. It does not read messages, servers, contacts, or voice data, and it does not send Discord data to a Mute Cue service.

## Native release build

The approved public application ID is injected into the installer payload:

```powershell
.\Overlay\Build-MuteCueExeRelease.ps1 -DiscordApplicationId <application-id> -OutputDirectory .\artifacts\release
```

The source-tree configuration intentionally has no production application ID. For local Dev testing, copy `Overlay/MuteCue.DiscordPublicClient.local.example.json` to the ignored `Overlay/MuteCue.DiscordPublicClient.local.json` and replace its placeholder with a tester-enabled application ID.

Do not add a client secret. OAuth uses PKCE and the loopback redirect.

## GitHub environment

Tagged releases are published by `.github/workflows/publish-release.yml`. Configure the protected `production` environment with:

- `MUTE_CUE_DISCORD_APPLICATION_ID`: the approved public-client application ID

The workflow rejects a version mismatch, an invalid application ID, a tag outside `main`, a legacy PowerShell payload, and an installer that fails its exact-artifact smoke test. It publishes the versioned installer and SHA-256 checksum.

## Privacy copy

> When you choose Connect Discord, Mute Cue asks Discord for permission to read your current self-mute and self-deafen state. The authorization is encrypted for your current Windows account and used only to display the overlay. Mute Cue does not collect or transmit Discord messages, server information, contacts, or voice audio. Disconnect stops monitoring, and Forget authorization deletes Mute Cue's saved local authorization.
