function New-BeacnActionTracker {
    [pscustomobject]@{
        Pending = ""
        Confirmations = 0
        LastObservationRevision = 0L
        LastCommittedObservationRevision = 0L
        Known = $false
        PersonalMuted = $false
        AudienceMuted = $false
        Mode = $null
        AllActive = $false
        AudienceActive = $false
    }
}

function Submit-BeacnDirectActionSnapshot {
    param(
        [Parameter(Mandatory)][object]$Tracker,
        [Parameter(Mandatory)][bool]$AllActive,
        [Parameter(Mandatory)][bool]$AudienceActive,
        [int]$RequiredConfirmations = 2,
        [long]$ObservationRevision = 0L
    )

    if ($RequiredConfirmations -lt 1) { $RequiredConfirmations = 1 }
    $signature = "{0}:{1}" -f [int]$AllActive, [int]$AudienceActive
    if (
        $ObservationRevision -gt 0 -and
        [long]$Tracker.LastObservationRevision -ge $ObservationRevision
    ) {
        # A provider heartbeat, cache-only scan, or out-of-order envelope must not
        # become another confirmation of this fader. Preserve a previously
        # committed identical observation without advancing its counter.
        $alreadyCommitted = (
            [bool]$Tracker.Known -and
            [string]$Tracker.Pending -eq $signature -and
            [int]$Tracker.Confirmations -ge $RequiredConfirmations
        )
        return [pscustomobject]@{
            Committed = $alreadyCommitted
            NeedsConfirmation = -not $alreadyCommitted
            Signature = $signature
            DuplicateObservation = $true
        }
    }
    if ($ObservationRevision -gt 0) {
        $Tracker.LastObservationRevision = $ObservationRevision
    }
    if ([string]$Tracker.Pending -eq $signature) {
        $Tracker.Confirmations++
    } else {
        $Tracker.Pending = $signature
        $Tracker.Confirmations = 1
    }

    $committed = $Tracker.Confirmations -ge $RequiredConfirmations
    if ($committed) {
        $Tracker.AllActive = $AllActive
        $Tracker.AudienceActive = $AudienceActive
        $Tracker.Known = $true
        if ($ObservationRevision -gt 0) {
            $Tracker.LastCommittedObservationRevision = $ObservationRevision
        }
        $Tracker.Mode = if ($AllActive -and $AudienceActive) {
            "Both"
        } elseif ($AllActive) {
            "All"
        } elseif ($AudienceActive) {
            "Audience"
        } else {
            $null
        }
    }

    [pscustomobject]@{
        Committed = $committed
        NeedsConfirmation = -not $committed
        Signature = $signature
        DuplicateObservation = $false
    }
}

function Test-BeacnAuthoritativePreviewAllowed {
    param(
        [bool]$HasActionAuthority,
        [bool]$NeedsConfirmation,
        [double]$StateAgeSeconds,
        [AllowEmptyString()][string]$CompatibilityStatus,
        [bool]$FaderPresent,
        [bool]$ActionStateKnown,
        [double]$MaximumStateAgeSeconds = 2.5,
        [bool]$PendingPreviewContinuation = $false
    )

    $readyAuthority = (
        $HasActionAuthority -and
        -not $NeedsConfirmation -and
        [string]::Equals($CompatibilityStatus, 'Ready', [StringComparison]::OrdinalIgnoreCase)
    )
    $ownedContinuation = (
        $PendingPreviewContinuation -and
        $NeedsConfirmation -and
        (
            [string]::Equals($CompatibilityStatus, 'Ready', [StringComparison]::OrdinalIgnoreCase) -or
            [string]::Equals($CompatibilityStatus, 'Synchronizing', [StringComparison]::OrdinalIgnoreCase)
        )
    )
    return (
        ($readyAuthority -or $ownedContinuation) -and
        $StateAgeSeconds -ge 0 -and
        $StateAgeSeconds -lt $MaximumStateAgeSeconds -and
        $FaderPresent -and
        $ActionStateKnown
    )
}

function Get-BeacnActionPointCandidateScore {
    param(
        [double]$X,
        [double]$Y,
        [double]$Left,
        [double]$Top,
        [double]$Right,
        [double]$Bottom,
        [double]$LeftPadding = 12,
        [double]$RightPadding = 96,
        [double]$VerticalPadding = 8
    )

    if (
        $Right -le $Left -or
        $Bottom -le $Top -or
        $X -lt ($Left - $LeftPadding) -or
        $X -gt ($Right + $RightPadding) -or
        $Y -lt ($Top - $VerticalPadding) -or
        $Y -gt ($Bottom + $VerticalPadding)
    ) { return $null }

    $distanceX = if ($X -lt $Left) { $Left - $X } elseif ($X -gt $Right) { $X - $Right } else { 0.0 }
    $distanceY = if ($Y -lt $Top) { $Top - $Y } elseif ($Y -gt $Bottom) { $Y - $Bottom } else { 0.0 }
    $centerX = ($Left + $Right) / 2.0
    $centerY = ($Top + $Bottom) / 2.0
    [pscustomobject]@{
        DirectContainment = ($distanceX -eq 0.0 -and $distanceY -eq 0.0)
        EdgeDistanceSquared = ($distanceX * $distanceX) + ($distanceY * $distanceY)
        CenterDistanceSquared = (($X - $centerX) * ($X - $centerX)) + (($Y - $centerY) * ($Y - $centerY))
        Area = ($Right - $Left) * ($Bottom - $Top)
    }
}

