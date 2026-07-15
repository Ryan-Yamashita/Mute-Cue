$ErrorActionPreference = "Stop"
$overlayDirectory = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
. (Join-Path $overlayDirectory "MuteCue.Startup.ps1")

function Assert-Startup {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

function Set-TestShortcut {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$TargetPath,
        [string]$Arguments = "",
        [string]$WorkingDirectory = "",
        [int]$WindowStyle = 1
    )

    $shell = $null
    $shortcut = $null
    try {
        $shell = New-Object -ComObject WScript.Shell
        $shortcut = $shell.CreateShortcut($Path)
        $shortcut.TargetPath = $TargetPath
        $shortcut.Arguments = $Arguments
        $shortcut.WorkingDirectory = $WorkingDirectory
        $shortcut.WindowStyle = $WindowStyle
        $shortcut.Description = "Startup test shortcut"
        $shortcut.Save()
    } finally {
        if ($null -ne $shortcut -and [Runtime.InteropServices.Marshal]::IsComObject($shortcut)) {
            [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($shortcut)
        }
        if ($null -ne $shell -and [Runtime.InteropServices.Marshal]::IsComObject($shell)) {
            [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($shell)
        }
    }
}

$temporaryRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("MuteCue.Startup.Tests.{0}" -f [Guid]::NewGuid().ToString("N"))
$startupDirectory = Join-Path $temporaryRoot "Injected Startup"
$launcherDirectory = Join-Path $temporaryRoot "Launcher Files"
$launcherPath = Join-Path $launcherDirectory "Mute Cue.vbs"

try {
    [void][System.IO.Directory]::CreateDirectory($startupDirectory)
    [void][System.IO.Directory]::CreateDirectory($launcherDirectory)
    [System.IO.File]::WriteAllText($launcherPath, "Option Explicit")

    $disabled = Get-MuteCueStartupRegistration -LauncherPath $launcherPath -StartupDirectory $startupDirectory
    Assert-Startup (-not $disabled.Exists -and -not $disabled.IsEnabled -and $disabled.State -eq "Disabled") "A missing shortcut must be reported as disabled."

    $enabled = Enable-MuteCueStartupRegistration -LauncherPath $launcherPath -StartupDirectory $startupDirectory
    Assert-Startup ($enabled.Exists -and $enabled.IsOwned -and $enabled.IsEnabled) "Enabling startup did not create an owned shortcut."
    Assert-Startup ($enabled.HasStartupMarker -and $enabled.IsCurrent -and -not $enabled.NeedsUpdate) "The new shortcut is missing its /startup marker or current metadata."
    Assert-Startup ([string]::Equals($enabled.Arguments, ('"{0}" /startup' -f [System.IO.Path]::GetFullPath($launcherPath)), [StringComparison]::OrdinalIgnoreCase)) "The startup shortcut arguments are incorrect."

    $firstWriteTime = [System.IO.File]::GetLastWriteTimeUtc($enabled.ShortcutPath)
    Start-Sleep -Milliseconds 40
    $idempotent = Set-MuteCueStartupRegistration -Enabled $true -LauncherPath $launcherPath -StartupDirectory $startupDirectory
    $secondWriteTime = [System.IO.File]::GetLastWriteTimeUtc($enabled.ShortcutPath)
    Assert-Startup ($idempotent.IsCurrent -and $firstWriteTime -eq $secondWriteTime) "Enabling an already-current shortcut must be idempotent."

    Set-TestShortcut `
        -Path $enabled.ShortcutPath `
        -TargetPath $enabled.WindowsScriptHostPath `
        -Arguments ('"{0}"' -f [System.IO.Path]::GetFullPath($launcherPath)) `
        -WorkingDirectory $launcherDirectory `
        -WindowStyle 7
    $legacy = Get-MuteCueStartupRegistration -LauncherPath $launcherPath -StartupDirectory $startupDirectory
    Assert-Startup ($legacy.IsEnabled -and $legacy.IsOwned -and -not $legacy.HasStartupMarker -and $legacy.NeedsUpdate) "An owned legacy shortcut must remain enabled while awaiting upgrade."

    $upgraded = Enable-MuteCueStartupRegistration -LauncherPath $launcherPath -StartupDirectory $startupDirectory
    Assert-Startup ($upgraded.IsCurrent -and $upgraded.HasStartupMarker -and -not $upgraded.NeedsUpdate) "The owned legacy shortcut was not upgraded safely."
    $leftovers = @(
        [System.IO.Directory]::GetFiles($startupDirectory, "Mute Cue.*") |
            Where-Object { -not [string]::Equals($_, $upgraded.ShortcutPath, [StringComparison]::OrdinalIgnoreCase) }
    )
    Assert-Startup ($leftovers.Count -eq 0) "A shortcut update left temporary or backup files behind."

    [System.IO.File]::Delete($upgraded.ShortcutPath)
    $externallyRemoved = Get-MuteCueStartupRegistration -LauncherPath $launcherPath -StartupDirectory $startupDirectory
    Assert-Startup (-not $externallyRemoved.Exists -and -not $externallyRemoved.IsEnabled) "Registration state must follow the actual shortcut after external removal."

    $missingLauncher = Join-Path $launcherDirectory "Missing.vbs"
    $missingLauncherRejected = $false
    try {
        [void](Enable-MuteCueStartupRegistration -LauncherPath $missingLauncher -StartupDirectory $startupDirectory)
    } catch {
        $missingLauncherRejected = $_.Exception.Message -match "launcher was not found"
    }
    Assert-Startup $missingLauncherRejected "Startup creation must reject a missing launcher."
    Assert-Startup (-not [System.IO.File]::Exists((Join-Path $startupDirectory "Mute Cue.lnk"))) "A missing-launcher failure created a shortcut."

    $shortcutPath = Get-MuteCueStartupShortcutPath -StartupDirectory $startupDirectory
    $notepadPath = Join-Path ([Environment]::GetFolderPath("System")) "notepad.exe"
    Set-TestShortcut -Path $shortcutPath -TargetPath $notepadPath -Arguments "" -WorkingDirectory ([System.IO.Path]::GetDirectoryName($notepadPath))
    $conflict = Get-MuteCueStartupRegistration -LauncherPath $launcherPath -StartupDirectory $startupDirectory
    Assert-Startup ($conflict.Exists -and $conflict.IsConflict -and -not $conflict.IsOwned -and -not $conflict.IsEnabled) "An unrelated shortcut must be reported as a conflict."
    $conflictBytes = [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($shortcutPath))

    $enableConflictRejected = $false
    try {
        [void](Enable-MuteCueStartupRegistration -LauncherPath $launcherPath -StartupDirectory $startupDirectory)
    } catch {
        $enableConflictRejected = $_.Exception.Message -match "different shortcut"
    }
    Assert-Startup $enableConflictRejected "Startup creation must refuse an unrelated shortcut conflict."
    Assert-Startup ([Convert]::ToBase64String([System.IO.File]::ReadAllBytes($shortcutPath)) -eq $conflictBytes) "Conflict handling modified an unrelated shortcut."

    $disableConflictRejected = $false
    try {
        [void](Disable-MuteCueStartupRegistration -LauncherPath $launcherPath -StartupDirectory $startupDirectory)
    } catch {
        $disableConflictRejected = $_.Exception.Message -match "not an owned"
    }
    Assert-Startup $disableConflictRejected "Startup removal must refuse an unrelated shortcut conflict."
    Assert-Startup ([Convert]::ToBase64String([System.IO.File]::ReadAllBytes($shortcutPath)) -eq $conflictBytes) "Conflict removal modified an unrelated shortcut."

    [System.IO.File]::Delete($shortcutPath)
    $ownedAgain = Enable-MuteCueStartupRegistration -LauncherPath $launcherPath -StartupDirectory $startupDirectory
    $removed = Disable-MuteCueStartupRegistration -LauncherPath $launcherPath -StartupDirectory $startupDirectory
    Assert-Startup ($ownedAgain.IsEnabled -and -not $removed.Exists -and -not $removed.IsEnabled) "An owned startup shortcut was not removed."

    $removeAgain = Disable-MuteCueStartupRegistration -LauncherPath $launcherPath -StartupDirectory $startupDirectory
    Assert-Startup (-not $removeAgain.Exists -and $removeAgain.State -eq "Disabled") "Removing an absent shortcut must be idempotent."

    $executableLauncherPath = Join-Path $launcherDirectory "MuteCue.exe"
    [System.IO.File]::WriteAllText($executableLauncherPath, "test executable host")
    $executableEnabled = Enable-MuteCueStartupRegistration -LauncherPath $executableLauncherPath -StartupDirectory $startupDirectory
    Assert-Startup (
        $executableEnabled.IsCurrent -and
        (Test-MuteCueStartupPathEqual -First $executableEnabled.TargetPath -Second $executableLauncherPath) -and
        $executableEnabled.Arguments -eq "--startup"
    ) "An installed Mute Cue executable must start directly with the --startup marker."

    $executableRemoved = Disable-MuteCueStartupRegistration -LauncherPath $executableLauncherPath -StartupDirectory $startupDirectory
    Assert-Startup (-not $executableRemoved.Exists -and $executableRemoved.State -eq "Disabled") "The executable startup shortcut was not removed."
} finally {
    if ([System.IO.Directory]::Exists($temporaryRoot)) {
        [System.IO.Directory]::Delete($temporaryRoot, $true)
    }
}

"Startup tests: PASS"
