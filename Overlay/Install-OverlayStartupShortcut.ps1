$ErrorActionPreference = "Stop"
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$targetPath = Join-Path $scriptDir "Start Beacn Mute Overlay Hidden.vbs"
. (Join-Path $scriptDir "MuteCue.Startup.ps1")

if (-not (Test-Path -LiteralPath $targetPath)) { throw "Mute Cue launcher was not found at '$targetPath'." }
$registration = Enable-MuteCueStartupRegistration -LauncherPath $targetPath

Write-Host "Installed startup shortcut:"
Write-Host $registration.ShortcutPath
Write-Host ""
Write-Host "Mute Cue will start with your normal Windows permissions after you sign in."
Read-Host "Press Enter to close"
