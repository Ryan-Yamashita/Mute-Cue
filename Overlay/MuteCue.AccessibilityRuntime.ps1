$script:MuteCueAccessibilityContractVersion = 1
$script:MuteCueAccessibilityAssemblyName = "MuteCue.Accessibility"
$script:MuteCueAccessibilityAssemblyRelativePath = "bin\MuteCue.Accessibility.dll"
$script:MuteCueAccessibilityManifestRelativePath = "bin\MuteCue.Accessibility.manifest.json"
$script:MuteCueAccessibilityMaximumBytes = 4MB

function Get-MuteCueSha256Hex {
    param(
        [Parameter(Mandatory, ParameterSetName = "File")][string]$Path,
        [Parameter(Mandatory, ParameterSetName = "Text")][AllowEmptyString()][string]$Text
    )

    $sha256 = [Security.Cryptography.SHA256]::Create()
    try {
        if ($PSCmdlet.ParameterSetName -eq "File") {
            $stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
            try { $hash = $sha256.ComputeHash($stream) } finally { $stream.Dispose() }
        } else {
            $hash = $sha256.ComputeHash((New-Object Text.UTF8Encoding($false)).GetBytes($Text))
        }
        return ([BitConverter]::ToString($hash)).Replace("-", "").ToLowerInvariant()
    } finally {
        $sha256.Dispose()
    }
}

function Test-MuteCueAccessibilitySourceFallbackAllowed {
    param([Parameter(Mandatory)][string]$OverlayDirectory)

    if ([string]$env:MUTECUE_ALLOW_SOURCE_FALLBACK -eq "1") { return $true }
    return (
        [IO.Directory]::Exists((Join-Path $OverlayDirectory "Tests")) -and
        [IO.File]::Exists((Join-Path $OverlayDirectory "Build-MuteCueAccessibilityAssembly.ps1"))
    )
}

function Get-MuteCueAccessibilityComponentInfo {
    param(
        [Parameter(Mandatory)][string]$OverlayDirectory,
        [AllowNull()][string]$SourceText
    )

    $assemblyPath = Join-Path $OverlayDirectory $script:MuteCueAccessibilityAssemblyRelativePath
    $manifestPath = Join-Path $OverlayDirectory $script:MuteCueAccessibilityManifestRelativePath
    $result = [ordered]@{
        IsValid = $false
        Status = "Unavailable"
        Detail = "The precompiled accessibility component is unavailable."
        AssemblyPath = $assemblyPath
        ManifestPath = $manifestPath
        AssemblyVersion = ""
        ContractVersion = 0
        IntegrityVerified = $false
        SourceVerified = $false
        AuthenticodeSigned = $false
        SignerThumbprint = ""
        AuthenticodeTimestamped = $false
        TimestampSignerThumbprint = ""
    }

    try {
        $overlayRoot = [IO.Path]::GetFullPath($OverlayDirectory).TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
        $resolvedAssemblyPath = [IO.Path]::GetFullPath($assemblyPath)
        $resolvedManifestPath = [IO.Path]::GetFullPath($manifestPath)
        if (
            -not $resolvedAssemblyPath.StartsWith($overlayRoot, [StringComparison]::OrdinalIgnoreCase) -or
            -not $resolvedManifestPath.StartsWith($overlayRoot, [StringComparison]::OrdinalIgnoreCase)
        ) { throw "The accessibility component path is outside the application directory." }

        if (-not [IO.File]::Exists($resolvedAssemblyPath) -or -not [IO.File]::Exists($resolvedManifestPath)) {
            $result.Status = "Missing"
            $result.Detail = "The precompiled accessibility component is missing."
            return [pscustomobject]$result
        }
        $assemblyFile = [IO.FileInfo]::new($resolvedAssemblyPath)
        if ($assemblyFile.Length -le 0 -or $assemblyFile.Length -gt $script:MuteCueAccessibilityMaximumBytes) {
            throw "The accessibility component has an invalid size."
        }

        $manifestText = [IO.File]::ReadAllText($resolvedManifestPath)
        if ($manifestText.Length -gt 64KB) { throw "The accessibility component manifest is too large." }
        $manifest = $manifestText | ConvertFrom-Json
        if ([int]$manifest.schemaVersion -ne 1) { throw "The accessibility component manifest schema is unsupported." }
        if ([string]$manifest.assemblyName -ne $script:MuteCueAccessibilityAssemblyName) { throw "The accessibility component identity is invalid." }
        if ([int]$manifest.contractVersion -ne $script:MuteCueAccessibilityContractVersion) { throw "The accessibility component contract is incompatible." }

        $actualHash = Get-MuteCueSha256Hex -Path $resolvedAssemblyPath
        if ($actualHash -ne ([string]$manifest.sha256).ToLowerInvariant()) { throw "The accessibility component integrity check failed." }

        $assemblyName = [Reflection.AssemblyName]::GetAssemblyName($resolvedAssemblyPath)
        if ($assemblyName.Name -ne $script:MuteCueAccessibilityAssemblyName) { throw "The accessibility assembly name is invalid." }
        if ([string]$assemblyName.Version -ne [string]$manifest.assemblyVersion) { throw "The accessibility assembly version does not match its manifest." }

        $result.AuthenticodeSigned = [bool]$manifest.authenticodeSigned
        $result.SignerThumbprint = [string]$manifest.signerThumbprint
        $result.AuthenticodeTimestamped = [bool]$manifest.authenticodeTimestamped
        $result.TimestampSignerThumbprint = [string]$manifest.timestampSignerThumbprint
        if ($result.AuthenticodeSigned) {
            $signature = Get-AuthenticodeSignature -LiteralPath $resolvedAssemblyPath
            if ($signature.Status -ne [Management.Automation.SignatureStatus]::Valid) {
                throw "The accessibility component Authenticode signature is invalid."
            }
            if (
                $null -eq $signature.SignerCertificate -or
                [string]$signature.SignerCertificate.Thumbprint -ne [string]$result.SignerThumbprint
            ) { throw "The accessibility component signer does not match its manifest." }
            $actualTimestamped = $null -ne $signature.TimeStamperCertificate
            if ($actualTimestamped -ne [bool]$result.AuthenticodeTimestamped) {
                throw "The accessibility component timestamp does not match its manifest."
            }
            if ($actualTimestamped -and [string]$signature.TimeStamperCertificate.Thumbprint -ne [string]$result.TimestampSignerThumbprint) {
                throw "The accessibility component timestamp signer does not match its manifest."
            }
        } elseif (-not [string]::IsNullOrWhiteSpace([string]$manifest.signerThumbprint)) {
            throw "The unsigned accessibility component contains an invalid signer identity."
        }

        $result.AssemblyVersion = [string]$assemblyName.Version
        $result.ContractVersion = [int]$manifest.contractVersion
        $result.IntegrityVerified = $true
        if ($PSBoundParameters.ContainsKey("SourceText") -and $null -ne $SourceText) {
            $sourceHash = Get-MuteCueSha256Hex -Text $SourceText
            if ($sourceHash -ne ([string]$manifest.sourceSha256).ToLowerInvariant()) {
                throw "The accessibility component was built from a different source revision."
            }
            $result.SourceVerified = $true
        }
        $result.IsValid = $true
        $result.Status = "Ready"
        $result.Detail = "The precompiled accessibility component passed its version and integrity checks."
    } catch {
        $result.Status = "Invalid"
        $result.Detail = $_.Exception.Message
        $result.IsValid = $false
    }
    return [pscustomobject]$result
}

