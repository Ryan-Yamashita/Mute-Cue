function Get-BeacnDefaultFaderNames {
    @(
        "Mic", "System", "Link In", "Game", "Link 2 In", "Chat", "Hardware",
        "Music", "Browser", "Aux 1", "Aux 2", "Link 3 In", "Link 4 In"
    )
}

function Get-BeacnCompatibilityProfile {
    param([AllowNull()][string]$Version)

    $manifestPath = Join-Path $PSScriptRoot "BeacnCompatibility.json"
    $profiles = @()
    try { $profiles = @((Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json).profiles) } catch {}
    if ($profiles.Count -eq 0) {
        return [pscustomobject]@{
            Id = "built-in-fallback"
            Verified = $false
            AllActionLabels = @("Knob: Mute to All")
            AudienceActionLabels = @("Mute to Audience")
        }
    }
    $parsedVersion = [Version]::new(0, 0, 0)
    $hasVersion = [Version]::TryParse(([string]$Version).Trim(), [ref]$parsedVersion)
    foreach ($profile in @($profiles | Where-Object { [bool]$_.verified })) {
        $minimum = [Version]::Parse([string]$profile.minimumVersion)
        $maximum = [Version]::Parse([string]$profile.maximumVersionExclusive)
        if ($hasVersion -and $parsedVersion -ge $minimum -and $parsedVersion -lt $maximum) {
            return [pscustomobject]@{
                Id = [string]$profile.id
                Verified = $true
                AllActionLabels = @($profile.allActionLabels)
                AudienceActionLabels = @($profile.audienceActionLabels)
            }
        }
    }
    $fallback = @($profiles | Where-Object { -not [bool]$_.verified } | Select-Object -First 1)
    $selected = if ($fallback.Count -gt 0) { $fallback[0] } else { $profiles[-1] }
    return [pscustomobject]@{
        Id = [string]$selected.id
        Verified = $false
        AllActionLabels = @($selected.allActionLabels)
        AudienceActionLabels = @($selected.audienceActionLabels)
    }
}

function Get-BeacnMixerProfilePath {
    $beacnDataPath = Join-Path ([Environment]::GetFolderPath("MyDocuments")) "BEACN"
    $profilesPath = Join-Path $beacnDataPath "profiles\MixerProfiles"
    if (-not (Test-Path -LiteralPath $profilesPath)) { return $null }

    $profileName = $null
    $lastLoadedPath = Join-Path $env:APPDATA "BEACN\lastLoaded.profiles"
    if (Test-Path -LiteralPath $lastLoadedPath) {
        try {
            [xml]$lastLoaded = Get-Content -LiteralPath $lastLoadedPath -Raw -ErrorAction Stop
            $profileName = [string]$lastLoaded.lastLoadedProfiles.MixerProfile.lastLoadedProfile
        } catch {}
    }

    if (-not [string]::IsNullOrWhiteSpace($profileName)) {
        $activePath = Join-Path $profilesPath ($profileName + ".beacnMixer")
        if (Test-Path -LiteralPath $activePath) { return $activePath }
    }

    return Get-ChildItem -LiteralPath $profilesPath -Filter "*.beacnMixer" -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1 -ExpandProperty FullName
}

function Get-BeacnProfileFaderDefinitions {
    $result = New-Object 'System.Collections.Generic.List[object]'
    try {
        $profilePath = Get-BeacnMixerProfilePath
        if ([string]::IsNullOrWhiteSpace($profilePath)) { return @() }

        [xml]$profile = Get-Content -LiteralPath $profilePath -Raw -ErrorAction Stop
        $profileMixers = @(
            $profile.DSPData.mixerTree.ChildNodes |
                Where-Object { $_.Name -match '^mixer\d+$' } |
                Sort-Object { [int]($_.Name -replace '\D', '') }
        )
        $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($mixer in $profileMixers) {
            if ($mixer.Name -notmatch '^mixer(\d+)$') { continue }
            $id = [int]$Matches[1]
            $name = ([string]$mixer.mixerName).Trim()
            if ([string]::IsNullOrWhiteSpace($name)) { continue }

            # Some BEACN profiles retain stale records after the live Add Fader
            # card. A repeated name marks that stale tail in affected versions.
            if (-not $seen.Add($name)) { break }
            [void]$result.Add([pscustomobject]@{
                Id = $id
                StableKey = "profile:$id"
                Name = $name
            })
        }
    } catch {}
    return @($result.ToArray())
}

