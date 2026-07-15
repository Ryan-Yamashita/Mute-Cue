$ErrorActionPreference = "Stop"
$overlayDirectory = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $overlayDirectory "MuteCue.Signing.ps1")
$temporaryRoot = Join-Path ([IO.Path]::GetTempPath()) ("MuteCue.SigningPipeline.{0}" -f [Guid]::NewGuid().ToString("N"))
$sourceDirectory = Join-Path $temporaryRoot "source"
$extractDirectory = Join-Path $temporaryRoot "extracted"
$archivePath = Join-Path $temporaryRoot "signed-test.zip"
$certificate = $null

try {
    [void][IO.Directory]::CreateDirectory($sourceDirectory)
    $sampleFiles = @(
        [pscustomobject]@{ Source = Join-Path $overlayDirectory "bin\MuteCue.Accessibility.dll"; Name = "MuteCue.Accessibility.dll" },
        [pscustomobject]@{ Source = Join-Path $overlayDirectory "Install-MuteCue.ps1"; Name = "Install-MuteCue.ps1" }
    )
    foreach ($sample in $sampleFiles) { [IO.File]::Copy($sample.Source, (Join-Path $sourceDirectory $sample.Name), $false) }

    $certificate = New-SelfSignedCertificate `
        -Type CodeSigningCert `
        -Subject "CN=Mute Cue Isolated Signing Pipeline Test" `
        -FriendlyName "Mute Cue temporary signing pipeline test" `
        -CertStoreLocation "Cert:\CurrentUser\My" `
        -KeyAlgorithm RSA `
        -KeyLength 2048 `
        -HashAlgorithm SHA256 `
        -KeyExportPolicy NonExportable `
        -NotAfter ([DateTime]::Now.AddDays(30))
    $validatedCertificate = Get-MuteCueCodeSigningCertificate -Thumbprint ([string]$certificate.Thumbprint)

    foreach ($sample in $sampleFiles) {
        $path = Join-Path $sourceDirectory $sample.Name
        $signature = Set-AuthenticodeSignature -LiteralPath $path -Certificate $validatedCertificate -HashAlgorithm SHA256
        if ($null -eq $signature.SignerCertificate -or [string]$signature.SignerCertificate.Thumbprint -ne [string]$certificate.Thumbprint) {
            throw "The cryptographic signature was not attached to '$($sample.Name)'."
        }
    }
    Compress-Archive -Path (Join-Path $sourceDirectory '*') -DestinationPath $archivePath
    Expand-Archive -LiteralPath $archivePath -DestinationPath $extractDirectory
    foreach ($sample in $sampleFiles) {
        $signature = Get-AuthenticodeSignature -LiteralPath (Join-Path $extractDirectory $sample.Name)
        if (
            $null -eq $signature.SignerCertificate -or
            [string]$signature.SignerCertificate.Thumbprint -ne [string]$certificate.Thumbprint -or
            $signature.Status -in @([Management.Automation.SignatureStatus]::NotSigned, [Management.Automation.SignatureStatus]::HashMismatch)
        ) {
            throw "The isolated archive did not preserve the signature for '$($sample.Name)'."
        }
        $strictValidation = Test-MuteCueAuthenticodeSignature `
            -Path (Join-Path $extractDirectory $sample.Name) `
            -ExpectedSignerThumbprint ([string]$certificate.Thumbprint)
        if ($strictValidation.IsValid) { throw "An untrusted self-signed certificate must not pass the public-release trust gate." }
    }
    Write-Output "Isolated Authenticode bytes and extracted-archive preservation: PASS"
    Write-Output "Untrusted certificate rejection: PASS"
} finally {
    if ($null -ne $certificate) {
        Remove-Item -LiteralPath ("Cert:\CurrentUser\My\{0}" -f [string]$certificate.Thumbprint) -Force -ErrorAction SilentlyContinue
    }
    if ([IO.Directory]::Exists($temporaryRoot)) { Remove-Item -LiteralPath $temporaryRoot -Recurse -Force -ErrorAction SilentlyContinue }
}

$remaining = @(Get-ChildItem Cert:\CurrentUser\My -ErrorAction SilentlyContinue | Where-Object { $_.Subject -eq "CN=Mute Cue Isolated Signing Pipeline Test" })
if ($remaining.Count -ne 0) { throw "The temporary signing certificate cleanup was incomplete." }
Write-Output "Temporary certificate and trust cleanup: PASS"
