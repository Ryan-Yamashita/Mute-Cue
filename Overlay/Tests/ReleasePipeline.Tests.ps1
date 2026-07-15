$ErrorActionPreference = "Stop"
$repositoryRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$overlayDirectory = Join-Path $repositoryRoot "Overlay"

function Assert-ReleasePipeline {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

$manifest = Get-Content -LiteralPath (Join-Path $overlayDirectory "MuteCue.ReleaseManifest.json") -Raw | ConvertFrom-Json
Assert-ReleasePipeline ([string]$manifest.version -match '^\d+\.\d+\.\d+(?:-[0-9A-Za-z]+(?:[.-][0-9A-Za-z]+)*)?$') "The release version must be a safe semantic version."

$builder = [IO.File]::ReadAllText((Join-Path $overlayDirectory "Build-MuteCueExeRelease.ps1"))
foreach ($requiredBuilderGate in @(
    'dotnet publish $projectPath --configuration Release --runtime win-x64 --self-contained true',
    '-p:MuteCueChannel=Stable',
    '$manifest.nativeFiles',
    'MuteCue.DiscordPublicClient.json',
    'legacy Runtime directory',
    'PowerShell files',
    'Test-MuteCueExeInstaller.ps1',
    'Inno Setup 6 is required'
)) {
    Assert-ReleasePipeline ($builder.Contains($requiredBuilderGate)) "The EXE release builder is missing '$requiredBuilderGate'."
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
    'merge-base --is-ancestor',
    'MuteCueChannel=Stable',
    'choco install innosetup',
    'dotnet run --project',
    'Build-MuteCueExeRelease.ps1',
    'MuteCue-$env:RELEASE_VERSION-Setup.exe',
    'gh release create',
    '--verify-tag',
    '--notes-file',
    'Native Windows application',
    'Important: unsigned Windows installer'
)) {
    Assert-ReleasePipeline ($workflow.Contains($requiredWorkflowGate)) "The production workflow is missing '$requiredWorkflowGate'."
}
Assert-ReleasePipeline ([regex]::IsMatch($workflow, 'actions/checkout@[a-f0-9]{40}')) "The checkout action must be pinned to a full commit SHA."
Assert-ReleasePipeline ([regex]::IsMatch($workflow, 'actions/setup-dotnet@[a-f0-9]{40}')) "The .NET setup action must be pinned to a full commit SHA."
Assert-ReleasePipeline (-not $workflow.Contains('-SkipTests')) "The production workflow must not skip release tests."
Assert-ReleasePipeline (-not $workflow.Contains('--clobber')) "Published release assets must remain immutable."
Assert-ReleasePipeline (-not $workflow.Contains('MUTE_CUE_SIGNING_CERTIFICATE')) "The unsigned release workflow must not require a private signing key."

$installerScript = [IO.File]::ReadAllText((Join-Path $repositoryRoot "src\MuteCue.Desktop\MuteCueSetup.iss"))
foreach ($requiredInstallerGate in @(
    'Uninstallable=not IsSmokeTest',
    'CreateUninstallRegKey=not IsSmokeTest',
    'DefaultDirName={autopf}\Mute Cue',
    'PrivilegesRequired=admin',
    'ArchitecturesAllowed=x64compatible',
    'ArchitecturesInstallIn64BitMode=x64compatible',
    'RestartApplications=no',
    '/MUTECUE-SMOKE-TEST',
    '[InstallDelete]',
    '--shutdown-for-update',
    'runasoriginaluser',
    'ShouldRunMigrationHelper',
    '{app}\versions',
    '{app}\Mute Cue.vbs',
    '{app}\MuteCue.Startup.ps1'
)) {
    Assert-ReleasePipeline ($installerScript.Contains($requiredInstallerGate)) "The native installer is missing '$requiredInstallerGate'."
}
Assert-ReleasePipeline (([regex]::Matches($installerScript, 'runasoriginaluser')).Count -ge 2) "Both the migration helper and normal application launch must drop the installer elevation token."

$installerTest = [IO.File]::ReadAllText((Join-Path $overlayDirectory "Test-MuteCueExeInstaller.ps1"))
foreach ($requiredInstallerTestGate in @('/NOICONS', '/MUTECUE-SMOKE-TEST')) {
    Assert-ReleasePipeline ($installerTest.Contains($requiredInstallerTestGate)) "The native installer smoke test is missing '$requiredInstallerTestGate'."
}

$nativeApp = [IO.File]::ReadAllText((Join-Path $repositoryRoot "src\MuteCue.Desktop\App.xaml.cs"))
foreach ($requiredActivationGate in @('ActivationEventName', 'SignalRunningInstanceToActivate', 'RestoreFromExternalLaunch', 'RepairExistingRegistration')) {
    Assert-ReleasePipeline ($nativeApp.Contains($requiredActivationGate)) "The native app is missing the existing-instance activation gate '$requiredActivationGate'."
}

$legacyMigration = [IO.File]::ReadAllText((Join-Path $repositoryRoot "src\MuteCue.Desktop\Services\LegacyInstallMigration.cs"))
foreach ($requiredMigrationGate in @('LocalApplicationData', 'Programs', 'MuteCue', 'unins000.exe', 'DeleteSubKeyTree', 'AppChannel.IsDevelopment', 'attempt < 20', 'Thread.Sleep(250)')) {
    Assert-ReleasePipeline ($legacyMigration.Contains($requiredMigrationGate)) "The native Program Files migration is missing '$requiredMigrationGate'."
}

$nativeRuntime = [IO.File]::ReadAllText((Join-Path $repositoryRoot "src\MuteCue.Desktop\NativeRuntime\NativeMuteCueRuntime.cs"))
Assert-ReleasePipeline (-not $nativeRuntime.Contains('DiscordMuteScanner.ScanAsync')) "The native runtime must not run the leaking Discord UI Automation fallback loop."

"Release pipeline tests: PASS"
