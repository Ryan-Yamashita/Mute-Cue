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
