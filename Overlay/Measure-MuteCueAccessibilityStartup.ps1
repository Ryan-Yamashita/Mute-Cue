param(
    [ValidateRange(1, 20)][int]$Iterations = 5,
    [ValidateRange(50, 5000)][int]$MaximumMilliseconds = 750,
    [switch]$Enforce,
    [switch]$Child
)

$ErrorActionPreference = "Stop"
$overlayDirectory = Split-Path -Parent $MyInvocation.MyCommand.Path

if ($Child) {
    Add-Type -AssemblyName PresentationCore
    Add-Type -AssemblyName WindowsBase
    Add-Type -AssemblyName UIAutomationClient
    Add-Type -AssemblyName UIAutomationTypes
    $timer = [Diagnostics.Stopwatch]::StartNew()
    . (Join-Path $overlayDirectory "MuteCue.AccessibilityRuntime.ps1")
    $overlayText = [IO.File]::ReadAllText((Join-Path $overlayDirectory "BeacnMuteOverlay.ps1"))
    $sourceMatch = [regex]::Match($overlayText, '(?ms)^\$discordScannerSource\s*=\s*@"\r?\n(.*?)\r?\n"@\s*$')
    if (-not $sourceMatch.Success) { throw "The accessibility source revision could not be read." }
    $runtime = Import-MuteCueAccessibilityRuntime `
        -OverlayDirectory $overlayDirectory `
        -SourceText $sourceMatch.Groups[1].Value
    $timer.Stop()
    if ($runtime.Mode -ne "Precompiled" -or -not $runtime.IntegrityVerified) {
        throw "The startup measurement did not load the validated precompiled runtime."
    }
    Write-Output ([Math]::Round($timer.Elapsed.TotalMilliseconds, 2))
    return
}

$windowsPowerShell = Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe"
$samples = New-Object 'System.Collections.Generic.List[double]'
for ($index = 0; $index -lt $Iterations; $index++) {
    $output = @(& $windowsPowerShell `
        -NoProfile `
        -ExecutionPolicy Bypass `
        -File $MyInvocation.MyCommand.Path `
        -Child)
    if ($LASTEXITCODE -ne 0 -or $output.Count -eq 0) { throw "The accessibility startup measurement failed." }
    [void]$samples.Add([double]$output[-1])
}

$ordered = @($samples.ToArray() | Sort-Object)
$percentileIndex = [Math]::Min($ordered.Count - 1, [Math]::Ceiling($ordered.Count * 0.95) - 1)
$result = [pscustomobject]@{
    Iterations = $Iterations
    MinimumMilliseconds = [Math]::Round($ordered[0], 2)
    MedianMilliseconds = [Math]::Round($ordered[[Math]::Floor(($ordered.Count - 1) / 2)], 2)
    P95Milliseconds = [Math]::Round($ordered[$percentileIndex], 2)
    MaximumAllowedMilliseconds = $MaximumMilliseconds
    Passed = $ordered[$percentileIndex] -le $MaximumMilliseconds
}
if ($Enforce -and -not $result.Passed) {
    throw "The precompiled accessibility startup P95 was $($result.P95Milliseconds) ms; the release limit is $MaximumMilliseconds ms."
}
$result
