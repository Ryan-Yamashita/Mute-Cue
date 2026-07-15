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
        [bool]$ActionStateKnown = $true,
        [long]$ActionRevision = 0L
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
        ActionRevision = $ActionRevision
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

$previewAt = [DateTime]::UtcNow
$allPreview = New-BeacnOptimisticActionState `
    -AuthoritativeAllActive ([bool]$third.ByName["Voice FX"].AllActive) `
    -AuthoritativeAudienceActive ([bool]$third.ByName["Voice FX"].AudienceActive) `
    -ExistingState $null `
    -Mode All `
    -MaximumAgeSeconds 4.0 `
    -Now $previewAt
$allFirst = Submit-BeacnAdapterSnapshot -Adapter $adapter -RawStates @(
    New-RawFader -Order 0 -Name "Mic" -Locked $true
    New-RawFader -Order 1 -Name "Voice FX" -All $true
)
Assert-Adapter (-not $allFirst.ByName["Voice FX"].AllActive) "A single redraw must not change published All state."
Assert-Adapter $allFirst.ByName["Voice FX"].ActionStateKnown "A pending transition must preserve the last committed readable state for stable rendering."
Assert-Adapter ($allFirst.NeedsConfirmation -and -not $allFirst.HasActionAuthority) "A pending action transition must not retain action authority."
$pendingDisplay = Resolve-BeacnDisplayedActionState `
    -AuthoritativeAllActive ([bool]$allFirst.ByName["Voice FX"].AllActive) `
    -AuthoritativeAudienceActive ([bool]$allFirst.ByName["Voice FX"].AudienceActive) `
    -AuthoritativeStateKnown ([bool]$allFirst.ByName["Voice FX"].ActionStateKnown) `
    -OptimisticState $allPreview `
    -Now $previewAt.AddMilliseconds(250)
Assert-Adapter ($pendingDisplay.UseOptimistic -and $pendingDisplay.AllActive) "A click preview must remain visible across the first changed observation instead of flashing off."
$allSecond = Submit-BeacnAdapterSnapshot -Adapter $adapter -RawStates @(
    New-RawFader -Order 0 -Name "Mic" -Locked $true
    New-RawFader -Order 1 -Name "Voice FX" -All $true
)
Assert-Adapter ($allSecond.ByName["Voice FX"].AllActive) "Two matching snapshots must commit All independently."
$confirmedDisplay = Resolve-BeacnDisplayedActionState `
    -AuthoritativeAllActive ([bool]$allSecond.ByName["Voice FX"].AllActive) `
    -AuthoritativeAudienceActive ([bool]$allSecond.ByName["Voice FX"].AudienceActive) `
    -AuthoritativeStateKnown ([bool]$allSecond.ByName["Voice FX"].ActionStateKnown) `
    -OptimisticState $allPreview `
    -Now $previewAt.AddMilliseconds(450)
Assert-Adapter (-not $confirmedDisplay.UseOptimistic -and $confirmedDisplay.AllActive) "The second real observation must replace the preview without changing the rendered value."

