function New-BeacnActionTracker {
    [pscustomobject]@{
        Pending = ""
        Confirmations = 0
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
        [int]$RequiredConfirmations = 2
    )

    if ($RequiredConfirmations -lt 1) { $RequiredConfirmations = 1 }
    $signature = "{0}:{1}" -f [int]$AllActive, [int]$AudienceActive
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
        [double]$MaximumStateAgeSeconds = 2.5
    )

    return (
        $HasActionAuthority -and
        -not $NeedsConfirmation -and
        $StateAgeSeconds -ge 0 -and
        $StateAgeSeconds -lt $MaximumStateAgeSeconds -and
        [string]::Equals($CompatibilityStatus, 'Ready', [StringComparison]::OrdinalIgnoreCase) -and
        $FaderPresent -and
        $ActionStateKnown
    )
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
    if (
        $null -ne $ExistingState -and
        ($Now - [DateTime]$ExistingState.At).TotalSeconds -lt $MaximumAgeSeconds
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
        AllRequestId = $allRequestId
        AudienceRequestId = $audienceRequestId
    }
}

function Resolve-BeacnDisplayedActionState {
    param(
        [Parameter(Mandatory)][bool]$AuthoritativeAllActive,
        [Parameter(Mandatory)][bool]$AuthoritativeAudienceActive,
        [AllowNull()][object]$OptimisticState,
        [Parameter(Mandatory)][DateTime]$Now,
        [double]$MaximumAgeSeconds = 0.85
    )

    $useOptimistic = (
        $null -ne $OptimisticState -and
        ($Now - [DateTime]$OptimisticState.At).TotalSeconds -lt $MaximumAgeSeconds -and
        (
            $AuthoritativeAllActive -ne [bool]$OptimisticState.AllActive -or
            $AuthoritativeAudienceActive -ne [bool]$OptimisticState.AudienceActive
        )
    )
    [pscustomobject]@{
        AllActive = if ($useOptimistic) { [bool]$OptimisticState.AllActive } else { $AuthoritativeAllActive }
        AudienceActive = if ($useOptimistic) { [bool]$OptimisticState.AudienceActive } else { $AuthoritativeAudienceActive }
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
