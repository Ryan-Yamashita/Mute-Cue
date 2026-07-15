$ErrorActionPreference = "Stop"
$overlayDirectory = Split-Path -Parent $PSScriptRoot
$overlayPath = Join-Path $overlayDirectory "BeacnMuteOverlay.ps1"
$source = [System.IO.File]::ReadAllText($overlayPath)

foreach ($file in @(
    $overlayPath,
    (Join-Path $overlayDirectory "MuteCue.Paths.ps1"),
    (Join-Path $overlayDirectory "MuteCue.Readiness.ps1"),
    (Join-Path $overlayDirectory "MuteCue.Startup.ps1"),
    (Join-Path $overlayDirectory "MuteCue.AccessibilityRuntime.ps1"),
    (Join-Path $overlayDirectory "MuteCue.AtomicFile.ps1"),
    (Join-Path $overlayDirectory "MuteCue.BeacnHotkeys.ps1"),
    (Join-Path $overlayDirectory "MuteCue.Signing.ps1"),
    (Join-Path $overlayDirectory "Build-MuteCueAccessibilityAssembly.ps1"),
    (Join-Path $overlayDirectory "Build-MuteCueRelease.ps1"),
    (Join-Path $overlayDirectory "Measure-MuteCueAccessibilityStartup.ps1"),
    (Join-Path $overlayDirectory "Test-MuteCueReleaseArtifact.ps1"),
    (Join-Path $overlayDirectory "Test-MuteCueSigningReadiness.ps1"),
    (Join-Path $overlayDirectory "Test-MuteCueDevelopmentSigningPipeline.ps1"),
    (Join-Path $overlayDirectory "Invoke-MuteCueHardwareAcceptance.ps1"),
    (Join-Path $overlayDirectory "BeacnActionState.ps1"),
    (Join-Path $overlayDirectory "BeacnAdapter.ps1"),
    (Join-Path $overlayDirectory "BeacnStateCoordinator.ps1"),
    (Join-Path $overlayDirectory "BeacnAccessibilityClient.ps1"),
    (Join-Path $overlayDirectory "BeacnAccessibilityHost.ps1"),
    (Join-Path $overlayDirectory "BeacnHealthReport.ps1"),
    (Join-Path $overlayDirectory "BeacnHardwareLayout.ps1"),
    (Join-Path $overlayDirectory "MuteCue.Configuration.ps1"),
    (Join-Path $overlayDirectory "MuteCue.Diagnostics.ps1"),
    (Join-Path $overlayDirectory "Install-MuteCue.ps1"),
    (Join-Path $overlayDirectory "Uninstall-MuteCue.ps1"),
    (Join-Path $overlayDirectory "Install-OverlayStartupShortcut.ps1"),
    (Join-Path $overlayDirectory "Remove-OverlayStartupShortcut.ps1")
)) {
    $errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($file, [ref]$null, [ref]$errors)
    if ($errors.Count -gt 0) {
        throw "PowerShell parse failed for '$file': $($errors[0].Message)"
    }
}
if (-not (Test-Path -LiteralPath (Join-Path $overlayDirectory "BeacnCompatibility.json"))) {
    throw "The versioned BEACN compatibility manifest is missing."
}

