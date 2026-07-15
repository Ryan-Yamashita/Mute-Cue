param(
    [Parameter(Mandatory)][string]$ArchivePath,
    [string]$ChecksumPath = ($ArchivePath + ".sha256"),
    [string]$ExpectedVersion,
    [switch]$RequireSigning,
    [switch]$RequireDiscordPublicClient
)

$ErrorActionPreference = "Stop"
$overlayDirectory = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $overlayDirectory "MuteCue.Signing.ps1")
$resolvedArchivePath = (Resolve-Path -LiteralPath $ArchivePath).Path
$resolvedChecksumPath = (Resolve-Path -LiteralPath $ChecksumPath).Path
$checksumParts = ([IO.File]::ReadAllText($resolvedChecksumPath).Trim() -split '\s+')
if ($checksumParts.Count -lt 2) { throw "The release checksum file is invalid." }
if ([string]$checksumParts[1] -ne [IO.Path]::GetFileName($resolvedArchivePath)) { throw "The release checksum names a different archive." }
$expectedHash = [string]$checksumParts[0]
$actualHash = (Get-FileHash -LiteralPath $resolvedArchivePath -Algorithm SHA256).Hash.ToLowerInvariant()
if ($actualHash -ne $expectedHash.ToLowerInvariant()) { throw "The release archive checksum does not match." }

$temporaryRoot = Join-Path ([IO.Path]::GetTempPath()) ("MuteCue.ReleaseArtifact.{0}" -f [Guid]::NewGuid().ToString("N"))
try {
    $extractDirectory = Join-Path $temporaryRoot "package"
    Expand-Archive -LiteralPath $resolvedArchivePath -DestinationPath $extractDirectory
    $packageDirectories = @(Get-ChildItem -LiteralPath $extractDirectory -Directory)
    if ($packageDirectories.Count -ne 1) { throw "The release archive must contain one product directory." }
    $packageDirectory = $packageDirectories[0].FullName
    $releaseIndexPath = Join-Path $packageDirectory "MuteCue.ReleaseFiles.json"
    if (-not [IO.File]::Exists($releaseIndexPath)) { throw "The release file index is missing." }
    $releaseIndex = [IO.File]::ReadAllText($releaseIndexPath) | ConvertFrom-Json
    if ([int]$releaseIndex.schemaVersion -ne 1) { throw "The release file index schema is invalid." }
    if (-not [string]::IsNullOrWhiteSpace($ExpectedVersion) -and [string]$releaseIndex.version -cne $ExpectedVersion) {
        throw "The release version does not match the requested version."
    }
    if ([bool]$releaseIndex.timestamped -and -not [bool]$releaseIndex.signed) { throw "A timestamped release must also be signed." }
    if ($RequireSigning -and (-not [bool]$releaseIndex.signed -or -not [bool]$releaseIndex.timestamped)) {
        throw "A public release must be signed and timestamped."
    }

    $discordConfigurationPath = Join-Path $packageDirectory "MuteCue.DiscordPublicClient.json"
    if (-not [IO.File]::Exists($discordConfigurationPath)) { throw "The Discord public-client configuration is missing." }
    $discordConfiguration = [IO.File]::ReadAllText($discordConfigurationPath) | ConvertFrom-Json
    $discordConfigurationValid = (
        [int]$discordConfiguration.schemaVersion -eq 1 -and
        [string]$discordConfiguration.applicationId -match '^\d{17,22}$' -and
        [string]$discordConfiguration.redirectUri -ceq 'http://127.0.0.1:47891/mute-cue/'
    )
    if ([bool]$releaseIndex.discordPublicClientConfigured -ne $discordConfigurationValid) {
        throw "The Discord configuration does not match the release index."
    }
    if ($RequireDiscordPublicClient -and -not $discordConfigurationValid) {
        throw "A public release must contain the configured Mute Cue Discord client."
    }

    $indexedPaths = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($entry in @($releaseIndex.files)) {
        $relativePath = [string]$entry.path
        if ([IO.Path]::IsPathRooted($relativePath) -or $relativePath.Contains("..")) { throw "The release index contains an unsafe path." }
        if (-not $indexedPaths.Add($relativePath.Replace('\', '/'))) { throw "The release index contains duplicate paths." }
        $filePath = Join-Path $packageDirectory $relativePath.Replace('/', '\')
        if (-not [IO.File]::Exists($filePath)) { throw "Indexed release file '$relativePath' is missing." }
        if ([long](Get-Item -LiteralPath $filePath).Length -ne [long]$entry.bytes) { throw "Indexed release file '$relativePath' has the wrong size." }
        $fileHash = (Get-FileHash -LiteralPath $filePath -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($fileHash -ne ([string]$entry.sha256).ToLowerInvariant()) { throw "Indexed release file '$relativePath' failed its checksum." }
    }
    foreach ($file in @(Get-ChildItem -LiteralPath $packageDirectory -File -Recurse)) {
        $relativePath = $file.FullName.Substring($packageDirectory.Length + 1).Replace('\', '/')
        if ($relativePath -ne "MuteCue.ReleaseFiles.json" -and -not $indexedPaths.Contains($relativePath)) {
            throw "Unindexed release file '$relativePath' was found."
        }
    }
    if ([bool]$releaseIndex.signed) {
        if ([string]::IsNullOrWhiteSpace([string]$releaseIndex.signerThumbprint)) { throw "The signed release does not identify its signer." }
        $signedFiles = @(Get-ChildItem -LiteralPath $packageDirectory -File -Recurse | Where-Object { $_.Extension -in @(".ps1", ".vbs", ".dll") })
        foreach ($signedFile in $signedFiles) {
            $signatureValidation = Test-MuteCueAuthenticodeSignature `
                -Path $signedFile.FullName `
                -ExpectedSignerThumbprint ([string]$releaseIndex.signerThumbprint) `
                -RequireTimestamp:([bool]$releaseIndex.timestamped)
            if (-not $signatureValidation.IsValid) { throw "Release signature validation failed for '$($signedFile.Name)'." }
        }
    }

    $installRoot = Join-Path $temporaryRoot "installed"
    $dataRoot = Join-Path $temporaryRoot "data"
    & (Join-Path $packageDirectory "Install-MuteCue.ps1") `
        -InstallRoot $installRoot `
        -DataRoot $dataRoot `
        -NoStartup `
        -NoLaunch | Out-Null
    $releaseId = [IO.File]::ReadAllText((Join-Path $installRoot "current.txt")).Trim()
    $installedDirectory = Join-Path (Join-Path $installRoot "versions") $releaseId
    $runtimePath = Join-Path $installedDirectory "bin\MuteCue.Accessibility.dll"
    if (-not [IO.File]::Exists($runtimePath)) { throw "The installed accessibility runtime is missing." }

    Write-Output ("Release artifact smoke test: PASS ({0} indexed files; SHA-256 {1})" -f @($releaseIndex.files).Count, $actualHash)
} finally {
    if ([IO.Directory]::Exists($temporaryRoot)) { Remove-Item -LiteralPath $temporaryRoot -Recurse -Force -ErrorAction SilentlyContinue }
}
