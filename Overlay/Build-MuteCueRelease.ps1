param(
    [string]$OutputDirectory = $(Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) "dist"),
    [string]$SigningCertificateThumbprint,
    [string]$TimestampServer,
    [string]$DiscordApplicationId,
    [switch]$RequireSigning,
    [switch]$SkipTests
)

$ErrorActionPreference = "Stop"
$overlayDirectory = Split-Path -Parent $MyInvocation.MyCommand.Path
$manifestPath = Join-Path $overlayDirectory "MuteCue.ReleaseManifest.json"
$manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
if ([int]$manifest.schemaVersion -ne 1 -or [string]::IsNullOrWhiteSpace([string]$manifest.version)) {
    throw "The release manifest is invalid."
}
if ($RequireSigning -and [string]::IsNullOrWhiteSpace($SigningCertificateThumbprint)) {
    throw "A public release requires -SigningCertificateThumbprint when -RequireSigning is used."
}
if ($RequireSigning -and [string]::IsNullOrWhiteSpace($TimestampServer)) {
    throw "A public release requires -TimestampServer when -RequireSigning is used."
}
$discordConfigured = $DiscordApplicationId -match '^\d{17,22}$'
if ($RequireSigning -and -not $discordConfigured) {
    throw "A public release requires -DiscordApplicationId for the built-in Discord public client."
}
if (-not [string]::IsNullOrWhiteSpace($DiscordApplicationId) -and -not $discordConfigured) {
    throw "DiscordApplicationId must contain 17 to 22 digits when supplied."
}
. (Join-Path $overlayDirectory "MuteCue.Signing.ps1")
$signingCertificate = $null
if (-not [string]::IsNullOrWhiteSpace($SigningCertificateThumbprint)) {
    $signingCertificate = Get-MuteCueCodeSigningCertificate -Thumbprint $SigningCertificateThumbprint
}

$componentBuildParameters = @{}
if ($null -ne $signingCertificate) {
    $componentBuildParameters.SigningCertificateThumbprint = [string]$signingCertificate.Thumbprint
    $componentBuildParameters.TimestampServer = $TimestampServer
    $componentBuildParameters.RequireTimestamp = [bool]$RequireSigning
}
& (Join-Path $overlayDirectory "Build-MuteCueAccessibilityAssembly.ps1") @componentBuildParameters | Out-Host
if (-not $SkipTests) { & (Join-Path $overlayDirectory "Tests\Run-All.ps1") | Out-Host }
& (Join-Path $overlayDirectory "Measure-MuteCueAccessibilityStartup.ps1") -Iterations 5 -MaximumMilliseconds 750 -Enforce | Format-List | Out-Host

$releaseName = "MuteCue-{0}" -f [string]$manifest.version
$resolvedOutput = [IO.Path]::GetFullPath($OutputDirectory)
$stagingDirectory = Join-Path $resolvedOutput (".{0}-{1}" -f $releaseName, [Guid]::NewGuid().ToString("N"))
$releaseDirectory = Join-Path $resolvedOutput $releaseName
$archivePath = Join-Path $resolvedOutput ($releaseName + ".zip")
$checksumPath = $archivePath + ".sha256"
$distributionFiles = @(
    "MuteCue.ReleaseManifest.json",
    "Install Mute Cue.cmd",
    "Install-MuteCue.ps1",
    "MuteCue.InstalledLauncher.vbs",
    "Uninstall Mute Cue.cmd",
    "Uninstall-MuteCue.ps1"
)

if (-not [IO.Directory]::Exists($resolvedOutput)) { [void][IO.Directory]::CreateDirectory($resolvedOutput) }
if ([IO.Directory]::Exists($releaseDirectory) -or [IO.File]::Exists($archivePath)) {
    throw "Release output '$releaseName' already exists. Remove or archive it before rebuilding."
}

