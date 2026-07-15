$ErrorActionPreference = "Stop"
$overlayDirectory = Split-Path -Parent $PSScriptRoot
. (Join-Path $overlayDirectory "BeacnActionState.ps1")
. (Join-Path $overlayDirectory "BeacnAdapter.ps1")
. (Join-Path $overlayDirectory "BeacnStateCoordinator.ps1")
. (Join-Path $overlayDirectory "BeacnAccessibilityClient.ps1")

function Assert-Isolation {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

function New-IsolationRawFader {
    param([int]$Order, [string]$Name, [double]$Offset = 0, [bool]$All = $false, [bool]$Audience = $false)
    [pscustomobject]@{
        Order = $Order
        Name = $Name
        PersonalMuted = $All
        AudienceMuted = ($All -or $Audience)
        IsLocked = $false
        AllActionStateKnown = $true
        AllActionActive = $All
        AudienceActionStateKnown = $true
        AudienceActionActive = $Audience
        HasAllActionBounds = $true
        AllActionLeft = 10 + ($Order * 100) + $Offset
        AllActionTop = 100 + $Offset
        AllActionRight = 80 + ($Order * 100) + $Offset
        AllActionBottom = 120 + $Offset
        HasAudienceActionBounds = $true
        AudienceActionLeft = 10 + ($Order * 100) + $Offset
        AudienceActionTop = 125 + $Offset
        AudienceActionRight = 80 + ($Order * 100) + $Offset
        AudienceActionBottom = 145 + $Offset
    }
}

function New-ProviderSnapshot {
    param([string]$Worker, [long]$Sequence, [object[]]$States, [DateTime]$At = [DateTime]::UtcNow)
    [pscustomobject]@{
        WorkerInstanceId = $Worker
        Sequence = $Sequence
        CapturedAtUtc = $At.ToString("o")
        States = $States
    }
}

$adapter = New-BeacnAdapterState
$coordinator = New-BeacnStateCoordinator -Adapter $adapter
$baseStates = @(
    New-IsolationRawFader -Order 0 -Name "Mic"
    New-IsolationRawFader -Order 1 -Name "System"
)
$first = Submit-BeacnProviderSnapshot -Coordinator $coordinator -Snapshot (New-ProviderSnapshot -Worker "worker-a" -Sequence 1 -States $baseStates)
Assert-Isolation $first.Accepted "The first valid provider snapshot must be accepted."
$duplicate = Submit-BeacnProviderSnapshot -Coordinator $coordinator -Snapshot (New-ProviderSnapshot -Worker "worker-a" -Sequence 1 -States $baseStates)
Assert-Isolation $duplicate.Duplicate "Duplicate provider sequences must be ignored."

$movedStates = @(
    New-IsolationRawFader -Order 0 -Name "Mic" -Offset 120
    New-IsolationRawFader -Order 1 -Name "System" -Offset 120
)
$moved = Submit-BeacnProviderSnapshot -Coordinator $coordinator -Snapshot (New-ProviderSnapshot -Worker "worker-a" -Sequence 2 -States $movedStates)
Assert-Isolation $moved.GeometryChanged "Moving the BEACN window must advance geometry."
Assert-Isolation (-not $moved.AdapterResult.LayoutInvalidated) "Moving the window must not invalidate fader layout."

$restarted = Submit-BeacnProviderSnapshot -Coordinator $coordinator -Snapshot (New-ProviderSnapshot -Worker "worker-b" -Sequence 1 -States $movedStates)
Assert-Isolation ($restarted.Accepted -and $restarted.WorkerGeneration -eq 2) "A replacement worker must start a new ordered generation."
$authoritativeBeforeEmpty = $coordinator.LastAuthoritativeUtc
$empty = Submit-BeacnProviderSnapshot -Coordinator $coordinator -Snapshot (New-ProviderSnapshot -Worker "worker-b" -Sequence 2 -States @())
Assert-Isolation ($empty.Accepted -and -not $empty.Publishable) "A transient empty provider snapshot must not replace the last authoritative state."
Assert-Isolation ($coordinator.LastAuthoritativeUtc -eq $authoritativeBeforeEmpty) "Transient provider emptiness must preserve the authoritative-state deadline."
$invalid = Submit-BeacnProviderSnapshot -Coordinator $coordinator -Snapshot (New-ProviderSnapshot -Worker "worker-b" -Sequence 3 -States @(
    New-IsolationRawFader -Order 0 -Name "Mic"
    New-IsolationRawFader -Order 1 -Name "Mic"
))
Assert-Isolation $invalid.Rejected "Duplicate fader identities from a worker must be rejected."

$sequence = 3L
$rapidTimer = [Diagnostics.Stopwatch]::StartNew()
for ($index = 0; $index -lt 200; $index++) {
    $all = ($index % 2) -eq 1
    foreach ($confirmation in 1..2) {
        $sequence++
        $rapidStates = @(
            New-IsolationRawFader -Order 0 -Name "Mic" -Offset 120 -All $all
            New-IsolationRawFader -Order 1 -Name "System" -Offset 120
        )
        [void](Submit-BeacnProviderSnapshot -Coordinator $coordinator -Snapshot (New-ProviderSnapshot -Worker "worker-b" -Sequence $sequence -States $rapidStates))
    }
}
$rapidTimer.Stop()
Assert-Isolation ($coordinator.LastAdapterResult.ByName["Mic"].AllActive) "Rapid confirmed actions must finish on the final ordered state."
Assert-Isolation ($rapidTimer.ElapsedMilliseconds -lt 5000) "Rapid worker snapshots exceeded the coordinator performance budget."

$sequence++
$reorderEdge = Submit-BeacnProviderSnapshot -Coordinator $coordinator -Snapshot (New-ProviderSnapshot -Worker "worker-b" -Sequence $sequence -States @(
    New-IsolationRawFader -Order 0 -Name "System" -Offset 120
    New-IsolationRawFader -Order 1 -Name "Mic" -Offset 120 -All $true
))
Assert-Isolation ($reorderEdge.AdapterResult.LayoutInvalidated -and -not $reorderEdge.AdapterResult.HasActionAuthority) "A reordered mixer must invalidate hardware mapping before publication (invalidated=$($reorderEdge.AdapterResult.LayoutInvalidated), actionAuthority=$($reorderEdge.AdapterResult.HasActionAuthority), publishable=$($reorderEdge.Publishable))."
$sequence++
$reorderCommit = Submit-BeacnProviderSnapshot -Coordinator $coordinator -Snapshot (New-ProviderSnapshot -Worker "worker-b" -Sequence $sequence -States @(
    New-IsolationRawFader -Order 0 -Name "System" -Offset 120
    New-IsolationRawFader -Order 1 -Name "Mic" -Offset 120 -All $true
))
Assert-Isolation ($reorderCommit.Publishable -and $reorderCommit.AdapterResult.LayoutChanged) "A reordered mixer must publish atomically after confirmation."

$coordinator.LastProviderHeartbeatUtc = [DateTime]::UtcNow.AddSeconds(-5)
$health = Get-BeacnCoordinatorHealth -Coordinator $coordinator -WorkerRunning $true
Assert-Isolation ($health.Status -eq "Recovering") "A stale worker heartbeat must enter recovery before authority is discarded."

$runtimeRoot = Join-Path ([IO.Path]::GetTempPath()) ("MuteCue-WorkerTest-" + [Guid]::NewGuid().ToString("N"))
$client = New-BeacnAccessibilityClient -OverlayDirectory $overlayDirectory -RuntimeRoot $runtimeRoot
try {
    $workerStartupTimer = [Diagnostics.Stopwatch]::StartNew()
    Assert-Isolation (Start-BeacnAccessibilityClient -Client $client) "The isolated accessibility worker must start."
    $deadline = [DateTime]::UtcNow.AddSeconds(20)
    $workerSnapshot = $null
    while ($null -eq $workerSnapshot -and [DateTime]::UtcNow -lt $deadline) {
        Start-Sleep -Milliseconds 100
        $workerSnapshot = Receive-BeacnAccessibilitySnapshot -Client $client
    }
    $workerStartupTimer.Stop()
    Assert-Isolation ($null -ne $workerSnapshot) "The isolated accessibility worker must publish a heartbeat snapshot."
    Assert-Isolation ($workerStartupTimer.ElapsedMilliseconds -lt 15000) "The precompiled worker exceeded its fifteen-second cold heartbeat budget ($($workerStartupTimer.ElapsedMilliseconds) ms)."
    Assert-Isolation ([int]$workerSnapshot.SchemaVersion -eq 1) "The worker protocol must be versioned."
    Assert-Isolation ([string]$workerSnapshot.AccessibilityRuntimeMode -eq "Precompiled") "The worker must load the precompiled accessibility runtime."
    Assert-Isolation ([bool]$workerSnapshot.AccessibilityRuntimeIntegrityVerified) "The worker must publish a verified accessibility runtime identity."
    Assert-Isolation ($null -ne $workerSnapshot.PSObject.Properties["ScanInProgress"]) "The worker heartbeat must expose non-blocking scan activity."
    Assert-Isolation ($null -ne $workerSnapshot.PSObject.Properties["ScanInProgressMilliseconds"]) "The worker heartbeat must expose slow-scan recovery timing."
    Assert-Isolation (Send-BeacnAccessibilityCommand -Client $client -Type GeometryRefresh) "The authenticated command channel must accept geometry refreshes."
    $originalWorkerId = [string]$workerSnapshot.WorkerInstanceId
    $originalRestartCount = [long]$client.RestartCount
    $client.Process.Kill()
    [void]$client.Process.WaitForExit(2000)
    $client.NextStartUtc = [DateTime]::MinValue
    [void](Update-BeacnAccessibilityClientWatchdog -Client $client -HeartbeatTimeoutSeconds 1)
    Start-Sleep -Milliseconds 1100
    [void](Update-BeacnAccessibilityClientWatchdog -Client $client -HeartbeatTimeoutSeconds 1)
    Assert-Isolation ([long]$client.RestartCount -gt $originalRestartCount) "The watchdog must replace a crashed accessibility worker."
    $replacementDeadline = [DateTime]::UtcNow.AddSeconds(20)
    $replacementSnapshot = $null
    while ($null -eq $replacementSnapshot -and [DateTime]::UtcNow -lt $replacementDeadline) {
        Start-Sleep -Milliseconds 100
        $replacementSnapshot = Receive-BeacnAccessibilitySnapshot -Client $client
    }
    Assert-Isolation ($null -ne $replacementSnapshot -and [string]$replacementSnapshot.WorkerInstanceId -ne $originalWorkerId) "The replacement worker must publish a new identity generation."
} finally {
    Stop-BeacnAccessibilityClient -Client $client
    if (Test-Path -LiteralPath $runtimeRoot) { Remove-Item -LiteralPath $runtimeRoot -Recurse -Force -ErrorAction SilentlyContinue }
}

"BEACN isolation tests: PASS"
