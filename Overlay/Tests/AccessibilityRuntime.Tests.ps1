$ErrorActionPreference = "Stop"
$overlayDirectory = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
. (Join-Path $overlayDirectory "MuteCue.AccessibilityRuntime.ps1")

function Assert-AccessibilityRuntime {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

$overlayText = [IO.File]::ReadAllText((Join-Path $overlayDirectory "BeacnMuteOverlay.ps1"))
$sourceMatch = [regex]::Match($overlayText, '(?ms)^\$discordScannerSource\s*=\s*@"\r?\n(.*?)\r?\n"@\s*$')
Assert-AccessibilityRuntime $sourceMatch.Success "The accessibility source revision could not be read."
$sourceText = $sourceMatch.Groups[1].Value

$component = Get-MuteCueAccessibilityComponentInfo -OverlayDirectory $overlayDirectory -SourceText $sourceText
Assert-AccessibilityRuntime ($component.IsValid -and $component.IntegrityVerified -and $component.SourceVerified) "The release accessibility component must pass all validation checks."
Assert-AccessibilityRuntime ($component.AssemblyVersion -eq "0.5.2.0" -and $component.ContractVersion -eq 1) "The accessibility component identity is unexpected."

$temporaryRoot = Join-Path ([IO.Path]::GetTempPath()) ("MuteCue.Accessibility.Tests.{0}" -f [Guid]::NewGuid().ToString("N"))
try {
    $temporaryBin = Join-Path $temporaryRoot "bin"
    [void][IO.Directory]::CreateDirectory($temporaryBin)
    $temporaryAssembly = Join-Path $temporaryBin "MuteCue.Accessibility.dll"
    $temporaryManifest = Join-Path $temporaryBin "MuteCue.Accessibility.manifest.json"
    [IO.File]::Copy([string]$component.AssemblyPath, $temporaryAssembly, $false)
    [IO.File]::Copy([string]$component.ManifestPath, $temporaryManifest, $false)

    $sourceMismatch = Get-MuteCueAccessibilityComponentInfo -OverlayDirectory $temporaryRoot -SourceText ($sourceText + "`n// changed")
    Assert-AccessibilityRuntime (-not $sourceMismatch.IsValid -and $sourceMismatch.Detail -match "different source revision") "A stale binary/source pair must be rejected."

    $manifest = [IO.File]::ReadAllText($temporaryManifest) | ConvertFrom-Json
    $manifest.contractVersion = 999
    [IO.File]::WriteAllText($temporaryManifest, ($manifest | ConvertTo-Json -Depth 4), (New-Object Text.UTF8Encoding($false)))
    $contractMismatch = Get-MuteCueAccessibilityComponentInfo -OverlayDirectory $temporaryRoot -SourceText $sourceText
    Assert-AccessibilityRuntime (-not $contractMismatch.IsValid -and $contractMismatch.Detail -match "contract") "An incompatible runtime contract must be rejected."

    [IO.File]::Copy([string]$component.ManifestPath, $temporaryManifest, $true)
    $falseSigningManifest = [IO.File]::ReadAllText($temporaryManifest) | ConvertFrom-Json
    $falseSigningManifest.authenticodeSigned = $true
    $falseSigningManifest.signerThumbprint = "0000000000000000000000000000000000000000"
    [IO.File]::WriteAllText($temporaryManifest, ($falseSigningManifest | ConvertTo-Json -Depth 4), (New-Object Text.UTF8Encoding($false)))
    $falseSigning = Get-MuteCueAccessibilityComponentInfo -OverlayDirectory $temporaryRoot -SourceText $sourceText
    Assert-AccessibilityRuntime (-not $falseSigning.IsValid -and $falseSigning.Detail -match "Authenticode|signer") "A falsely declared component signature must be rejected."

    [IO.File]::Copy([string]$component.ManifestPath, $temporaryManifest, $true)
    $bytes = [IO.File]::ReadAllBytes($temporaryAssembly)
    $byteIndex = [Math]::Min(128, $bytes.Length - 1)
    $bytes[$byteIndex] = $bytes[$byteIndex] -bxor 0x5A
    [IO.File]::WriteAllBytes($temporaryAssembly, $bytes)
    $corrupt = Get-MuteCueAccessibilityComponentInfo -OverlayDirectory $temporaryRoot -SourceText $sourceText
    Assert-AccessibilityRuntime (-not $corrupt.IsValid -and $corrupt.Detail -match "integrity") "A corrupted accessibility binary must be rejected."

    Remove-Item -LiteralPath $temporaryAssembly -Force
    $missing = Get-MuteCueAccessibilityComponentInfo -OverlayDirectory $temporaryRoot -SourceText $sourceText
    Assert-AccessibilityRuntime (-not $missing.IsValid -and $missing.Status -eq "Missing") "A missing accessibility binary must fail closed."
} finally {
    if ([IO.Directory]::Exists($temporaryRoot)) { Remove-Item -LiteralPath $temporaryRoot -Recurse -Force }
}

"Accessibility runtime tests: PASS"