# An observation of System (or a cache-only envelope) must never become Mic's
# second confirmation. Each fader carries its own monotonic action revision.
$revisionAdapter = New-BeacnAdapterState
$revisionLayoutFirst = @(
    New-RawFader -Order 0 -Name "Mic" -Locked $true -ActionRevision 1
    New-RawFader -Order 1 -Name "System" -ActionRevision 1
)
[void](Submit-BeacnAdapterSnapshot -Adapter $revisionAdapter -RawStates $revisionLayoutFirst)
$revisionLayoutSecond = @(
    New-RawFader -Order 0 -Name "Mic" -Locked $true -ActionRevision 2
    New-RawFader -Order 1 -Name "System" -ActionRevision 2
)
[void](Submit-BeacnAdapterSnapshot -Adapter $revisionAdapter -RawStates $revisionLayoutSecond)
$revisionReadyRaw = @(
    New-RawFader -Order 0 -Name "Mic" -Locked $true -ActionRevision 3
    New-RawFader -Order 1 -Name "System" -ActionRevision 3
)
$revisionReady = Submit-BeacnAdapterSnapshot -Adapter $revisionAdapter -RawStates $revisionReadyRaw
Assert-Adapter $revisionReady.HasActionAuthority "Distinct observations must establish the revision regression baseline."
Assert-Adapter ($revisionReady.ByName['Mic'].CommittedActionRevision -eq 3) "Published state must expose the revision of Mic's committed observation."
$micFirst = Submit-BeacnAdapterSnapshot -Adapter $revisionAdapter -RawStates @(
    New-RawFader -Order 0 -Name "Mic" -Locked $true -All $true -ActionRevision 4
    New-RawFader -Order 1 -Name "System" -ActionRevision 3
)
Assert-Adapter (-not $micFirst.HasActionAuthority -and -not $micFirst.ByName['Mic'].AllActive) "Mic's first changed observation must remain pending."
Assert-Adapter $micFirst.ByName['Mic'].ActionStateKnown "Mic's last confirmed state must remain renderable while its changed observation is pending."
$systemOnly = Submit-BeacnAdapterSnapshot -Adapter $revisionAdapter -RawStates @(
    New-RawFader -Order 0 -Name "Mic" -Locked $true -All $true -ActionRevision 4
    New-RawFader -Order 1 -Name "System" -ActionRevision 4
)
Assert-Adapter (-not $systemOnly.HasActionAuthority -and -not $systemOnly.ByName['Mic'].AllActive) "A System-only observation must not confirm Mic."
Assert-Adapter $systemOnly.ByName['Mic'].ActionStateKnown "An unrelated fader observation must not blank Mic while Mic awaits confirmation."
$micSecond = Submit-BeacnAdapterSnapshot -Adapter $revisionAdapter -RawStates @(
    New-RawFader -Order 0 -Name "Mic" -Locked $true -All $true -ActionRevision 5
    New-RawFader -Order 1 -Name "System" -ActionRevision 4
)
Assert-Adapter ($micSecond.HasActionAuthority -and $micSecond.ByName['Mic'].AllActive) "Mic's second real observation must commit its transition."
Assert-Adapter ($micSecond.ByName['Mic'].CommittedActionRevision -eq 5) "The committed revision must advance only after Mic's second real observation."

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

$partialAdapter = New-BeacnAdapterState
$activeRaw = @(New-RawFader -Order 0 -Name "Game" -All $true)
[void](Submit-BeacnAdapterSnapshot -Adapter $partialAdapter -RawStates $activeRaw -RequiredConfirmations 1)
$active = Submit-BeacnAdapterSnapshot -Adapter $partialAdapter -RawStates $activeRaw -RequiredConfirmations 1
Assert-Adapter ($active.HasActionAuthority -and $active.ByName["Game"].AllActive) "The partial-state regression needs an established active fader."
$unknownRaw = @(New-RawFader -Order 0 -Name "Game" -ActionStateKnown $false)
$unknown = Submit-BeacnAdapterSnapshot -Adapter $partialAdapter -RawStates $unknownRaw -RequiredConfirmations 1
Assert-Adapter (-not $unknown.ByName["Game"].ActionStateKnown -and -not $unknown.ByName["Game"].AllActive) "An unreadable row must not publish its previously active state."
$unknownAgain = Submit-BeacnAdapterSnapshot -Adapter $partialAdapter -RawStates $unknownRaw -RequiredConfirmations 1
Assert-Adapter (-not $unknownAgain.ByName["Game"].AllActive) "Repeated partial snapshots must not keep a stale overlay active."
$recoveredRaw = @(New-RawFader -Order 0 -Name "Game")
$recovered = Submit-BeacnAdapterSnapshot -Adapter $partialAdapter -RawStates $recoveredRaw -RequiredConfirmations 1
Assert-Adapter ($recovered.HasActionAuthority -and -not $recovered.ByName["Game"].AllActive) "A readable row must recover cleanly after a partial snapshot."

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
