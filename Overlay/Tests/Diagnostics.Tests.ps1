$ErrorActionPreference = "Stop"
. (Join-Path (Split-Path -Parent $PSScriptRoot) "MuteCue.Diagnostics.ps1")
. (Join-Path (Split-Path -Parent $PSScriptRoot) "BeacnActionState.ps1")
. (Join-Path (Split-Path -Parent $PSScriptRoot) "BeacnAdapter.ps1")
. (Join-Path (Split-Path -Parent $PSScriptRoot) "BeacnStateCoordinator.ps1")
. (Join-Path (Split-Path -Parent $PSScriptRoot) "BeacnAccessibilityClient.ps1")
. (Join-Path (Split-Path -Parent $PSScriptRoot) "BeacnHealthReport.ps1")

$temporaryDirectory = Join-Path ([System.IO.Path]::GetTempPath()) ("MuteCue-Diagnostics-" + [Guid]::NewGuid().ToString("N"))
[void][System.IO.Directory]::CreateDirectory($temporaryDirectory)
try {
    $path = Join-Path $temporaryDirectory "errors.log"
    Initialize-MuteCueDiagnostics -Path $path -MaximumBytes 64KB
    Write-MuteCueDiagnostic -Level Error -Component "Test" -Message "access_token=do-not-write client_secret:also-private"
    $content = [System.IO.File]::ReadAllText($path)
    if ($content.Contains("do-not-write") -or $content.Contains("also-private")) {
        throw "Diagnostics must redact credential-like values."
    }
    if (-not $content.Contains("[redacted]")) { throw "Diagnostics must mark redacted values." }

    for ($index = 0; $index -lt 90; $index++) {
        Write-MuteCueDiagnostic -Level Warning -Component "Rotation" -Message (("x" * 900) + $index)
    }
    if (-not [System.IO.File]::Exists($path + ".1")) { throw "Diagnostics must rotate a bounded log." }

    $adapter = New-BeacnAdapterState
    $coordinator = New-BeacnStateCoordinator -Adapter $adapter
    $coordinator.LastProviderHeartbeatUtc = [DateTime]::UtcNow
    $report = Get-BeacnHealthReport `
        -Coordinator $coordinator `
        -Client $null `
        -Telemetry ([pscustomobject]@{
            BeacnVersion = "1.2.62"
            CompatibilityProfile = "beacn-1.2"
            CompatibilityProfileVerified = $true
            ScannerStatus = "Ready"
            ScannerDetail = "Test"
            LastScanMilliseconds = 12.5
        }) `
        -States @([pscustomobject]@{
            Order = 0; Name = "Mic"; StableKey = "profile:0"; AllActive = $false
            AudienceActive = $true; ActionStateKnown = $true; IsLocked = $true
        }) `
        -HasAuthority $true `
        -HasActionAuthority $true `
        -UsbStatus "test"
    if (-not $report.Contains("profile:0") -or -not $report.Contains("beacn-1.2")) {
        throw "The BEACN health report must contain stable identity and compatibility data."
    }
    if ($report -match '(?i)token|secret|authorization') {
        throw "The BEACN health report must not expose credential fields."
    }
} finally {
    [System.IO.Directory]::Delete($temporaryDirectory, $true)
}

"Diagnostics tests: PASS"
