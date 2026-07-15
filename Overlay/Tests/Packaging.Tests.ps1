$ErrorActionPreference = "Stop"
$overlayDirectory = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)

function Assert-Packaging {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

$manifestPath = Join-Path $overlayDirectory "MuteCue.ReleaseManifest.json"
$manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
Assert-Packaging ([int]$manifest.schemaVersion -eq 1) "The release manifest schema is invalid."
foreach ($relativePathValue in @($manifest.files)) {
    $relativePath = [string]$relativePathValue
    Assert-Packaging (-not [System.IO.Path]::IsPathRooted($relativePath) -and -not $relativePath.Contains("..")) "The release manifest contains an unsafe path."
    Assert-Packaging (Test-Path -LiteralPath (Join-Path $overlayDirectory $relativePath)) "Release file '$relativePath' does not exist."
    Assert-Packaging ($relativePath -notmatch '(?i)(settings\.json|discord-.*\.dat|\.log|\.pcap)') "Private runtime file '$relativePath' must not be packaged."
}
Assert-Packaging (@($manifest.files) -contains "bin\MuteCue.Accessibility.dll") "The release must include the precompiled accessibility component."
Assert-Packaging (@($manifest.files) -contains "bin\MuteCue.Accessibility.manifest.json") "The release must include the accessibility component manifest."
Assert-Packaging (@($manifest.files) -contains "MuteCue.DiscordPublicClient.json") "The release must include the built-in Discord public-client configuration."
$unsignedPublicReleaseBlocked = $false
try {
    & (Join-Path $overlayDirectory "Build-MuteCueRelease.ps1") `
        -OutputDirectory (Join-Path ([IO.Path]::GetTempPath()) ("MuteCue.UnsignedGate.{0}" -f [Guid]::NewGuid().ToString("N"))) `
        -SkipTests `
        -RequireSigning | Out-Null
} catch {
    $unsignedPublicReleaseBlocked = $_.Exception.Message -match "requires -SigningCertificateThumbprint"
}
Assert-Packaging $unsignedPublicReleaseBlocked "The public-release gate must reject a missing signing certificate."

$temporaryRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("MuteCue.Packaging.Tests.{0}" -f [Guid]::NewGuid().ToString("N"))
$installRoot = Join-Path $temporaryRoot "installed-product"
$dataRoot = Join-Path $temporaryRoot "user-data"
$mainStartupDirectory = Join-Path $temporaryRoot "main-startup"
try {
    [void](New-Item -ItemType Directory -Path $temporaryRoot -Force)
    & (Join-Path $overlayDirectory "Install-MuteCue.ps1") `
        -InstallRoot $installRoot `
        -DataRoot $dataRoot `
        -StartupDirectory $mainStartupDirectory `
        -NoStartup `
        -NoLaunch | Out-Null
    $firstRelease = [System.IO.File]::ReadAllText((Join-Path $installRoot "current.txt")).Trim()
    $firstDirectory = Join-Path (Join-Path $installRoot "versions") $firstRelease
    Assert-Packaging ([System.IO.File]::Exists((Join-Path $firstDirectory "BeacnMuteOverlay.ps1"))) "The active release is incomplete."
    Assert-Packaging ([System.IO.File]::Exists((Join-Path $firstDirectory "bin\MuteCue.Accessibility.dll"))) "The installed accessibility component is missing."
    . (Join-Path $firstDirectory "MuteCue.AccessibilityRuntime.ps1")
    $installedOverlayText = [IO.File]::ReadAllText((Join-Path $firstDirectory "BeacnMuteOverlay.ps1"))
    $installedSourceMatch = [regex]::Match($installedOverlayText, '(?ms)^\$discordScannerSource\s*=\s*@"\r?\n(.*?)\r?\n"@\s*$')
    $installedComponent = Get-MuteCueAccessibilityComponentInfo -OverlayDirectory $firstDirectory -SourceText $installedSourceMatch.Groups[1].Value
    Assert-Packaging $installedComponent.IsValid "The installed accessibility component failed validation."
    Assert-Packaging ([System.IO.File]::Exists((Join-Path $installRoot "Mute Cue.vbs"))) "The stable installed launcher is missing."
    Assert-Packaging (-not [System.IO.File]::Exists((Join-Path $firstDirectory "settings.json"))) "The release copied machine-specific settings."

    Start-Sleep -Milliseconds 20
    & (Join-Path $overlayDirectory "Install-MuteCue.ps1") `
        -InstallRoot $installRoot `
        -DataRoot $dataRoot `
        -StartupDirectory $mainStartupDirectory `
        -NoStartup `
        -NoLaunch | Out-Null
    $secondRelease = [System.IO.File]::ReadAllText((Join-Path $installRoot "current.txt")).Trim()
    Assert-Packaging ($secondRelease -ne $firstRelease) "A reinstall must stage a distinct immutable release."
    Assert-Packaging ([System.IO.Directory]::Exists($firstDirectory)) "The previous release must remain available for rollback."
    Assert-Packaging ([System.IO.File]::ReadAllText((Join-Path $installRoot "current.txt.previous")).Trim() -eq $firstRelease) "The atomic version switch did not preserve the rollback marker."

    # Exercise the installer's startup policy through an isolated Startup folder.
    . (Join-Path $overlayDirectory "MuteCue.Startup.ps1")
    $startupInstallRoot = Join-Path $temporaryRoot "startup-product"
    $startupDataRoot = Join-Path $temporaryRoot "startup-user-data"
    $startupDirectory = Join-Path $temporaryRoot "startup-folder"
    & (Join-Path $overlayDirectory "Install-MuteCue.ps1") `
        -InstallRoot $startupInstallRoot `
        -DataRoot $startupDataRoot `
        -StartupDirectory $startupDirectory `
        -NoLaunch | Out-Null
    $startupLauncher = Join-Path $startupInstallRoot "Mute Cue.vbs"
    $startupState = Get-MuteCueStartupRegistration -LauncherPath $startupLauncher -StartupDirectory $startupDirectory
    Assert-Packaging $startupState.IsCurrent "A first install must create the current startup shortcut by default."

    Start-Sleep -Milliseconds 20
    & (Join-Path $overlayDirectory "Install-MuteCue.ps1") `
        -InstallRoot $startupInstallRoot `
        -DataRoot $startupDataRoot `
        -StartupDirectory $startupDirectory `
        -NoLaunch | Out-Null
    $startupState = Get-MuteCueStartupRegistration -LauncherPath $startupLauncher -StartupDirectory $startupDirectory
    Assert-Packaging $startupState.IsCurrent "An update must preserve an enabled startup shortcut."

    [void](Disable-MuteCueStartupRegistration -LauncherPath $startupLauncher -StartupDirectory $startupDirectory)
    Start-Sleep -Milliseconds 20
    & (Join-Path $overlayDirectory "Install-MuteCue.ps1") `
        -InstallRoot $startupInstallRoot `
        -DataRoot $startupDataRoot `
        -StartupDirectory $startupDirectory `
        -NoLaunch | Out-Null
    $startupState = Get-MuteCueStartupRegistration -LauncherPath $startupLauncher -StartupDirectory $startupDirectory
    Assert-Packaging (-not $startupState.Exists) "An update must preserve a user-disabled startup choice."

    [void](Enable-MuteCueStartupRegistration -LauncherPath $startupLauncher -StartupDirectory $startupDirectory)
    Start-Sleep -Milliseconds 20
    & (Join-Path $overlayDirectory "Install-MuteCue.ps1") `
        -InstallRoot $startupInstallRoot `
        -DataRoot $startupDataRoot `
        -StartupDirectory $startupDirectory `
        -NoStartup `
        -NoLaunch | Out-Null
    $startupState = Get-MuteCueStartupRegistration -LauncherPath $startupLauncher -StartupDirectory $startupDirectory
    Assert-Packaging (-not $startupState.Exists) "-NoStartup must disable an owned startup shortcut during an update."

    $noStartupInstallRoot = Join-Path $temporaryRoot "no-startup-product"
    $noStartupDataRoot = Join-Path $temporaryRoot "no-startup-user-data"
    $noStartupDirectory = Join-Path $temporaryRoot "no-startup-folder"
    & (Join-Path $overlayDirectory "Install-MuteCue.ps1") `
        -InstallRoot $noStartupInstallRoot `
        -DataRoot $noStartupDataRoot `
        -StartupDirectory $noStartupDirectory `
        -NoStartup `
        -NoLaunch | Out-Null
    $noStartupState = Get-MuteCueStartupRegistration `
        -LauncherPath (Join-Path $noStartupInstallRoot "Mute Cue.vbs") `
        -StartupDirectory $noStartupDirectory
    Assert-Packaging (-not $noStartupState.Exists) "-NoStartup must keep a first install out of Windows startup."

    [void][System.IO.Directory]::CreateDirectory($noStartupDirectory)
    $conflictPath = Join-Path $noStartupDirectory "Mute Cue.lnk"
    $conflictShell = New-Object -ComObject WScript.Shell
    $conflictShortcut = $null
    try {
        $conflictShortcut = $conflictShell.CreateShortcut($conflictPath)
        $conflictShortcut.TargetPath = Join-Path $env:SystemRoot "System32\notepad.exe"
        $conflictShortcut.Arguments = ('"{0}"' -f $noStartupInstallRoot)
        $conflictShortcut.Save()
    } finally {
        if ($null -ne $conflictShortcut) { [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($conflictShortcut) }
        [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($conflictShell)
    }

    & (Join-Path $overlayDirectory "Uninstall-MuteCue.ps1") `
        -InstallRoot $startupInstallRoot `
        -DataRoot $startupDataRoot `
        -StartupDirectory $startupDirectory | Out-Null
    & (Join-Path $overlayDirectory "Uninstall-MuteCue.ps1") `
        -InstallRoot $noStartupInstallRoot `
        -DataRoot $noStartupDataRoot `
        -StartupDirectory $noStartupDirectory | Out-Null
    Assert-Packaging ([System.IO.File]::Exists($conflictPath)) "Uninstall must preserve a conflicting startup shortcut it does not own."
    Remove-Item -LiteralPath $conflictPath -Force

    & (Join-Path $overlayDirectory "Uninstall-MuteCue.ps1") `
        -InstallRoot $installRoot `
        -DataRoot $dataRoot `
        -StartupDirectory $mainStartupDirectory | Out-Null
    Assert-Packaging (-not [System.IO.Directory]::Exists($installRoot)) "The per-user uninstaller did not remove the installed application."
} finally {
    if (Test-Path -LiteralPath $temporaryRoot) { Remove-Item -LiteralPath $temporaryRoot -Recurse -Force }
}

"Packaging tests: PASS"
