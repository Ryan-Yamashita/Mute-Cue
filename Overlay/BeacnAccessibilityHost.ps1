param(
    [Parameter(Mandatory)][string]$RuntimePath,
    [Parameter(Mandatory)][string]$SessionToken,
    [Parameter(Mandatory)][int]$ParentProcessId
)

$ErrorActionPreference = "Stop"
$overlayDirectory = Split-Path -Parent $MyInvocation.MyCommand.Path
$overlayPath = Join-Path $overlayDirectory "BeacnMuteOverlay.ps1"
$commandPath = Join-Path $RuntimePath "commands"
$snapshotPath = Join-Path $RuntimePath "snapshot.json"
$workerInstanceId = [Guid]::NewGuid().ToString("N")
$sequence = 0L
$startedAt = [DateTime]::UtcNow
$lastWriteUtc = [DateTime]::MinValue
$lastPayloadSignature = ""
$stopping = $false
$scanTask = $null
$scanStartedUtc = [DateTime]::MinValue
$lastScanStartedUtc = [DateTime]::MinValue
$idleScanCadenceMilliseconds = 2000
$lastConfigurationCheckUtc = [DateTime]::MinValue
$lastCommandSweepUtc = [DateTime]::MinValue
$commandSignalPending = $true
$lastCompletedStates = @()
$lastCompletedStateRevision = 0L
$lastCompletedStateCapturedAtUtc = [DateTime]::MinValue
$maximumScanDurationMilliseconds = 30000
$skipScannerShutdown = $false
$fatalErrorPath = Join-Path $RuntimePath "worker-error.log"
$lifecyclePath = Join-Path $RuntimePath "worker-lifecycle.log"
. (Join-Path $overlayDirectory "MuteCue.AtomicFile.ps1")

trap {
    try {
        $errorText = "{0:o} {1}{2}{3}" -f [DateTime]::UtcNow, $_.Exception.ToString(), [Environment]::NewLine, $_.ScriptStackTrace
        [IO.File]::AppendAllText($fatalErrorPath, $errorText + [Environment]::NewLine, [Text.UTF8Encoding]::new($false))
    } catch {}
    exit 1
}

function Get-EmbeddedSource {
    param([Parameter(Mandatory)][string]$VariableName)

    $text = [IO.File]::ReadAllText($overlayPath)
    $pattern = '(?ms)^\$' + [regex]::Escape($VariableName) + '\s*=\s*@"\r?\n(.*?)\r?\n"@\s*$'
    $match = [regex]::Match($text, $pattern)
    if (-not $match.Success) { throw "Embedded source '$VariableName' was not found." }
    return $match.Groups[1].Value
}

function Write-AtomicJson {
    param([Parameter(Mandatory)][object]$Value)

    $json = $Value | ConvertTo-Json -Depth 8 -Compress
    Write-MuteCueAtomicText -Path $snapshotPath -Text $json -MaximumAttempts 10
}

function Test-ParentRunning {
    try { return $null -ne (Get-Process -Id $ParentProcessId -ErrorAction Stop) } catch {
        try { [IO.File]::AppendAllText($lifecyclePath, ("{0:o} parent check failed: {1}{2}" -f [DateTime]::UtcNow, $_.Exception.Message, [Environment]::NewLine)) } catch {}
        return $false
    }
}

