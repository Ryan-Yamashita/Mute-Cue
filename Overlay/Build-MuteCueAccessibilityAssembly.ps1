param(
    [string]$AssemblyVersion,
    [string]$SigningCertificateThumbprint,
    [string]$TimestampServer,
    [switch]$RequireTimestamp,
    [switch]$PassThru
)

$ErrorActionPreference = "Stop"
$overlayDirectory = Split-Path -Parent $MyInvocation.MyCommand.Path
$overlayPath = Join-Path $overlayDirectory "BeacnMuteOverlay.ps1"
$releaseManifestPath = Join-Path $overlayDirectory "MuteCue.ReleaseManifest.json"
$runtimeModulePath = Join-Path $overlayDirectory "MuteCue.AccessibilityRuntime.ps1"
. $runtimeModulePath
. (Join-Path $overlayDirectory "MuteCue.Signing.ps1")

if ([string]::IsNullOrWhiteSpace($AssemblyVersion)) {
    $releaseManifest = Get-Content -LiteralPath $releaseManifestPath -Raw | ConvertFrom-Json
    $versionParts = @(([string]$releaseManifest.version).Split('.'))
    while ($versionParts.Count -lt 4) { $versionParts += "0" }
    $AssemblyVersion = ($versionParts[0..3] -join '.')
}
if ($AssemblyVersion -notmatch '^\d+\.\d+\.\d+\.\d+$') { throw "AssemblyVersion must contain four numeric fields." }

$overlayText = [IO.File]::ReadAllText($overlayPath)
$sourceMatch = [regex]::Match(
    $overlayText,
    '(?ms)^\$discordScannerSource\s*=\s*@"\r?\n(.*?)\r?\n"@\s*$'
)
if (-not $sourceMatch.Success) { throw "The accessibility source was not found in BeacnMuteOverlay.ps1." }
$sourceText = $sourceMatch.Groups[1].Value

$frameworkDirectory = [Runtime.InteropServices.RuntimeEnvironment]::GetRuntimeDirectory()
$compilerPath = Join-Path $frameworkDirectory "csc.exe"
if (-not [IO.File]::Exists($compilerPath)) {
    $compilerPath = Join-Path $env:SystemRoot "Microsoft.NET\Framework64\v4.0.30319\csc.exe"
}
if (-not [IO.File]::Exists($compilerPath)) { throw "The .NET Framework C# compiler is unavailable." }

Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes
$references = @(
    [System.Windows.Automation.AutomationElement].Assembly.Location,
    [System.Windows.Automation.AutomationProperty].Assembly.Location,
    [System.Windows.Rect].Assembly.Location
) | Select-Object -Unique

$outputDirectory = Join-Path $overlayDirectory "bin"
if (-not [IO.Directory]::Exists($outputDirectory)) { [void][IO.Directory]::CreateDirectory($outputDirectory) }
$temporaryDirectory = Join-Path ([IO.Path]::GetTempPath()) ("MuteCue.Accessibility.Build.{0}" -f [Guid]::NewGuid().ToString("N"))
$temporaryOutputDirectory = Join-Path $outputDirectory (".build-{0}" -f [Guid]::NewGuid().ToString("N"))
$temporaryAssemblyPath = Join-Path $temporaryOutputDirectory "MuteCue.Accessibility.dll"
$assemblyPath = Join-Path $outputDirectory "MuteCue.Accessibility.dll"
$componentManifestPath = Join-Path $outputDirectory "MuteCue.Accessibility.manifest.json"

