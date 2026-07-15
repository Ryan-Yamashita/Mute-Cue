param(
    [string]$InstallRoot = $(Join-Path $env:LOCALAPPDATA "Programs\MuteCue"),
    [string]$DataRoot = $(Join-Path $env:LOCALAPPDATA "MuteCue"),
    [string]$StartupDirectory = $([Environment]::GetFolderPath("Startup")),
    [switch]$NoStartup,
    [switch]$NoLaunch
)

$ErrorActionPreference = "Stop"
$sourceDirectory = Split-Path -Parent $MyInvocation.MyCommand.Path
$pathsModule = Join-Path $sourceDirectory "MuteCue.Paths.ps1"
if (-not (Test-Path -LiteralPath $pathsModule)) { throw "The Mute Cue data-path module is missing." }
. $pathsModule
. (Join-Path $sourceDirectory "MuteCue.Startup.ps1")
$dataPaths = Get-MuteCueDataPaths -Root $DataRoot
[void](Initialize-MuteCueDataPaths -Paths $dataPaths -LegacyDirectory $sourceDirectory)
$manifestPath = Join-Path $sourceDirectory "MuteCue.ReleaseManifest.json"
if (-not (Test-Path -LiteralPath $manifestPath)) { throw "The Mute Cue release manifest is missing." }
$manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
if ([int]$manifest.schemaVersion -ne 1 -or [string]::IsNullOrWhiteSpace([string]$manifest.version)) {
    throw "The Mute Cue release manifest is invalid."
}
$accessibilityRuntimeModule = Join-Path $sourceDirectory "MuteCue.AccessibilityRuntime.ps1"
if (-not (Test-Path -LiteralPath $accessibilityRuntimeModule)) { throw "The accessibility runtime validator is missing." }
. $accessibilityRuntimeModule
$overlaySourcePath = Join-Path $sourceDirectory "BeacnMuteOverlay.ps1"
$overlaySourceText = [IO.File]::ReadAllText($overlaySourcePath)
$accessibilitySourceMatch = [regex]::Match(
    $overlaySourceText,
    '(?ms)^\$discordScannerSource\s*=\s*@"\r?\n(.*?)\r?\n"@\s*$'
)
if (-not $accessibilitySourceMatch.Success) { throw "The accessibility source revision cannot be verified." }
$accessibilitySource = $accessibilitySourceMatch.Groups[1].Value
$accessibilityComponent = Get-MuteCueAccessibilityComponentInfo `
    -OverlayDirectory $sourceDirectory `
    -SourceText $accessibilitySource
if (-not $accessibilityComponent.IsValid) {
    throw "The BEACN monitoring component is not release-ready: $($accessibilityComponent.Detail)"
}

$resolvedInstallRoot = [System.IO.Path]::GetFullPath($InstallRoot)
$versionsDirectory = Join-Path $resolvedInstallRoot "versions"
$launcherPath = Join-Path $resolvedInstallRoot "Mute Cue.vbs"
$existingInstallation = (
    [System.IO.File]::Exists((Join-Path $resolvedInstallRoot "install.json")) -or
    [System.IO.File]::Exists((Join-Path $resolvedInstallRoot "current.txt"))
)
$startupWasEnabled = $false
if ($existingInstallation -and [System.IO.File]::Exists($launcherPath)) {
    try {
        $startupWasEnabled = [bool](Get-MuteCueStartupRegistration `
            -LauncherPath $launcherPath `
            -StartupDirectory $StartupDirectory).IsEnabled
    } catch {}
}
foreach ($directory in @($resolvedInstallRoot, $versionsDirectory)) {
    if (-not [System.IO.Directory]::Exists($directory)) { [void][System.IO.Directory]::CreateDirectory($directory) }
}

