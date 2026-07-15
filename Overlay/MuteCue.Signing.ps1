$script:MuteCueCodeSigningEkuOid = "1.3.6.1.5.5.7.3.3"

function Get-MuteCueCodeSigningCertificate {
    param(
        [Parameter(Mandatory)][string]$Thumbprint,
        [ValidateRange(0, 3650)][int]$MinimumRemainingDays = 7,
        [DateTime]$Now = [DateTime]::Now
    )

    $normalizedThumbprint = $Thumbprint.Replace(" ", "").ToUpperInvariant()
    if ($normalizedThumbprint -notmatch '^[A-F0-9]{40,128}$') { throw "The code-signing certificate thumbprint is invalid." }
    $certificate = Get-Item -LiteralPath "Cert:\CurrentUser\My\$normalizedThumbprint" -ErrorAction Stop
    if (-not $certificate.HasPrivateKey) { throw "The code-signing certificate does not have an accessible private key." }
    if ($Now -lt $certificate.NotBefore) { throw "The code-signing certificate is not valid yet." }
    if ($certificate.NotAfter -le $Now.AddDays($MinimumRemainingDays)) {
        throw "The code-signing certificate expires too soon for a safe release."
    }
    $ekuOids = @($certificate.EnhancedKeyUsageList | ForEach-Object {
        if ($_.ObjectId -is [string]) { [string]$_.ObjectId } else { [string]$_.ObjectId.Value }
    })
    if ($ekuOids -notcontains $script:MuteCueCodeSigningEkuOid) {
        throw "The selected certificate is not authorized for code signing."
    }
    return $certificate
}

function Test-MuteCueAuthenticodeSignature {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$ExpectedSignerThumbprint,
        [switch]$RequireTimestamp
    )

    $signature = Get-AuthenticodeSignature -LiteralPath $Path
    $expectedSigner = $ExpectedSignerThumbprint.Replace(" ", "").ToUpperInvariant()
    $actualSigner = if ($null -ne $signature.SignerCertificate) {
        ([string]$signature.SignerCertificate.Thumbprint).Replace(" ", "").ToUpperInvariant()
    } else { "" }
    $timestamped = $null -ne $signature.TimeStamperCertificate
    $isValid = (
        $signature.Status -eq [Management.Automation.SignatureStatus]::Valid -and
        $actualSigner -eq $expectedSigner -and
        (-not $RequireTimestamp -or $timestamped)
    )
    [pscustomobject]@{
        IsValid = $isValid
        Status = [string]$signature.Status
        StatusMessage = [string]$signature.StatusMessage
        SignerThumbprint = $actualSigner
        Timestamped = $timestamped
        TimestampSignerThumbprint = $(if ($timestamped) { [string]$signature.TimeStamperCertificate.Thumbprint } else { "" })
        Path = [IO.Path]::GetFullPath($Path)
    }
}

function Set-MuteCueAuthenticodeSignature {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][Security.Cryptography.X509Certificates.X509Certificate2]$Certificate,
        [string]$TimestampServer,
        [switch]$RequireTimestamp
    )

    if ($RequireTimestamp -and [string]::IsNullOrWhiteSpace($TimestampServer)) {
        throw "A timestamp server is required for a public release."
    }
    $signatureParameters = @{
        LiteralPath = $Path
        Certificate = $Certificate
        HashAlgorithm = "SHA256"
    }
    if (-not [string]::IsNullOrWhiteSpace($TimestampServer)) {
        $timestampUri = $null
        if (-not [Uri]::TryCreate($TimestampServer, [UriKind]::Absolute, [ref]$timestampUri) -or $timestampUri.Scheme -ne "https") {
            throw "The timestamp server must be an absolute HTTPS URL supplied by the certificate authority."
        }
        $signatureParameters.TimestampServer = $timestampUri.AbsoluteUri
    }
    $signature = Set-AuthenticodeSignature @signatureParameters
    $validation = Test-MuteCueAuthenticodeSignature `
        -Path $Path `
        -ExpectedSignerThumbprint ([string]$Certificate.Thumbprint) `
        -RequireTimestamp:$RequireTimestamp
    if (-not $validation.IsValid) {
        throw "The Authenticode signature is invalid for '$([IO.Path]::GetFileName($Path))': $($validation.StatusMessage)"
    }
    return $validation
}

function Get-MuteCueSigningReadiness {
    param([ValidateRange(0, 3650)][int]$MinimumRemainingDays = 30)

    $now = [DateTime]::Now
    $candidates = New-Object 'System.Collections.Generic.List[object]'
    foreach ($certificate in @(Get-ChildItem Cert:\CurrentUser\My -CodeSigningCert -ErrorAction SilentlyContinue)) {
        $ready = $false
        $detail = "Ready"
        try {
            [void](Get-MuteCueCodeSigningCertificate `
                -Thumbprint ([string]$certificate.Thumbprint) `
                -MinimumRemainingDays $MinimumRemainingDays `
                -Now $now)
            $ready = $true
        } catch {
            $detail = $_.Exception.Message
        }
        [void]$candidates.Add([pscustomobject]@{
            Subject = [string]$certificate.Subject
            Thumbprint = [string]$certificate.Thumbprint
            NotAfter = [DateTime]$certificate.NotAfter
            Ready = $ready
            Detail = $detail
        })
    }
    [pscustomobject]@{
        Ready = @($candidates | Where-Object Ready).Count -gt 0
        CheckedAt = $now
        MinimumRemainingDays = $MinimumRemainingDays
        Certificates = @($candidates.ToArray())
        Summary = $(if (@($candidates | Where-Object Ready).Count -gt 0) { "A release code-signing certificate is available." } else { "No release-ready code-signing certificate is installed for this Windows user." })
    }
}
