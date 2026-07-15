function Get-MuteCueDiscordPublicClient {
    param([Parameter(Mandatory)][string]$Path)

    $expectedRedirectUri = "http://127.0.0.1:47891/mute-cue/"
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
        if ([int]$configuration.schemaVersion -ne 1) { throw "The Discord public-client schema is unsupported." }
        $applicationId = ([string]$configuration.applicationId).Trim()
        $redirectUri = ([string]$configuration.redirectUri).Trim()
        if ($applicationId -notmatch '^\d{17,22}$') { throw "The Discord application ID is missing or invalid." }
        if ($redirectUri -cne $expectedRedirectUri) {
            throw "The Discord redirect URI does not match Mute Cue's registered loopback callback."
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
