$ErrorActionPreference = "Stop"
$overlayDirectory = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
. (Join-Path $overlayDirectory "MuteCue.Readiness.ps1")

function Assert-Readiness {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

$staticReady = [pscustomobject]@{
    PlatformReady = $true
    PowerShellReady = $true
    PowerShellVersion = "5.1"
    DotNetReady = $true
    DotNetRelease = 528040
    DataWritable = $true
    DataRoot = "C:\Users\Test\AppData\Local\MuteCue"
    IsElevated = $false
    BaseReady = $true
}
$verifiedTelemetry = [pscustomobject]@{
    ScannerStatus = "Ready"
    BeacnVersion = "1.2.62"
    CompatibilityProfile = "beacn-1.2"
    CompatibilityProfileVerified = $true
    AccessibilityRuntimeMode = "Precompiled"
    AccessibilityRuntimeVersion = "0.5.0.0"
    AccessibilityRuntimeIntegrityVerified = $true
}

$ready = Get-MuteCueBeacnReadiness -StaticReadiness $staticReady -Telemetry $verifiedTelemetry -FaderCount 7 -HasAuthority $true -HasActionAuthority $true -UsbAvailable $true -UsbActive $true
Assert-Readiness ($ready.Status -eq "Ready" -and $ready.CanMonitor) "A verified authoritative provider must be release-ready."

$unverifiedTelemetry = $verifiedTelemetry.PSObject.Copy()
$unverifiedTelemetry.CompatibilityProfile = "structural-fallback"
$unverifiedTelemetry.CompatibilityProfileVerified = $false
$unverified = Get-MuteCueBeacnReadiness -StaticReadiness $staticReady -Telemetry $unverifiedTelemetry -FaderCount 7 -HasAuthority $true -HasActionAuthority $true -UsbAvailable $false -UsbActive $false
Assert-Readiness ($unverified.Status -eq "Unverified" -and $unverified.CanMonitor) "A structurally compatible future version must work with a visible warning."

$limited = Get-MuteCueBeacnReadiness -StaticReadiness $staticReady -Telemetry $verifiedTelemetry -FaderCount 7 -HasAuthority $true -HasActionAuthority $false -UsbAvailable $false -UsbActive $false
Assert-Readiness ($limited.Status -eq "Limited" -and -not $limited.CanMonitor) "Missing independent action rows must fail closed."

$invalidRuntimeTelemetry = $verifiedTelemetry.PSObject.Copy()
$invalidRuntimeTelemetry.AccessibilityRuntimeIntegrityVerified = $false
$componentBlocked = Get-MuteCueBeacnReadiness -StaticReadiness $staticReady -Telemetry $invalidRuntimeTelemetry -FaderCount 7 -HasAuthority $true -HasActionAuthority $true -UsbAvailable $true -UsbActive $true
Assert-Readiness ($componentBlocked.Status -eq "ComponentIssue" -and -not $componentBlocked.CanMonitor) "An invalid accessibility component must block monitoring."

$staticBlocked = $staticReady.PSObject.Copy()
$staticBlocked.DataWritable = $false
$staticBlocked.BaseReady = $false
$blocked = Get-MuteCueBeacnReadiness -StaticReadiness $staticBlocked -Telemetry $verifiedTelemetry -FaderCount 7 -HasAuthority $true -HasActionAuthority $true -UsbAvailable $true -UsbActive $true
Assert-Readiness ($blocked.Status -eq "EnvironmentIssue" -and -not $blocked.CanMonitor) "An unwritable per-user data directory must block readiness."

$report = Format-MuteCueReadinessReport -Readiness $ready
Assert-Readiness ($report.Contains("Readiness: Ready") -and $report.Contains("normal user")) "The readiness report must explain the verified environment."

$statusState = New-MuteCueBeacnStatusPresentationState
$statusStart = [DateTime]::Parse("2026-07-14T20:00:00Z").ToUniversalTime()
$presentedReady = Update-MuteCueBeacnStatusPresentation `
    -State $statusState `
    -RawPhase Ready `
    -RawPrimary "Ready - Fast hardware response active" `
    -RawDetail "7 faders synchronized" `
    -EverReady $true `
    -Now $statusStart
Assert-Readiness ($presentedReady.VisiblePhase -eq "Ready") "A healthy connection must display Ready immediately."

$briefConfirmation = Update-MuteCueBeacnStatusPresentation `
    -State $statusState `
    -RawPhase Resyncing `
    -RawPrimary "Resyncing - Verifying the latest BEACN state" `
    -RawDetail "0 faders currently reported" `
    -EverReady $true `
    -Now $statusStart.AddMilliseconds(160)
Assert-Readiness (
    $briefConfirmation.VisiblePhase -eq "Ready" -and
    $briefConfirmation.VisiblePrimary -eq "Ready - Fast hardware response active" -and
    $briefConfirmation.VisibleDetail -eq "7 faders synchronized" -and
    $briefConfirmation.ResyncDelayed
) "A routine hardware confirmation must not flash the Ready card amber."

$stillBrief = Update-MuteCueBeacnStatusPresentation `
    -State $statusState `
    -RawPhase Resyncing `
    -EverReady $true `
    -Now $statusStart.AddMilliseconds(1159)
Assert-Readiness ($stillBrief.VisiblePhase -eq "Ready") "Recovery presentation must remain calm before the one-second threshold."

$sustainedRecovery = Update-MuteCueBeacnStatusPresentation `
    -State $statusState `
    -RawPhase Resyncing `
    -EverReady $true `
    -Now $statusStart.AddMilliseconds(1160)
Assert-Readiness ($sustainedRecovery.VisiblePhase -eq "Resyncing") "A recovery lasting one second must remain visibly Resyncing."

$recovered = Update-MuteCueBeacnStatusPresentation `
    -State $statusState `
    -RawPhase Ready `
    -EverReady $true `
    -Now $statusStart.AddMilliseconds(1200)
Assert-Readiness ($recovered.VisiblePhase -eq "Ready") "Recovery completion must return to Ready immediately."

$newCandidate = Update-MuteCueBeacnStatusPresentation `
    -State $statusState `
    -RawPhase Resyncing `
    -EverReady $true `
    -Now $statusStart.AddMilliseconds(1300)
Assert-Readiness ($newCandidate.VisiblePhase -eq "Ready") "A completed recovery must reset the presentation timer."

$hardFailure = Update-MuteCueBeacnStatusPresentation `
    -State $statusState `
    -RawPhase Unavailable `
    -EverReady $true `
    -Now $statusStart.AddMilliseconds(1350)
Assert-Readiness ($hardFailure.VisiblePhase -eq "Unavailable") "Unavailable must bypass the Ready grace period."

$troubleState = New-MuteCueBeacnStatusPresentationState
$lateSession = [DateTime]::Parse("2026-07-15T08:00:00Z").ToUniversalTime()
$newOutage = Update-MuteCueBeacnProviderTrouble `
    -State $troubleState `
    -TroubleDetected $true `
    -Now $lateSession
Assert-Readiness (-not $newOutage.IsUnavailable) "A fresh worker outage must not inherit the application's age."

$recoveringOutage = Update-MuteCueBeacnProviderTrouble `
    -State $troubleState `
    -TroubleDetected $true `
    -Now $lateSession.AddMilliseconds(14999)
Assert-Readiness (-not $recoveringOutage.IsUnavailable) "A worker outage inside its recovery window must remain recoverable."

$unavailableOutage = Update-MuteCueBeacnProviderTrouble `
    -State $troubleState `
    -TroubleDetected $true `
    -Now $lateSession.AddSeconds(15)
Assert-Readiness ($unavailableOutage.IsUnavailable) "A continuous fifteen-second provider outage must become unavailable."

[void](Update-MuteCueBeacnProviderTrouble `
    -State $troubleState `
    -TroubleDetected $false `
    -Now $lateSession.AddSeconds(16))
$secondOutage = Update-MuteCueBeacnProviderTrouble `
    -State $troubleState `
    -TroubleDetected $true `
    -Now $lateSession.AddHours(8)
Assert-Readiness (-not $secondOutage.IsUnavailable) "A healthy interval must reset the provider-outage timer."

"Readiness tests: PASS"