$requiredPatterns = [ordered]@{
    "atomic settings writes" = "Write-MuteCueAtomicText"
    "request-correlated hardware refresh" = "LastHardwareRequestId"
    "mapping generation protection" = "mixCreateMappingGeneration"
    "authoritative BEACN adapter" = "Submit-BeacnAdapterSnapshot"
    "dynamic profile catalog" = "Update-BeacnScannerAdapterConfiguration"
    "versioned compatibility probe" = "ConfigureCompatibility"
    "bounded accessibility refresh" = "MaximumFaderRefreshesPerScan"
    "layout invalidation" = "LayoutInvalidated"
    "bounded USB queue" = "MaximumQueuedPackets"
    "bounded global input queue" = "MaximumQueuedInputEvents"
    "bounded hardware queue" = "MaximumPendingHardwareRefreshes"
    "bounded Discord queue" = "MaximumQueuedEvents"
    "USB child process ownership" = "JobObjectLimitKillOnJobClose"
    "Discord HTTP timeout" = "request.Timeout = 10000"
    "Discord reconnect loop" = "Discord disconnected. Reconnecting in"
    "interruptible Discord reconnect" = "WaitForRetry"
    "Discord reconnect session reset" = "pendingCodeVerifier = null;"
    "Discord RPC ping response" = "SendFrame(stream, 4, json)"
    "runtime fault boundary" = "A monitoring update failed; the next update will retry."
}
foreach ($entry in $requiredPatterns.GetEnumerator()) {
    if ($source.IndexOf($entry.Value, [StringComparison]::Ordinal) -lt 0) {
        throw "Missing architecture guarantee: $($entry.Key)."
    }
}
if (-not [regex]::IsMatch($source, '(?s)finally\s*\{\s*Stop-MuteCueRuntime\s*\}')) {
    throw "Missing architecture guarantee: guaranteed runtime cleanup."
}
if ($source.Contains("info.RedirectStandardError = true")) {
    throw "An unread redirected stderr stream can deadlock USB capture."
}

