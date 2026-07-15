param(
    [string]$InstallRoot = $(Join-Path $env:LOCALAPPDATA "Programs\MuteCue"),
    [string]$DataRoot = $(Join-Path $env:LOCALAPPDATA "MuteCue"),
    [string]$StartupDirectory = $([Environment]::GetFolderPath("Startup")),
    [switch]$RemoveUserData
)

$ErrorActionPreference = "Stop"
$resolvedInstallRoot = [System.IO.Path]::GetFullPath($InstallRoot)
$metadataPath = Join-Path $resolvedInstallRoot "install.json"
if (-not [System.IO.File]::Exists($metadataPath)) {
    throw "Mute Cue installation metadata was not found. No files were removed."
}
$metadata = Get-Content -LiteralPath $metadataPath -Raw | ConvertFrom-Json
if ([int]$metadata.SchemaVersion -ne 1 -or [string]$metadata.Product -ne "Mute Cue") {
    throw "The selected directory is not a recognized Mute Cue installation. No files were removed."
}

$startupModule = Join-Path $resolvedInstallRoot "MuteCue.Startup.ps1"
$launcherPath = Join-Path $resolvedInstallRoot "Mute Cue.vbs"
if ([System.IO.File]::Exists($startupModule)) {
    . $startupModule
    $startupState = Get-MuteCueStartupRegistration `
        -LauncherPath $launcherPath `
        -StartupDirectory $StartupDirectory
    if ([bool]$startupState.IsOwned) {
        [void](Disable-MuteCueStartupRegistration `
            -LauncherPath $launcherPath `
            -StartupDirectory $StartupDirectory)
    }
}

Set-Location ([System.IO.Path]::GetTempPath())
Remove-Item -LiteralPath $resolvedInstallRoot -Recurse -Force
if ($RemoveUserData) {
    $resolvedDataRoot = [System.IO.Path]::GetFullPath($DataRoot)
    $dataRootVolume = [System.IO.Path]::GetPathRoot($resolvedDataRoot)
    if (
        [string]::Equals($resolvedDataRoot.TrimEnd('\'), $dataRootVolume.TrimEnd('\'), [StringComparison]::OrdinalIgnoreCase) -or
        -not [System.IO.File]::Exists((Join-Path $resolvedDataRoot "legacy-migration-v1.json"))
    ) { throw "The selected user-data directory is not a recognized Mute Cue data root. It was not removed." }
    if ([System.IO.Directory]::Exists($resolvedDataRoot)) { Remove-Item -LiteralPath $resolvedDataRoot -Recurse -Force }
    Write-Output "Mute Cue and its per-user data were removed."
} else {
    Write-Output "Mute Cue was removed. Per-user settings and credentials were preserved."
}
