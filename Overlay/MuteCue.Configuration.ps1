if ($null -eq (Get-Command Read-MuteCueSharedText -ErrorAction SilentlyContinue)) {
    . (Join-Path $PSScriptRoot "MuteCue.AtomicFile.ps1")
}

function Get-MuteCueDefaultSettings {
    [ordered]@{
        SchemaVersion = 5
        X = 250
        Y = 180
        Size = 420
        Opacity = 0.88
        ClickThrough = $false
        BeacnDirectDetect = $true
        BeacnFaderNames = "Mic"
        # Retained only for one-time migration from older installations.
        BeacnFaderIndices = "0,1,2,3,4,5,6,7"
        BeacnAudienceFaderIds = "0,1,2,3,4,5,6,7"
        BeacnAllFaderIds = "0,1,2,3,4,5,6,7"
        BeacnAudienceFaderNames = "Mic,System,Link In,Game,Link 2 In,Chat,Hardware,Music,Browser,Aux 1,Aux 2,Link 3 In,Link 4 In"
        BeacnAllFaderNames = "Mic,System,Link In,Game,Link 2 In,Chat,Hardware,Music,Browser,Aux 1,Aux 2,Link 3 In,Link 4 In"
        BeacnAudienceFaderKeys = ""
        BeacnAllFaderKeys = ""
        BeacnFaderSelectionFormat = 3
        BeacnAudienceDetect = $true
        BeacnMuteAllDetect = $true
        BeacnMuteAllMuted = $false
        DiscordMicDetect = $true
        DiscordDeafenDetect = $true
        ForceShow = $false
        CloseToSystemTray = $false
        StartInSystemTray = $false
    }
}

function Test-MuteCueSettingExists {
    param([AllowNull()][object]$Settings, [Parameter(Mandatory)][string]$Name)

    if ($null -eq $Settings) { return $false }
    if ($Settings -is [System.Collections.IDictionary]) { return $Settings.Contains($Name) }
    return $null -ne $Settings.PSObject.Properties[$Name]
}

function Get-MuteCueSettingValue {
    param([AllowNull()][object]$Settings, [Parameter(Mandatory)][string]$Name, $Fallback)

    if (-not (Test-MuteCueSettingExists -Settings $Settings -Name $Name)) { return $Fallback }
    if ($Settings -is [System.Collections.IDictionary]) { return $Settings[$Name] }
    return $Settings.PSObject.Properties[$Name].Value
}

function ConvertTo-MuteCueBoolean {
    param($Value, [bool]$Fallback)

    if ($Value -is [bool]) { return [bool]$Value }
    if ($Value -is [string]) {
        $parsed = $false
        if ([bool]::TryParse($Value, [ref]$parsed)) { return $parsed }
        if ($Value -eq "1") { return $true }
        if ($Value -eq "0") { return $false }
    }
    try { return [Convert]::ToBoolean($Value, [Globalization.CultureInfo]::InvariantCulture) } catch { return $Fallback }
}

function ConvertTo-MuteCueInteger {
    param($Value, [int]$Fallback, [int]$Minimum, [int]$Maximum)

    try { $converted = [Convert]::ToInt32($Value, [Globalization.CultureInfo]::InvariantCulture) } catch { $converted = $Fallback }
    return [Math]::Max($Minimum, [Math]::Min($Maximum, $converted))
}

function ConvertTo-MuteCueDouble {
    param($Value, [double]$Fallback, [double]$Minimum, [double]$Maximum)

    try { $converted = [Convert]::ToDouble($Value, [Globalization.CultureInfo]::InvariantCulture) } catch { $converted = $Fallback }
    if ([double]::IsNaN($converted) -or [double]::IsInfinity($converted)) { $converted = $Fallback }
    return [Math]::Max($Minimum, [Math]::Min($Maximum, $converted))
}

function ConvertTo-MuteCueString {
    param($Value, [string]$Fallback, [int]$MaximumLength = 4096)

    if ($null -eq $Value) { return $Fallback }
    $converted = [string]$Value
    if ($converted.Length -gt $MaximumLength) { return $converted.Substring(0, $MaximumLength) }
    return $converted
}