function Import-MuteCueAccessibilityRuntime {
    param(
        [Parameter(Mandatory)][string]$OverlayDirectory,
        [Parameter(Mandatory)][AllowEmptyString()][string]$SourceText,
        [switch]$AllowSourceFallback
    )

    $existingType = "BeacnMuteOverlay.BeacnAppScanner" -as [type]
    if ($null -ne $existingType) {
        $existingAssembly = $existingType.Assembly
        return [pscustomobject]@{
            Mode = $(if ([string]::IsNullOrWhiteSpace($existingAssembly.Location)) { "ExistingDevelopmentRuntime" } else { "ExistingPrecompiled" })
            AssemblyPath = [string]$existingAssembly.Location
            AssemblyVersion = [string]$existingAssembly.GetName().Version
            ContractVersion = $script:MuteCueAccessibilityContractVersion
            IntegrityVerified = -not [string]::IsNullOrWhiteSpace($existingAssembly.Location)
            Detail = "The accessibility runtime was already loaded in this process."
        }
    }

    $component = Get-MuteCueAccessibilityComponentInfo -OverlayDirectory $OverlayDirectory -SourceText $SourceText
    if ($component.IsValid) {
        $assembly = [Reflection.Assembly]::LoadFrom([string]$component.AssemblyPath)
        $scannerType = $assembly.GetType("BeacnMuteOverlay.BeacnAppScanner", $true, $false)
        $contractField = $scannerType.GetField("ContractVersion", [Reflection.BindingFlags]"Public,Static")
        if ($null -eq $contractField -or [int]$contractField.GetRawConstantValue() -ne $script:MuteCueAccessibilityContractVersion) {
            throw "The accessibility component does not implement the required runtime contract."
        }
        return [pscustomobject]@{
            Mode = "Precompiled"
            AssemblyPath = [string]$component.AssemblyPath
            AssemblyVersion = [string]$component.AssemblyVersion
            ContractVersion = [int]$component.ContractVersion
            IntegrityVerified = $true
            AuthenticodeSigned = [bool]$component.AuthenticodeSigned
            SignerThumbprint = [string]$component.SignerThumbprint
            AuthenticodeTimestamped = [bool]$component.AuthenticodeTimestamped
            TimestampSignerThumbprint = [string]$component.TimestampSignerThumbprint
            Detail = [string]$component.Detail
        }
    }

    if (-not $AllowSourceFallback) {
        throw "The precompiled accessibility component cannot be loaded: $($component.Detail)"
    }

    Add-Type -TypeDefinition $SourceText -ReferencedAssemblies @(
        [System.Windows.Automation.AutomationElement].Assembly.Location,
        [System.Windows.Automation.AutomationProperty].Assembly.Location,
        [System.Windows.Rect].Assembly.Location
    )
    return [pscustomobject]@{
        Mode = "DevelopmentFallback"
        AssemblyPath = ""
        AssemblyVersion = "development"
        ContractVersion = $script:MuteCueAccessibilityContractVersion
        IntegrityVerified = $false
        AuthenticodeSigned = $false
        SignerThumbprint = ""
        AuthenticodeTimestamped = $false
        TimestampSignerThumbprint = ""
        Detail = "Development source fallback is active because the precompiled component failed validation: $($component.Detail)"
    }
}