$launcher = [System.IO.File]::ReadAllText((Join-Path $overlayDirectory "Start Beacn Mute Overlay Hidden.vbs"))
if (-not $launcher.Contains("Option Explicit") -or -not $launcher.Contains("%SystemRoot%")) {
    throw "The launcher must use explicit declarations and a trusted Windows PowerShell path."
}
if ($launcher.Contains('"runas"')) {
    throw "The default overlay launcher must not elevate the entire application."
}
foreach ($startupMarker in @('/startup', '-StartedAtLogin', '-StartupLauncherPath')) {
    if (-not $launcher.Contains($startupMarker)) {
        throw "The portable launcher is missing startup-origin marker '$startupMarker'."
    }
}
$clientSource = [IO.File]::ReadAllText((Join-Path $overlayDirectory "BeacnAccessibilityClient.ps1"))
$hostSource = [IO.File]::ReadAllText((Join-Path $overlayDirectory "BeacnAccessibilityHost.ps1"))
$runtimeSource = [IO.File]::ReadAllText((Join-Path $overlayDirectory "MuteCue.AccessibilityRuntime.ps1"))
$atomicFileSource = [IO.File]::ReadAllText((Join-Path $overlayDirectory "MuteCue.AtomicFile.ps1"))
$signingSource = [IO.File]::ReadAllText((Join-Path $overlayDirectory "MuteCue.Signing.ps1"))
$coordinatorSource = [IO.File]::ReadAllText((Join-Path $overlayDirectory "BeacnStateCoordinator.ps1"))
foreach ($workerGuarantee in @("SessionToken", "WorkerInstanceId", "LastSnapshotSequence", "DiscoveryTimeoutSeconds", "ScanInProgressMilliseconds", "maximumScanDurationMilliseconds")) {
    if (-not $clientSource.Contains($workerGuarantee) -and -not $hostSource.Contains($workerGuarantee)) {
        throw "The isolated worker protocol is missing '$workerGuarantee'."
    }
}
foreach ($stateEnvelopeGuarantee in @(
    'lastCompletedStateRevision',
    'lastCompletedStateCapturedAtUtc',
    "GetFiles(`$commandPath, '*.json')"
)) {
    if (-not $hostSource.Contains($stateEnvelopeGuarantee)) {
        throw "The isolated worker is missing state-envelope guarantee '$stateEnvelopeGuarantee'."
    }
}
if ($hostSource.Contains("Add-Type -TypeDefinition")) {
    throw "The release worker must not compile the accessibility provider at runtime."
}
if (-not $hostSource.Contains("Import-MuteCueAccessibilityRuntime")) {
    throw "The worker must use the validated accessibility runtime loader."
}
foreach ($atomicGuarantee in @("FileShare]::Delete", "MaximumAttempts", "Write-MuteCueAtomicText", "Read-MuteCueSharedText")) {
    if (-not $atomicFileSource.Contains($atomicGuarantee)) { throw "Atomic worker IPC is missing '$atomicGuarantee'." }
}
$configurationSource = [IO.File]::ReadAllText((Join-Path $overlayDirectory "MuteCue.Configuration.ps1"))
if (([regex]::Matches($atomicFileSource + $configurationSource, 'function\s+Write-MuteCueAtomicText\s*\{', [Text.RegularExpressions.RegexOptions]::IgnoreCase)).Count -ne 1) {
    throw "Atomic text publication must have exactly one canonical implementation."
}
if ($hostSource.Contains('snapshotPath + ".tmp"') -or $clientSource.Contains("Get-Content -LiteralPath `$Client.SnapshotPath")) {
    throw "Worker snapshot IPC must use the contention-safe atomic file boundary."
}
foreach ($runtimeGuarantee in @("IntegrityVerified", "ContractVersion", "sourceSha256", "DevelopmentFallback")) {
    if (-not $runtimeSource.Contains($runtimeGuarantee)) {
        throw "The accessibility runtime is missing '$runtimeGuarantee'."
    }
}
foreach ($signingGuarantee in @("1.3.6.1.5.5.7.3.3", "MinimumRemainingDays", "RequireTimestamp", "TimeStamperCertificate")) {
    if (-not $signingSource.Contains($signingGuarantee)) {
        throw "The release-signing architecture is missing '$signingGuarantee'."
    }
}
foreach ($coordinatorGuarantee in @("LastProviderSequence", "GeometryGeneration", "RejectedSnapshots", "Publishable")) {
    if (-not $coordinatorSource.Contains($coordinatorGuarantee)) {
        throw "The BEACN coordinator is missing '$coordinatorGuarantee'."
    }
}
$pathsSource = [IO.File]::ReadAllText((Join-Path $overlayDirectory "MuteCue.Paths.ps1"))
$actionStateSource = [IO.File]::ReadAllText((Join-Path $overlayDirectory "BeacnActionState.ps1"))
$installerSource = [IO.File]::ReadAllText((Join-Path $overlayDirectory "Install-MuteCue.ps1"))
$installedLauncher = [IO.File]::ReadAllText((Join-Path $overlayDirectory "MuteCue.InstalledLauncher.vbs"))
if (-not $pathsSource.Contains('Join-Path $env:LOCALAPPDATA "MuteCue"') -or -not $pathsSource.Contains("MigrationMarkerPath")) {
    throw "Mutable application data must use marker-backed per-user storage."
}
if (-not $source.Contains("Test-BeacnOptimisticActionAllowed") -or -not $source.Contains("SafetySweepCadenceMilliseconds")) {
    throw "The BEACN fast path must be confidence-gated and freshness-reconciled."
}
foreach ($movementGuarantee in @("ObserveNativeWindowGeometry", "PollWindowGeometry", "NativeGeometryGeneration", "CaptureTrackedFaderState", "discovery discarded across window movement", "ResolveCachedActionAtPoint")) {
    if (-not $source.Contains($movementGuarantee)) {
        throw "Monitor movement hardening is missing '$movementGuarantee'."
    }
}
foreach ($statusGuarantee in @("Ready - Fast hardware response active", "Resyncing - Refreshing BEACN locations", "Discovering - BEACN monitoring unavailable")) {
    if (-not $source.Contains($statusGuarantee)) {
        throw "The BEACN connection card is missing '$statusGuarantee'."
    }
}
foreach ($calmStatusGuarantee in @("Update-MuteCueBeacnProviderTrouble", "Update-MuteCueBeacnStatusPresentation", "Resyncing - Verifying the latest BEACN state")) {
    if (-not $source.Contains($calmStatusGuarantee)) {
        throw "The BEACN connection card is missing calm recovery behavior '$calmStatusGuarantee'."
    }
}
if (-not $actionStateSource.Contains('[double]$MaximumAgeSeconds = 0.85')) {
    throw "Hardware predictions must have a bounded short lease."
}
foreach ($fastInputGuarantee in @('FromMilliseconds(15)', 'Invoke-BeacnHotkeyGestureQueue', 'Invoke-MixCreateUsbPacketQueue')) {
    if (-not $source.Contains($fastInputGuarantee)) {
        throw "The fast input path is missing '$fastInputGuarantee'."
    }
}
foreach ($exactHardwareEventGuarantee in @('QueueUrgentFaderRefresh(name, mask)', '? 21', '? 26', 'coalescing urgent dictionary')) {
    if (-not $source.Contains($exactHardwareEventGuarantee)) {
        throw "Unknown-page hardware events must prioritize an exact rendered fader reread ('$exactHardwareEventGuarantee')."
    }
}
foreach ($hardwareCorrelationGuarantee in @('recentPersonalOutputEdges', 'recentAudienceOutputEdges', 'OutputEdgePreRequestToleranceMilliseconds', 'InputAtUtcTicks', 'IsCorrelatedUniqueOutputEdge', 'ShouldCompletePreferredHardwareRead')) {
    if (-not $source.Contains($hardwareCorrelationGuarantee)) {
        throw "Unknown-page hardware calibration must correlate one exact, recent output edge ('$hardwareCorrelationGuarantee')."
    }
}
foreach ($desktopPointGuarantee in @('Get-BeacnActionPointCandidateScore', 'Test-BeacnActionPointCandidatePreferred', '$bestScore = $null')) {
    if (-not $source.Contains($desktopPointGuarantee) -and -not $actionStateSource.Contains($desktopPointGuarantee)) {
        throw "Desktop action-point resolution must prefer the nearest exact BEACN row ('$desktopPointGuarantee')."
    }
}
foreach ($workerCadenceGuarantee in @('$idleScanCadenceMilliseconds = 2000', '$scanRequested', 'WaitForChanged($watchTypes, 60)', '$shouldPublish')) {
    if (-not $hostSource.Contains($workerCadenceGuarantee)) {
        throw "The accessibility worker cadence is missing '$workerCadenceGuarantee'."
    }
}
foreach ($installerGuarantee in @(".staging-", "Directory]::Move", "File]::Replace", "current.txt.previous")) {
    if (-not $installerSource.Contains($installerGuarantee) -and -not $installerSource.Contains($installerGuarantee.Replace("current.txt.previous", "current.txt"))) {
        throw "The per-user installer is missing '$installerGuarantee'."
    }
}
if ($installedLauncher.Contains('"runas"') -or -not $installedLauncher.Contains('InStr(releaseId, "..")')) {
    throw "The stable installed launcher must remain non-elevated and constrain the active release marker."
}
foreach ($startupMarker in @('/startup', '-StartedAtLogin', '-StartupLauncherPath')) {
    if (-not $installedLauncher.Contains($startupMarker)) {
        throw "The installed launcher is missing startup-origin marker '$startupMarker'."
    }
}
foreach ($tabGuarantee in @('Select-MuteCueSettingsTab -Name "Discord"', 'settingsTabButtons.Discord', 'settingsTabButtons.BEACN', 'settingsTabButtons.Settings', '$faderHeading.Text = "Fader Sources"')) {
    if (-not $source.Contains($tabGuarantee)) {
        throw "The Discord-first settings tabs are missing '$tabGuarantee'."
    }
}
if ($source.Contains('New-CollapsibleSection -Container $beacnAdvancedPanel -Text "Faders"')) {
    throw 'Fader Sources must remain visible within its dedicated BEACN tab.'
}
foreach ($startupUiGuarantee in @('Run on startup', 'Start in system tray', 'Refresh-MuteCueStartupControls')) {
    if (-not $source.Contains($startupUiGuarantee)) {
        throw "The settings tab is missing startup behavior '$startupUiGuarantee'."
    }
}
foreach ($removedF24Path in @('VK_F24', 'StartF24Listener', 'F24 Mute All hotkey')) {
    if ($source.Contains($removedF24Path)) {
        throw "The hardcoded F24 path remains: '$removedF24Path'."
    }
}
foreach ($genericHotkeyGuarantee in @(
    'MuteCue.BeacnHotkeys.ps1',
    'StartKeyboardListener',
    'ConsumeKeyGesture',
    'Update-BeacnHotkeyConfiguration',
    'Request-BeacnHotkeyFaderRefresh',
    'MaximumQueuedInputEvents = 256',
    'CallNextHookEx(keyboardHook'
)) {
    if (-not $source.Contains($genericHotkeyGuarantee)) {
        throw "The generic pass-through BEACN shortcut path is missing '$genericHotkeyGuarantee'."
    }
}
foreach ($latencyGuarantee in @(
    'RequestUrgentFaderRefresh',
    'pendingUrgentActionRefreshes',
    'missingRefreshDeadlineGeneration',
    'RetainActionRefreshUntilNextDiscovery',
    'SelectUniqueOutputChange',
    'FindUniqueOutputChange',
    'CommitHardwareCompletion',
    'RequeueHardwareCompletion',
    '$hotkeyInputTimer.Interval = [TimeSpan]::FromMilliseconds(15)',
    'one[stalest.Name] = 15',
    'Request-BeacnFaderRefresh -Name $resolvedName -Mode $Mode -Rendered -Urgent',
    'Set-BeacnOptimisticAction',
    'preferredRetryDelays',
    'pendingBeacnPointRefreshes',
    'ActionRevision'
)) {
    if (-not $source.Contains($latencyGuarantee)) {
        throw "The low-latency BEACN action path is missing '$latencyGuarantee'."
    }
}
$urgentDrain = $source.IndexOf('DrainActionRefreshes(pendingUrgentActionRefreshes', [StringComparison]::Ordinal)
$ordinaryDrain = $source.IndexOf('DrainActionRefreshes(pendingActionRefreshes', [StringComparison]::Ordinal)
if ($urgentDrain -lt 0 -or $ordinaryDrain -lt 0 -or $urgentDrain -ge $ordinaryDrain) {
    throw 'Urgent shortcut refreshes must be drained before ordinary background row work.'
}
$hardwareDequeueAfterUrgent = $source.IndexOf('TryDequeueHardwareRefresh(out hardwareRequest)', $urgentDrain, [StringComparison]::Ordinal)
if ($hardwareDequeueAfterUrgent -lt 0 -or $urgentDrain -ge $hardwareDequeueAfterUrgent) {
    throw 'Urgent exact-name refreshes must be able to interrupt hardware page recovery.'
}
$hardwareRefreshMatch = [regex]::Match(
    $source,
    '(?s)private static HardwareRefreshCompletion RefreshHardwareActionState.*?private static bool TryReadActionRow'
)
if (-not $hardwareRefreshMatch.Success) { throw 'The physical hardware refresh path could not be inspected.' }
$confidentCompletionIndex = $hardwareRefreshMatch.Value.IndexOf('if (request.MappingConfident)', [StringComparison]::Ordinal)
$fallbackWalkIndex = $hardwareRefreshMatch.Value.IndexOf('if (request.FallbackIndex < 0) request.FallbackIndex = 0', [StringComparison]::Ordinal)
if ($confidentCompletionIndex -lt 0 -or $fallbackWalkIndex -lt 0 -or $confidentCompletionIndex -ge $fallbackWalkIndex) {
    throw 'A confident hardware mapping must finish without walking unrelated faders.'
}
if (-not $source.Contains('? 5') -or -not $source.Contains('? 10')) {
    throw 'Explicit hardware refreshes must retain the rendered-row probe bits.'
}
if ([regex]::Matches($source, '-MappingConfident\s+\$mappingConfident').Count -ne 4) {
    throw 'Both hardware action modes must carry page confidence into the scanner.'
}
if ($source.Contains('RefreshOutputBaseline')) {
    throw 'Latency-critical action reads must not add output-toggle baseline round trips.'
}
$hotkeyPreviewMatch = [regex]::Match(
    $source,
    '(?s)function Test-BeacnHotkeyOptimisticActionAllowed \{.*?\r?\n\}'
)
if (
    -not $hotkeyPreviewMatch.Success -or
    -not $hotkeyPreviewMatch.Value.Contains('GeometryRefreshInProgress') -or
    -not $hotkeyPreviewMatch.Value.Contains('Get-BeacnCoordinatorHealth')
) {
    throw 'Shortcut preview must be guarded by stable geometry and worker health.'
}
$scannerScanMatch = [regex]::Match(
    $source,
    '(?s)private static BeacnFaderState\[\] Scan\(\).*?private static void PromotePossibleLayoutChange'
)
if (-not $scannerScanMatch.Success) { throw 'The BEACN scanner loop could not be inspected.' }
$geometryFenceIndex = $scannerScanMatch.Value.IndexOf('Interlocked.Read(ref nativeGeometryGeneration) != scanGeometryGeneration')
$hardwareCommitIndex = $scannerScanMatch.Value.IndexOf('CommitHardwareCompletion(hardwareCompletion)')
if ($geometryFenceIndex -lt 0 -or $hardwareCommitIndex -lt 0 -or $hardwareCommitIndex -le $geometryFenceIndex) {
    throw 'Hardware results must remain staged until after the native-geometry fence.'
}
$gitIgnore = [System.IO.File]::ReadAllText((Join-Path (Split-Path -Parent $overlayDirectory) ".gitignore"))
foreach ($privatePattern in @(".discord-client-secret.dat", ".discord-authorization.dat", "MuteCue.DiscordPublicClient.local.json", "*.pcapng", "Settings/", "*.pfx", "*.p12", "*.key")) {
    if (-not $gitIgnore.Contains($privatePattern)) { throw "Git ignore is missing private pattern '$privatePattern'." }
}
if ($source.Contains('RequestHardwareRefresh($preferredName, "All", $position)')) {
    throw "Legacy uncorrelated hardware refresh call remains."
}
if ($source.Contains("KnownFaderNames")) {
    throw "BEACN discovery must not be restricted to a compiled fader-name whitelist."
}
if ($source.Contains("ResolveFaderNameAtPoint")) {
    throw "Desktop actions must not infer fader identity from a cached horizontal coordinate."
}
if (-not $source.Contains("ResolveActionAtPoint")) {
    throw "Desktop actions must resolve the current named BEACN action row."
}
if (-not $source.Contains("IsTrackedBeacnPoint")) {
    throw "Global desktop clicks must be filtered to the tracked BEACN process."
}
if ($source.Contains('CanMonitorAudience = [bool]$state.ActionStateKnown')) {
    throw "Transient BEACN authority must not remove the Audience monitoring capability."
}
foreach ($destructiveSelectionPattern in @(
    '$fader.CanMonitorAudience -and $selectedAudience',
    '$Fader.CanMonitorAudience -and $selectedAudience',
    '$fader.CanMonitorAudience -and $initialAudienceFaderNames',
    '$fader.IsAvailable -and $initialAllFaderNames',
    '$Fader.IsAvailable -and $selectedAll'
)) {
    if ($source.Contains($destructiveSelectionPattern)) {
        throw "Temporary fader availability must not clear a saved selection: $destructiveSelectionPattern"
    }
}
$actionReaderMatch = [regex]::Match(
    $source,
    '(?s)private static bool TryReadActionRow\(.*?private static bool IsCursorInside\('
)
if (-not $actionReaderMatch.Success) {
    throw "The named BEACN action-row reader could not be inspected."
}
$actionReader = $actionReaderMatch.Value
$liveGeometryIndex = $actionReader.IndexOf('AutomationElement.AutomationElementInformation labelInfo = label.Current')
$cursorGeometryIndex = $actionReader.IndexOf('bool cursorInsideRow = IsCursorInside(rowBounds)')
if ($liveGeometryIndex -lt 0 -or $cursorGeometryIndex -lt 0 -or $liveGeometryIndex -gt $cursorGeometryIndex) {
    throw "BEACN action rows must refresh live geometry before using pointer coordinates."
}
$desktopClickMatch = [regex]::Match(
    $source,
    '(?s)function Update-BeacnDesktopClickActions \{.*?\r?\n\}\r?\n\r?\nfunction Update-BeacnTrackerMode'
)
if (-not $desktopClickMatch.Success) {
    throw "The desktop click dispatcher could not be inspected."
}
foreach ($cachedCoordinate in @('AllActionTop', 'AllActionLeft', 'AudienceActionTop', 'AudienceActionLeft')) {
    if ($desktopClickMatch.Value.Contains($cachedCoordinate)) {
        throw "Desktop click dispatch must not use cached $cachedCoordinate geometry."
    }
}
if ([regex]::Matches($source, 'Update-BeacnAppFaderStateLegacy').Count -ne 1) {
    throw "The isolated legacy BEACN state function must not be called by the runtime."
}

"Architecture tests: PASS"
