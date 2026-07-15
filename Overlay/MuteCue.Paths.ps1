function Get-MuteCueDataPaths {
    param(
        [string]$Root = $(Join-Path $env:LOCALAPPDATA "MuteCue")
    )

    $resolvedRoot = [System.IO.Path]::GetFullPath($Root)
    $settingsDirectory = Join-Path $resolvedRoot "Settings"
    $credentialsDirectory = Join-Path $resolvedRoot "Credentials"
    $logsDirectory = Join-Path $resolvedRoot "Logs"
    $runtimeDirectory = Join-Path $resolvedRoot "Runtime"

    [pscustomobject]@{
        Root = $resolvedRoot
        SettingsDirectory = $settingsDirectory
        CredentialsDirectory = $credentialsDirectory
        LogsDirectory = $logsDirectory
        RuntimeDirectory = $runtimeDirectory
        SettingsPath = Join-Path $settingsDirectory "settings.json"
        SettingsBackupPath = Join-Path $settingsDirectory "settings.json.bak"
        DiscordSecretPath = Join-Path $credentialsDirectory "discord-client-secret.dat"
        DiscordAuthorizationPath = Join-Path $credentialsDirectory "discord-authorization.dat"
        DiagnosticPath = Join-Path $logsDirectory "mute-cue.log"
        BeacnStateLogPath = Join-Path $logsDirectory "beacn-state.log"
        LockPath = Join-Path $runtimeDirectory "mute-cue.lock"
        MigrationMarkerPath = Join-Path $resolvedRoot "legacy-migration-v1.json"
    }
}

function Initialize-MuteCueDataPaths {
    param(
        [Parameter(Mandatory)][object]$Paths,
        [string]$LegacyDirectory = ""
    )

    foreach ($directory in @(
        $Paths.Root,
        $Paths.SettingsDirectory,
        $Paths.CredentialsDirectory,
        $Paths.LogsDirectory,
        $Paths.RuntimeDirectory
    )) {
        if (-not [System.IO.Directory]::Exists([string]$directory)) {
            [void][System.IO.Directory]::CreateDirectory([string]$directory)
        }
    }

    $copied = New-Object 'System.Collections.Generic.List[string]'
    $skipped = New-Object 'System.Collections.Generic.List[string]'
    if (
        -not [string]::IsNullOrWhiteSpace($LegacyDirectory) -and
        [System.IO.Directory]::Exists($LegacyDirectory) -and
        -not [System.IO.File]::Exists([string]$Paths.MigrationMarkerPath)
    ) {
        $migrations = @(
            @{ Source = "settings.json"; Destination = [string]$Paths.SettingsPath },
            @{ Source = "settings.json.bak"; Destination = [string]$Paths.SettingsBackupPath },
            @{ Source = ".discord-client-secret.dat"; Destination = [string]$Paths.DiscordSecretPath },
            @{ Source = ".discord-authorization.dat"; Destination = [string]$Paths.DiscordAuthorizationPath },
            @{ Source = ".mute-cue-error.log"; Destination = [string]$Paths.DiagnosticPath },
            @{ Source = ".beacn-live-state.log"; Destination = [string]$Paths.BeacnStateLogPath }
        )
        foreach ($migration in $migrations) {
            $sourcePath = Join-Path $LegacyDirectory ([string]$migration.Source)
            $destinationPath = [string]$migration.Destination
            if (-not [System.IO.File]::Exists($sourcePath)) { continue }
            if ([System.IO.File]::Exists($destinationPath)) {
                [void]$skipped.Add([System.IO.Path]::GetFileName($destinationPath))
                continue
            }
            [System.IO.File]::Copy($sourcePath, $destinationPath, $false)
            [void]$copied.Add([System.IO.Path]::GetFileName($destinationPath))
        }

        $marker = [ordered]@{
            SchemaVersion = 1
            MigratedAtUtc = [DateTime]::UtcNow.ToString("o")
            LegacyDirectory = [System.IO.Path]::GetFullPath($LegacyDirectory)
            Copied = @($copied.ToArray())
            ExistingDestinations = @($skipped.ToArray())
        } | ConvertTo-Json -Depth 4
        $temporaryMarker = [string]$Paths.MigrationMarkerPath + ".tmp"
        [System.IO.File]::WriteAllText($temporaryMarker, $marker, (New-Object System.Text.UTF8Encoding($false)))
        [System.IO.File]::Move($temporaryMarker, [string]$Paths.MigrationMarkerPath)
    }

    [pscustomobject]@{
        Paths = $Paths
        Copied = @($copied.ToArray())
        ExistingDestinations = @($skipped.ToArray())
    }
}
