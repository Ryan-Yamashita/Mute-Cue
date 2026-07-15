$ErrorActionPreference = "Stop"
. (Join-Path (Split-Path -Parent $PSScriptRoot) "BeacnActionState.ps1")

function Assert-Equal {
    param($Actual, $Expected, [string]$Message)
    if ($Actual -ne $Expected) {
        throw "$Message (expected '$Expected', got '$Actual')"
    }
}

function Commit-State {
    param([object]$Tracker, [bool]$All, [bool]$Audience)
    $first = Submit-BeacnDirectActionSnapshot -Tracker $Tracker -AllActive $All -AudienceActive $Audience
    Assert-Equal $first.Committed $false "A single snapshot must not commit"
    $second = Submit-BeacnDirectActionSnapshot -Tracker $Tracker -AllActive $All -AudienceActive $Audience
    Assert-Equal $second.Committed $true "Two identical snapshots must commit"
}

$tracker = New-BeacnActionTracker
Commit-State $tracker $false $false
Assert-Equal $tracker.Mode $null "Neither state"

# All -> Both -> Audience -> Neither.
Commit-State $tracker $true $false
Assert-Equal $tracker.Mode "All" "All state"
Commit-State $tracker $true $true
Assert-Equal $tracker.Mode "Both" "All then Audience"
Commit-State $tracker $false $true
Assert-Equal $tracker.Mode "Audience" "Unmute All while Audience remains"
Commit-State $tracker $false $false
Assert-Equal $tracker.Mode $null "Clear Audience last"

# Immediate previews are allowed only while they are anchored to fresh,
# fully authoritative state. Both hardware and configured BEACN shortcuts use
# this shared gate before showing a bounded expected result.
Assert-Equal (Test-BeacnAuthoritativePreviewAllowed $true $false 0.1 'Ready' $true $true) $true "Fresh authoritative state allows a preview"
Assert-Equal (Test-BeacnAuthoritativePreviewAllowed $false $false 0.1 'Ready' $true $true) $false "Missing action authority rejects a preview"
Assert-Equal (Test-BeacnAuthoritativePreviewAllowed $true $true 0.1 'Ready' $true $true) $false "Pending confirmation rejects a preview"
Assert-Equal (Test-BeacnAuthoritativePreviewAllowed $false $true 0.1 'Synchronizing' $true $true 2.5 $true) $true "The same fader's active preview may continue through confirmation"
Assert-Equal (Test-BeacnAuthoritativePreviewAllowed $false $true 0.1 'Synchronizing' $true $true 2.5 $false) $false "Unowned synchronization must not create a preview"
Assert-Equal (Test-BeacnAuthoritativePreviewAllowed $false $true 0.1 'Unavailable' $true $true 2.5 $true) $false "A preview cannot continue through provider failure"
Assert-Equal (Test-BeacnAuthoritativePreviewAllowed $true $false 2.5 'Ready' $true $true) $false "Stale state rejects a preview"
Assert-Equal (Test-BeacnAuthoritativePreviewAllowed $true $false 0.1 'Synchronizing' $true $true) $false "Non-ready compatibility rejects a preview"
Assert-Equal (Test-BeacnAuthoritativePreviewAllowed $true $false 0.1 'Ready' $false $true) $false "An absent fader rejects a preview"
Assert-Equal (Test-BeacnAuthoritativePreviewAllowed $true $false 0.1 'Ready' $true $false) $false "Unknown row state rejects a preview"

# Audience -> Both -> All -> Neither.
Commit-State $tracker $false $true
Assert-Equal $tracker.Mode "Audience" "Audience state"
Commit-State $tracker $true $true
Assert-Equal $tracker.Mode "Both" "Audience then All"
Commit-State $tracker $true $false
Assert-Equal $tracker.Mode "All" "Unmute Audience while All remains"
Commit-State $tracker $false $false
Assert-Equal $tracker.Mode $null "Clear All last"

# An intermediate JUCE snapshot cannot overwrite the committed state.
Commit-State $tracker $true $true
$transient = Submit-BeacnDirectActionSnapshot -Tracker $tracker -AllActive $false -AudienceActive $true
Assert-Equal $transient.Committed $false "Transient snapshot must remain pending"
Assert-Equal $tracker.Mode "Both" "Transient snapshot must preserve committed state"
Commit-State $tracker $false $false
Assert-Equal $tracker.Mode $null "Tracker must recover after a transient"

# Confirmations are tied to a real observation of this fader. Replaying the same
# revision (or wrapping it in another provider heartbeat) cannot commit a change.
$revisionTracker = New-BeacnActionTracker
$revisionFirst = Submit-BeacnDirectActionSnapshot `
    -Tracker $revisionTracker -AllActive $true -AudienceActive $false -ObservationRevision 10
$revisionDuplicate = Submit-BeacnDirectActionSnapshot `
    -Tracker $revisionTracker -AllActive $true -AudienceActive $false -ObservationRevision 10
