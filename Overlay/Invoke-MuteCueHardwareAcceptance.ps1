param(
    [ValidateSet("Quick", "Full")][string]$Scope = "Full",
    [switch]$DiscoveryOnly,
    [switch]$SkipMovement,
    [ValidateRange(3, 30)][int]$ActionTimeoutSeconds = 10
)

$ErrorActionPreference = "Stop"
$overlayDirectory = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $overlayDirectory "MuteCue.Paths.ps1")
. (Join-Path $overlayDirectory "BeacnAccessibilityClient.ps1")

function Wait-MuteCueAcceptanceSnapshot {
    param(
        [Parameter(Mandatory)][object]$Client,
        [Parameter(Mandatory)][scriptblock]$Condition,
        [ValidateRange(1, 60)][int]$TimeoutSeconds
    )
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    $latest = $null
    while ([DateTime]::UtcNow -lt $deadline) {
        [void](Update-BeacnAccessibilityClientWatchdog -Client $Client -HeartbeatTimeoutSeconds 3)
        $snapshot = Receive-BeacnAccessibilitySnapshot -Client $Client
        if ($null -ne $snapshot) {
            $latest = $snapshot
            if (& $Condition $snapshot) { return $snapshot }
        }
        Start-Sleep -Milliseconds 40
    }
    return $null
}

function Get-MuteCueAcceptanceFader {
    param([Parameter(Mandatory)][object]$Snapshot, [Parameter(Mandatory)][string]$Name)
    return @($Snapshot.States | Where-Object { [string]$_.Name -eq $Name } | Select-Object -First 1)[0]
}

function Get-MuteCueAcceptanceStateValue {
    param(
        [Parameter(Mandatory)][object]$Snapshot,
        [Parameter(Mandatory)][string]$Name,
        [ValidateSet("All", "Audience")][string]$Mode
    )
    $fader = Get-MuteCueAcceptanceFader -Snapshot $Snapshot -Name $Name
    if ($null -eq $fader) { return $null }
    return [bool]$(if ($Mode -eq "All") { $fader.AllActionActive } else { $fader.AudienceActionActive })
}

$paths = Get-MuteCueDataPaths
[void](Initialize-MuteCueDataPaths -Paths $paths -LegacyDirectory $overlayDirectory)
$acceptanceDirectory = Join-Path ([string]$paths.Root) "Acceptance"
if (-not [IO.Directory]::Exists($acceptanceDirectory)) { [void][IO.Directory]::CreateDirectory($acceptanceDirectory) }
$reportPath = Join-Path $acceptanceDirectory ("hardware-acceptance-{0}.json" -f [DateTime]::UtcNow.ToString("yyyyMMdd-HHmmss"))
$runtimeRoot = Join-Path ([string]$paths.RuntimeDirectory) ("acceptance-{0}" -f [Guid]::NewGuid().ToString("N"))
$client = New-BeacnAccessibilityClient -OverlayDirectory $overlayDirectory -RuntimeRoot $runtimeRoot
$results = New-Object 'System.Collections.Generic.List[object]'
$startedAt = [DateTime]::UtcNow
$report = [ordered]@{
    SchemaVersion = 1
    StartedAtUtc = $startedAt.ToString("o")
    CompletedAtUtc = ""
    Scope = $(if ($DiscoveryOnly) { "DiscoveryOnly" } else { $Scope })
    Passed = $false
    DiscoveryMilliseconds = 0
    DiscoveryBudgetMilliseconds = 30000
    RuntimeMode = ""
    RuntimeVersion = ""
    RuntimeIntegrityVerified = $false
    ScannerStatus = ""
    BeacnVersion = ""
    CompatibilityProfile = ""
    DiagnosticSummary = ""
    LastScanMilliseconds = 0
    DiscoveryGeneration = 0
    NativeGeometryGeneration = 0
    Faders = @()
    Results = @()
    ReportPath = $reportPath
}

