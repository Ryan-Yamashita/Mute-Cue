$ErrorActionPreference = "Stop"
. (Join-Path (Split-Path -Parent $PSScriptRoot) "MuteCue.Diagnostics.ps1")
. (Join-Path (Split-Path -Parent $PSScriptRoot) "MuteCue.Configuration.ps1")

function Assert-Equal {
    param($Actual, $Expected, [string]$Message)
    if ($Actual -ne $Expected) { throw "$Message (expected '$Expected', got '$Actual')" }
}

$defaults = Get-MuteCueDefaultSettings
$normalized = Normalize-MuteCueSettings -Settings ([pscustomobject]@{
    Size = 50000
    Opacity = "not-a-number"
    X = -42
    ClickThrough = "true"
    BeacnFaderSelectionFormat = 99
}) -Defaults $defaults
Assert-Equal $normalized.Size 900 "Size must be clamped"
Assert-Equal $normalized.Opacity 0.88 "Invalid opacity must use the default"
Assert-Equal $normalized.X -42 "Valid coordinates must survive normalization"
Assert-Equal $normalized.ClickThrough $true "String booleans must normalize"
Assert-Equal $normalized.BeacnFaderSelectionFormat 3 "Selection format must be clamped"
Assert-Equal $normalized.SchemaVersion 5 "The current settings schema must include startup presentation without storing Discord developer credentials"
Assert-Equal $normalized.StartInSystemTray $false "Startup-in-tray must be opt-in"

$startupTrayEnabled = Normalize-MuteCueSettings -Settings ([pscustomobject]@{
    StartInSystemTray = "true"
}) -Defaults $defaults
Assert-Equal $startupTrayEnabled.StartInSystemTray $true "String startup-in-tray values must normalize"

$runtimeSelections = Normalize-MuteCueSettings -Settings ([pscustomobject]@{
    BeacnAllFaderNames = "Mic"
    BeacnAudienceFaderNames = "Mic"
    BeacnAllFaderKeys = "profile:0"
    BeacnAudienceFaderKeys = "profile:0"
    BeacnFaderSelectionFormat = 3
}) -Defaults $defaults
$externalSelections = Normalize-MuteCueSettings -Settings ([pscustomobject]@{
    BeacnFaderNames = ""
    BeacnAllFaderNames = ""
    BeacnAudienceFaderNames = ""
    BeacnAllFaderKeys = ""
    BeacnAudienceFaderKeys = ""
    BeacnFaderSelectionFormat = 2
}) -Defaults $defaults
$beforeSelectionSignature = Get-MuteCueFaderSelectionSignature -Settings $runtimeSelections
[void](Copy-MuteCueFaderSelectionSettings -Source $externalSelections -Destination $runtimeSelections)
if ((Get-MuteCueFaderSelectionSignature -Settings $runtimeSelections) -eq $beforeSelectionSignature) {
    throw "An external fader selection update must change the runtime signature"
}
Assert-Equal $runtimeSelections.BeacnAllFaderNames "" "External All deselection must reach the runtime"
Assert-Equal $runtimeSelections.BeacnAudienceFaderNames "" "External Audience deselection must reach the runtime"
Assert-Equal $runtimeSelections.BeacnAllFaderKeys "" "External All deselection must clear stable keys"
Assert-Equal $runtimeSelections.BeacnAudienceFaderKeys "" "External Audience deselection must clear stable keys"
Assert-Equal $runtimeSelections.BeacnFaderSelectionFormat 2 "External name selections must remain authoritative"

$legacy = Normalize-MuteCueSettings -Settings ([pscustomobject]@{
    BeacnFaderNames = "Mic"
    BeacnMuteAllDetect = $true
}) -Defaults $defaults
Assert-Equal $legacy.BeacnFaderSelectionFormat 1 "Legacy selection format must migrate once"
Assert-Equal $legacy.BeacnFaderIndices "" "Legacy profile mapping must start unresolved"
Assert-Equal $legacy.BeacnAudienceFaderNames "" "Legacy audience names must be resolved from the profile"
Assert-Equal $legacy.BeacnAllFaderNames "" "Legacy All names must be resolved from the profile"

$temporaryDirectory = Join-Path ([System.IO.Path]::GetTempPath()) ("MuteCue-Configuration-" + [Guid]::NewGuid().ToString("N"))
[void][System.IO.Directory]::CreateDirectory($temporaryDirectory)
try {
    Initialize-MuteCueDiagnostics -Path (Join-Path $temporaryDirectory "errors.log")
    $path = Join-Path $temporaryDirectory "settings.json"
    $settings = Normalize-MuteCueSettings -Settings ([pscustomobject]@{
        Size = 512
        Opacity = 0.75
        ClickThrough = $true
        StartInSystemTray = $true
        BeacnFaderSelectionFormat = 2
    }) -Defaults $defaults
    [void](Save-MuteCueSettings -Path $path -Settings $settings -Defaults $defaults)
    $roundTrip = Read-MuteCueSettings -Path $path -Defaults $defaults
    Assert-Equal $roundTrip.Size 512 "Settings size round trip"
    Assert-Equal $roundTrip.Opacity 0.75 "Settings opacity round trip"
    Assert-Equal $roundTrip.ClickThrough $true "Settings boolean round trip"
    Assert-Equal $roundTrip.StartInSystemTray $true "Startup-in-tray round trip"

    # Recreate the production module load order. The accessibility client must not
    # replace the configuration writer with an incompatible command signature.
    . (Join-Path (Split-Path -Parent $PSScriptRoot) "BeacnAccessibilityClient.ps1")
    $settings.Opacity = 0.76
    [void](Save-MuteCueSettings -Path $path -Settings $settings -Defaults $defaults)
    $afterAccessibilityLoad = Read-MuteCueSettings -Path $path -Defaults $defaults
    Assert-Equal $afterAccessibilityLoad.Opacity 0.76 "Settings save after accessibility module load"

    $settings.Size = 640
    [void](Save-MuteCueSettings -Path $path -Settings $settings -Defaults $defaults)
    if (-not [System.IO.File]::Exists($path + ".bak")) { throw "Atomic replacement must retain a backup." }
    [System.IO.File]::WriteAllText($path, "{corrupt")
    $recovered = Read-MuteCueSettings -Path $path -Defaults $defaults
    Assert-Equal $recovered.Size 512 "Corrupt primary settings must recover from the previous backup"

    $temporaryFiles = @([System.IO.Directory]::GetFiles($temporaryDirectory, "*.tmp"))
    Assert-Equal $temporaryFiles.Count 0 "Atomic saves must not leave temporary files"
} finally {
    [System.IO.Directory]::Delete($temporaryDirectory, $true)
}

"Configuration tests: PASS"
