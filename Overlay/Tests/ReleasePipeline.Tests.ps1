$ErrorActionPreference = "Stop"
$repositoryRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$overlayDirectory = Join-Path $repositoryRoot "Overlay"

function Assert-ReleasePipeline {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

$manifest = Get-Content -LiteralPath (Join-Path $overlayDirectory "MuteCue.ReleaseManifest.json") -Raw | ConvertFrom-Json
Assert-ReleasePipeline ([string]$manifest.version -match '^\d+\.\d+\.\d+(?:-[0-9A-Za-z]+(?:[.-][0-9A-Za-z]+)*)?$') "The release version must be a safe semantic version."

$builder = [IO.File]::ReadAllText((Join-Path $overlayDirectory "Build-MuteCueRelease.ps1"))
foreach ($requiredBuilderGate in @(
    '-RequireSigning:$RequireSigning',
    '-RequireDiscordPublicClient:$RequireDiscordPublicClient',
    'discordPublicClientConfigured = $discordConfigured'
)) {
    Assert-ReleasePipeline ($builder.Contains($requiredBuilderGate)) "The release builder is missing '$requiredBuilderGate'."
}

$artifactValidator = [IO.File]::ReadAllText((Join-Path $overlayDirectory "Test-MuteCueReleaseArtifact.ps1"))
foreach ($requiredArtifactGate in @(
    'A public release must be signed and timestamped.',
    'A public release must contain the configured Mute Cue Discord client.',
    'The Discord configuration does not match the release index.',
    'The release checksum names a different archive.',
    'The release index contains duplicate paths.'
)) {
    Assert-ReleasePipeline ($artifactValidator.Contains($requiredArtifactGate)) "The exact-artifact validator is missing '$requiredArtifactGate'."
}

$workflowPath = Join-Path $repositoryRoot ".github\workflows\publish-release.yml"
Assert-ReleasePipeline ([IO.File]::Exists($workflowPath)) "The tagged production release workflow is missing."
$workflow = [IO.File]::ReadAllText($workflowPath)
foreach ($requiredWorkflowGate in @(
    'environment: production',
    'MUTE_CUE_DISCORD_APPLICATION_ID',
    'dotnet run --project',
    '-RequireDiscordPublicClient',
    'gh release create',
    '--verify-tag',
    'Important: unsigned Windows download'
)) {
    Assert-ReleasePipeline ($workflow.Contains($requiredWorkflowGate)) "The production workflow is missing '$requiredWorkflowGate'."
}
Assert-ReleasePipeline ([regex]::IsMatch($workflow, 'actions/checkout@[a-f0-9]{40}')) "The checkout action must be pinned to a full commit SHA."
Assert-ReleasePipeline ([regex]::IsMatch($workflow, 'actions/setup-dotnet@[a-f0-9]{40}')) "The .NET setup action must be pinned to a full commit SHA."
Assert-ReleasePipeline (-not $workflow.Contains('-SkipTests')) "The production workflow must not skip release tests."
Assert-ReleasePipeline (-not $workflow.Contains('--clobber')) "Published release assets must remain immutable."
Assert-ReleasePipeline (-not $workflow.Contains('MUTE_CUE_SIGNING_CERTIFICATE')) "The unsigned release workflow must not require a private signing key."

"Release pipeline tests: PASS"
