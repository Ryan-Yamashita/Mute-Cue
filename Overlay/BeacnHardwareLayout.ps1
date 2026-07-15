function Get-BeacnPagedSourceStartIndex {
    param(
        [int]$Page,
        [int]$SourceCount,
        [int]$PagedSlots
    )

    if ($SourceCount -le 0 -or $PagedSlots -le 0) { return 0 }
    $maximumStart = [Math]::Max(0, $SourceCount - $PagedSlots)
    $nominalStart = [Math]::Max(0, $Page) * $PagedSlots
    return [Math]::Min($nominalStart, $maximumStart)
}

function Get-BeacnHardwareLayoutModel {
    param(
        [AllowNull()][object[]]$States,
        [int]$Page = 0
    )

    $orderedStates = @(@($States) | Sort-Object Order)
    $lockedStates = @(
        $orderedStates |
            Where-Object { [bool]$_.IsLocked } |
            Select-Object -First 3
    )
    $unlockedStates = @($orderedStates | Where-Object { -not [bool]$_.IsLocked })
    $pagedSlots = [Math]::Max(1, 4 - $lockedStates.Count)
    $pageCount = [Math]::Max(1, [int][Math]::Ceiling($unlockedStates.Count / [double]$pagedSlots))
    $page = [Math]::Max(0, [Math]::Min($Page, $pageCount - 1))

    $names = New-Object 'System.Collections.Generic.List[string]'
    foreach ($state in $lockedStates) {
        $name = ([string]$state.Name).Trim()
        if (-not [string]::IsNullOrWhiteSpace($name)) { [void]$names.Add($name) }
    }
    $startIndex = Get-BeacnPagedSourceStartIndex `
        -Page $page `
        -SourceCount $unlockedStates.Count `
        -PagedSlots $pagedSlots
    for ($offset = 0; $offset -lt $pagedSlots; $offset++) {
        $sourceIndex = $startIndex + $offset
        if ($sourceIndex -ge $unlockedStates.Count) { break }
        $name = ([string]$unlockedStates[$sourceIndex].Name).Trim()
        if (-not [string]::IsNullOrWhiteSpace($name)) { [void]$names.Add($name) }
    }

    [pscustomobject]@{
        Page = $page
        PageCount = $pageCount
        PagedSlots = $pagedSlots
        LockedCount = $lockedStates.Count
        PagedStartIndex = $startIndex
        Names = @($names.ToArray())
    }
}

function Find-BeacnHardwareSourceMatch {
    param(
        [AllowNull()][object[]]$States,
        [int]$Position,
        [AllowNull()][string]$SourceName
    )

    if ($Position -lt 0 -or $Position -gt 3 -or [string]::IsNullOrWhiteSpace($SourceName)) {
        return $null
    }
    $orderedStates = @(@($States) | Sort-Object Order)
    $lockedStates = @(
        $orderedStates |
            Where-Object { [bool]$_.IsLocked } |
            Select-Object -First 3
    )
    if ($Position -lt $lockedStates.Count) {
        if ([string]::Equals(
            ([string]$lockedStates[$Position].Name).Trim(),
            $SourceName.Trim(),
            [StringComparison]::OrdinalIgnoreCase
        )) { return [pscustomobject]@{ Page = $null } }
        return $null
    }

    $unlockedStates = @($orderedStates | Where-Object { -not [bool]$_.IsLocked })
    $pagedSlots = [Math]::Max(1, 4 - $lockedStates.Count)
    $pageOffset = $Position - $lockedStates.Count
    if ($pageOffset -lt 0 -or $pageOffset -ge $pagedSlots) { return $null }

    $sourceIndex = -1
    for ($index = 0; $index -lt $unlockedStates.Count; $index++) {
        if ([string]::Equals(
            ([string]$unlockedStates[$index].Name).Trim(),
            $SourceName.Trim(),
            [StringComparison]::OrdinalIgnoreCase
        )) {
            $sourceIndex = $index
            break
        }
    }
    if ($sourceIndex -lt 0) { return $null }

    $pageCount = [Math]::Max(1, [int][Math]::Ceiling($unlockedStates.Count / [double]$pagedSlots))
    for ($page = 0; $page -lt $pageCount; $page++) {
        $startIndex = Get-BeacnPagedSourceStartIndex `
            -Page $page `
            -SourceCount $unlockedStates.Count `
            -PagedSlots $pagedSlots
        if (($startIndex + $pageOffset) -eq $sourceIndex) {
            return [pscustomobject]@{ Page = $page }
        }
    }
    return $null
}

function Get-BeacnHardwareLayoutFingerprint {
    param([AllowNull()][object[]]$States)

    return @(
        @($States) |
            Sort-Object Order |
            ForEach-Object {
                "{0}:{1}" -f (Get-BeacnStableFaderKey -Name ([string]$_.Name)), [int][bool]$_.IsLocked
            }
    ) -join "|"
}
