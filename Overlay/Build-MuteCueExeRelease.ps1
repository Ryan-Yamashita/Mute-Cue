param(
    [string]$OutputDirectory = $(Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) "dist"),
    [Parameter(Mandatory)][string]$DiscordApplicationId,
    [string]$InnoSetupCompilerPath,
    [switch]$SkipTests
)

$ErrorActionPreference = "Stop"
$overlayDirectory = Split-Path -Parent $MyInvocation.MyCommand.Path
$repositoryRoot = Split-Path -Parent $overlayDirectory
$manifest = Get-Content -LiteralPath (Join-Path $overlayDirectory "MuteCue.ReleaseManifest.json") -Raw | ConvertFrom-Json

if ([int]$manifest.schemaVersion -ne 1 -or [string]$manifest.version -notmatch '^\d+\.\d+\.\d+(?:-[0-9A-Za-z]+(?:[.-][0-9A-Za-z]+)*)?$') {
    throw "The release manifest is invalid."
}
if ($DiscordApplicationId -notmatch '^\d{17,22}$') {
    throw "DiscordApplicationId must contain 17 to 22 digits."
}

function Find-MuteCueInnoSetupCompiler {
    param([string]$ExplicitPath)

    $candidates = @(
        $ExplicitPath,
        (Get-Command ISCC.exe -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source -ErrorAction SilentlyContinue),
        (Join-Path $env:LOCALAPPDATA "Programs\Inno Setup 6\ISCC.exe"),
        (Join-Path $env:ProgramFiles "Inno Setup 6\ISCC.exe"),
        (Join-Path ${env:ProgramFiles(x86)} "Inno Setup 6\ISCC.exe")
    ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }

    foreach ($candidate in $candidates) {
        if ([IO.File]::Exists($candidate)) { return [IO.Path]::GetFullPath($candidate) }
    }
    throw "Inno Setup 6 is required to build MuteCue-Setup.exe. Install Inno Setup, then try again."
}

& (Join-Path $overlayDirectory "Build-MuteCueAccessibilityAssembly.ps1") | Out-Host
if (-not $SkipTests) {
    & (Join-Path $overlayDirectory "Tests\Run-All.ps1") | Out-Host
}

$compiler = Find-MuteCueInnoSetupCompiler -ExplicitPath $InnoSetupCompilerPath
$resolvedOutput = [IO.Path]::GetFullPath($OutputDirectory)
$releaseName = "MuteCue-{0}-Setup.exe" -f [string]$manifest.version
$installerPath = Join-Path $resolvedOutput $releaseName
$checksumPath = "$installerPath.sha256"
$stagingDirectory = Join-Path $resolvedOutput (".native-stage-{0}" -f [Guid]::NewGuid().ToString("N"))
$innoOutputDirectory = Join-Path $stagingDirectory "installer"

if ([IO.File]::Exists($installerPath) -or [IO.File]::Exists($checksumPath)) {
    throw "Release output '$releaseName' already exists. Choose a new output directory or version."
}
if (-not [IO.Directory]::Exists($resolvedOutput)) { [void][IO.Directory]::CreateDirectory($resolvedOutput) }

try {
    $publishDirectory = Join-Path $stagingDirectory "publish"
    $projectPath = Join-Path $repositoryRoot "src\MuteCue.Desktop\MuteCue.Desktop.csproj"
    dotnet publish $projectPath --configuration Release --runtime win-x64 --self-contained true --output $publishDirectory --nologo
    if ($LASTEXITCODE -ne 0) { throw "The native Mute Cue executable did not publish successfully." }

    $discordConfiguration = [ordered]@{
        schemaVersion = 1
        applicationId = $DiscordApplicationId
        redirectUri = "http://127.0.0.1:47891/mute-cue/"
    } | ConvertTo-Json -Depth 3
    [IO.File]::WriteAllText(
        (Join-Path $publishDirectory "MuteCue.DiscordPublicClient.json"),
        $discordConfiguration,
        (New-Object Text.UTF8Encoding($false))
    )

    foreach ($relativePath in @(
        "MuteCue.exe",
        "MuteCue.DiscordPublicClient.json"
    )) {
        if (-not [IO.File]::Exists((Join-Path $publishDirectory $relativePath))) {
            throw "The published installer payload is missing '$relativePath'."
        }
    }

    $previousSource = $env:MUTECUE_EXE_SOURCE
    $previousOutput = $env:MUTECUE_EXE_OUTPUT
    $previousVersion = $env:MUTECUE_EXE_VERSION
    try {
        $env:MUTECUE_EXE_SOURCE = $publishDirectory
        $env:MUTECUE_EXE_OUTPUT = $innoOutputDirectory
        $env:MUTECUE_EXE_VERSION = [string]$manifest.version
        & $compiler (Join-Path $repositoryRoot "src\MuteCue.Desktop\MuteCueSetup.iss") | Out-Host
        if ($LASTEXITCODE -ne 0) { throw "Inno Setup could not create the Mute Cue installer." }
    } finally {
        $env:MUTECUE_EXE_SOURCE = $previousSource
        $env:MUTECUE_EXE_OUTPUT = $previousOutput
        $env:MUTECUE_EXE_VERSION = $previousVersion
    }

    $compiledInstaller = Join-Path $innoOutputDirectory "MuteCue-Setup.exe"
    if (-not [IO.File]::Exists($compiledInstaller)) { throw "Inno Setup did not produce MuteCue-Setup.exe." }
    [IO.File]::Move($compiledInstaller, $installerPath)
    $hash = (Get-FileHash -LiteralPath $installerPath -Algorithm SHA256).Hash.ToLowerInvariant()
    [IO.File]::WriteAllText($checksumPath, "$hash  $releaseName`r`n", (New-Object Text.UTF8Encoding($false)))
    & (Join-Path $overlayDirectory "Test-MuteCueExeInstaller.ps1") -InstallerPath $installerPath | Out-Host

    Write-Output ("Mute Cue {0} EXE release: PASS" -f [string]$manifest.version)
    Write-Output $installerPath
    Write-Output $checksumPath
} finally {
    if ([IO.Directory]::Exists($stagingDirectory)) { Remove-Item -LiteralPath $stagingDirectory -Recurse -Force -ErrorAction SilentlyContinue }
}
