# Local Mute Cue development

Local testing does not use an installer or require a GitHub upload. Double-click
`Build and Launch Mute Cue Dev.cmd` in the repository root. It:

1. asks an existing Mute Cue Dev instance to shut down cleanly;
2. publishes the current source into a temporary staging directory;
3. verifies the payload has no legacy Runtime directory or PowerShell files;
4. replaces the fixed `artifacts\dev\MuteCue-Dev.exe`; and
5. launches that executable.

If compilation fails, the staging directory is removed and the last working Dev
EXE is preserved.

## Dev and Stable isolation

The distinction is compiled into the binary rather than inferred from its file
location.

| Concern | Stable | Dev |
| --- | --- | --- |
| Executable | `MuteCue.exe` | `MuteCue-Dev.exe` |
| User data | `%LOCALAPPDATA%\MuteCue` | `%LOCALAPPDATA%\MuteCue-Dev` |
| Single-instance identity | Stable channel | Dev channel |
| Run on startup | Available | Disabled |
| Build output | Installer/release flow | Fixed local folder, overwritten |

On its first launch, Dev copies the existing Stable settings and encrypted
Discord authorization if they exist. Each destination is copied only when its
Dev file is missing. After that first copy, the files are independent, so
changing or forgetting authorization in Dev cannot change Stable.

When the ignored `Overlay\MuteCue.DiscordPublicClient.local.json` exists, the
Dev builder places that public client configuration beside the Dev EXE. The
file remains local and is never added to Git.

Stable and Dev can technically run together, but close Stable while testing
overlay behavior to avoid seeing two overlays monitoring the same applications.

## Normal workflow

1. Edit the source locally or pull source changes from GitHub.
2. Double-click `Build and Launch Mute Cue Dev.cmd`.
3. Test Mute Cue Dev.
4. Repeat until the change is ready.
5. Build an installer only for an intentional Stable release.

The `artifacts` directory is ignored by Git. Dev binaries are local build output
and should not be committed or uploaded.
