$ErrorActionPreference = "Stop"
$overlayDirectory = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
. (Join-Path $overlayDirectory "MuteCue.Paths.ps1")

function Assert-Paths {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

$temporaryRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("MuteCue.Paths.Tests.{0}" -f [Guid]::NewGuid().ToString("N"))
$legacyDirectory = Join-Path $temporaryRoot "legacy"
$dataRoot = Join-Path $temporaryRoot "data"
try {
    [void](New-Item -ItemType Directory -Path $legacyDirectory -Force)
    [System.IO.File]::WriteAllText((Join-Path $legacyDirectory "settings.json"), '{"SchemaVersion":3}')
    [System.IO.File]::WriteAllText((Join-Path $legacyDirectory ".discord-client-secret.dat"), 'encrypted-secret')
    [System.IO.File]::WriteAllText((Join-Path $legacyDirectory ".mute-cue-error.log"), 'legacy-log')

    $paths = Get-MuteCueDataPaths -Root $dataRoot
    $result = Initialize-MuteCueDataPaths -Paths $paths -LegacyDirectory $legacyDirectory

    foreach ($directory in @($paths.Root, $paths.SettingsDirectory, $paths.CredentialsDirectory, $paths.LogsDirectory, $paths.RuntimeDirectory)) {
        Assert-Paths ([System.IO.Directory]::Exists([string]$directory)) "Expected per-user data directory '$directory'."
    }
    Assert-Paths ([System.IO.File]::Exists([string]$paths.SettingsPath)) "Legacy settings were not migrated."
    Assert-Paths ([System.IO.File]::Exists([string]$paths.DiscordSecretPath)) "Legacy credentials were not migrated."
    Assert-Paths ([System.IO.File]::Exists([string]$paths.DiagnosticPath)) "Legacy diagnostics were not migrated."
    Assert-Paths ([System.IO.File]::Exists([string]$paths.MigrationMarkerPath)) "Migration marker was not committed."
    Assert-Paths (@($result.Copied).Count -eq 3) "Migration did not report every copied file."

    [System.IO.File]::WriteAllText((Join-Path $legacyDirectory "settings.json"), '{"SchemaVersion":999}')
    [void](Initialize-MuteCueDataPaths -Paths $paths -LegacyDirectory $legacyDirectory)
    $persisted = [System.IO.File]::ReadAllText([string]$paths.SettingsPath)
    Assert-Paths ($persisted -eq '{"SchemaVersion":3}') "A later launch overwrote migrated user settings."
} finally {
    if (Test-Path -LiteralPath $temporaryRoot) { Remove-Item -LiteralPath $temporaryRoot -Recurse -Force }
}

"Path and migration tests: PASS"
