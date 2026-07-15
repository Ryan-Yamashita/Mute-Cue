$ErrorActionPreference = "Stop"
$overlayDirectory = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
. (Join-Path $overlayDirectory "MuteCue.DiscordPublicClient.ps1")

function Assert-DiscordPublicClient {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

$temporaryRoot = Join-Path ([IO.Path]::GetTempPath()) ("MuteCue.DiscordPublicClient.{0}" -f [Guid]::NewGuid().ToString("N"))
[void][IO.Directory]::CreateDirectory($temporaryRoot)
try {
    $path = Join-Path $temporaryRoot "client.json"
    [IO.File]::WriteAllText($path, '{"schemaVersion":1,"applicationId":"123456789012345678","redirectUri":"http://127.0.0.1:47891/mute-cue/"}')
    $client = Get-MuteCueDiscordPublicClient -Path $path
    Assert-DiscordPublicClient ([bool]$client.Available) "A valid embedded public client must be accepted."
    Assert-DiscordPublicClient ($client.ApplicationId -eq "123456789012345678") "The embedded application ID changed."

    [IO.File]::WriteAllText($path, '{"applicationId":"not-an-id","redirectUri":"https://example.com/callback"}')
    $invalid = Get-MuteCueDiscordPublicClient -Path $path
    Assert-DiscordPublicClient (-not [bool]$invalid.Available) "An invalid public client must fail closed."
} finally {
    if (Test-Path -LiteralPath $temporaryRoot) { Remove-Item -LiteralPath $temporaryRoot -Recurse -Force }
}

"Discord public-client tests: PASS"
