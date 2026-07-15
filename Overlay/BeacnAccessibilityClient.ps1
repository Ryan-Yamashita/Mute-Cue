if ($null -eq (Get-Command Read-MuteCueSharedText -ErrorAction SilentlyContinue)) {
    . (Join-Path $PSScriptRoot "MuteCue.AtomicFile.ps1")
}

function New-BeacnAccessibilityClient {
    param(
        [Parameter(Mandatory)][string]$OverlayDirectory,
        [string]$RuntimeRoot = ""
    )

    if ([string]::IsNullOrWhiteSpace($RuntimeRoot)) {
        $RuntimeRoot = Join-Path $env:LOCALAPPDATA "MuteCue\Runtime"
    }
    $instanceId = [Guid]::NewGuid().ToString("N")
    $runtimePath = Join-Path $RuntimeRoot $instanceId
    [pscustomobject]@{
        OverlayDirectory = $OverlayDirectory
        RuntimePath = $runtimePath
        CommandPath = Join-Path $runtimePath "commands"
        SnapshotPath = Join-Path $runtimePath "snapshot.json"
        SessionToken = [Convert]::ToBase64String((1..32 | ForEach-Object { Get-Random -Minimum 0 -Maximum 256 }))
        Process = $null
        LastSnapshot = $null
        LastSnapshotSequence = 0L
        LastSnapshotReadUtc = [DateTime]::MinValue
        LastStartAttemptUtc = [DateTime]::MinValue
        RestartCount = 0L
        ConsecutiveFailures = 0
        NextStartUtc = [DateTime]::MinValue
        Stopped = $false
    }
}

function Start-BeacnAccessibilityClient {
    param([Parameter(Mandatory)][object]$Client)

    if ($Client.Stopped) { return $false }
    if ($null -ne $Client.Process) {
        try { if (-not $Client.Process.HasExited) { return $true } } catch {}
        $Client.Process = $null
    }
    $now = [DateTime]::UtcNow
    if ($now -lt [DateTime]$Client.NextStartUtc) { return $false }
    $Client.LastStartAttemptUtc = $now

    try {
        [void](New-Item -ItemType Directory -Path $Client.CommandPath -Force)
        Get-ChildItem -LiteralPath $Client.CommandPath -File -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $Client.SnapshotPath -Force -ErrorAction SilentlyContinue
        $hostPath = Join-Path $Client.OverlayDirectory "BeacnAccessibilityHost.ps1"
        if (-not (Test-Path -LiteralPath $hostPath)) { throw "The BEACN accessibility host is missing." }
        $powershellPath = Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe"
        $arguments = '-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}" -RuntimePath "{1}" -SessionToken "{2}" -ParentProcessId {3}' -f `
            $hostPath.Replace('"', '\"'), `
            ([string]$Client.RuntimePath).Replace('"', '\"'), `
            ([string]$Client.SessionToken).Replace('"', '\"'), `
            $PID
        $processInfo = New-Object Diagnostics.ProcessStartInfo
        $processInfo.FileName = $powershellPath
        $processInfo.Arguments = $arguments
        $processInfo.WorkingDirectory = $Client.OverlayDirectory
        $processInfo.UseShellExecute = $false
        $processInfo.CreateNoWindow = $true
        $processInfo.WindowStyle = [Diagnostics.ProcessWindowStyle]::Hidden
        $Client.Process = [Diagnostics.Process]::Start($processInfo)
        if ($null -eq $Client.Process) { throw "Windows did not create the BEACN accessibility worker." }
        $Client.RestartCount++
        $Client.LastSnapshot = $null
        $Client.LastSnapshotSequence = 0L
        $Client.LastSnapshotReadUtc = [DateTime]::MinValue
        $Client.ConsecutiveFailures = 0
        $Client.NextStartUtc = [DateTime]::MinValue
        return $true
    } catch {
        $Client.Process = $null
        $Client.ConsecutiveFailures++
        $delay = [Math]::Min(30, [Math]::Pow(2, [Math]::Min(5, $Client.ConsecutiveFailures - 1)))
        $Client.NextStartUtc = $now.AddSeconds($delay)
        return $false
    }
}