function Normalize-MuteCueSettings {
    param(
        [AllowNull()][object]$Settings,
        [AllowNull()][System.Collections.IDictionary]$Defaults
    )

    if ($null -eq $Defaults) { $Defaults = Get-MuteCueDefaultSettings }
    $normalized = [ordered]@{}
    foreach ($key in @($Defaults.Keys)) {
        $normalized[$key] = Get-MuteCueSettingValue -Settings $Settings -Name $key -Fallback $Defaults[$key]
    }

    $normalized.SchemaVersion = [int]$Defaults.SchemaVersion
    $normalized.X = ConvertTo-MuteCueInteger $normalized.X $Defaults.X -100000 100000
    $normalized.Y = ConvertTo-MuteCueInteger $normalized.Y $Defaults.Y -100000 100000
    $normalized.Size = ConvertTo-MuteCueInteger $normalized.Size $Defaults.Size 220 900
    $normalized.Opacity = ConvertTo-MuteCueDouble $normalized.Opacity $Defaults.Opacity 0.25 1.0

    foreach ($name in @(
        "ClickThrough", "BeacnDirectDetect", "BeacnAudienceDetect", "BeacnMuteAllDetect",
        "BeacnMuteAllMuted", "DiscordMicDetect", "DiscordDeafenDetect", "ForceShow",
        "CloseToSystemTray", "StartInSystemTray"
    )) {
        $normalized[$name] = ConvertTo-MuteCueBoolean $normalized[$name] ([bool]$Defaults[$name])
    }

    foreach ($name in @(
        "BeacnFaderNames", "BeacnFaderIndices", "BeacnAudienceFaderIds", "BeacnAllFaderIds",
        "BeacnAudienceFaderNames", "BeacnAllFaderNames", "BeacnAudienceFaderKeys", "BeacnAllFaderKeys"
    )) {
        $normalized[$name] = ConvertTo-MuteCueString $normalized[$name] ([string]$Defaults[$name]) 4096
    }
    $normalized.BeacnFaderSelectionFormat = ConvertTo-MuteCueInteger `
        $normalized.BeacnFaderSelectionFormat $Defaults.BeacnFaderSelectionFormat 1 3

    # Preserve the original one-time migration semantics.
    if ($null -ne $Settings -and -not (Test-MuteCueSettingExists $Settings "BeacnFaderIndices")) {
        $normalized.BeacnFaderIndices = ""
    }
    if ($null -ne $Settings -and -not (Test-MuteCueSettingExists $Settings "BeacnAudienceFaderIds")) {
        $normalized.BeacnAudienceFaderIds = [string]$normalized.BeacnFaderIndices
    }
    if ($null -ne $Settings -and -not (Test-MuteCueSettingExists $Settings "BeacnAllFaderIds")) {
        $normalized.BeacnAllFaderIds = if ([bool]$normalized.BeacnMuteAllDetect) {
            [string]$normalized.BeacnFaderIndices
        } else { "" }
    }
    if ($null -ne $Settings -and -not (Test-MuteCueSettingExists $Settings "BeacnFaderSelectionFormat")) {
        $normalized.BeacnFaderSelectionFormat = 1
        $normalized.BeacnAudienceFaderNames = ""
        $normalized.BeacnAllFaderNames = ""
    }

    return [pscustomobject]$normalized
}

function Write-MuteCueConfigurationDiagnostic {
    param([string]$Message, [System.Exception]$Exception)

    if ($null -ne (Get-Command Write-MuteCueDiagnostic -ErrorAction SilentlyContinue)) {
        Write-MuteCueDiagnostic -Level Warning -Component "Configuration" -Message $Message -Exception $Exception
    }
}

function Read-MuteCueSettings {
    param(
        [Parameter(Mandatory)][string]$Path,
        [AllowNull()][System.Collections.IDictionary]$Defaults
    )

    if ($null -eq $Defaults) { $Defaults = Get-MuteCueDefaultSettings }
    foreach ($candidate in @($Path, ($Path + ".bak"))) {
        if (-not [System.IO.File]::Exists($candidate)) { continue }
        try {
            $file = New-Object System.IO.FileInfo($candidate)
            if ($file.Length -gt 1MB) { throw "Settings file is larger than 1 MB." }
            $loaded = [System.IO.File]::ReadAllText($candidate) | ConvertFrom-Json
            if ($null -eq $loaded) { throw "Settings file is empty." }
            if ($candidate -ne $Path) {
                Write-MuteCueConfigurationDiagnostic -Message "Recovered settings from the backup file." -Exception $null
            }
            return Normalize-MuteCueSettings -Settings $loaded -Defaults $Defaults
        } catch {
            Write-MuteCueConfigurationDiagnostic -Message ("Could not read settings from '{0}'." -f $candidate) -Exception $_.Exception
        }
    }
    return Normalize-MuteCueSettings -Settings $null -Defaults $Defaults
}

function Save-MuteCueSettings {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][object]$Settings,
        [AllowNull()][System.Collections.IDictionary]$Defaults
    )

    if ($null -eq $Defaults) { $Defaults = Get-MuteCueDefaultSettings }
    $normalized = Normalize-MuteCueSettings -Settings $Settings -Defaults $Defaults
    $json = $normalized | ConvertTo-Json -Depth 4
    Write-MuteCueAtomicText -Path $Path -Content $json -BackupPath ($Path + ".bak")
    return $normalized
}
