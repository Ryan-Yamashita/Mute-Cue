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
        "Runtime\BeacnMuteOverlay.ps1",
        "Runtime\MuteCue.DiscordPublicClient.json",
        "Runtime\bin\MuteCue.Accessibility.dll",
        "Runtime\bin\MuteCue.Accessibility.manifest.json"
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
    $runtimeScript = Join-Path $installDirectory "Runtime\BeacnMuteOverlay.ps1"
    $deadline = [DateTime]::UtcNow.AddSeconds(15)
    $runtimeStarted = $false
    while ([DateTime]::UtcNow -lt $deadline) {
        $runtimeStarted = @(
            Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" -ErrorAction SilentlyContinue |
                Where-Object { $_.CommandLine -like "*$runtimeScript*" }
        ).Count -gt 0
        if ($runtimeStarted) { break }
        Start-Sleep -Milliseconds 250
    }
    if (-not $runtimeStarted) { throw "The installed MuteCue.exe did not start its bundled runtime." }

    Write-Output "EXE installer smoke test: PASS"
} finally {
    $runtimePrefix = [regex]::Escape($installDirectory)
    Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -match $runtimePrefix } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    if ($null -ne $hostProcess -and -not $hostProcess.HasExited) {
        Stop-Process -Id $hostProcess.Id -Force -ErrorAction SilentlyContinue
    }
    if ([IO.Directory]::Exists($temporaryRoot)) {
        Remove-Item -LiteralPath $temporaryRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
