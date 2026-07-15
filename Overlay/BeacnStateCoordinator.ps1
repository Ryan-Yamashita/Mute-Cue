function New-BeacnStateCoordinator {
    param([Parameter(Mandatory)][object]$Adapter)

    [pscustomobject]@{
        Adapter = $Adapter
        WorkerInstanceId = ""
        WorkerGeneration = 0L
        LastProviderSequence = 0L
        LastProviderHeartbeatUtc = [DateTime]::MinValue
        LastAcceptedUtc = [DateTime]::MinValue
        LastAuthoritativeUtc = [DateTime]::MinValue
        GeometryFingerprint = ""
        GeometryGeneration = 0L
        RejectedSnapshots = 0L
        LastRejection = ""
        LastSnapshot = $null
        LastAdapterResult = $null
    }
}

function Get-BeacnGeometryFingerprint {
    param([AllowNull()][object[]]$States)

    return @(
        @($States) |
            Sort-Object Order |
            ForEach-Object {
                "{0}:{1:N0},{2:N0},{3:N0},{4:N0}:{5:N0},{6:N0},{7:N0},{8:N0}" -f `
                    [string]$_.Name, `
                    [double]$_.AllActionLeft, `
                    [double]$_.AllActionTop, `
                    [double]$_.AllActionRight, `
                    [double]$_.AllActionBottom, `
                    [double]$_.AudienceActionLeft, `
                    [double]$_.AudienceActionTop, `
                    [double]$_.AudienceActionRight, `
                    [double]$_.AudienceActionBottom
            }
    ) -join "|"
}

function New-BeacnRejectedProviderResult {
    param(
        [Parameter(Mandatory)][object]$Coordinator,
        [Parameter(Mandatory)][string]$Reason
    )

    $Coordinator.RejectedSnapshots++
    $Coordinator.LastRejection = $Reason
    [pscustomobject]@{
        Accepted = $false
        Duplicate = $false
        Rejected = $true
        Reason = $Reason
        AdapterResult = $Coordinator.LastAdapterResult
        GeometryChanged = $false
        GeometryGeneration = [long]$Coordinator.GeometryGeneration
        WorkerGeneration = [long]$Coordinator.WorkerGeneration
        Publishable = $false
    }
}

function Submit-BeacnProviderSnapshot {
    param(
        [Parameter(Mandatory)][object]$Coordinator,
        [Parameter(Mandatory)][object]$Snapshot,
        [DateTime]$Now = [DateTime]::UtcNow,
        [int]$MaximumFaders = 64
    )

    $instanceId = ([string]$Snapshot.WorkerInstanceId).Trim()
    if ([string]::IsNullOrWhiteSpace($instanceId)) {
        return New-BeacnRejectedProviderResult -Coordinator $Coordinator -Reason "missing worker identity"
    }
    $sequence = 0L
    if (-not [long]::TryParse([string]$Snapshot.Sequence, [ref]$sequence) -or $sequence -le 0) {
        return New-BeacnRejectedProviderResult -Coordinator $Coordinator -Reason "invalid provider sequence"
    }
    $capturedAt = [DateTime]::MinValue
    if (-not [DateTime]::TryParse(
        [string]$Snapshot.CapturedAtUtc,
        [Globalization.CultureInfo]::InvariantCulture,
        [Globalization.DateTimeStyles]::AssumeUniversal,
        [ref]$capturedAt
    )) {
        return New-BeacnRejectedProviderResult -Coordinator $Coordinator -Reason "invalid provider timestamp"
    }
    $capturedAt = $capturedAt.ToUniversalTime()
    if ($capturedAt -gt $Now.AddSeconds(5)) {
        return New-BeacnRejectedProviderResult -Coordinator $Coordinator -Reason "provider timestamp is in the future"
    }

    if ($Coordinator.WorkerInstanceId -ne $instanceId) {
        $Coordinator.WorkerInstanceId = $instanceId
        $Coordinator.WorkerGeneration++
        $Coordinator.LastProviderSequence = 0L
    }
    if ($sequence -le [long]$Coordinator.LastProviderSequence) {
        return [pscustomobject]@{
            Accepted = $false
            Duplicate = $true
            Rejected = $false
            Reason = "duplicate or out-of-order snapshot"
            AdapterResult = $Coordinator.LastAdapterResult
            GeometryChanged = $false
            GeometryGeneration = [long]$Coordinator.GeometryGeneration
            WorkerGeneration = [long]$Coordinator.WorkerGeneration
            Publishable = $false
        }
    }

    $rawStates = @($Snapshot.States)
    if ($rawStates.Count -gt $MaximumFaders) {
        return New-BeacnRejectedProviderResult -Coordinator $Coordinator -Reason "provider fader count exceeded the safety limit"
    }
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($state in $rawStates) {
        $name = ([string]$state.Name).Trim()
        if ([string]::IsNullOrWhiteSpace($name) -or $name.Length -gt 128 -or -not $seen.Add($name)) {
            return New-BeacnRejectedProviderResult -Coordinator $Coordinator -Reason "provider returned an invalid fader identity"
        }
    }

    $Coordinator.LastProviderSequence = $sequence
    $Coordinator.LastProviderHeartbeatUtc = $capturedAt
    $Coordinator.LastSnapshot = $Snapshot
    $geometryFingerprint = Get-BeacnGeometryFingerprint -States $rawStates
    $geometryChanged = $geometryFingerprint -ne [string]$Coordinator.GeometryFingerprint
    if ($geometryChanged) {
        $Coordinator.GeometryFingerprint = $geometryFingerprint
        $Coordinator.GeometryGeneration++
    }

    $adapterResult = Submit-BeacnAdapterSnapshot -Adapter $Coordinator.Adapter -RawStates $rawStates
    $Coordinator.LastAdapterResult = $adapterResult
    $Coordinator.LastAcceptedUtc = $Now
    if ([bool]$adapterResult.HasActionAuthority) {
        $Coordinator.LastAuthoritativeUtc = $Now
    }
    [pscustomobject]@{
        Accepted = $true
        Duplicate = $false
        Rejected = $false
        Reason = ""
        AdapterResult = $adapterResult
        GeometryChanged = $geometryChanged
        GeometryGeneration = [long]$Coordinator.GeometryGeneration
        WorkerGeneration = [long]$Coordinator.WorkerGeneration
        Publishable = [bool]$adapterResult.HasAuthority
    }
}

function Get-BeacnCoordinatorHealth {
    param(
        [Parameter(Mandatory)][object]$Coordinator,
        [bool]$WorkerRunning,
        [DateTime]$Now = [DateTime]::UtcNow,
        [double]$StaleAfterSeconds = 2.5,
        [double]$UnavailableAfterSeconds = 10
    )

    $heartbeatAge = if ($Coordinator.LastProviderHeartbeatUtc -eq [DateTime]::MinValue) {
        [double]::PositiveInfinity
    } else {
        ($Now - [DateTime]$Coordinator.LastProviderHeartbeatUtc).TotalSeconds
    }
    $authorityAge = if ($Coordinator.LastAuthoritativeUtc -eq [DateTime]::MinValue) {
        [double]::PositiveInfinity
    } else {
        ($Now - [DateTime]$Coordinator.LastAuthoritativeUtc).TotalSeconds
    }
    $status = if (-not $WorkerRunning) {
        "WorkerStopped"
    } elseif ($heartbeatAge -ge $UnavailableAfterSeconds) {
        "Unavailable"
    } elseif ($heartbeatAge -ge $StaleAfterSeconds) {
        "Recovering"
    } elseif ($null -ne $Coordinator.LastAdapterResult -and [bool]$Coordinator.LastAdapterResult.HasActionAuthority) {
        "Healthy"
    } else {
        "Synchronizing"
    }
    [pscustomobject]@{
        Status = $status
        WorkerRunning = $WorkerRunning
        HeartbeatAgeSeconds = $heartbeatAge
        AuthorityAgeSeconds = $authorityAge
        WorkerGeneration = [long]$Coordinator.WorkerGeneration
        GeometryGeneration = [long]$Coordinator.GeometryGeneration
        LayoutGeneration = [long]$Coordinator.Adapter.LayoutGeneration
        RejectedSnapshots = [long]$Coordinator.RejectedSnapshots
        LastRejection = [string]$Coordinator.LastRejection
    }
}