try {
    [void][IO.Directory]::CreateDirectory($stagingDirectory)
    foreach ($relativePathValue in @($manifest.files) + $distributionFiles | Select-Object -Unique) {
        $relativePath = [string]$relativePathValue
        if ([IO.Path]::IsPathRooted($relativePath) -or $relativePath.Contains("..")) { throw "The release contains an unsafe path." }
        $sourcePath = Join-Path $overlayDirectory $relativePath
        if (-not [IO.File]::Exists($sourcePath)) { throw "Release file '$relativePath' is missing." }
        $destinationPath = Join-Path $stagingDirectory $relativePath
        $destinationParent = [IO.Path]::GetDirectoryName($destinationPath)
        if (-not [IO.Directory]::Exists($destinationParent)) { [void][IO.Directory]::CreateDirectory($destinationParent) }
        [IO.File]::Copy($sourcePath, $destinationPath, $false)
    }
    $discordClientConfiguration = [ordered]@{
        schemaVersion = 1
        applicationId = $(if ($discordConfigured) { $DiscordApplicationId } else { "" })
        redirectUri = "http://127.0.0.1:47891/mute-cue/"
    } | ConvertTo-Json -Depth 3
    [IO.File]::WriteAllText(
        (Join-Path $stagingDirectory "MuteCue.DiscordPublicClient.json"),
        $discordClientConfiguration,
        (New-Object Text.UTF8Encoding($false))
    )

    if ($null -ne $signingCertificate) {
        $signableFiles = @(Get-ChildItem -LiteralPath $stagingDirectory -File -Recurse | Where-Object { $_.Extension -in @(".ps1", ".vbs") })
        foreach ($signableFile in $signableFiles) {
            [void](Set-MuteCueAuthenticodeSignature `
                -Path $signableFile.FullName `
                -Certificate $signingCertificate `
                -TimestampServer $TimestampServer `
                -RequireTimestamp:$RequireSigning)
        }
        $stagedAssemblySignature = Test-MuteCueAuthenticodeSignature `
            -Path (Join-Path $stagingDirectory "bin\MuteCue.Accessibility.dll") `
            -ExpectedSignerThumbprint ([string]$signingCertificate.Thumbprint) `
            -RequireTimestamp:$RequireSigning
        if (-not $stagedAssemblySignature.IsValid) {
            throw "The staged accessibility assembly is not signed by a trusted certificate."
        }
    }

    $fileIndex = foreach ($file in @(Get-ChildItem -LiteralPath $stagingDirectory -File -Recurse | Sort-Object FullName)) {
        [ordered]@{
            path = $file.FullName.Substring($stagingDirectory.Length + 1).Replace('\', '/')
            bytes = [long]$file.Length
            sha256 = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
        }
    }
    $releaseIndex = [ordered]@{
        schemaVersion = 1
        product = "Mute Cue"
        version = [string]$manifest.version
        generatedAtUtc = [DateTime]::UtcNow.ToString("o")
        signed = $null -ne $signingCertificate
        signerThumbprint = $(if ($null -ne $signingCertificate) { [string]$signingCertificate.Thumbprint } else { "" })
        timestamped = $null -ne $signingCertificate -and [bool]$RequireSigning
        discordPublicClientConfigured = $discordConfigured
        files = @($fileIndex)
    }
    [IO.File]::WriteAllText(
        (Join-Path $stagingDirectory "MuteCue.ReleaseFiles.json"),
        ($releaseIndex | ConvertTo-Json -Depth 6),
        (New-Object Text.UTF8Encoding($false))
    )

    [IO.Directory]::Move($stagingDirectory, $releaseDirectory)
    Compress-Archive -LiteralPath $releaseDirectory -DestinationPath $archivePath -CompressionLevel Optimal
    $archiveHash = (Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash.ToLowerInvariant()
    [IO.File]::WriteAllText($checksumPath, "$archiveHash  $([IO.Path]::GetFileName($archivePath))`r`n", (New-Object Text.UTF8Encoding($false)))
    & (Join-Path $overlayDirectory "Test-MuteCueReleaseArtifact.ps1") `
        -ArchivePath $archivePath `
        -ChecksumPath $checksumPath | Out-Host
    Write-Output ("Mute Cue {0} release: PASS" -f [string]$manifest.version)
    Write-Output $archivePath
    Write-Output $checksumPath
} finally {
    if ([IO.Directory]::Exists($stagingDirectory)) { Remove-Item -LiteralPath $stagingDirectory -Recurse -Force -ErrorAction SilentlyContinue }
}