function Invoke-WorkerCommand {
    param([Parameter(Mandatory)][object]$Command)

    if ([int]$Command.SchemaVersion -ne 1 -or [string]$Command.SessionToken -ne $SessionToken) { return }
    $data = $Command.Data
    switch ([string]$Command.Type) {
        "Discovery" { [BeacnMuteOverlay.BeacnAppScanner]::RequestDiscovery() }
        "GeometryRefresh" { [BeacnMuteOverlay.BeacnAppScanner]::RequestGeometryRefresh() }
        "FaderRefresh" {
            [BeacnMuteOverlay.BeacnAppScanner]::RequestFaderRefresh([string]$data.Name, [string]$data.Mode)
        }
        "UrgentFaderRefresh" {
            [BeacnMuteOverlay.BeacnAppScanner]::RequestUrgentFaderRefresh([string]$data.Name, [string]$data.Mode)
        }
        "RenderedRefresh" {
            [BeacnMuteOverlay.BeacnAppScanner]::RequestRenderedFaderRefresh([string]$data.Name, [string]$data.Mode)
        }
        "PointRefresh" {
            $x = [double]$data.X
            $y = [double]$data.Y
            $target = [BeacnMuteOverlay.BeacnAppScanner]::ResolveCachedActionAtPoint($x, $y)
            if ($null -ne $target) {
                [BeacnMuteOverlay.BeacnAppScanner]::RequestRenderedFaderRefresh($target.Name, $target.Mode)
            } elseif ([BeacnMuteOverlay.BeacnAppScanner]::IsTrackedBeacnPoint($x, $y)) {
                # Cached row geometry can expire during a BEACN redraw or window
                # move. Reacquire it while the main process performs bounded point
                # retries; never drop the click silently into the slow safety sweep.
                [BeacnMuteOverlay.BeacnAppScanner]::RequestGeometryRefresh()
            }
        }
        "HardwareRefresh" {
            $inputAtUtcTicks = 0L
            $inputAtProperty = $data.PSObject.Properties['InputAtUtcTicks']
            if ($null -ne $inputAtProperty) { $inputAtUtcTicks = [long]$inputAtProperty.Value }
            [BeacnMuteOverlay.BeacnAppScanner]::RequestHardwareRefresh(
                [string]$data.PreferredName,
                [string]$data.Mode,
                [int]$data.Position,
                [long]$data.RequestId,
                [long]$data.MappingGeneration,
                [bool]$data.MappingConfident,
                $inputAtUtcTicks
            )
        }
        "Shutdown" { $script:stopping = $true }
    }
}

Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes
. (Join-Path $overlayDirectory "MuteCue.AccessibilityRuntime.ps1")
$accessibilitySource = Get-EmbeddedSource -VariableName "discordScannerSource"
$accessibilityRuntime = Import-MuteCueAccessibilityRuntime `
    -OverlayDirectory $overlayDirectory `
    -SourceText $accessibilitySource `
    -AllowSourceFallback:(Test-MuteCueAccessibilitySourceFallbackAllowed -OverlayDirectory $overlayDirectory)
. (Join-Path $overlayDirectory "BeacnAdapter.ps1")

[void](New-Item -ItemType Directory -Path $commandPath -Force)
$commandWatcher = [IO.FileSystemWatcher]::new($commandPath, "*.json")
$commandWatcher.NotifyFilter = [IO.NotifyFilters]::FileName
$commandWatcher.EnableRaisingEvents = $true
[IO.File]::AppendAllText($lifecyclePath, ("{0:o} worker={1} parent={2} initialized{3}" -f [DateTime]::UtcNow, $PID, $ParentProcessId, [Environment]::NewLine))
$configurationState = New-BeacnAdapterState
[void](Update-BeacnScannerAdapterConfiguration -Adapter $configurationState -Force)
[BeacnMuteOverlay.BeacnAppScanner]::RequestDiscovery()

try {
    while (-not $stopping -and (Test-ParentRunning)) {
        # Native bounds polling is intentionally independent from ScanAsync. It can
        # fence a scan that was already inside a slow JUCE provider call when the
        # user moved the BEACN window.
        try { [void][BeacnMuteOverlay.BeacnAppScanner]::PollWindowGeometry() } catch {}
        $loopNow = [DateTime]::UtcNow
        if (($loopNow - $lastCommandSweepUtc).TotalMilliseconds -ge 1000) {
            $commandSignalPending = $true
        }
        $commandsProcessed = $false
        if ($commandSignalPending) {
            $commandSignalPending = $false
            $lastCommandSweepUtc = $loopNow
            foreach ($file in @(Get-ChildItem -LiteralPath $commandPath -Filter "*.json" -File -ErrorAction SilentlyContinue | Sort-Object Name)) {
                try {
                    $command = Get-Content -LiteralPath $file.FullName -Raw | ConvertFrom-Json
                    Invoke-WorkerCommand -Command $command
                    $commandsProcessed = $true
                } catch {} finally {
                    Remove-Item -LiteralPath $file.FullName -Force -ErrorAction SilentlyContinue
                }
            }
        }
        if (($loopNow - $lastConfigurationCheckUtc).TotalMilliseconds -ge 2000) {
            $lastConfigurationCheckUtc = $loopNow
            try { [void](Update-BeacnScannerAdapterConfiguration -Adapter $configurationState) } catch {}
        }

        $scanRequested = [bool][BeacnMuteOverlay.BeacnAppScanner]::HasPendingChanges
        $scanNow = [DateTime]::UtcNow
        if (
            $null -eq $scanTask -and
            (
                $scanRequested -or
                $lastScanStartedUtc -eq [DateTime]::MinValue -or
                ($scanNow - $lastScanStartedUtc).TotalMilliseconds -ge $idleScanCadenceMilliseconds
            )
        ) {
            $scanStartedUtc = $scanNow
            $lastScanStartedUtc = $scanNow
            $scanTask = [BeacnMuteOverlay.BeacnAppScanner]::ScanAsync()
        }
        $scanCompleted = $false
        if ($null -ne $scanTask -and $scanTask.IsCompleted) {
            $completedStates = @($scanTask.GetAwaiter().GetResult() | Sort-Object Order)
            if ($completedStates.Count -gt 0 -or $lastCompletedStates.Count -eq 0) {
                $lastCompletedStates = $completedStates
                # Latch the revision with the exact state array returned by this
                # completed scan. Never pair an in-progress revision with the
                # previous cached array in a heartbeat snapshot.
                $lastCompletedStateRevision = [long][BeacnMuteOverlay.BeacnAppScanner]::StateRevision
                $lastCompletedStateCapturedAtUtc = [DateTime][BeacnMuteOverlay.BeacnAppScanner]::StateCapturedAtUtc
            }
            $scanTask = $null
            $scanStartedUtc = [DateTime]::MinValue
            $scanCompleted = $true
        }

        $now = [DateTime]::UtcNow
        $scanInProgress = $null -ne $scanTask
        $scanInProgressMilliseconds = if ($scanInProgress -and $scanStartedUtc -ne [DateTime]::MinValue) {
            [Math]::Max(0, ($now - $scanStartedUtc).TotalMilliseconds)
        } else {
            0
        }
        $shouldPublish = (
            $scanCompleted -or
            $commandsProcessed -or
            $lastWriteUtc -eq [DateTime]::MinValue -or
            ($now - $lastWriteUtc).TotalMilliseconds -ge 1000
        )
        if ($shouldPublish) {
            $sequence++
            $snapshot = [ordered]@{
            SchemaVersion = 1
            SessionToken = $SessionToken
            WorkerInstanceId = $workerInstanceId
            WorkerProcessId = $PID
            Sequence = $sequence
            StateRevision = [long]$lastCompletedStateRevision
            StartedAtUtc = $startedAt.ToString("o")
            CapturedAtUtc = $now.ToString("o")
            StateCapturedAtUtc = $(
                $stateCapturedAt = [DateTime]$lastCompletedStateCapturedAtUtc
                if ($stateCapturedAt -eq [DateTime]::MinValue) { "" } else { $stateCapturedAt.ToString("o") }
            )
            ScannerStatus = [string][BeacnMuteOverlay.BeacnAppScanner]::CompatibilityStatus
            ScannerDetail = [string][BeacnMuteOverlay.BeacnAppScanner]::CompatibilityDetail
            AccessibilityRuntimeMode = [string]$accessibilityRuntime.Mode
            AccessibilityRuntimeVersion = [string]$accessibilityRuntime.AssemblyVersion
            AccessibilityRuntimeContract = [int]$accessibilityRuntime.ContractVersion
            AccessibilityRuntimeIntegrityVerified = [bool]$accessibilityRuntime.IntegrityVerified
            BeacnVersion = [string][BeacnMuteOverlay.BeacnAppScanner]::BeacnVersion
            CompatibilityProfile = [string]$configurationState.CompatibilityProfileId
            CompatibilityProfileVerified = [bool]$configurationState.CompatibilityProfileVerified
            LayoutFingerprint = [string][BeacnMuteOverlay.BeacnAppScanner]::LayoutFingerprint
            DiscoveryGeneration = [int][BeacnMuteOverlay.BeacnAppScanner]::DiscoveryGeneration
            HasPendingChanges = [bool][BeacnMuteOverlay.BeacnAppScanner]::HasPendingChanges
            GeometryRefreshInProgress = [bool][BeacnMuteOverlay.BeacnAppScanner]::GeometryRefreshInProgress
            GeometryRefreshRemaining = [int][BeacnMuteOverlay.BeacnAppScanner]::GeometryRefreshRemaining
            NativeGeometryGeneration = [long][BeacnMuteOverlay.BeacnAppScanner]::NativeGeometryGeneration
            ScanInProgress = [bool]$scanInProgress
            ScanInProgressMilliseconds = [double]$scanInProgressMilliseconds
            LastScanMilliseconds = [double][BeacnMuteOverlay.BeacnAppScanner]::LastScanMilliseconds
            DiagnosticSummary = [string][BeacnMuteOverlay.BeacnAppScanner]::DiagnosticSummary
            LastActionEventSummary = [string][BeacnMuteOverlay.BeacnAppScanner]::LastActionEventSummary
            HardwareResultSequence = [long][BeacnMuteOverlay.BeacnAppScanner]::HardwareResultSequence
            LastHardwareChangedName = [string][BeacnMuteOverlay.BeacnAppScanner]::LastHardwareChangedName
            LastHardwarePreferredName = [string][BeacnMuteOverlay.BeacnAppScanner]::LastHardwarePreferredName
            LastHardwareChangedMode = [string][BeacnMuteOverlay.BeacnAppScanner]::LastHardwareChangedMode
            LastHardwarePosition = [int][BeacnMuteOverlay.BeacnAppScanner]::LastHardwarePosition
            LastHardwareRequestId = [long][BeacnMuteOverlay.BeacnAppScanner]::LastHardwareRequestId
            LastHardwareMappingGeneration = [long][BeacnMuteOverlay.BeacnAppScanner]::LastHardwareMappingGeneration
            LastHardwareRefreshSummary = [string][BeacnMuteOverlay.BeacnAppScanner]::LastHardwareRefreshSummary
            States = $lastCompletedStates
            }
            $payloadSignature = ($snapshot | ConvertTo-Json -Depth 8 -Compress) `
                -replace '"Sequence":\d+,', '' `
                -replace '"CapturedAtUtc":"[^"]+",', '' `
                -replace '"ScanInProgress":(?:true|false),', '' `
                -replace '"ScanInProgressMilliseconds":[^,]+,', ''
            if ($payloadSignature -ne $lastPayloadSignature -or ($now - $lastWriteUtc).TotalMilliseconds -ge 1000) {
                try {
                    Write-AtomicJson -Value $snapshot
                    $lastPayloadSignature = $payloadSignature
                    $lastWriteUtc = $now
                } catch {
                    # Antivirus and indexers can briefly hold the shared snapshot.
                    # A missed heartbeat is recoverable; killing the state worker is not.
                    try {
                        [IO.File]::AppendAllText(
                            $lifecyclePath,
                            ("{0:o} snapshot write deferred: {1}{2}" -f [DateTime]::UtcNow, $_.Exception.Message, [Environment]::NewLine)
                        )
                    } catch {}
                }
            }
        }

        if ($scanInProgressMilliseconds -ge $maximumScanDurationMilliseconds) {
            try {
                [IO.File]::AppendAllText(
                    $lifecyclePath,
                    ("{0:o} scan exceeded {1} ms; recycling worker without discarding the last snapshot{2}" -f `
                        [DateTime]::UtcNow, [int]$scanInProgressMilliseconds, [Environment]::NewLine)
                )
            } catch {}
            $skipScannerShutdown = $true
            [Environment]::Exit(2)
        }
        # WaitForChanged uses the kernel notification path, so command pickup stays
        # near 60 Hz without repeatedly walking the command directory while idle.
        try {
            $watchTypes = [IO.WatcherChangeTypes]::Created -bor [IO.WatcherChangeTypes]::Renamed
            # The kernel wakes this immediately for a command; the 60 ms value is
            # only the idle heartbeat, avoiding a busy PowerShell wake loop.
            $change = $commandWatcher.WaitForChanged($watchTypes, 60)
            if (-not $change.TimedOut) {
                $commandSignalPending = $true
            } elseif ([IO.Directory]::GetFiles($commandPath, '*.json').Length -gt 0) {
                # FileSystemWatcher can miss a rename that lands between the prior
                # level sweep and WaitForChanged registration. The directory is
                # bounded and normally empty, so this cheap level check removes the
                # former one-second recovery delay without scanning BEACN itself.
                $commandSignalPending = $true
            }
        } catch {
            $commandSignalPending = $true
            Start-Sleep -Milliseconds 60
        }
    }
} finally {
    if ($null -ne $commandWatcher) { $commandWatcher.Dispose() }
    try { [IO.File]::AppendAllText($lifecyclePath, ("{0:o} worker stopping; requested={1}; parentRunning={2}{3}" -f [DateTime]::UtcNow, [int]$stopping, [int](Test-ParentRunning), [Environment]::NewLine)) } catch {}
    if (-not $skipScannerShutdown) {
        try { [BeacnMuteOverlay.BeacnAppScanner]::Shutdown() } catch {}
    }
}
