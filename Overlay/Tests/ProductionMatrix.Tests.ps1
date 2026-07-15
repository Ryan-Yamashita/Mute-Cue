$ErrorActionPreference = "Stop"
$overlayDirectory = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
. (Join-Path $overlayDirectory "BeacnActionState.ps1")
. (Join-Path $overlayDirectory "BeacnAdapter.ps1")
. (Join-Path $overlayDirectory "BeacnHardwareLayout.ps1")
. (Join-Path $overlayDirectory "BeacnStateCoordinator.ps1")

function Assert-ProductionMatrix {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

function New-MatrixFader {
    param(
        [int]$Order,
        [string]$Name,
        [int]$LockedCount,
        [double]$OffsetX = 0,
        [double]$OffsetY = 0,
        [bool]$All = $false,
        [bool]$Audience = $false
    )
    $left = $OffsetX + 20 + ($Order * 110)
    $top = $OffsetY + 100
    [pscustomobject]@{
        Order = $Order
        Name = $Name
        PersonalMuted = $All
        AudienceMuted = ($All -or $Audience)
        IsLocked = $Order -lt $LockedCount
        AllActionStateKnown = $true
        AllActionActive = $All
        AudienceActionStateKnown = $true
        AudienceActionActive = $Audience
        HasAllActionBounds = $true
        AllActionLeft = $left
        AllActionTop = $top
        AllActionRight = $left + 90
        AllActionBottom = $top + 24
        HasAudienceActionBounds = $true
        AudienceActionLeft = $left
        AudienceActionTop = $top + 25
        AudienceActionRight = $left + 90
        AudienceActionBottom = $top + 49
    }
}

function New-MatrixStates {
    param(
        [string[]]$Names,
        [int]$LockedCount,
        [double]$OffsetX = 0,
        [double]$OffsetY = 0,
        [string]$ActiveName = "",
        [ValidateSet("None", "All", "Audience", "Both")][string]$Mode = "None"
    )
    @(
        for ($index = 0; $index -lt $Names.Count; $index++) {
            $isActive = $Names[$index] -eq $ActiveName
            New-MatrixFader `
                -Order $index `
                -Name $Names[$index] `
                -LockedCount $LockedCount `
                -OffsetX $OffsetX `
                -OffsetY $OffsetY `
                -All ($isActive -and $Mode -in @("All", "Both")) `
                -Audience ($isActive -and $Mode -in @("Audience", "Both"))
        }
    )
}

$allNames = @("Mic", "System", "Link In", "Game", "Link 2 In", "Chat", "Hardware", "Music", "Browser", "Aux 1", "Aux 2", "Link 3 In", "Link 4 In")
$scenarios = @(
    [pscustomobject]@{ Count = 4; Locked = 0; X = 0; Y = 0 },
    [pscustomobject]@{ Count = 7; Locked = 1; X = -2560; Y = 0 },
    [pscustomobject]@{ Count = 8; Locked = 2; X = 0; Y = -1440 },
    [pscustomobject]@{ Count = 13; Locked = 3; X = -2560; Y = -1440 }
)

$timer = [Diagnostics.Stopwatch]::StartNew()
foreach ($scenario in $scenarios) {
    $names = @($allNames[0..($scenario.Count - 1)])
    $adapter = New-BeacnAdapterState
    $baselineRaw = New-MatrixStates -Names $names -LockedCount $scenario.Locked -OffsetX $scenario.X -OffsetY $scenario.Y
    $baseline = $null
    foreach ($confirmation in 1..3) { $baseline = Submit-BeacnAdapterSnapshot -Adapter $adapter -RawStates $baselineRaw }
    Assert-ProductionMatrix ($baseline.Accepted -and $baseline.HasActionAuthority) "$($scenario.Count)-fader layout did not become authoritative."
    Assert-ProductionMatrix (@($baseline.States).Count -eq $scenario.Count) "$($scenario.Count)-fader layout was truncated."
    Assert-ProductionMatrix ((@($baseline.States | Sort-Object Order | ForEach-Object Name) -join '|') -eq ($names -join '|')) "$($scenario.Count)-fader order changed."

    $model = Get-BeacnHardwareLayoutModel -States $baseline.States -Page 999
    Assert-ProductionMatrix ($model.Names.Count -le 4 -and $model.Names.Count -gt 0) "The four-knob hardware model produced an invalid page."
    foreach ($page in 0..([Math]::Max(0, $model.PageCount - 1))) {
        $pageModel = Get-BeacnHardwareLayoutModel -States $baseline.States -Page $page
        for ($position = 0; $position -lt $pageModel.Names.Count; $position++) {
            $match = Find-BeacnHardwareSourceMatch -States $baseline.States -Position $position -SourceName $pageModel.Names[$position]
            Assert-ProductionMatrix ($null -ne $match) "Hardware mapping failed for $($pageModel.Names[$position]) on page $page."
        }
    }

    foreach ($name in $names) {
        foreach ($mode in @("All", "Audience", "Both")) {
            $activeRaw = New-MatrixStates -Names $names -LockedCount $scenario.Locked -OffsetX $scenario.X -OffsetY $scenario.Y -ActiveName $name -Mode $mode
            [void](Submit-BeacnAdapterSnapshot -Adapter $adapter -RawStates $activeRaw)
            $active = Submit-BeacnAdapterSnapshot -Adapter $adapter -RawStates $activeRaw
            $expectedAll = $mode -in @("All", "Both")
            $expectedAudience = $mode -in @("Audience", "Both")
            Assert-ProductionMatrix ($active.ByName[$name].AllActive -eq $expectedAll) "$name All failed in the $($scenario.Count)-fader matrix."
            Assert-ProductionMatrix ($active.ByName[$name].AudienceActive -eq $expectedAudience) "$name Audience failed in the $($scenario.Count)-fader matrix."
            [void](Submit-BeacnAdapterSnapshot -Adapter $adapter -RawStates $baselineRaw)
            $restored = Submit-BeacnAdapterSnapshot -Adapter $adapter -RawStates $baselineRaw
            Assert-ProductionMatrix (-not $restored.ByName[$name].AllActive -and -not $restored.ByName[$name].AudienceActive) "$name did not restore cleanly."
        }
    }

    $movedRaw = New-MatrixStates -Names $names -LockedCount $scenario.Locked -OffsetX ($scenario.X + 317) -OffsetY ($scenario.Y + 211)
    $moved = Submit-BeacnAdapterSnapshot -Adapter $adapter -RawStates $movedRaw
    $geometryChanged = (Get-BeacnGeometryFingerprint -States $baselineRaw) -ne (Get-BeacnGeometryFingerprint -States $movedRaw)
    Assert-ProductionMatrix ($geometryChanged -and -not $moved.LayoutInvalidated) "Monitor movement incorrectly invalidated the $($scenario.Count)-fader layout (geometry=$geometryChanged; invalidated=$($moved.LayoutInvalidated))."

    $reversedNames = @($names[($names.Count - 1)..0])
    $reversedRaw = New-MatrixStates -Names $reversedNames -LockedCount $scenario.Locked -OffsetX $scenario.X -OffsetY $scenario.Y
    $reorderEdge = Submit-BeacnAdapterSnapshot -Adapter $adapter -RawStates $reversedRaw
    $reorderCommit = Submit-BeacnAdapterSnapshot -Adapter $adapter -RawStates $reversedRaw
    Assert-ProductionMatrix ($reorderEdge.LayoutInvalidated -and -not $reorderEdge.HasActionAuthority) "Reorder did not fail closed immediately."
    Assert-ProductionMatrix ($reorderCommit.LayoutChanged -and $reorderCommit.HasActionAuthority) "Reorder did not publish atomically after confirmation."
}
$timer.Stop()
Assert-ProductionMatrix ($timer.ElapsedMilliseconds -lt 10000) "The production matrix exceeded its ten-second processing budget."

"Production matrix tests: PASS ($($timer.ElapsedMilliseconds) ms; 4/7/8/13 faders; 0/1/2/3 locks; mixed monitor coordinates)"