function Get-BeacnCompatibilityCandidateNames {
    $names = New-Object 'System.Collections.Generic.List[string]'
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($fader in @(Get-BeacnProfileFaderDefinitions)) {
        $name = ([string]$fader.Name).Trim()
        if (-not [string]::IsNullOrWhiteSpace($name) -and $seen.Add($name)) {
            [void]$names.Add($name)
        }
    }
    foreach ($name in @(Get-BeacnDefaultFaderNames)) {
        if ($seen.Add($name)) { [void]$names.Add($name) }
    }
    return @($names.ToArray())
}

function Initialize-BeacnScannerAdapter {
    if ($null -eq ('BeacnMuteOverlay.BeacnAppScanner' -as [type])) { return }
    $candidateNames = [string[]]@(Get-BeacnCompatibilityCandidateNames)
    [BeacnMuteOverlay.BeacnAppScanner]::ConfigureCompatibility(
        $candidateNames,
        [string[]]@("Knob: Mute to All"),
        [string[]]@("Mute to Audience")
    )
}

function Update-BeacnAdapterIdentityCatalog {
    param([Parameter(Mandatory)][object]$Adapter)

    $identityByName = @{}
    foreach ($profileFader in @(Get-BeacnProfileFaderDefinitions)) {
        $profileName = ([string]$profileFader.Name).Trim()
        if (-not [string]::IsNullOrWhiteSpace($profileName)) {
            $identityByName[$profileName] = [string]$profileFader.StableKey
        }
    }
    $oldSignature = @(
        $Adapter.IdentityByName.GetEnumerator() |
            Sort-Object Name |
            ForEach-Object { "{0}={1}" -f $_.Name.ToLowerInvariant(), ([string]$_.Value).ToLowerInvariant() }
    ) -join "|"
    $newSignature = @(
        $identityByName.GetEnumerator() |
            Sort-Object Name |
            ForEach-Object { "{0}={1}" -f $_.Name.ToLowerInvariant(), ([string]$_.Value).ToLowerInvariant() }
    ) -join "|"
    $Adapter.IdentityByName = $identityByName
    return $oldSignature -ne $newSignature
}

function Update-BeacnScannerAdapterConfiguration {
    param(
        [Parameter(Mandatory)][object]$Adapter,
        [switch]$Force
    )

    $now = [DateTime]::UtcNow
    if (
        -not $Force -and
        ($now - [DateTime]$Adapter.LastCompatibilityCandidateCheckUtc).TotalSeconds -lt 5
    ) { return $false }
    $Adapter.LastCompatibilityCandidateCheckUtc = $now

    [void](Update-BeacnAdapterIdentityCatalog -Adapter $Adapter)
    $candidateNames = [string[]]@(Get-BeacnCompatibilityCandidateNames)
    $beacnVersion = ""
    try { $beacnVersion = [string][BeacnMuteOverlay.BeacnAppScanner]::BeacnVersion } catch {}
    $compatibilityProfile = Get-BeacnCompatibilityProfile -Version $beacnVersion
    $Adapter.CompatibilityProfileId = [string]$compatibilityProfile.Id
    $Adapter.CompatibilityProfileVerified = [bool]$compatibilityProfile.Verified
    $signature = (@($candidateNames | ForEach-Object { $_.Trim().ToLowerInvariant() }) -join "|") + "||" + [string]$compatibilityProfile.Id
    if (-not $Force -and $signature -eq [string]$Adapter.CompatibilityCandidateSignature) { return $false }

    [BeacnMuteOverlay.BeacnAppScanner]::ConfigureCompatibility(
        $candidateNames,
        [string[]]@($compatibilityProfile.AllActionLabels),
        [string[]]@($compatibilityProfile.AudienceActionLabels)
    )
    $Adapter.CompatibilityCandidateSignature = $signature
    return $true
}

