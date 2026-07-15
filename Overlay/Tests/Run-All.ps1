$ErrorActionPreference = "Stop"
$tests = @(
    "Paths.Tests.ps1",
    "Readiness.Tests.ps1",
    "Packaging.Tests.ps1",
    "Configuration.Tests.ps1",
    "Startup.Tests.ps1",
    "DiscordPublicClient.Tests.ps1",
    "Diagnostics.Tests.ps1",
    "AtomicFile.Tests.ps1",
    "AccessibilityRuntime.Tests.ps1",
    "Signing.Tests.ps1",
    "BeacnActionState.Tests.ps1",
    "BeacnAdapter.Tests.ps1",
    "BeacnIsolation.Tests.ps1",
    "BeacnHardwareLayout.Tests.ps1",
    "BeacnHotkeys.Tests.ps1",
    "ProductionMatrix.Tests.ps1",
    "Architecture.Tests.ps1",
    "EmbeddedSources.Tests.ps1"
)
foreach ($test in $tests) {
    & (Join-Path $PSScriptRoot $test)
}
"Mute Cue test suite: PASS"
