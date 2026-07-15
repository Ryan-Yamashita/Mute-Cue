function Test-MuteCueDirectoryWritable {
    param([Parameter(Mandatory)][string]$Path)

    try {
        if (-not [System.IO.Directory]::Exists($Path)) {
            [void][System.IO.Directory]::CreateDirectory($Path)
        }
        $probe = Join-Path $Path (".write-probe-{0}.tmp" -f [Guid]::NewGuid().ToString("N"))
        [System.IO.File]::WriteAllText($probe, "ok", (New-Object System.Text.UTF8Encoding($false)))
        [System.IO.File]::Delete($probe)
        return $true
    } catch {
        return $false
    }
}

function Get-MuteCueStaticReadiness {
    param([Parameter(Mandatory)][object]$Paths)

    $isWindows = [string]$env:OS -eq "Windows_NT"
    $powerShellReady = $PSVersionTable.PSVersion.Major -ge 5
    $dotNetRelease = 0
    try {
        $dotNetRelease = [int](Get-ItemPropertyValue `
            -LiteralPath 'Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full' `
            -Name Release `
            -ErrorAction Stop)
    } catch {}
    $dotNetReady = $dotNetRelease -ge 528040
    $dataWritable = Test-MuteCueDirectoryWritable -Path ([string]$Paths.SettingsDirectory)
    $isElevated = $false
    try {
        $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = New-Object Security.Principal.WindowsPrincipal($identity)
        $isElevated = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch {}

    [pscustomobject]@{
        PlatformReady = $isWindows
        PowerShellReady = $powerShellReady
        PowerShellVersion = [string]$PSVersionTable.PSVersion
        DotNetReady = $dotNetReady
        DotNetRelease = $dotNetRelease
        DataWritable = $dataWritable
        DataRoot = [string]$Paths.Root
        IsElevated = $isElevated
        BaseReady = ($isWindows -and $powerShellReady -and $dotNetReady -and $dataWritable)
    }
}

function Get-MuteCueBeacnReadiness {
    param(
        [Parameter(Mandatory)][object]$StaticReadiness,
        [AllowNull()][object]$Telemetry,
        [int]$FaderCount,
        [bool]$HasAuthority,
        [bool]$HasActionAuthority,
        [bool]$UsbAvailable,
        [bool]$UsbActive
    )

    $scannerStatus = if ($null -ne $Telemetry) { [string]$Telemetry.ScannerStatus } else { "Unavailable" }
    $version = if ($null -ne $Telemetry) { [string]$Telemetry.BeacnVersion } else { "" }
    $profile = if ($null -ne $Telemetry) { [string]$Telemetry.CompatibilityProfile } else { "" }
    $verified = $null -ne $Telemetry -and [bool]$Telemetry.CompatibilityProfileVerified
    $baseReady = [bool]$StaticReadiness.BaseReady
    $runtimeReported = $null -ne $Telemetry -and $null -ne $Telemetry.PSObject.Properties["AccessibilityRuntimeMode"]
    $runtimeMode = if ($runtimeReported) { [string]$Telemetry.AccessibilityRuntimeMode } else { "NotReported" }
    $runtimeVersion = if ($runtimeReported) { [string]$Telemetry.AccessibilityRuntimeVersion } else { "" }
    $runtimeIntegrityVerified = if (
        $runtimeReported -and
        $null -ne $Telemetry.PSObject.Properties["AccessibilityRuntimeIntegrityVerified"]
    ) { [bool]$Telemetry.AccessibilityRuntimeIntegrityVerified } else { -not $runtimeReported }
    $runtimeReady = (-not $runtimeReported) -or (
        $runtimeMode -in @("Precompiled", "ExistingPrecompiled") -and
        $runtimeIntegrityVerified
    )

    $status = if (-not $baseReady) {
        "EnvironmentIssue"
    } elseif (-not $runtimeReady) {
        "ComponentIssue"
    } elseif ($scannerStatus -eq "Incompatible") {
        "Incompatible"
    } elseif ($HasAuthority -and $HasActionAuthority -and $FaderCount -gt 0 -and $verified) {
        "Ready"
    } elseif ($HasAuthority -and $HasActionAuthority -and $FaderCount -gt 0) {
        "Unverified"
    } elseif ($scannerStatus -in @("Discovering", "Reconnecting", "Synchronizing") -or $null -eq $Telemetry) {
        "Starting"
    } else {
        "Limited"
    }

    $summary = switch ($status) {
        "Ready" { "Ready for this computer" }
        "Unverified" { "Working, but this BEACN version is not verified" }
        "Starting" { "Starting and validating BEACN" }
        "Incompatible" { "BEACN compatibility check failed" }
        "EnvironmentIssue" { "This Windows environment needs attention" }
        "ComponentIssue" { "The BEACN monitoring component needs repair" }
        default { "BEACN monitoring is limited" }
    }

    $issues = New-Object 'System.Collections.Generic.List[string]'
    if (-not [bool]$StaticReadiness.PlatformReady) { [void]$issues.Add("Windows is required") }
    if (-not [bool]$StaticReadiness.PowerShellReady) { [void]$issues.Add("Windows PowerShell 5.1 or newer is required") }
    if (-not [bool]$StaticReadiness.DotNetReady) { [void]$issues.Add(".NET Framework 4.8 is required") }
    if (-not [bool]$StaticReadiness.DataWritable) { [void]$issues.Add("the per-user data directory is not writable") }
    if (-not $runtimeReady) { [void]$issues.Add("the BEACN monitoring component failed its version or integrity check") }
    if ($status -eq "Incompatible") { [void]$issues.Add("the BEACN interface does not match a safe compatibility profile") }
    if ($status -eq "Limited" -and -not $HasActionAuthority) {
        [void]$issues.Add("independent All and Audience rows are not authoritative")
    }
    if ($status -eq "Unverified") { [void]$issues.Add("the structural fallback is active") }

    [pscustomobject]@{
        Status = $status
        Summary = $summary
        CanMonitor = ($baseReady -and $runtimeReady -and $HasAuthority -and $HasActionAuthority -and $FaderCount -gt 0)
        RuntimeMode = $runtimeMode
        RuntimeVersion = $runtimeVersion
        RuntimeIntegrityVerified = $runtimeIntegrityVerified
        Version = $version
        Profile = $profile
        ProfileVerified = $verified
        FaderCount = $FaderCount
        HasAuthority = $HasAuthority
        HasActionAuthority = $HasActionAuthority
        UsbAvailable = $UsbAvailable
        UsbActive = $UsbActive
        Issues = @($issues.ToArray())
        Static = $StaticReadiness
    }
}

function New-MuteCueBeacnStatusPresentationState {
    [pscustomobject]@{
        VisiblePhase = "Discovering"
        ResyncCandidateStartedAtUtc = [DateTime]::MinValue
        ProviderTroubleStartedAtUtc = [DateTime]::MinValue
        LastReadyPrimary = ""
        LastReadyDetail = ""
    }
}

function Update-MuteCueBeacnProviderTrouble {
    param(
        [Parameter(Mandatory)][object]$State,
        [Parameter(Mandatory)][bool]$TroubleDetected,
        [DateTime]$Now = [DateTime]::UtcNow,
        [ValidateRange(0.0, 120.0)][double]$UnavailableDelaySeconds = 15.0
    )

    if (-not $TroubleDetected) {
        $State.ProviderTroubleStartedAtUtc = [DateTime]::MinValue
        return [pscustomobject]@{
            TroubleDetected = $false
            TroubleAgeSeconds = 0.0
            IsUnavailable = $false
        }
    }

    $startedAt = [DateTime]::MinValue
    try { $startedAt = [DateTime]$State.ProviderTroubleStartedAtUtc } catch {}
    if ($startedAt -eq [DateTime]::MinValue -or $startedAt -gt $Now) {
        $startedAt = $Now
        $State.ProviderTroubleStartedAtUtc = $startedAt
    }
    $ageSeconds = [Math]::Max(0.0, ($Now - $startedAt).TotalSeconds)
    [pscustomobject]@{
        TroubleDetected = $true
        TroubleAgeSeconds = $ageSeconds
        IsUnavailable = ($ageSeconds -ge $UnavailableDelaySeconds)
    }
}

function Update-MuteCueBeacnStatusPresentation {
    param(
        [Parameter(Mandatory)][object]$State,
        [Parameter(Mandatory)][ValidateSet("Ready", "Resyncing", "Discovering", "Unavailable")][string]$RawPhase,
        [AllowEmptyString()][string]$RawPrimary = "",
        [AllowEmptyString()][string]$RawDetail = "",
        [bool]$EverReady,
        [DateTime]$Now = [DateTime]::UtcNow,
        [ValidateRange(0.0, 30.0)][double]$ResyncDelaySeconds = 1.0
    )

    $visiblePhase = [string]$State.VisiblePhase
    $candidateStartedAt = [DateTime]::MinValue
    try { $candidateStartedAt = [DateTime]$State.ResyncCandidateStartedAtUtc } catch {}
    if ($RawPhase -eq "Ready") {
        $State.LastReadyPrimary = $RawPrimary
        $State.LastReadyDetail = $RawDetail
    }

    # A hardware or desktop action is confirmed by more than one provider read.
    # Keep the last green Ready presentation during that short, expected window;
    # only a continuous recovery state should become visually alarming.
    if ($RawPhase -eq "Resyncing" -and $EverReady -and $visiblePhase -eq "Ready") {
        if ($candidateStartedAt -eq [DateTime]::MinValue -or $candidateStartedAt -gt $Now) {
            $candidateStartedAt = $Now
            $State.ResyncCandidateStartedAtUtc = $candidateStartedAt
        }
        $ageSeconds = [Math]::Max(0.0, ($Now - $candidateStartedAt).TotalSeconds)
        if ($ageSeconds -lt $ResyncDelaySeconds) {
            return [pscustomobject]@{
                RawPhase = $RawPhase
                VisiblePhase = "Ready"
                VisiblePrimary = [string]$State.LastReadyPrimary
                VisibleDetail = [string]$State.LastReadyDetail
                ResyncDelayed = $true
                ResyncAgeSeconds = $ageSeconds
            }
        }
    }

    $State.ResyncCandidateStartedAtUtc = [DateTime]::MinValue
    $State.VisiblePhase = $RawPhase
    [pscustomobject]@{
        RawPhase = $RawPhase
        VisiblePhase = $RawPhase
        VisiblePrimary = $RawPrimary
        VisibleDetail = $RawDetail
        ResyncDelayed = $false
        ResyncAgeSeconds = 0.0
    }
}

function Format-MuteCueReadinessReport {
    param([Parameter(Mandatory)][object]$Readiness)

    $static = $Readiness.Static
    $lines = New-Object 'System.Collections.Generic.List[string]'
    [void]$lines.Add(("Readiness: {0} - {1}" -f $Readiness.Status, $Readiness.Summary))
    [void]$lines.Add(("Platform: Windows={0}; PowerShell={1}; .NET release={2}" -f [int][bool]$static.PlatformReady, $static.PowerShellVersion, $static.DotNetRelease))
    [void]$lines.Add(("Per-user data: writable={0}; root={1}" -f [int][bool]$static.DataWritable, $static.DataRoot))
    [void]$lines.Add(("Process permissions: {0}" -f $(if ([bool]$static.IsElevated) { "elevated" } else { "normal user" })))
    [void]$lines.Add(("Accessibility runtime: mode={0}; version={1}; integrity={2}" -f $Readiness.RuntimeMode, $Readiness.RuntimeVersion, [int][bool]$Readiness.RuntimeIntegrityVerified))
    [void]$lines.Add(("BEACN: version={0}; profile={1}; verified={2}; faders={3}; authority={4}/{5}" -f $Readiness.Version, $Readiness.Profile, [int][bool]$Readiness.ProfileVerified, $Readiness.FaderCount, [int][bool]$Readiness.HasAuthority, [int][bool]$Readiness.HasActionAuthority))
    [void]$lines.Add(("Optional USB fast path: available={0}; active={1}" -f [int][bool]$Readiness.UsbAvailable, [int][bool]$Readiness.UsbActive))
    if (@($Readiness.Issues).Count -gt 0) {
        [void]$lines.Add(("Attention: {0}" -f (@($Readiness.Issues) -join "; ")))
    }
    return @($lines.ToArray()) -join [Environment]::NewLine
}