try {
    [void][IO.Directory]::CreateDirectory($temporaryDirectory)
    [void][IO.Directory]::CreateDirectory($temporaryOutputDirectory)
    $sourcePath = Join-Path $temporaryDirectory "Accessibility.cs"
    $assemblyInfoPath = Join-Path $temporaryDirectory "AssemblyInfo.cs"
    [IO.File]::WriteAllText($sourcePath, $sourceText, (New-Object Text.UTF8Encoding($false)))
    $assemblyInfo = @"
using System.Reflection;
[assembly: AssemblyTitle("Mute Cue Accessibility Runtime")]
[assembly: AssemblyDescription("Versioned BEACN and Discord accessibility provider for Mute Cue")]
[assembly: AssemblyCompany("Mute Cue")]
[assembly: AssemblyProduct("Mute Cue")]
[assembly: AssemblyVersion("$AssemblyVersion")]
[assembly: AssemblyFileVersion("$AssemblyVersion")]
"@
    [IO.File]::WriteAllText($assemblyInfoPath, $assemblyInfo, (New-Object Text.UTF8Encoding($false)))

    $compilerArguments = @(
        "/nologo",
        "/target:library",
        "/optimize+",
        "/platform:anycpu",
        "/out:$temporaryAssemblyPath"
    )
    foreach ($reference in $references) { $compilerArguments += "/reference:$reference" }
    $compilerArguments += @($assemblyInfoPath, $sourcePath)
    $compilerOutput = @(& $compilerPath @compilerArguments 2>&1)
    if ($LASTEXITCODE -ne 0 -or -not [IO.File]::Exists($temporaryAssemblyPath)) {
        throw "Accessibility component compilation failed: $($compilerOutput -join [Environment]::NewLine)"
    }

    $compiledAssemblyName = [Reflection.AssemblyName]::GetAssemblyName($temporaryAssemblyPath)
    if ($compiledAssemblyName.Name -ne "MuteCue.Accessibility" -or [string]$compiledAssemblyName.Version -ne $AssemblyVersion) {
        throw "The compiled accessibility assembly identity is invalid."
    }

    $signerThumbprint = ""
    $timestamped = $false
    $timestampSignerThumbprint = ""
    if (-not [string]::IsNullOrWhiteSpace($SigningCertificateThumbprint)) {
        $certificate = Get-MuteCueCodeSigningCertificate -Thumbprint $SigningCertificateThumbprint
        $signature = Set-MuteCueAuthenticodeSignature `
            -Path $temporaryAssemblyPath `
            -Certificate $certificate `
            -TimestampServer $TimestampServer `
            -RequireTimestamp:$RequireTimestamp
        $signerThumbprint = [string]$certificate.Thumbprint
        $timestamped = [bool]$signature.Timestamped
        $timestampSignerThumbprint = [string]$signature.TimestampSignerThumbprint
    }

    $reusedExistingComponent = $false
    if ([IO.File]::Exists($assemblyPath)) {
        $backupPath = $assemblyPath + ".bak"
        Remove-Item -LiteralPath $backupPath -Force -ErrorAction SilentlyContinue
        try {
            [IO.File]::Replace($temporaryAssemblyPath, $assemblyPath, $backupPath, $true)
            Remove-Item -LiteralPath $backupPath -Force -ErrorAction SilentlyContinue
        } catch [IO.IOException] {
            $existingComponent = Get-MuteCueAccessibilityComponentInfo -OverlayDirectory $overlayDirectory -SourceText $sourceText
            $requestedSigner = ([string]$SigningCertificateThumbprint).Replace(" ", "").ToUpperInvariant()
            $existingSigner = ([string]$existingComponent.SignerThumbprint).Replace(" ", "").ToUpperInvariant()
            $signingCompatible = if ([string]::IsNullOrWhiteSpace($requestedSigner)) {
                -not [bool]$existingComponent.AuthenticodeSigned
            } else {
                [bool]$existingComponent.AuthenticodeSigned -and $existingSigner -eq $requestedSigner
            }
            if ($RequireTimestamp) { $signingCompatible = $signingCompatible -and [bool]$existingComponent.AuthenticodeTimestamped }
            if (
                $existingComponent.IsValid -and
                [string]$existingComponent.AssemblyVersion -eq $AssemblyVersion -and
                $signingCompatible
            ) {
                $reusedExistingComponent = $true
                Remove-Item -LiteralPath $temporaryAssemblyPath -Force -ErrorAction SilentlyContinue
            } else {
                throw "The accessibility component is in use and must be replaced. Close Mute Cue before building this release. $($_.Exception.Message)"
            }
        }
    } else {
        [IO.File]::Move($temporaryAssemblyPath, $assemblyPath)
    }

    if (-not $reusedExistingComponent) {
        $componentManifest = [ordered]@{
            schemaVersion = 1
            component = "Mute Cue Accessibility Runtime"
            assemblyName = "MuteCue.Accessibility"
            assemblyVersion = $AssemblyVersion
            contractVersion = $script:MuteCueAccessibilityContractVersion
            sha256 = Get-MuteCueSha256Hex -Path $assemblyPath
            sourceSha256 = Get-MuteCueSha256Hex -Text $sourceText
            authenticodeSigned = -not [string]::IsNullOrWhiteSpace($signerThumbprint)
            signerThumbprint = $signerThumbprint
            authenticodeTimestamped = $timestamped
            timestampSignerThumbprint = $timestampSignerThumbprint
            builtAtUtc = [DateTime]::UtcNow.ToString("o")
        }
        $temporaryManifestPath = $componentManifestPath + ".tmp"
        [IO.File]::WriteAllText(
            $temporaryManifestPath,
            ($componentManifest | ConvertTo-Json -Depth 4),
            (New-Object Text.UTF8Encoding($false))
        )
        if ([IO.File]::Exists($componentManifestPath)) {
            $backupPath = $componentManifestPath + ".bak"
            Remove-Item -LiteralPath $backupPath -Force -ErrorAction SilentlyContinue
            [IO.File]::Replace($temporaryManifestPath, $componentManifestPath, $backupPath, $true)
            Remove-Item -LiteralPath $backupPath -Force -ErrorAction SilentlyContinue
        } else {
            [IO.File]::Move($temporaryManifestPath, $componentManifestPath)
        }
    }

    $componentInfo = Get-MuteCueAccessibilityComponentInfo -OverlayDirectory $overlayDirectory -SourceText $sourceText
    if (-not $componentInfo.IsValid) { throw "The built accessibility component failed validation: $($componentInfo.Detail)" }
    if ($PassThru) { return $componentInfo }
    Write-Output ("Mute Cue accessibility component {0}: PASS" -f $AssemblyVersion)
} finally {
    if ([IO.File]::Exists($temporaryAssemblyPath)) { Remove-Item -LiteralPath $temporaryAssemblyPath -Force -ErrorAction SilentlyContinue }
    if ([IO.Directory]::Exists($temporaryOutputDirectory)) { Remove-Item -LiteralPath $temporaryOutputDirectory -Recurse -Force -ErrorAction SilentlyContinue }
    if ([IO.Directory]::Exists($temporaryDirectory)) { Remove-Item -LiteralPath $temporaryDirectory -Recurse -Force -ErrorAction SilentlyContinue }
}
