param([ValidateRange(0, 3650)][int]$MinimumRemainingDays = 30)

$ErrorActionPreference = "Stop"
$overlayDirectory = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $overlayDirectory "MuteCue.Signing.ps1")
$readiness = Get-MuteCueSigningReadiness -MinimumRemainingDays $MinimumRemainingDays
Write-Output $readiness.Summary
foreach ($certificate in @($readiness.Certificates)) {
    Write-Output ("{0} | expires {1:yyyy-MM-dd} | ready={2} | {3}" -f $certificate.Subject, $certificate.NotAfter, [int][bool]$certificate.Ready, $certificate.Detail)
}
if (-not $readiness.Ready) {
    Write-Output "A public build remains blocked until a trusted code-signing certificate with an accessible private key is installed in CurrentUser\My."
}