function Test-BeacnActionPointCandidatePreferred {
    param(
        [Parameter(Mandatory)][object]$Score,
        [AllowNull()][object]$BestScore
    )

    if ($null -eq $BestScore) { return $true }
    if ([bool]$Score.DirectContainment -ne [bool]$BestScore.DirectContainment) {
        return [bool]$Score.DirectContainment
    }
    foreach ($property in @('EdgeDistanceSquared', 'CenterDistanceSquared', 'Area')) {
        $candidateValue = [double]$Score.$property
        $bestValue = [double]$BestScore.$property
        if ([Math]::Abs($candidateValue - $bestValue) -le 0.001) { continue }
        return $candidateValue -lt $bestValue
    }
    return $false
}

function New-BeacnOptimisticActionState {
    param(
        [Parameter(Mandatory)][bool]$AuthoritativeAllActive,
        [Parameter(Mandatory)][bool]$AuthoritativeAudienceActive,
        [AllowNull()][object]$ExistingState,
        [Parameter(Mandatory)][ValidateSet("All", "Audience")][string]$Mode,
        [Parameter(Mandatory)][DateTime]$Now,
        [long]$RequestId = 0,
        [int]$Position = -1,
        [double]$MaximumAgeSeconds = 0.85
    )

    $allActive = $AuthoritativeAllActive
    $audienceActive = $AuthoritativeAudienceActive
    $allRequestId = 0L
    $audienceRequestId = 0L
    $existingAgeSeconds = if ($null -ne $ExistingState) {
        ($Now - [DateTime]$ExistingState.At).TotalSeconds
    } else {
        [double]::PositiveInfinity
    }
    if (
        $null -ne $ExistingState -and
        $existingAgeSeconds -ge 0 -and
        $existingAgeSeconds -lt $MaximumAgeSeconds
    ) {
        $allActive = [bool]$ExistingState.AllActive
        $audienceActive = [bool]$ExistingState.AudienceActive
        $allRequestProperty = $ExistingState.PSObject.Properties["AllRequestId"]
        $audienceRequestProperty = $ExistingState.PSObject.Properties["AudienceRequestId"]
        if ($null -ne $allRequestProperty) { $allRequestId = [long]$allRequestProperty.Value }
        if ($null -ne $audienceRequestProperty) { $audienceRequestId = [long]$audienceRequestProperty.Value }
    }
    if ($Mode -eq "All") {
        $allActive = -not $allActive
        $allRequestId = $RequestId
    } else {
        $audienceActive = -not $audienceActive
        $audienceRequestId = $RequestId
    }

    [pscustomobject]@{
        AllActive = $allActive
        AudienceActive = $audienceActive
        At = $Now
        Mode = $Mode
        Position = $Position
        MaximumAgeSeconds = $MaximumAgeSeconds
        AllRequestId = $allRequestId
        AudienceRequestId = $audienceRequestId
        AllVerificationRequestId = 0L
        AllVerificationAfterRevision = 0L
        AudienceVerificationRequestId = 0L
        AudienceVerificationAfterRevision = 0L
    }
}

function Test-BeacnOptimisticActionStateActive {
    param(
        [AllowNull()][object]$State,
        [Parameter(Mandatory)][DateTime]$Now,
        [double]$DefaultMaximumAgeSeconds = 0.85
    )

    if ($null -eq $State) { return $false }
    $maximumAgeSeconds = $DefaultMaximumAgeSeconds
    $maximumAgeProperty = $State.PSObject.Properties['MaximumAgeSeconds']
    if ($null -ne $maximumAgeProperty -and [double]$maximumAgeProperty.Value -gt 0) {
        $maximumAgeSeconds = [double]$maximumAgeProperty.Value
    }
    $ageSeconds = ($Now - [DateTime]$State.At).TotalSeconds
    return ($ageSeconds -ge 0 -and $ageSeconds -lt $maximumAgeSeconds)
}

function Resolve-BeacnDisplayedActionState {
    param(
        [Parameter(Mandatory)][bool]$AuthoritativeAllActive,
        [Parameter(Mandatory)][bool]$AuthoritativeAudienceActive,
        [bool]$AuthoritativeStateKnown = $true,
        [AllowNull()][object]$OptimisticState,
        [Parameter(Mandatory)][DateTime]$Now,
        [double]$MaximumAgeSeconds = 0.85
    )

    $useOptimistic = (
        $AuthoritativeStateKnown -and
        (Test-BeacnOptimisticActionStateActive `
            -State $OptimisticState `
            -Now $Now `
            -DefaultMaximumAgeSeconds $MaximumAgeSeconds) -and
        (
            $AuthoritativeAllActive -ne [bool]$OptimisticState.AllActive -or
            $AuthoritativeAudienceActive -ne [bool]$OptimisticState.AudienceActive
        )
    )
    [pscustomobject]@{
        AllActive = if (-not $AuthoritativeStateKnown) { $false } elseif ($useOptimistic) { [bool]$OptimisticState.AllActive } else { $AuthoritativeAllActive }
        AudienceActive = if (-not $AuthoritativeStateKnown) { $false } elseif ($useOptimistic) { [bool]$OptimisticState.AudienceActive } else { $AuthoritativeAudienceActive }
        StateKnown = $AuthoritativeStateKnown
        UseOptimistic = $useOptimistic
    }
}

function Test-BeacnOptimisticRequestOwnership {
    param(
        [AllowNull()][object]$State,
        [Parameter(Mandatory)][ValidateSet("All", "Audience")][string]$Mode,
        [Parameter(Mandatory)][long]$RequestId
    )

    if ($null -eq $State -or $RequestId -le 0) { return $false }
    $propertyName = if ($Mode -eq "All") { "AllRequestId" } else { "AudienceRequestId" }
    $property = $State.PSObject.Properties[$propertyName]
    return $null -ne $property -and [long]$property.Value -eq $RequestId
}
