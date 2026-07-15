function Get-MuteCueDiscordPublicClient {
    param([Parameter(Mandatory)][string]$Path)

    $empty = [pscustomobject]@{
        Available = $false
        ApplicationId = ""
        RedirectUri = ""
        Detail = "Discord sign-in is not configured in this build."
    }
    try {
        if (-not [IO.File]::Exists($Path)) { return $empty }
        $file = New-Object IO.FileInfo($Path)
        if ($file.Length -le 0 -or $file.Length -gt 64KB) { throw "The public-client configuration has an invalid size." }
        $configuration = [IO.File]::ReadAllText($Path) | ConvertFrom-Json
        $applicationId = ([string]$configuration.applicationId).Trim()
        $redirectUri = ([string]$configuration.redirectUri).Trim()
        if ($applicationId -notmatch '^\d{17,22}$') { throw "The Discord application ID is missing or invalid." }
        $uri = $null
        if (-not [Uri]::TryCreate($redirectUri, [UriKind]::Absolute, [ref]$uri) -or $uri.Scheme -ne 'http' -or $uri.Host -ne '127.0.0.1') {
            throw "The Discord redirect URI must be an http://127.0.0.1 loopback address."
        }
        return [pscustomobject]@{
            Available = $true
            ApplicationId = $applicationId
            RedirectUri = $redirectUri
            Detail = "Discord will ask for permission to read your own mute and deafen state locally."
        }
    } catch {
        if ($null -ne (Get-Command Write-MuteCueDiagnostic -ErrorAction SilentlyContinue)) {
            Write-MuteCueDiagnostic -Level Warning -Component "Discord" -Message "The built-in Discord public-client configuration is invalid." -Exception $_.Exception
        }
        return $empty
    }
}