$revisionSecond = Submit-BeacnDirectActionSnapshot `
    -Tracker $revisionTracker -AllActive $true -AudienceActive $false -ObservationRevision 11
Assert-Equal $revisionFirst.Committed $false "The first real fader observation must remain pending"
Assert-Equal $revisionDuplicate.Committed $false "A duplicate fader revision must not confirm itself"
Assert-Equal $revisionDuplicate.DuplicateObservation $true "Duplicate observations must be explicit"
Assert-Equal $revisionSecond.Committed $true "A second real fader observation must commit"
Assert-Equal $revisionTracker.LastCommittedObservationRevision 11 "A committed state must retain the exact revision that established it"
$committedDuplicate = Submit-BeacnDirectActionSnapshot `
    -Tracker $revisionTracker -AllActive $true -AudienceActive $false -ObservationRevision 11
Assert-Equal $committedDuplicate.Committed $true "A duplicate of an already committed revision must preserve authority"

# Optimistic display state is independent per action and supports rapid presses.
$now = [DateTime]::UtcNow
$optimistic = New-BeacnOptimisticActionState `
    -AuthoritativeAllActive $false `
    -AuthoritativeAudienceActive $false `
    -ExistingState $null `
    -Mode All `
    -RequestId 10 `
    -Now $now
Assert-Equal $optimistic.AllActive $true "Optimistic All press"
Assert-Equal $optimistic.AudienceActive $false "Optimistic All preserves Audience"
Assert-Equal $optimistic.AllRequestId 10 "All request correlation"
Assert-Equal $optimistic.AudienceRequestId 0 "Untouched Audience request correlation"
$optimistic = New-BeacnOptimisticActionState `
    -AuthoritativeAllActive $false `
    -AuthoritativeAudienceActive $false `
    -ExistingState $optimistic `
    -Mode Audience `
    -RequestId 11 `
    -Now $now.AddMilliseconds(10)
Assert-Equal $optimistic.AllActive $true "Optimistic Audience preserves All"
Assert-Equal $optimistic.AudienceActive $true "Optimistic Audience press"
Assert-Equal $optimistic.AllRequestId 10 "Audience press preserves All request"
Assert-Equal $optimistic.AudienceRequestId 11 "Audience request correlation"
$optimistic = New-BeacnOptimisticActionState `
    -AuthoritativeAllActive $false `
    -AuthoritativeAudienceActive $false `
    -ExistingState $optimistic `
    -Mode All `
    -RequestId 12 `
    -Now $now.AddMilliseconds(20)
Assert-Equal $optimistic.AllActive $false "Rapid second All press"
Assert-Equal $optimistic.AudienceActive $true "Rapid All press preserves Audience"
Assert-Equal $optimistic.AllRequestId 12 "Latest All request owns All prediction"
Assert-Equal $optimistic.AudienceRequestId 11 "Rapid All preserves Audience request"
Assert-Equal (Test-BeacnOptimisticRequestOwnership -State $optimistic -Mode All -RequestId 10) $false "An older All result cannot own a newer prediction"
Assert-Equal (Test-BeacnOptimisticRequestOwnership -State $optimistic -Mode All -RequestId 12) $true "The latest All result owns its prediction"
Assert-Equal (Test-BeacnOptimisticRequestOwnership -State $optimistic -Mode Audience -RequestId 11) $true "Audience ownership remains independent"

$display = Resolve-BeacnDisplayedActionState `
    -AuthoritativeAllActive $false `
    -AuthoritativeAudienceActive $false `
    -OptimisticState $optimistic `
    -Now $now.AddMilliseconds(30)
Assert-Equal $display.UseOptimistic $true "Pending state must drive the display"
Assert-Equal $display.AudienceActive $true "Pending Audience must be displayed"
$caughtUp = Resolve-BeacnDisplayedActionState `
    -AuthoritativeAllActive $false `
    -AuthoritativeAudienceActive $true `
    -OptimisticState $optimistic `
    -Now $now.AddMilliseconds(40)
Assert-Equal $caughtUp.UseOptimistic $false "Matching software state clears the prediction"
$expired = Resolve-BeacnDisplayedActionState `
    -AuthoritativeAllActive $false `
    -AuthoritativeAudienceActive $false `
    -OptimisticState $optimistic `
    -Now $now.AddSeconds(2)
Assert-Equal $expired.UseOptimistic $false "Expired prediction must not be displayed"

$stillLeased = Resolve-BeacnDisplayedActionState `
    -AuthoritativeAllActive $false `
    -AuthoritativeAudienceActive $false `
    -OptimisticState $optimistic `
    -Now $now.AddMilliseconds(700)
Assert-Equal $stillLeased.UseOptimistic $true "A recent high-confidence prediction must remain responsive"
$shortLeaseExpired = Resolve-BeacnDisplayedActionState `
    -AuthoritativeAllActive $false `
    -AuthoritativeAudienceActive $false `
    -OptimisticState $optimistic `
    -Now $now.AddSeconds(1)
