$ErrorActionPreference = "Stop"
$overlayDirectory = Split-Path -Parent $PSScriptRoot
. (Join-Path $overlayDirectory "BeacnActionState.ps1")
. (Join-Path $overlayDirectory "BeacnAdapter.ps1")

function Assert-Adapter {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

function New-RawFader {
    param(
        [int]$Order,
        [string]$Name,
        [bool]$All = $false,
        [bool]$Audience = $false,
        [bool]$Locked = $false,
        [bool]$ActionStateKnown = $true
    )

    [pscustomobject]@{
        Order = $Order
        Name = $Name
        PersonalMuted = $All
        AudienceMuted = ($All -or $Audience)
        IsLocked = $Locked
        AllActionStateKnown = $ActionStateKnown
        AllActionActive = $All
        AudienceActionStateKnown = $ActionStateKnown
        AudienceActionActive = $Audience
        HasAllActionBounds = $true
        AllActionLeft = 10.0 + ($Order * 100)
        AllActionTop = 100.0
        AllActionRight = 80.0 + ($Order * 100)
        AllActionBottom = 120.0
        HasAudienceActionBounds = $true
        AudienceActionLeft = 10.0 + ($Order * 100)
        AudienceActionTop = 125.0
        AudienceActionRight = 80.0 + ($Order * 100)
        AudienceActionBottom = 145.0
    }
}

$verifiedCompatibility = Get-BeacnCompatibilityProfile -Version "1.2.62"
Assert-Adapter ($verifiedCompatibility.Verified -and $verifiedCompatibility.Id -eq "beacn-1.2") "Known BEACN versions must select a verified compatibility profile."
$futureCompatibility = Get-BeacnCompatibilityProfile -Version "2.0.0"
Assert-Adapter (-not $futureCompatibility.Verified -and $futureCompatibility.Id -eq "structural-fallback") "Unknown BEACN versions must be explicitly marked unverified."

$adapter = New-BeacnAdapterState
$initial = @(
    New-RawFader -Order 0 -Name "Mic" -Locked $true
    New-RawFader -Order 1 -Name "Voice FX"
)
$first = Submit-BeacnAdapterSnapshot -Adapter $adapter -RawStates $initial
Assert-Adapter (-not $first.Accepted -and $first.NeedsConfirmation) "A new layout must be confirmed before publication."
$second = Submit-BeacnAdapterSnapshot -Adapter $adapter -RawStates $initial
Assert-Adapter ($second.Accepted -and -not $second.HasActionAuthority) "First action snapshot must remain unconfirmed."
$third = Submit-BeacnAdapterSnapshot -Adapter $adapter -RawStates $initial
Assert-Adapter ($third.HasActionAuthority -and $third.CompatibilityStatus -eq "Ready") "Confirmed independent action rows must become authoritative."
Assert-Adapter ($third.ByName.ContainsKey("Voice FX")) "The adapter must accept dynamically discovered fader names."
Assert-Adapter ($third.ByName["Voice FX"].StableKey -eq "voice fx") "Dynamic faders must receive a stable normalized identity."

$allFirst = Submit-BeacnAdapterSnapshot -Adapter $adapter -RawStates @(
    New-RawFader -Order 0 -Name "Mic" -Locked $true
    New-RawFader -Order 1 -Name "Voice FX" -All $true
)
Assert-Adapter (-not $allFirst.ByName["Voice FX"].AllActive) "A single redraw must not change published All state."
$allSecond = Submit-BeacnAdapterSnapshot -Adapter $adapter -RawStates @(
    New-RawFader -Order 0 -Name "Mic" -Locked $true
    New-RawFader -Order 1 -Name "Voice FX" -All $true
)
Assert-Adapter ($allSecond.ByName["Voice FX"].AllActive) "Two matching snapshots must commit All independently."

$bothRaw = @(
    New-RawFader -Order 0 -Name "Mic" -Locked $true
    New-RawFader -Order 1 -Name "Voice FX" -All $true -Audience $true
)
[void](Submit-BeacnAdapterSnapshot -Adapter $adapter -RawStates $bothRaw)
$both = Submit-BeacnAdapterSnapshot -Adapter $adapter -RawStates $bothRaw
Assert-Adapter ($both.ByName["Voice FX"].AllActive -and $both.ByName["Voice FX"].AudienceActive) "All and Audience must remain independent when both are active."

$reordered = @(
    New-RawFader -Order 0 -Name "Voice FX" -All $true -Audience $true
    New-RawFader -Order 1 -Name "Mic" -Locked $true
)
$layoutEdge = Submit-BeacnAdapterSnapshot -Adapter $adapter -RawStates $reordered
Assert-Adapter ($layoutEdge.LayoutInvalidated -and -not $layoutEdge.HasActionAuthority) "The first changed layout snapshot must invalidate hardware mapping immediately."
$layoutCommit = Submit-BeacnAdapterSnapshot -Adapter $adapter -RawStates $reordered
Assert-Adapter ($layoutCommit.LayoutChanged -and $layoutCommit.HasActionAuthority) "A confirmed layout must publish atomically."
Assert-Adapter ($layoutCommit.States[0].Name -eq "Voice FX") "Published order must follow the confirmed BEACN layout."

$duplicate = Submit-BeacnAdapterSnapshot -Adapter $adapter -RawStates @(
    New-RawFader -Order 0 -Name "Mic"
    New-RawFader -Order 1 -Name "mic"
)
Assert-Adapter ($duplicate.CompatibilityStatus -eq "Incompatible" -and -not $duplicate.HasActionAuthority) "Duplicate fader identities must fail closed."

$degradedAdapter = New-BeacnAdapterState
$degradedRaw = @(New-RawFader -Order 0 -Name "Mic" -ActionStateKnown $false)
[void](Submit-BeacnAdapterSnapshot -Adapter $degradedAdapter -RawStates $degradedRaw -RequiredConfirmations 1)
$degraded = Submit-BeacnAdapterSnapshot -Adapter $degradedAdapter -RawStates $degradedRaw -RequiredConfirmations 1
Assert-Adapter ($degraded.CompatibilityStatus -eq "Degraded" -and -not $degraded.HasActionAuthority) "Missing independent action rows must never be inferred from aggregate outputs."

$identityAdapter = New-BeacnAdapterState
$identityAdapter.IdentityByName = @{ "Broadcast" = "profile:9" }
$identityRaw = @(New-RawFader -Order 0 -Name "Broadcast" -All $true)
[void](Submit-BeacnAdapterSnapshot -Adapter $identityAdapter -RawStates $identityRaw -RequiredConfirmations 1)
$identityReady = Submit-BeacnAdapterSnapshot -Adapter $identityAdapter -RawStates $identityRaw -RequiredConfirmations 1
Assert-Adapter ($identityReady.ByName["Broadcast"].StableKey -eq "profile:9") "Profile-backed identities must replace mutable display names."
$identityAdapter.IdentityByName = @{ "Renamed Broadcast" = "profile:9" }
$renamedRaw = @(New-RawFader -Order 0 -Name "Renamed Broadcast" -All $true)
$renameResult = Submit-BeacnAdapterSnapshot -Adapter $identityAdapter -RawStates $renamedRaw -RequiredConfirmations 1
Assert-Adapter (-not $renameResult.LayoutInvalidated) "Renaming a profile-backed fader must not invalidate its logical layout identity."
Assert-Adapter ($renameResult.ByName["Renamed Broadcast"].AllActive) "A renamed profile-backed fader must retain its confirmed action tracker."

$performanceAdapter = New-BeacnAdapterState
$performanceRaw = @(
    New-RawFader -Order 0 -Name "Mic"
    New-RawFader -Order 1 -Name "System"
    New-RawFader -Order 2 -Name "Game"
    New-RawFader -Order 3 -Name "Chat"
)
$timer = [System.Diagnostics.Stopwatch]::StartNew()
for ($index = 0; $index -lt 1000; $index++) {
    [void](Submit-BeacnAdapterSnapshot -Adapter $performanceAdapter -RawStates $performanceRaw -RequiredConfirmations 1)
}
$timer.Stop()
Assert-Adapter ($timer.ElapsedMilliseconds -lt 5000) "Adapter snapshot processing exceeded its performance budget."

"BeacnAdapter tests: PASS ($($timer.ElapsedMilliseconds) ms / 1,000 snapshots)"
