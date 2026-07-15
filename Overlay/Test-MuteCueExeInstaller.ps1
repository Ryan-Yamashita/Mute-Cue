param(
    [Parameter(Mandatory)][string]$InstallerPath
)

$ErrorActionPreference = "Stop"
$resolvedInstaller = (Resolve-Path -LiteralPath $InstallerPath).Path
$temporaryRoot = Join-Path ([IO.Path]::GetTempPath()) ("MuteCue.ExeInstaller.{0}" -f [Guid]::NewGuid().ToString("N"))
$installDirectory = Join-Path $temporaryRoot "installed"
$hostProcess = $null

try {
    [void][IO.Directory]::CreateDirectory($temporaryRoot)
    $installerProcess = Start-Process `
        -FilePath $resolvedInstaller `
        -ArgumentList @(
            "/VERYSILENT",
            "/SUPPRESSMSGBOXES",
            "/NORESTART",
            "/SP-",
            ('/DIR="{0}"' -f $installDirectory)
        ) `
        -PassThru `
        -Wait
    if ($installerProcess.ExitCode -ne 0) { throw "Mute Cue Setup exited with code $($installerProcess.ExitCode)." }

    foreach ($relativePath in @(
        "MuteCue.exe",
        "MuteCue.DiscordPublicClient.json"
    )) {
        if (-not [IO.File]::Exists((Join-Path $installDirectory $relativePath))) {
            throw "The installed Mute Cue application is missing '$relativePath'."
        }
    }

    $installedExecutable = Join-Path $installDirectory "MuteCue.exe"
    $otherMuteCueInstances = @(
        Get-CimInstance Win32_Process -Filter "Name = 'MuteCue.exe'" -ErrorAction SilentlyContinue |
            Where-Object {
                -not [string]::IsNullOrWhiteSpace($_.ExecutablePath) -and
                -not [string]::Equals($_.ExecutablePath, $installedExecutable, [StringComparison]::OrdinalIgnoreCase)
            }
    )
    if ($otherMuteCueInstances.Count -gt 0) {
        Write-Output "EXE installer smoke test: PASS (installed layout verified; another Mute Cue instance is already running)."
        return
    }

    $hostProcess = Start-Process -FilePath $installedExecutable -PassThru
    $deadline = [DateTime]::UtcNow.AddSeconds(15)
    $started = $false
    while ([DateTime]::UtcNow -lt $deadline) {
        $started = -not $hostProcess.HasExited
        if ($started) { break }
        Start-Sleep -Milliseconds 250
    }
    if (-not $started) { throw "The installed MuteCue.exe exited during startup." }

    $powerShellChildren = @(
        Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
            Where-Object { $_.ParentProcessId -eq $hostProcess.Id -and $_.Name -ieq 'powershell.exe' }
    )
    if ($powerShellChildren.Count -gt 0) { throw "The installed MuteCue.exe started PowerShell instead of the native runtime." }

    Write-Output "EXE installer smoke test: PASS"
} finally {
    if ($null -ne $hostProcess -and -not $hostProcess.HasExited) {
        Stop-Process -Id $hostProcess.Id -Force -ErrorAction SilentlyContinue
    }
    if ([IO.Directory]::Exists($temporaryRoot)) {
        Remove-Item -LiteralPath $temporaryRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
