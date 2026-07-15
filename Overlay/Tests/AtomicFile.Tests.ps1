$ErrorActionPreference = "Stop"
$overlayDirectory = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$modulePath = Join-Path $overlayDirectory "MuteCue.AtomicFile.ps1"
. $modulePath

function Assert-AtomicFile {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

function Remove-AtomicTestDirectory {
    param([Parameter(Mandatory)][string]$Path)

    if (-not [IO.Directory]::Exists($Path)) { return }
    $lastError = $null
    foreach ($attempt in 1..20) {
        try {
            Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop
            return
        } catch {
            $lastError = $_.Exception
            if ($attempt -lt 20) { Start-Sleep -Milliseconds 25 }
        }
    }
    throw $lastError
}

$temporaryRoot = Join-Path ([IO.Path]::GetTempPath()) ("MuteCue.AtomicFile.Tests.{0}" -f [Guid]::NewGuid().ToString("N"))
$targetPath = Join-Path $temporaryRoot "snapshot.json"
try {
    [void][IO.Directory]::CreateDirectory($temporaryRoot)
    Write-MuteCueAtomicText -Path $targetPath -Text '{"sequence":0}'
    $initial = Read-MuteCueSharedText -Path $targetPath | ConvertFrom-Json
    Assert-AtomicFile ([int]$initial.sequence -eq 0) "The initial atomic file could not be read."

    $lockScriptPath = Join-Path $temporaryRoot "hold-lock.ps1"
    $lockSignalPath = Join-Path $temporaryRoot "locked.signal"
    $lockScript = @'
param([string]$TargetPath, [string]$SignalPath)
$stream = [IO.FileStream]::new($TargetPath, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
try {
    [IO.File]::WriteAllText($SignalPath, "locked")
    Start-Sleep -Milliseconds 300
} finally { $stream.Dispose() }
'@
    [IO.File]::WriteAllText($lockScriptPath, $lockScript, (New-Object Text.UTF8Encoding($false)))
    $powershellPath = Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe"
    $lockProcess = Start-Process -FilePath $powershellPath -ArgumentList @(
        "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "`"$lockScriptPath`"", "-TargetPath", "`"$targetPath`"", "-SignalPath", "`"$lockSignalPath`""
    ) -WindowStyle Hidden -PassThru
    $signalDeadline = [DateTime]::UtcNow.AddSeconds(5)
    while (-not [IO.File]::Exists($lockSignalPath) -and [DateTime]::UtcNow -lt $signalDeadline) { Start-Sleep -Milliseconds 10 }
    Assert-AtomicFile ([IO.File]::Exists($lockSignalPath)) "The deterministic reader lock was not acquired."
    Write-MuteCueAtomicText -Path $targetPath -Text '{"sequence":1}' -MaximumAttempts 12
    [void]$lockProcess.WaitForExit(5000)
    $afterContention = Read-MuteCueSharedText -Path $targetPath | ConvertFrom-Json
    Assert-AtomicFile ([int]$afterContention.sequence -eq 1) "Atomic publication did not recover from reader contention."

    $writerScriptPath = Join-Path $temporaryRoot "writer.ps1"
    $writerScript = @'
param([string]$ModulePath, [string]$TargetPath)
. $ModulePath
foreach ($sequence in 2..300) {
    Write-MuteCueAtomicText -Path $TargetPath -Text ("{`"sequence`":$sequence}")
}
'@
    [IO.File]::WriteAllText($writerScriptPath, $writerScript, (New-Object Text.UTF8Encoding($false)))
    $writerProcess = Start-Process -FilePath $powershellPath -ArgumentList @(
        "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "`"$writerScriptPath`"", "-ModulePath", "`"$modulePath`"", "-TargetPath", "`"$targetPath`""
    ) -WindowStyle Hidden -PassThru
    $readCount = 0
    while (-not $writerProcess.HasExited) {
        $value = Read-MuteCueSharedText -Path $targetPath | ConvertFrom-Json
        Assert-AtomicFile ([int]$value.sequence -ge 1) "A concurrent snapshot read returned invalid JSON."
        $readCount++
    }
    [void]$writerProcess.WaitForExit(5000)
    Assert-AtomicFile ($writerProcess.ExitCode -eq 0 -and $readCount -gt 0) "The concurrent writer stress process failed."
    $final = Read-MuteCueSharedText -Path $targetPath | ConvertFrom-Json
    Assert-AtomicFile ([int]$final.sequence -eq 300) "The concurrent publication sequence did not complete."
    Assert-AtomicFile (@(Get-ChildItem -LiteralPath $temporaryRoot -Filter "*.tmp" -File -ErrorAction SilentlyContinue).Count -eq 0) "Atomic publication left temporary files behind."
    Assert-AtomicFile (@(Get-ChildItem -LiteralPath $temporaryRoot -Filter "*.bak" -File -ErrorAction SilentlyContinue).Count -eq 0) "Atomic publication left backup files behind."
} finally {
    foreach ($process in @($lockProcess, $writerProcess)) {
        if ($null -ne $process) { try { if (-not $process.HasExited) { $process.Kill() } } catch {} }
    }
    Remove-AtomicTestDirectory -Path $temporaryRoot
}

"Atomic file contention tests: PASS ($readCount concurrent reads)"