function Get-BeacnStableFaderKey {
    param(
        [AllowNull()][string]$Name,
        [AllowNull()][System.Collections.IDictionary]$IdentityByName
    )

    if ([string]::IsNullOrWhiteSpace($Name)) { return "" }
    if ($null -ne $IdentityByName -and $IdentityByName.Contains($Name.Trim())) {
        $identity = ([string]$IdentityByName[$Name.Trim()]).Trim()
        if (-not [string]::IsNullOrWhiteSpace($identity)) { return $identity.ToLowerInvariant() }
    }
    return $Name.Trim().ToLowerInvariant()
}

function Get-BeacnRawLayoutFingerprint {
    param(
        [AllowNull()][object[]]$States,
        [AllowNull()][System.Collections.IDictionary]$IdentityByName
    )

    return @(
        @($States) |
            Sort-Object Order |
            ForEach-Object {
                "{0}:{1}:{2}" -f `
                    [int]$_.Order, `
                    (Get-BeacnStableFaderKey -Name ([string]$_.Name) -IdentityByName $IdentityByName), `
                    [int][bool]$_.IsLocked
            }
    ) -join "|"
}

function New-BeacnAdapterState {
    [pscustomobject]@{
        Trackers = @{}
        IdentityByName = @{}
        PublishedStates = @()
        PublishedByName = @{}
        LayoutFingerprint = ""
        PendingLayoutFingerprint = ""
        PendingLayoutConfirmations = 0
        InvalidatedLayoutFingerprint = ""
        LayoutGeneration = 0L
        NeedsConfirmation = $true
        CompatibilityStatus = "Discovering"
        CompatibilityDetail = "Waiting for the BEACN mixer layout."
        CompatibilityCandidateSignature = ""
        CompatibilityProfileId = ""
        CompatibilityProfileVerified = $false
        LastCompatibilityCandidateCheckUtc = [DateTime]::MinValue
        LastRawSnapshotUtc = [DateTime]::MinValue
        LastPublishedSnapshotUtc = [DateTime]::MinValue
    }
}

function New-BeacnPublishedFaderState {
    param(
        [Parameter(Mandatory)][object]$RawState,
        [Parameter(Mandatory)][object]$Tracker,
        [Parameter(Mandatory)][bool]$DirectActionStateKnown,
        [Parameter(Mandatory)][string]$StableKey
    )

    [pscustomobject]@{
        Order = [int]$RawState.Order
        StableKey = $StableKey
        Name = [string]$RawState.Name
        IsLocked = [bool]$RawState.IsLocked
        PersonalMuted = ([bool]$Tracker.Known -and [bool]$Tracker.PersonalMuted)
        AudienceMuted = ([bool]$Tracker.Known -and [bool]$Tracker.AudienceMuted)
        Mode = if ([bool]$Tracker.Known) { [string]$Tracker.Mode } else { $null }
        AllActive = ([bool]$Tracker.Known -and [bool]$Tracker.AllActive)
        AudienceActive = ([bool]$Tracker.Known -and [bool]$Tracker.AudienceActive)
        ActionStateKnown = ([bool]$Tracker.Known -and $DirectActionStateKnown)
        HasAllActionBounds = [bool]$RawState.HasAllActionBounds
        AllActionLeft = [double]$RawState.AllActionLeft
        AllActionTop = [double]$RawState.AllActionTop
        AllActionRight = [double]$RawState.AllActionRight
        AllActionBottom = [double]$RawState.AllActionBottom
        HasAudienceActionBounds = [bool]$RawState.HasAudienceActionBounds
        AudienceActionLeft = [double]$RawState.AudienceActionLeft
        AudienceActionTop = [double]$RawState.AudienceActionTop
        AudienceActionRight = [double]$RawState.AudienceActionRight
        AudienceActionBottom = [double]$RawState.AudienceActionBottom
    }
}

function Submit-BeacnAdapterSnapshot {
    param(
        [Parameter(Mandatory)][object]$Adapter,
        [AllowNull()][object[]]$RawStates,
        [int]$RequiredConfirmations = 2
    )

    if ($RequiredConfirmations -lt 1) { $RequiredConfirmations = 1 }
    $now = [DateTime]::UtcNow
    $ordered = @(@($RawStates) | Sort-Object Order)
    $Adapter.LastRawSnapshotUtc = $now

    if ($ordered.Count -eq 0) {
        $Adapter.NeedsConfirmation = $true
        $Adapter.CompatibilityStatus = "Unavailable"
        $Adapter.CompatibilityDetail = "No BEACN faders were discovered."
        return [pscustomobject]@{
            Accepted = $false
            HasAuthority = $false
            HasActionAuthority = $false
            NeedsConfirmation = $true
            LayoutChanged = $false
            LayoutInvalidated = $false
            States = @($Adapter.PublishedStates)
            ByName = $Adapter.PublishedByName
            CompatibilityStatus = [string]$Adapter.CompatibilityStatus
            CompatibilityDetail = [string]$Adapter.CompatibilityDetail
        }
    }

    $seenNames = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($rawState in $ordered) {
        $name = ([string]$rawState.Name).Trim()
        if ([string]::IsNullOrWhiteSpace($name) -or -not $seenNames.Add($name)) {
            $Adapter.NeedsConfirmation = $true
            $Adapter.CompatibilityStatus = "Incompatible"
            $Adapter.CompatibilityDetail = "The BEACN fader list contains a missing or duplicate identity."
            return [pscustomobject]@{
                Accepted = $false
                HasAuthority = ($Adapter.PublishedStates.Count -gt 0)
                HasActionAuthority = $false
                NeedsConfirmation = $true
                LayoutChanged = $false
                LayoutInvalidated = $false
                States = @($Adapter.PublishedStates)
                ByName = $Adapter.PublishedByName
                CompatibilityStatus = [string]$Adapter.CompatibilityStatus
                CompatibilityDetail = [string]$Adapter.CompatibilityDetail
            }
        }
    }

    $layoutFingerprint = Get-BeacnRawLayoutFingerprint -States $ordered -IdentityByName $Adapter.IdentityByName
    $layoutPending = $layoutFingerprint -ne [string]$Adapter.LayoutFingerprint
    $layoutInvalidated = $false
    $layoutChanged = $false
    if ($layoutPending) {
        if ([string]$Adapter.PendingLayoutFingerprint -eq $layoutFingerprint) {
            $Adapter.PendingLayoutConfirmations++
        } else {
            $Adapter.PendingLayoutFingerprint = $layoutFingerprint
            $Adapter.PendingLayoutConfirmations = 1
        }
        if ([string]$Adapter.InvalidatedLayoutFingerprint -ne $layoutFingerprint) {
            $Adapter.InvalidatedLayoutFingerprint = $layoutFingerprint
            $layoutInvalidated = -not [string]::IsNullOrWhiteSpace([string]$Adapter.LayoutFingerprint)
        }
        if ([int]$Adapter.PendingLayoutConfirmations -ge $RequiredConfirmations) {
            $layoutChanged = -not [string]::IsNullOrWhiteSpace([string]$Adapter.LayoutFingerprint)
            $Adapter.LayoutFingerprint = $layoutFingerprint
            $Adapter.PendingLayoutFingerprint = ""
            $Adapter.PendingLayoutConfirmations = 0
            $Adapter.LayoutGeneration++
            $layoutPending = $false
        }
    } else {
        $Adapter.PendingLayoutFingerprint = ""
        $Adapter.PendingLayoutConfirmations = 0
        $Adapter.InvalidatedLayoutFingerprint = ""
    }

    if ($layoutPending) {
        $Adapter.NeedsConfirmation = $true
        $Adapter.CompatibilityStatus = "Discovering"
        $Adapter.CompatibilityDetail = "Confirming the changed BEACN fader layout."
        return [pscustomobject]@{
            Accepted = $false
            HasAuthority = ($Adapter.PublishedStates.Count -gt 0)
            HasActionAuthority = $false
            NeedsConfirmation = $true
            LayoutChanged = $false
            LayoutInvalidated = $layoutInvalidated
            States = @($Adapter.PublishedStates)
            ByName = $Adapter.PublishedByName
            CompatibilityStatus = [string]$Adapter.CompatibilityStatus
            CompatibilityDetail = [string]$Adapter.CompatibilityDetail
        }
    }

    $published = New-Object 'System.Collections.Generic.List[object]'
    $publishedByName = @{}
    $activeKeys = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    $needsConfirmation = $false
    $missingActionRows = New-Object 'System.Collections.Generic.List[string]'
    foreach ($rawState in $ordered) {
        $name = ([string]$rawState.Name).Trim()
        $key = Get-BeacnStableFaderKey -Name $name -IdentityByName $Adapter.IdentityByName
        [void]$activeKeys.Add($key)
        if (-not $Adapter.Trackers.ContainsKey($key)) {
            $Adapter.Trackers[$key] = New-BeacnActionTracker
        }
        $tracker = $Adapter.Trackers[$key]
        $directKnown = [bool]$rawState.AllActionStateKnown -and [bool]$rawState.AudienceActionStateKnown
        if ($directKnown) {
            $submission = Submit-BeacnDirectActionSnapshot `
                -Tracker $tracker `
                -AllActive ([bool]$rawState.AllActionActive) `
                -AudienceActive ([bool]$rawState.AudienceActionActive) `
                -RequiredConfirmations $RequiredConfirmations
            if ([bool]$submission.Committed) {
                $tracker.PersonalMuted = [bool]$rawState.PersonalMuted
                $tracker.AudienceMuted = [bool]$rawState.AudienceMuted
            } else {
                $needsConfirmation = $true
            }
        } else {
            $needsConfirmation = $true
            [void]$missingActionRows.Add($name)
        }

        $state = New-BeacnPublishedFaderState `
            -RawState $rawState `
            -Tracker $tracker `
            -DirectActionStateKnown $directKnown `
            -StableKey $key
        [void]$published.Add($state)
        $publishedByName[$name] = $state
    }

    foreach ($key in @($Adapter.Trackers.Keys)) {
        if (-not $activeKeys.Contains([string]$key)) { [void]$Adapter.Trackers.Remove($key) }
    }

    $Adapter.PublishedStates = @($published.ToArray())
    $Adapter.PublishedByName = $publishedByName
    $Adapter.NeedsConfirmation = $needsConfirmation
    $Adapter.LastPublishedSnapshotUtc = $now
    if ($missingActionRows.Count -gt 0) {
        $Adapter.CompatibilityStatus = "Degraded"
        $Adapter.CompatibilityDetail = "Independent mute rows were not readable for: $($missingActionRows -join ', ')."
    } elseif ($needsConfirmation) {
        $Adapter.CompatibilityStatus = "Synchronizing"
        $Adapter.CompatibilityDetail = "Confirming the latest BEACN mute state."
    } else {
        $Adapter.CompatibilityStatus = "Ready"
        $Adapter.CompatibilityDetail = "$($published.Count) faders are synchronized."
    }

    $hasActionAuthority = (
        $published.Count -gt 0 -and
        $missingActionRows.Count -eq 0 -and
        @($published | Where-Object { -not [bool]$_.ActionStateKnown }).Count -eq 0
    )
    return [pscustomobject]@{
        Accepted = $true
        HasAuthority = ($published.Count -gt 0)
        HasActionAuthority = $hasActionAuthority
        NeedsConfirmation = $needsConfirmation
        LayoutChanged = $layoutChanged
        LayoutInvalidated = $layoutInvalidated
        States = @($Adapter.PublishedStates)
        ByName = $Adapter.PublishedByName
        CompatibilityStatus = [string]$Adapter.CompatibilityStatus
        CompatibilityDetail = [string]$Adapter.CompatibilityDetail
    }
}
