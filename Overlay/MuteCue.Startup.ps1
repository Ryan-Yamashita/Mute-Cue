function Resolve-MuteCueStartupPathValue {
    param(
        [Parameter(Mandatory)][string]$Path,
        [string]$Description = "path"
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        throw "The Mute Cue $Description is empty."
    }

    try {
        $expanded = [Environment]::ExpandEnvironmentVariables($Path.Trim())
        return [System.IO.Path]::GetFullPath($expanded)
    } catch {
        throw "The Mute Cue $Description '$Path' is not a valid path: $($_.Exception.Message)"
    }
}

function Get-MuteCueWindowsScriptHostPath {
    $systemRoot = [Environment]::GetEnvironmentVariable("SystemRoot")
    if ([string]::IsNullOrWhiteSpace($systemRoot)) {
        throw "Windows did not provide its system directory."
    }
    return Resolve-MuteCueStartupPathValue `
        -Path (Join-Path $systemRoot "System32\wscript.exe") `
        -Description "Windows Script Host path"
}

function Get-MuteCueStartupTargetPath {
    param([Parameter(Mandatory)][string]$LauncherPath)

    $resolvedLauncherPath = Resolve-MuteCueStartupPathValue `
        -Path $LauncherPath `
        -Description "launcher path"

    # Installed builds use the native MuteCue.exe host directly. Development
    # launchers remain VBS files and continue to be hosted by wscript.exe.
    if ([string]::Equals(
        [System.IO.Path]::GetExtension($resolvedLauncherPath),
        ".exe",
        [System.StringComparison]::OrdinalIgnoreCase
    )) {
        return $resolvedLauncherPath
    }

    return Get-MuteCueWindowsScriptHostPath
}

function Get-MuteCueStartupShortcutPath {
    param(
        [string]$StartupDirectory = $([Environment]::GetFolderPath("Startup"))
    )

    $resolvedStartupDirectory = Resolve-MuteCueStartupPathValue `
        -Path $StartupDirectory `
        -Description "Startup directory"
    return Join-Path $resolvedStartupDirectory "Mute Cue.lnk"
}

function Get-MuteCueStartupArguments {
    param([Parameter(Mandatory)][string]$LauncherPath)

    $resolvedLauncherPath = Resolve-MuteCueStartupPathValue `
        -Path $LauncherPath `
        -Description "launcher path"

    if ([string]::Equals(
        [System.IO.Path]::GetExtension($resolvedLauncherPath),
        ".exe",
        [System.StringComparison]::OrdinalIgnoreCase
    )) {
        return "--startup"
    }

    return ('"{0}" /startup' -f $resolvedLauncherPath)
}

