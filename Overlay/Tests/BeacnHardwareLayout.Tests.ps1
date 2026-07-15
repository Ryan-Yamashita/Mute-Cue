$ErrorActionPreference = "Stop"
$overlayDirectory = Split-Path -Parent $PSScriptRoot
. (Join-Path $overlayDirectory "BeacnActionState.ps1")
. (Join-Path $overlayDirectory "BeacnAdapter.ps1")
. (Join-Path $overlayDirectory "BeacnHardwareLayout.ps1")

function Assert-Layout {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

function New-LayoutState {
    param([int]$Order, [string]$Name, [bool]$Locked = $false)
    [pscustomobject]@{ Order = $Order; Name = $Name; IsLocked = $Locked }
}

$sevenUnlocked = @(
    for ($index = 0; $index -lt 7; $index++) {
        New-LayoutState -Order $index -Name ("F{0}" -f ($index + 1))
    }
)
$firstPage = Get-BeacnHardwareLayoutModel -States $sevenUnlocked -Page 0
$finalPage = Get-BeacnHardwareLayoutModel -States $sevenUnlocked -Page 1
Assert-Layout ($firstPage.PageCount -eq 2 -and ($firstPage.Names -join ',') -eq 'F1,F2,F3,F4') "The first four-knob page is incorrect."
Assert-Layout ($finalPage.PagedStartIndex -eq 3 -and ($finalPage.Names -join ',') -eq 'F4,F5,F6,F7') "The overlapping final page must slide backward to fill four knobs."
Assert-Layout ((Find-BeacnHardwareSourceMatch -States $sevenUnlocked -Position 0 -SourceName 'F4').Page -eq 1) "Final-page overlap must map F4 at position zero to page one."
Assert-Layout ((Find-BeacnHardwareSourceMatch -States $sevenUnlocked -Position 3 -SourceName 'F4').Page -eq 0) "First-page F4 must remain independently addressable."

$oneLocked = @(
    New-LayoutState -Order 0 -Name 'Mic' -Locked $true
    for ($index = 0; $index -lt 6; $index++) {
        New-LayoutState -Order ($index + 1) -Name ("U{0}" -f ($index + 1))
    }
)
$oneLockedFinal = Get-BeacnHardwareLayoutModel -States $oneLocked -Page 1
Assert-Layout ($oneLockedFinal.PagedSlots -eq 3 -and ($oneLockedFinal.Names -join ',') -eq 'Mic,U4,U5,U6') "One locked fader must leave three paged positions."
$lockedMatch = Find-BeacnHardwareSourceMatch -States $oneLocked -Position 0 -SourceName 'Mic'
Assert-Layout ($null -ne $lockedMatch -and $null -eq $lockedMatch.Page) "A locked fader must not depend on page confidence."
Assert-Layout ((Find-BeacnHardwareSourceMatch -States $oneLocked -Position 2 -SourceName 'U5').Page -eq 1) "Unlocked sources must account for the locked-position offset."

$twoLocked = @(
    New-LayoutState -Order 0 -Name 'Mic' -Locked $true
    New-LayoutState -Order 1 -Name 'System' -Locked $true
    for ($index = 0; $index -lt 5; $index++) {
        New-LayoutState -Order ($index + 2) -Name ("P{0}" -f ($index + 1))
    }
)
$twoLockedMiddle = Get-BeacnHardwareLayoutModel -States $twoLocked -Page 1
$twoLockedFinal = Get-BeacnHardwareLayoutModel -States $twoLocked -Page 2
Assert-Layout (($twoLockedMiddle.Names -join ',') -eq 'Mic,System,P3,P4') "Two locked faders must leave two paged positions."
Assert-Layout ($twoLockedFinal.PagedStartIndex -eq 3 -and ($twoLockedFinal.Names -join ',') -eq 'Mic,System,P4,P5') "Two-lock final-page overlap is incorrect."

$threeLocked = @(
    New-LayoutState -Order 0 -Name 'L1' -Locked $true
    New-LayoutState -Order 1 -Name 'L2' -Locked $true
    New-LayoutState -Order 2 -Name 'L3' -Locked $true
    New-LayoutState -Order 3 -Name 'Only1'
    New-LayoutState -Order 4 -Name 'Only2'
    New-LayoutState -Order 5 -Name 'Only3'
)
$threeLockedFinal = Get-BeacnHardwareLayoutModel -States $threeLocked -Page 99
Assert-Layout ($threeLockedFinal.Page -eq 2 -and $threeLockedFinal.PagedSlots -eq 1) "Three locks must clamp to the last one-source page."
Assert-Layout (($threeLockedFinal.Names -join ',') -eq 'L1,L2,L3,Only3') "Three locked faders must remain on every page."

$fingerprintA = Get-BeacnHardwareLayoutFingerprint -States $oneLocked
$fingerprintB = Get-BeacnHardwareLayoutFingerprint -States @(
    for ($index = $oneLocked.Count - 1; $index -ge 0; $index--) {
        New-LayoutState `
            -Order ($oneLocked.Count - 1 - $index) `
            -Name ([string]$oneLocked[$index].Name) `
            -Locked ([bool]$oneLocked[$index].IsLocked)
    }
)
Assert-Layout ($fingerprintA -ne $fingerprintB) "A reordered fader layout must invalidate the fingerprint."
Assert-Layout ($null -eq (Find-BeacnHardwareSourceMatch -States $oneLocked -Position 4 -SourceName 'U1')) "Invalid physical positions must fail safely."

"BeacnHardwareLayout tests: PASS"
