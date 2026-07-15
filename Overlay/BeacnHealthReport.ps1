function Get-BeacnHealthReport {
    param(
        [Parameter(Mandatory)][object]$Coordinator,
        [AllowNull()][object]$Client,
        [AllowNull()][object]$Telemetry,
        [AllowNull()][object[]]$States,
        [bool]$HasAuthority,
        [bool]$HasActionAuthority,
        [AllowNull()][object]$Readiness,
        [string]$UsbStatus,
        [long]$UsbDroppedPackets = 0,
        [DateTime]$Now = [DateTime]::UtcNow
    )

    $workerRunning = $false
    if ($null -ne $Client) {
        try { $workerRunning = Test-BeacnAccessibilityClientRunning -Client $Client } catch {}
    }
    $health = Get-BeacnCoordinatorHealth -Coordinator $Coordinator -WorkerRunning $workerRunning -Now $Now
    $lines = New-Object 'System.Collections.Generic.List[string]'
    [void]$lines.Add("Mute Cue BEACN diagnostics")
    [void]$lines.Add(("Generated: {0:o}" -f $Now))
    [void]$lines.Add(("Health: {0}" -f $health.Status))
    [void]$lines.Add(("State authority: {0}; action authority: {1}" -f [int]$HasAuthority, [int]$HasActionAuthority))
    if ($null -ne $Readiness) {
        foreach ($readinessLine in @((Format-MuteCueReadinessReport -Readiness $Readiness) -split "`r?`n")) {
            [void]$lines.Add($readinessLine)
        }
    }
    [void]$lines.Add(("BEACN version: {0}" -f $(if ($null -ne $Telemetry) { [string]$Telemetry.BeacnVersion } else { "unknown" })))
    [void]$lines.Add(("Compatibility profile: {0}; verified: {1}" -f $(if ($null -ne $Telemetry) { [string]$Telemetry.CompatibilityProfile } else { "unknown" }), $(if ($null -ne $Telemetry) { [int][bool]$Telemetry.CompatibilityProfileVerified } else { 0 })))
    [void]$lines.Add(("Scanner: {0} - {1}" -f $(if ($null -ne $Telemetry) { [string]$Telemetry.ScannerStatus } else { "Unavailable" }), $(if ($null -ne $Telemetry) { [string]$Telemetry.ScannerDetail } else { "No worker snapshot." })))
    $runtimeMode = if ($null -ne $Telemetry -and $null -ne $Telemetry.PSObject.Properties["AccessibilityRuntimeMode"]) { [string]$Telemetry.AccessibilityRuntimeMode } else { "NotReported" }
    $runtimeVersion = if ($null -ne $Telemetry -and $null -ne $Telemetry.PSObject.Properties["AccessibilityRuntimeVersion"]) { [string]$Telemetry.AccessibilityRuntimeVersion } else { "unknown" }
    $runtimeIntegrity = if ($null -ne $Telemetry -and $null -ne $Telemetry.PSObject.Properties["AccessibilityRuntimeIntegrityVerified"]) { [int][bool]$Telemetry.AccessibilityRuntimeIntegrityVerified } else { 0 }
    [void]$lines.Add(("Accessibility runtime: mode={0}; version={1}; integrity={2}" -f $runtimeMode, $runtimeVersion, $runtimeIntegrity))
    [void]$lines.Add(("Worker running: {0}; worker generation: {1}; restarts: {2}" -f [int]$workerRunning, $health.WorkerGeneration, $(if ($null -ne $Client) { [long]$Client.RestartCount } else { 0 })))
    [void]$lines.Add(("Heartbeat age: {0:N2}s; authority age: {1:N2}s" -f $health.HeartbeatAgeSeconds, $health.AuthorityAgeSeconds))
    [void]$lines.Add(("Layout generation: {0}; geometry generation: {1}" -f $health.LayoutGeneration, $health.GeometryGeneration))
    [void]$lines.Add(("Rejected worker snapshots: {0}; last rejection: {1}" -f $health.RejectedSnapshots, $(if ([string]::IsNullOrWhiteSpace($health.LastRejection)) { "none" } else { $health.LastRejection })))
    [void]$lines.Add(("Last scanner duration: {0:N1}ms" -f $(if ($null -ne $Telemetry) { [double]$Telemetry.LastScanMilliseconds } else { 0 })))
    [void]$lines.Add(("USB: {0}; dropped packets: {1}" -f $UsbStatus, $UsbDroppedPackets))
    [void]$lines.Add(("Faders ({0}):" -f @($States).Count))
    foreach ($state in @($States | Sort-Object Order)) {
        [void]$lines.Add((
            "  {0}. {1} [{2}] All={3} Audience={4} Known={5} Locked={6}" -f `
                [int]$state.Order, `
                [string]$state.Name, `
                [string]$state.StableKey, `
                [int][bool]$state.AllActive, `
                [int][bool]$state.AudienceActive, `
                [int][bool]$state.ActionStateKnown, `
                [int][bool]$state.IsLocked
        ))
    }
    return @($lines.ToArray()) -join [Environment]::NewLine
}