function Test-MuteCueStartupPathEqual {
    param(
        [AllowEmptyString()][string]$First,
        [AllowEmptyString()][string]$Second
    )

    if ([string]::IsNullOrWhiteSpace($First) -or [string]::IsNullOrWhiteSpace($Second)) {
        return $false
    }

    try {
        $resolvedFirst = Resolve-MuteCueStartupPathValue -Path $First -Description "shortcut path"
        $resolvedSecond = Resolve-MuteCueStartupPathValue -Path $Second -Description "expected shortcut path"
        return [string]::Equals(
            $resolvedFirst.TrimEnd('\'),
            $resolvedSecond.TrimEnd('\'),
            [System.StringComparison]::OrdinalIgnoreCase
        )
    } catch {
        return $false
    }
}

function Read-MuteCueStartupShortcut {
    param([Parameter(Mandatory)][string]$ShortcutPath)

    $shell = $null
    $shortcut = $null
    try {
        $shell = New-Object -ComObject WScript.Shell
        $shortcut = $shell.CreateShortcut($ShortcutPath)
        return [pscustomobject]@{
            TargetPath = [string]$shortcut.TargetPath
            Arguments = [string]$shortcut.Arguments
            WorkingDirectory = [string]$shortcut.WorkingDirectory
            WindowStyle = [int]$shortcut.WindowStyle
            Description = [string]$shortcut.Description
        }
    } finally {
        if ($null -ne $shortcut -and [Runtime.InteropServices.Marshal]::IsComObject($shortcut)) {
            [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($shortcut)
        }
        if ($null -ne $shell -and [Runtime.InteropServices.Marshal]::IsComObject($shell)) {
            [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($shell)
        }
    }
}

function Get-MuteCueStartupRegistration {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$LauncherPath,
        [string]$StartupDirectory = $([Environment]::GetFolderPath("Startup"))
    )

    $resolvedLauncherPath = Resolve-MuteCueStartupPathValue `
        -Path $LauncherPath `
        -Description "launcher path"
    $resolvedStartupDirectory = Resolve-MuteCueStartupPathValue `
        -Path $StartupDirectory `
        -Description "Startup directory"
    $shortcutPath = Get-MuteCueStartupShortcutPath -StartupDirectory $resolvedStartupDirectory
    $scriptHostPath = Get-MuteCueWindowsScriptHostPath
    $startupTargetPath = Get-MuteCueStartupTargetPath -LauncherPath $resolvedLauncherPath
    $launcherIsExecutable = [string]::Equals(
        [System.IO.Path]::GetExtension($resolvedLauncherPath),
        ".exe",
        [System.StringComparison]::OrdinalIgnoreCase
    )
    $launcherExists = [System.IO.File]::Exists($resolvedLauncherPath)
    $exists = [System.IO.File]::Exists($shortcutPath)

    $result = [ordered]@{
        StartupDirectory = $resolvedStartupDirectory
        ShortcutPath = $shortcutPath
        LauncherPath = $resolvedLauncherPath
        LauncherExists = $launcherExists
        WindowsScriptHostPath = $scriptHostPath
        StartupTargetPath = $startupTargetPath
        Exists = $exists
        IsOwned = $false
        IsEnabled = $false
        HasStartupMarker = $false
        NeedsUpdate = $false
        IsCurrent = $false
        IsConflict = $false
        State = $(if ($exists) { "Inspecting" } else { "Disabled" })
        TargetPath = ""
        Arguments = ""
        WorkingDirectory = ""
        WindowStyle = 0
        Detail = $(if ($exists) { "Inspecting the startup shortcut." } else { "Mute Cue is not registered to run at sign-in." })
        ErrorMessage = ""
    }

    if (-not $exists) {
        return [pscustomobject]$result
    }

    try {
        $details = Read-MuteCueStartupShortcut -ShortcutPath $shortcutPath
        $result.TargetPath = [string]$details.TargetPath
        $result.Arguments = [string]$details.Arguments
        $result.WorkingDirectory = [string]$details.WorkingDirectory
        $result.WindowStyle = [int]$details.WindowStyle

        $expectedArguments = Get-MuteCueStartupArguments -LauncherPath $resolvedLauncherPath
        $legacyArguments = ('"{0}"' -f $resolvedLauncherPath)
        $actualArguments = ([string]$details.Arguments).Trim()
        $trustedTarget = Test-MuteCueStartupPathEqual `
            -First ([string]$details.TargetPath) `
            -Second $startupTargetPath
        $hasStartupMarker = [string]::Equals(
            $actualArguments,
            $expectedArguments,
            [System.StringComparison]::OrdinalIgnoreCase
        )
        $hasLegacyArguments = -not $launcherIsExecutable -and [string]::Equals(
            $actualArguments,
            $legacyArguments,
            [System.StringComparison]::OrdinalIgnoreCase
        )
        $isOwned = $trustedTarget -and ($hasStartupMarker -or $hasLegacyArguments)
        $workingDirectoryCurrent = Test-MuteCueStartupPathEqual `
            -First ([string]$details.WorkingDirectory) `
            -Second ([System.IO.Path]::GetDirectoryName($resolvedLauncherPath))
        $needsUpdate = $isOwned -and (
            -not $hasStartupMarker -or
            -not $workingDirectoryCurrent -or
            [int]$details.WindowStyle -ne 7
        )

        $result.IsOwned = $isOwned
        # The shortcut itself is authoritative. A recognized legacy shortcut is
        # enabled even before it is upgraded with the launch-origin marker.
        $result.IsEnabled = $isOwned
        $result.HasStartupMarker = $hasStartupMarker
        $result.NeedsUpdate = $needsUpdate
        $result.IsCurrent = $isOwned -and -not $needsUpdate -and $launcherExists
        $result.IsConflict = -not $isOwned

        if (-not $isOwned) {
            $result.State = "Conflict"
            $result.Detail = "A different shortcut already uses the Mute Cue startup filename."
        } elseif (-not $launcherExists) {
            $result.State = "Broken"
            $result.Detail = "The Mute Cue startup shortcut exists, but its launcher is missing."
        } elseif ($needsUpdate) {
            $result.State = "NeedsUpdate"
            $result.Detail = "The Mute Cue startup shortcut is enabled and needs a safe metadata update."
        } else {
            $result.State = "Enabled"
            $result.Detail = "Mute Cue is registered to run after Windows sign-in."
        }
    } catch {
        $result.IsConflict = $true
        $result.State = "Conflict"
        $result.Detail = "The existing startup shortcut could not be verified, so Mute Cue will not change it."
        $result.ErrorMessage = [string]$_.Exception.Message
    }

    return [pscustomobject]$result
}

function Set-MuteCueStartupRegistration {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][bool]$Enabled,
        [Parameter(Mandatory)][string]$LauncherPath,
        [string]$StartupDirectory = $([Environment]::GetFolderPath("Startup"))
    )

    $state = Get-MuteCueStartupRegistration `
        -LauncherPath $LauncherPath `
        -StartupDirectory $StartupDirectory

    if (-not $Enabled) {
        if (-not $state.Exists) { return $state }
        if (-not $state.IsOwned) {
            throw "Mute Cue did not remove '$($state.ShortcutPath)' because it is not an owned Mute Cue startup shortcut."
        }

        Remove-Item -LiteralPath $state.ShortcutPath -Force
        $disabledState = Get-MuteCueStartupRegistration `
            -LauncherPath $state.LauncherPath `
            -StartupDirectory $state.StartupDirectory
        if ($disabledState.Exists) {
            throw "The Mute Cue startup shortcut could not be removed."
        }
        return $disabledState
    }

    if ($state.IsConflict) {
        throw "Mute Cue did not replace '$($state.ShortcutPath)' because a different shortcut already uses that filename."
    }
    if (-not [System.IO.File]::Exists($state.LauncherPath)) {
        throw "The Mute Cue launcher was not found at '$($state.LauncherPath)'."
    }
    if (-not [System.IO.File]::Exists($state.StartupTargetPath)) {
        throw "The Mute Cue startup target was not found at '$($state.StartupTargetPath)'."
    }
    if ($state.IsCurrent) { return $state }

    if (-not [System.IO.Directory]::Exists($state.StartupDirectory)) {
        [void][System.IO.Directory]::CreateDirectory($state.StartupDirectory)
    }

    $temporaryPath = Join-Path $state.StartupDirectory ("Mute Cue.{0}.lnk" -f [Guid]::NewGuid().ToString("N"))
    $backupPath = Join-Path $state.StartupDirectory ("Mute Cue.{0}.bak" -f [Guid]::NewGuid().ToString("N"))
    $destinationExisted = [System.IO.File]::Exists($state.ShortcutPath)
    $replacementCommitted = $false
    $preserveBackup = $false
    try {
        $shell = $null
        $shortcut = $null
        try {
            $shell = New-Object -ComObject WScript.Shell
            $shortcut = $shell.CreateShortcut($temporaryPath)
            $shortcut.TargetPath = $state.StartupTargetPath
            $shortcut.Arguments = Get-MuteCueStartupArguments -LauncherPath $state.LauncherPath
            $shortcut.WorkingDirectory = [System.IO.Path]::GetDirectoryName($state.LauncherPath)
            $shortcut.WindowStyle = 7
            $shortcut.Description = "Starts Mute Cue after Windows sign-in."
            $shortcut.Save()
        } finally {
            if ($null -ne $shortcut -and [Runtime.InteropServices.Marshal]::IsComObject($shortcut)) {
                [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($shortcut)
            }
            if ($null -ne $shell -and [Runtime.InteropServices.Marshal]::IsComObject($shell)) {
                [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($shell)
            }
        }

        $temporaryDetails = Read-MuteCueStartupShortcut -ShortcutPath $temporaryPath
        $temporaryIsValid = (
            (Test-MuteCueStartupPathEqual -First $temporaryDetails.TargetPath -Second $state.StartupTargetPath) -and
            [string]::Equals(
                ([string]$temporaryDetails.Arguments).Trim(),
                (Get-MuteCueStartupArguments -LauncherPath $state.LauncherPath),
                [System.StringComparison]::OrdinalIgnoreCase
            ) -and
            (Test-MuteCueStartupPathEqual `
                -First $temporaryDetails.WorkingDirectory `
                -Second ([System.IO.Path]::GetDirectoryName($state.LauncherPath))) -and
            [int]$temporaryDetails.WindowStyle -eq 7
        )
        if (-not $temporaryIsValid) {
            throw "The new Mute Cue startup shortcut did not pass validation."
        }

        if ($destinationExisted) {
            [System.IO.File]::Replace($temporaryPath, $state.ShortcutPath, $backupPath, $true)
        } else {
            [System.IO.File]::Move($temporaryPath, $state.ShortcutPath)
        }
        $replacementCommitted = $true

        $enabledState = Get-MuteCueStartupRegistration `
            -LauncherPath $state.LauncherPath `
            -StartupDirectory $state.StartupDirectory
        if (-not $enabledState.IsCurrent -or -not $enabledState.HasStartupMarker) {
            throw "The Mute Cue startup shortcut could not be verified after it was saved."
        }
        return $enabledState
    } catch {
        $failure = $_
        if ($replacementCommitted) {
            if ($destinationExisted -and [System.IO.File]::Exists($backupPath)) {
                try {
                    [System.IO.File]::Replace($backupPath, $state.ShortcutPath, $null, $true)
                } catch {
                    # Keep the recovery copy if Windows cannot restore it in place.
                    $preserveBackup = $true
                }
            } elseif (-not $destinationExisted -and [System.IO.File]::Exists($state.ShortcutPath)) {
                try { Remove-Item -LiteralPath $state.ShortcutPath -Force } catch {}
            }
        }
        throw $failure
    } finally {
        foreach ($cleanupPath in @($temporaryPath, $backupPath)) {
            if ($preserveBackup -and $cleanupPath -eq $backupPath) { continue }
            if ([System.IO.File]::Exists($cleanupPath)) {
                try { Remove-Item -LiteralPath $cleanupPath -Force } catch {}
            }
        }
    }
}

function Enable-MuteCueStartupRegistration {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$LauncherPath,
        [string]$StartupDirectory = $([Environment]::GetFolderPath("Startup"))
    )

    return Set-MuteCueStartupRegistration `
        -Enabled $true `
        -LauncherPath $LauncherPath `
        -StartupDirectory $StartupDirectory
}

function Disable-MuteCueStartupRegistration {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$LauncherPath,
        [string]$StartupDirectory = $([Environment]::GetFolderPath("Startup"))
    )

    return Set-MuteCueStartupRegistration `
        -Enabled $false `
        -LauncherPath $LauncherPath `
        -StartupDirectory $StartupDirectory
}
