$ErrorActionPreference = "Stop"
$overlayDirectory = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
. (Join-Path $overlayDirectory "MuteCue.Signing.ps1")

function Assert-Signing {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

$invalidThumbprintRejected = $false
try { [void](Get-MuteCueCodeSigningCertificate -Thumbprint "not-a-thumbprint") } catch {
    $invalidThumbprintRejected = $_.Exception.Message -match "thumbprint is invalid"
}
Assert-Signing $invalidThumbprintRejected "An invalid certificate thumbprint must be rejected before certificate-store access."

$readiness = Get-MuteCueSigningReadiness -MinimumRemainingDays 30
Assert-Signing ($null -ne $readiness -and $null -ne $readiness.Certificates) "Signing readiness must always return a bounded report."

$unsignedPath = Join-Path ([IO.Path]::GetTempPath()) ("MuteCue.Signing.Tests.{0}.ps1" -f [Guid]::NewGuid().ToString("N"))
try {
    [IO.File]::WriteAllText($unsignedPath, "'test'", (New-Object Text.UTF8Encoding($false)))
    $unsigned = Test-MuteCueAuthenticodeSignature -Path $unsignedPath -ExpectedSignerThumbprint ("0" * 40)
    Assert-Signing (-not $unsigned.IsValid -and $unsigned.Status -in @("NotSigned", "UnknownError")) "An unsigned file must not validate as a release signature."
} finally {
    if ([IO.File]::Exists($unsignedPath)) { Remove-Item -LiteralPath $unsignedPath -Force }
}

"Signing tests: PASS"
