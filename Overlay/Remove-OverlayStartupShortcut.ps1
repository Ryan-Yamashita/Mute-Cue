$ErrorActionPreference = "Stop"
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $scriptDir "MuteCue.Startup.ps1")
$targetPath = Join-Path $scriptDir "Start Beacn Mute Overlay Hidden.vbs"
$before = Get-MuteCueStartupRegistration -LauncherPath $targetPath
$after = Disable-MuteCueStartupRegistration -LauncherPath $targetPath
if ($before.IsEnabled -and -not $after.Exists) {
    Write-Host "Removed startup shortcut:"
    Write-Host $before.ShortcutPath
} else {
    Write-Host "No owned Mute Cue startup shortcut was found."
}

Read-Host "Press Enter to close"