try {
    Write-Output "Starting an isolated, read-only Mute Cue observer..."
    $discoveryTimer = [Diagnostics.Stopwatch]::StartNew()
    if (-not (Start-BeacnAccessibilityClient -Client $client)) { throw "The isolated BEACN observer could not start." }
    $baseline = Wait-MuteCueAcceptanceSnapshot -Client $client -TimeoutSeconds 45 -Condition {
        param($snapshot)
        @($snapshot.States).Count -gt 0 -and [string]$snapshot.ScannerStatus -eq "Ready"
    }
    $discoveryTimer.Stop()
    if ($null -eq $baseline) { throw "BEACN did not publish an authoritative fader layout within 45 seconds." }

    $report.DiscoveryMilliseconds = [Math]::Round($discoveryTimer.Elapsed.TotalMilliseconds, 1)
    $report.RuntimeMode = [string]$baseline.AccessibilityRuntimeMode
    $report.RuntimeVersion = [string]$baseline.AccessibilityRuntimeVersion
    $report.RuntimeIntegrityVerified = [bool]$baseline.AccessibilityRuntimeIntegrityVerified
    $report.ScannerStatus = [string]$baseline.ScannerStatus
    $report.BeacnVersion = [string]$baseline.BeacnVersion
    $report.CompatibilityProfile = [string]$baseline.CompatibilityProfile
    $report.DiagnosticSummary = [string]$baseline.DiagnosticSummary
    $report.LastScanMilliseconds = [Math]::Round([double]$baseline.LastScanMilliseconds, 1)
    $report.DiscoveryGeneration = [int]$baseline.DiscoveryGeneration
    $report.NativeGeometryGeneration = [long]$baseline.NativeGeometryGeneration
    $report.Faders = @($baseline.States | Sort-Object Order | ForEach-Object {
        [ordered]@{
            Order = [int]$_.Order
            Name = [string]$_.Name
            Locked = [bool]$_.IsLocked
            All = [bool]$_.AllActionActive
            Audience = [bool]$_.AudienceActionActive
        }
    })
    Write-Output ("Detected {0} faders in authoritative order: {1}" -f @($report.Faders).Count, (@($report.Faders | ForEach-Object Name) -join ", "))
    Write-Output ("Runtime {0} {1}; integrity={2}; discovery={3:N0} ms" -f $report.RuntimeMode, $report.RuntimeVersion, [int]$report.RuntimeIntegrityVerified, $report.DiscoveryMilliseconds)

    if ($DiscoveryOnly) {
        $report.Passed = (
            $report.RuntimeMode -eq "Precompiled" -and
            $report.RuntimeIntegrityVerified -and
            @($report.Faders).Count -gt 0 -and
            $report.DiscoveryMilliseconds -le $report.DiscoveryBudgetMilliseconds
        )
    } else {
        $testFaders = @($report.Faders)
        if ($Scope -eq "Quick") { $testFaders = @($testFaders | Select-Object -First ([Math]::Min(4, $testFaders.Count))) }
        $pathsToTest = @(
            [pscustomobject]@{ Name = "Mix Create knob - Mute to All"; Mode = "All" },
            [pscustomobject]@{ Name = "BEACN desktop - Mute to All"; Mode = "All" },
            [pscustomobject]@{ Name = "Mix Create button - Mute to Audience"; Mode = "Audience" },
            [pscustomobject]@{ Name = "BEACN desktop - Mute to Audience"; Mode = "Audience" }
        )
        Write-Output "Each test toggles a state once, observes it, then asks you to restore it. No result is inferred from the button press itself."
        foreach ($fader in $testFaders) {
            foreach ($inputPath in $pathsToTest) {
                $latest = Wait-MuteCueAcceptanceSnapshot -Client $client -TimeoutSeconds 3 -Condition { param($snapshot) $true }
                if ($null -eq $latest) { $latest = $baseline }
                $before = Get-MuteCueAcceptanceStateValue -Snapshot $latest -Name $fader.Name -Mode $inputPath.Mode
                [void](Read-Host ("Press Enter, then immediately toggle '{0}' using {1}" -f $fader.Name, $inputPath.Name))
                $actionTimer = [Diagnostics.Stopwatch]::StartNew()
                $changed = Wait-MuteCueAcceptanceSnapshot -Client $client -TimeoutSeconds $ActionTimeoutSeconds -Condition {
                    param($snapshot)
                    $value = Get-MuteCueAcceptanceStateValue -Snapshot $snapshot -Name $fader.Name -Mode $inputPath.Mode
                    $null -ne $value -and $value -ne $before
                }
                $actionTimer.Stop()
                $changedPassed = $null -ne $changed
                $restoredPassed = $false
                if ($changedPassed) {
                    [void](Read-Host ("Observed in {0:N0} ms. Press Enter, then toggle it again to restore the starting state" -f $actionTimer.Elapsed.TotalMilliseconds))
                    $restored = Wait-MuteCueAcceptanceSnapshot -Client $client -TimeoutSeconds $ActionTimeoutSeconds -Condition {
                        param($snapshot)
                        $value = Get-MuteCueAcceptanceStateValue -Snapshot $snapshot -Name $fader.Name -Mode $inputPath.Mode
                        $null -ne $value -and $value -eq $before
                    }
                    $restoredPassed = $null -ne $restored
                }
                [void]$results.Add([ordered]@{
                    Type = "Action"
                    Fader = [string]$fader.Name
                    InputPath = [string]$inputPath.Name
                    Mode = [string]$inputPath.Mode
                    Changed = $changedPassed
                    Restored = $restoredPassed
                    ObservedMilliseconds = [Math]::Round($actionTimer.Elapsed.TotalMilliseconds, 1)
                    Passed = $changedPassed -and $restoredPassed
                })
                Write-Output $(if ($changedPassed -and $restoredPassed) { "PASS" } else { "FAILED - restore the fader manually before continuing" })
            }
        }

        if (-not $SkipMovement) {
            $beforeGeneration = [long]$baseline.NativeGeometryGeneration
            $beforeSignature = @($baseline.States | Sort-Object Order | ForEach-Object { "{0}:{1}:{2}" -f $_.Name, [int][bool]$_.AllActionActive, [int][bool]$_.AudienceActionActive }) -join '|'
            [void](Read-Host "Press Enter, move the BEACN window to another monitor, wait for it to settle, then press Enter again")
            $movement = Wait-MuteCueAcceptanceSnapshot -Client $client -TimeoutSeconds 15 -Condition {
                param($snapshot)
                [long]$snapshot.NativeGeometryGeneration -gt $beforeGeneration -and -not [bool]$snapshot.GeometryRefreshInProgress
            }
            $afterSignature = if ($null -ne $movement) { @($movement.States | Sort-Object Order | ForEach-Object { "{0}:{1}:{2}" -f $_.Name, [int][bool]$_.AllActionActive, [int][bool]$_.AudienceActionActive }) -join '|' } else { "" }
            [void]$results.Add([ordered]@{
                Type = "Movement"
                GeometryChanged = $null -ne $movement
                StatePreserved = $null -ne $movement -and $afterSignature -eq $beforeSignature
                Passed = $null -ne $movement -and $afterSignature -eq $beforeSignature
            })
        }
        $report.Passed = @($results | Where-Object { -not [bool]$_.Passed }).Count -eq 0
    }
} catch {
    [void]$results.Add([ordered]@{ Type = "Fatal"; Passed = $false; Detail = $_.Exception.Message })
    $report.Passed = $false
    Write-Output ("FAILED: {0}" -f $_.Exception.Message)
} finally {
    $report.CompletedAtUtc = [DateTime]::UtcNow.ToString("o")
    $report.Results = @($results.ToArray())
    [IO.File]::WriteAllText($reportPath, ($report | ConvertTo-Json -Depth 8), (New-Object Text.UTF8Encoding($false)))
    Stop-BeacnAccessibilityClient -Client $client
    if ([IO.Directory]::Exists($runtimeRoot)) { Remove-Item -LiteralPath $runtimeRoot -Recurse -Force -ErrorAction SilentlyContinue }
    Write-Output ("Acceptance report: {0}" -f $reportPath)
    Write-Output $(if ($report.Passed) { "Mute Cue hardware acceptance: PASS" } else { "Mute Cue hardware acceptance: ATTENTION NEEDED" })
}