function Send-BeacnAccessibilityCommand {
    param(
        [Parameter(Mandatory)][object]$Client,
        [Parameter(Mandatory)][ValidateSet('Discovery','GeometryRefresh','FaderRefresh','UrgentFaderRefresh','RenderedRefresh','PointRefresh','HardwareRefresh','Shutdown')][string]$Type,
        [hashtable]$Data = @{}
    )

    if ($Client.Stopped -or -not (Test-Path -LiteralPath $Client.CommandPath)) { return $false }
    try {
        $commands = @(Get-ChildItem -LiteralPath $Client.CommandPath -Filter "*.json" -File -ErrorAction SilentlyContinue)
        if ($commands.Count -ge 128) {
            $commands | Sort-Object CreationTimeUtc | Select-Object -First ($commands.Count - 127) | Remove-Item -Force
        }
        $command = [ordered]@{
            SchemaVersion = 1
            SessionToken = [string]$Client.SessionToken
            Type = $Type
            CreatedAtUtc = [DateTime]::UtcNow.ToString("o")
            Data = $Data
        }
        $name = "{0:D20}-{1}.json" -f [DateTime]::UtcNow.Ticks, [Guid]::NewGuid().ToString("N")
        $path = Join-Path $Client.CommandPath $name
        $temporaryPath = $path + ".tmp"
        [IO.File]::WriteAllText($temporaryPath, ($command | ConvertTo-Json -Depth 6 -Compress), [Text.UTF8Encoding]::new($false))
        [IO.File]::Move($temporaryPath, $path)
        return $true
    } catch {
        return $false
    }
}

function Receive-BeacnAccessibilitySnapshot {
    param([Parameter(Mandatory)][object]$Client)

    if (-not (Test-Path -LiteralPath $Client.SnapshotPath)) { return $null }
    try {
        $snapshot = Read-MuteCueSharedText -Path $Client.SnapshotPath -MaximumBytes 2MB | ConvertFrom-Json
        if ([int]$snapshot.SchemaVersion -ne 1 -or [string]$snapshot.SessionToken -ne [string]$Client.SessionToken) {
            return $null
        }
        $sequence = [long]$snapshot.Sequence
        if ($sequence -le [long]$Client.LastSnapshotSequence) { return $null }
        $Client.LastSnapshotSequence = $sequence
        $Client.LastSnapshotReadUtc = [DateTime]::UtcNow
        $Client.LastSnapshot = $snapshot
        return $snapshot
    } catch {
        return $null
    }
}

function Test-BeacnAccessibilityClientRunning {
    param([Parameter(Mandatory)][object]$Client)

    if ($null -eq $Client.Process) { return $false }
    try { return -not $Client.Process.HasExited } catch { return $false }
}

function Update-BeacnAccessibilityClientWatchdog {
    param(
        [Parameter(Mandatory)][object]$Client,
        [DateTime]$Now = [DateTime]::UtcNow,
        [double]$HeartbeatTimeoutSeconds = 12,
        [double]$DiscoveryTimeoutSeconds = 35
    )

    $running = Test-BeacnAccessibilityClientRunning -Client $Client
    $heartbeatUtc = if ($null -ne $Client.LastSnapshot) {
        try { [DateTime]::Parse([string]$Client.LastSnapshot.CapturedAtUtc).ToUniversalTime() } catch { [DateTime]::MinValue }
    } else {
        [DateTime]::MinValue
    }
    $hasDiscoveredStates = $null -ne $Client.LastSnapshot -and @($Client.LastSnapshot.States).Count -gt 0
    $effectiveHeartbeatTimeout = if ($hasDiscoveredStates) {
        $HeartbeatTimeoutSeconds
    } else {
        [Math]::Max($HeartbeatTimeoutSeconds, $DiscoveryTimeoutSeconds)
    }
    $stale = (
        $running -and
        $heartbeatUtc -ne [DateTime]::MinValue -and
        ($Now - $heartbeatUtc).TotalSeconds -ge $effectiveHeartbeatTimeout
    )
    $startingTooLong = (
        $running -and
        $heartbeatUtc -eq [DateTime]::MinValue -and
        ($Now - [DateTime]$Client.LastStartAttemptUtc).TotalSeconds -ge $DiscoveryTimeoutSeconds
    )
    if ($running -and ($stale -or $startingTooLong)) {
        try { $Client.Process.Kill() } catch {}
        try { [void]$Client.Process.WaitForExit(1000) } catch {}
        $Client.Process = $null
        $Client.ConsecutiveFailures++
        $delay = [Math]::Min(30, [Math]::Pow(2, [Math]::Min(5, $Client.ConsecutiveFailures - 1)))
        $Client.NextStartUtc = $Now.AddSeconds($delay)
        return $false
    }
    if (-not $running) {
        if ($Now -ge [DateTime]$Client.NextStartUtc) {
            return [bool](Start-BeacnAccessibilityClient -Client $Client)
        }
        return $false
    }
    return $true
}

function Stop-BeacnAccessibilityClient {
    param([Parameter(Mandatory)][object]$Client)

    if ($Client.Stopped) { return }
    [void](Send-BeacnAccessibilityCommand -Client $Client -Type Shutdown)
    $Client.Stopped = $true
    if ($null -ne $Client.Process) {
        try {
            if (-not $Client.Process.WaitForExit(1200)) { $Client.Process.Kill() }
        } catch {}
        try { $Client.Process.Dispose() } catch {}
        $Client.Process = $null
    }
    if (Test-Path -LiteralPath $Client.RuntimePath) {
        try { Remove-Item -LiteralPath $Client.RuntimePath -Recurse -Force } catch {}
    }
}