$releaseId = "{0}-{1}-{2}" -f `
    ([string]$manifest.version), `
    ([DateTime]::UtcNow.ToString("yyyyMMddHHmmss")), `
    ([Guid]::NewGuid().ToString("N").Substring(0, 8))
$stagingDirectory = Join-Path $versionsDirectory (".staging-" + $releaseId)
$releaseDirectory = Join-Path $versionsDirectory $releaseId
[void][System.IO.Directory]::CreateDirectory($stagingDirectory)

try {
    foreach ($relativePathValue in @($manifest.files)) {
        $relativePath = [string]$relativePathValue
        if (
            [string]::IsNullOrWhiteSpace($relativePath) -or
            [System.IO.Path]::IsPathRooted($relativePath) -or
            $relativePath.Contains("..")
        ) { throw "The release manifest contains an unsafe path." }
        $sourcePath = Join-Path $sourceDirectory $relativePath
        if (-not [System.IO.File]::Exists($sourcePath)) { throw "Release file '$relativePath' is missing." }
        $destinationPath = Join-Path $stagingDirectory $relativePath
        $destinationParent = [System.IO.Path]::GetDirectoryName($destinationPath)
        if (-not [System.IO.Directory]::Exists($destinationParent)) { [void][System.IO.Directory]::CreateDirectory($destinationParent) }
        [System.IO.File]::Copy($sourcePath, $destinationPath, $false)
    }
    [System.IO.File]::Copy($manifestPath, (Join-Path $stagingDirectory "MuteCue.ReleaseManifest.json"), $false)

    foreach ($scriptPath in @(Get-ChildItem -LiteralPath $stagingDirectory -Filter "*.ps1" -File -Recurse)) {
        $parseErrors = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile($scriptPath.FullName, [ref]$null, [ref]$parseErrors)
        if ($parseErrors.Count -gt 0) { throw "Installed script '$($scriptPath.Name)' did not pass validation: $($parseErrors[0].Message)" }
    }
    $stagedAccessibilityComponent = Get-MuteCueAccessibilityComponentInfo `
        -OverlayDirectory $stagingDirectory `
        -SourceText $accessibilitySource
    if (-not $stagedAccessibilityComponent.IsValid) {
        throw "The staged BEACN monitoring component failed validation: $($stagedAccessibilityComponent.Detail)"
    }
    [System.IO.Directory]::Move($stagingDirectory, $releaseDirectory)
} catch {
    if ([System.IO.Directory]::Exists($stagingDirectory)) { Remove-Item -LiteralPath $stagingDirectory -Recurse -Force }
    throw
}

$launcherSource = Join-Path $sourceDirectory "MuteCue.InstalledLauncher.vbs"
[System.IO.File]::Copy($launcherSource, $launcherPath, $true)
[System.IO.File]::Copy((Join-Path $sourceDirectory "MuteCue.Startup.ps1"), (Join-Path $resolvedInstallRoot "MuteCue.Startup.ps1"), $true)
[System.IO.File]::Copy((Join-Path $sourceDirectory "Uninstall-MuteCue.ps1"), (Join-Path $resolvedInstallRoot "Uninstall-MuteCue.ps1"), $true)
[System.IO.File]::Copy((Join-Path $sourceDirectory "Uninstall Mute Cue.cmd"), (Join-Path $resolvedInstallRoot "Uninstall Mute Cue.cmd"), $true)

$currentPath = Join-Path $resolvedInstallRoot "current.txt"
$currentTemporaryPath = $currentPath + ".tmp"
$currentBackupPath = $currentPath + ".previous"
[System.IO.File]::WriteAllText($currentTemporaryPath, $releaseId, (New-Object System.Text.UTF8Encoding($false)))
if ([System.IO.File]::Exists($currentPath)) {
    [System.IO.File]::Replace($currentTemporaryPath, $currentPath, $currentBackupPath, $true)
} else {
    [System.IO.File]::Move($currentTemporaryPath, $currentPath)
}

$installMetadata = [ordered]@{
    SchemaVersion = 1
    Product = "Mute Cue"
    Version = [string]$manifest.version
    ReleaseId = $releaseId
    InstalledAtUtc = [DateTime]::UtcNow.ToString("o")
} | ConvertTo-Json
[System.IO.File]::WriteAllText((Join-Path $resolvedInstallRoot "install.json"), $installMetadata, (New-Object System.Text.UTF8Encoding($false)))

if ($NoStartup) {
    try {
        $startupState = Get-MuteCueStartupRegistration `
            -LauncherPath $launcherPath `
            -StartupDirectory $StartupDirectory
        if ([bool]$startupState.IsOwned) {
            [void](Disable-MuteCueStartupRegistration `
                -LauncherPath $launcherPath `
                -StartupDirectory $StartupDirectory)
        }
    } catch {
        Write-Warning ("Mute Cue was installed, but its owned startup shortcut could not be disabled safely: {0}" -f $_.Exception.Message)
    }
} elseif (-not $existingInstallation -or $startupWasEnabled) {
    try {
        [void](Enable-MuteCueStartupRegistration `
            -LauncherPath $launcherPath `
            -StartupDirectory $StartupDirectory)
    } catch {
        Write-Warning ("Mute Cue was installed, but its startup shortcut could not be updated safely: {0}" -f $_.Exception.Message)
    }
}

if (-not $NoLaunch) {
    $wscriptPath = Join-Path $env:SystemRoot "System32\wscript.exe"
    [void](Start-Process -FilePath $wscriptPath -ArgumentList @("`"$launcherPath`"") -WorkingDirectory $resolvedInstallRoot)
}

Write-Output ("Mute Cue {0} installed for the current Windows user." -f $manifest.version)
Write-Output ("Install location: {0}" -f $resolvedInstallRoot)
Write-Output ("User data location: {0}" -f $dataPaths.Root)