Assert-Equal $shortLeaseExpired.UseOptimistic $false "An incorrect prediction must return to authoritative state promptly"
$unknownDisplay = Resolve-BeacnDisplayedActionState `
    -AuthoritativeAllActive $true `
    -AuthoritativeAudienceActive $true `
    -AuthoritativeStateKnown $false `
    -OptimisticState $optimistic `
    -Now $now.AddMilliseconds(100)
Assert-Equal $unknownDisplay.StateKnown $false "An unreadable row must remain explicitly unknown"
Assert-Equal $unknownDisplay.AllActive $false "An unreadable row must fail closed for All"
Assert-Equal $unknownDisplay.AudienceActive $false "An unreadable row must fail closed for Audience"
Assert-Equal $unknownDisplay.UseOptimistic $false "An unreadable row must not reuse an optimistic state"
$leaseBoundary = [DateTime]$optimistic.At
$at849 = Resolve-BeacnDisplayedActionState $false $false $true $optimistic $leaseBoundary.AddMilliseconds(849)
$at850 = Resolve-BeacnDisplayedActionState $false $false $true $optimistic $leaseBoundary.AddMilliseconds(850)
$clockMovedBackward = Resolve-BeacnDisplayedActionState $false $false $true $optimistic $leaseBoundary.AddMilliseconds(-1)
Assert-Equal $at849.UseOptimistic $true "The optimistic lease must remain active just before its boundary"
Assert-Equal $at850.UseOptimistic $false "The optimistic lease must expire at its boundary"
Assert-Equal $clockMovedBackward.UseOptimistic $false "A backward clock must not extend an optimistic lease"

$physicalOptimistic = New-BeacnOptimisticActionState `
    -AuthoritativeAllActive $false `
    -AuthoritativeAudienceActive $false `
    -ExistingState $null `
    -Mode All `
    -RequestId 50 `
    -Position 2 `
    -MaximumAgeSeconds 4.0 `
    -Now $leaseBoundary
$physicalBeforeBoundary = Resolve-BeacnDisplayedActionState $false $false $true $physicalOptimistic $leaseBoundary.AddSeconds(3.999)
$physicalAtBoundary = Resolve-BeacnDisplayedActionState $false $false $true $physicalOptimistic $leaseBoundary.AddSeconds(4)
Assert-Equal $physicalBeforeBoundary.UseOptimistic $true "A confident physical mapping must remain responsive through a slow confirmation"
Assert-Equal $physicalAtBoundary.UseOptimistic $false "A physical prediction must still have a bounded lease"
Assert-Equal (Test-BeacnOptimisticActionStateActive $physicalOptimistic $leaseBoundary.AddSeconds(3.999)) $true "A rapid follow-up press may chain inside the owned lease"
Assert-Equal (Test-BeacnOptimisticActionStateActive $physicalOptimistic $leaseBoundary.AddSeconds(4)) $false "An expired prediction cannot authorize a follow-up preview"

$micOverlap = Get-BeacnActionPointCandidateScore -X 200 -Y 105 -Left 100 -Top 100 -Right 140 -Bottom 110
$systemDirect = Get-BeacnActionPointCandidateScore -X 200 -Y 105 -Left 180 -Top 100 -Right 220 -Bottom 110
Assert-Equal ($null -ne $micOverlap) $true "The test must exercise horizontally overlapping padded action regions"
Assert-Equal (Test-BeacnActionPointCandidatePreferred -Score $systemDirect -BestScore $micOverlap) $true "A direct neighboring label must beat the preceding fader's padded region"
$allOverlap = Get-BeacnActionPointCandidateScore -X 200 -Y 116 -Left 180 -Top 100 -Right 220 -Bottom 110
$audienceDirect = Get-BeacnActionPointCandidateScore -X 200 -Y 116 -Left 180 -Top 114 -Right 220 -Bottom 124
Assert-Equal ($null -ne $allOverlap) $true "The test must exercise vertically overlapping padded action rows"
Assert-Equal (Test-BeacnActionPointCandidatePreferred -Score $audienceDirect -BestScore $allOverlap) $true "The direct Audience row must beat the All row's padded region"

$performanceTracker = New-BeacnActionTracker
$stopwatch = [Diagnostics.Stopwatch]::StartNew()
for ($index = 0; $index -lt 10000; $index++) {
    $all = ($index % 4) -ge 2
    $audience = ($index % 2) -eq 1
    [void](Submit-BeacnDirectActionSnapshot -Tracker $performanceTracker -AllActive $all -AudienceActive $audience -RequiredConfirmations 1)
}
$stopwatch.Stop()
if ($stopwatch.ElapsedMilliseconds -ge 2000) {
    throw "State model performance regression: $($stopwatch.ElapsedMilliseconds) ms for 10,000 snapshots"
}

"BeacnActionState tests: PASS ($($stopwatch.ElapsedMilliseconds) ms / 10,000 snapshots)"
