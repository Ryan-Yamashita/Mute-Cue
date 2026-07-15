param(
    [Parameter(Mandatory)][string]$InstallerPath
)

$ErrorActionPreference = "Stop"
$overlayDirectory = Split-Path -Parent $MyInvocation.MyCommand.Path
$manifest = Get-Content -LiteralPath (Join-Path $overlayDirectory "MuteCue.ReleaseManifest.json") -Raw | ConvertFrom-Json
$nativeFiles = @($manifest.nativeFiles | ForEach-Object { [string]$_ })
if ($nativeFiles.Count -eq 0) { throw "The native installer payload declaration is missing." }
$resolvedInstaller = (Resolve-Path -LiteralPath $InstallerPath).Path
$temporaryRoot = Join-Path ([IO.Path]::GetTempPath()) ("MuteCue.ExeInstaller.{0}" -f [Guid]::NewGuid().ToString("N"))
$installDirectory = Join-Path $temporaryRoot "installed"
$hostProcess = $null

function Remove-MuteCueInstallerTestDirectory {
    param([Parameter(Mandatory)][string]$Path)

    for ($attempt = 0; $attempt -lt 20; $attempt++) {
        if (-not [IO.Directory]::Exists($Path)) { return }
        Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue
        if (-not [IO.Directory]::Exists($Path)) { return }
        Start-Sleep -Milliseconds 250
    }
    throw "The temporary installer test directory could not be removed: $Path"
}

try {
    [void][IO.Directory]::CreateDirectory($temporaryRoot)
    $legacyPaths = @(
        "versions\0.5.2\legacy-runtime.ps1",
        "current.txt",
        "current.txt.previous",
        "install.json",
        "Mute Cue.vbs",
        "MuteCue.Startup.ps1",
        "Uninstall Mute Cue.cmd",
        "Uninstall-MuteCue.ps1"
    )
    foreach ($legacyPath in $legacyPaths) {
        $fullLegacyPath = Join-Path $installDirectory $legacyPath
        [void][IO.Directory]::CreateDirectory((Split-Path -Parent $fullLegacyPath))
        [IO.File]::WriteAllText($fullLegacyPath, "obsolete")
    }
    $installerProcess = Start-Process `
        -FilePath $resolvedInstaller `
        -ArgumentList @(
            "/VERYSILENT",
            "/SUPPRESSMSGBOXES",
            "/NORESTART",
            "/SP-",
            "/NOICONS",
            "/MUTECUE-SMOKE-TEST",
            ('/DIR="{0}"' -f $installDirectory)
        ) `
        -PassThru `
        -Wait
    if ($installerProcess.ExitCode -ne 0) { throw "Mute Cue Setup exited with code $($installerProcess.ExitCode)." }

    foreach ($relativePath in $nativeFiles) {
        if (-not [IO.File]::Exists((Join-Path $installDirectory $relativePath))) {
            throw "The installed Mute Cue application is missing '$relativePath'."
        }
    }
    if ([IO.Directory]::Exists((Join-Path $installDirectory "Runtime"))) {
        throw "The installed native application contains a legacy Runtime directory."
    }
    if (@(Get-ChildItem -LiteralPath $installDirectory -Recurse -File -Filter "*.ps1").Count -gt 0) {
        throw "The installed native application contains PowerShell files."
    }
    foreach ($legacyPath in $legacyPaths) {
        if ([IO.File]::Exists((Join-Path $installDirectory $legacyPath))) {
            throw "The native upgrade retained obsolete file '$legacyPath'."
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
    Remove-MuteCueInstallerTestDirectory -Path $temporaryRoot
}
