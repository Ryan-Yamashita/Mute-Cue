$ErrorActionPreference = "Stop"
$overlayPath = Join-Path (Split-Path -Parent $PSScriptRoot) "BeacnMuteOverlay.ps1"
$text = [System.IO.File]::ReadAllText($overlayPath)

function Get-EmbeddedSource {
    param([Parameter(Mandatory)][string]$VariableName)

    $pattern = '(?ms)^\$' + [regex]::Escape($VariableName) + '\s*=\s*@"\r?\n(.*?)\r?\n"@\s*$'
    $match = [regex]::Match($text, $pattern)
    if (-not $match.Success) { throw "Embedded source '$VariableName' was not found." }
    return $match.Groups[1].Value
}

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes

Add-Type -TypeDefinition (Get-EmbeddedSource "coreAudioSource")
Add-Type -TypeDefinition (Get-EmbeddedSource "usbCaptureSource")
Add-Type -TypeDefinition (Get-EmbeddedSource "discordScannerSource") -ReferencedAssemblies @(
    [System.Windows.Automation.AutomationElement].Assembly.Location,
    [System.Windows.Automation.AutomationProperty].Assembly.Location,
    [System.Windows.Rect].Assembly.Location
)
Add-Type -TypeDefinition (Get-EmbeddedSource "discordRpcSource") -ReferencedAssemblies "System.Web.Extensions.dll"
Add-Type -TypeDefinition (Get-EmbeddedSource "nativeWindowSource")

$selector = [BeacnMuteOverlay.BeacnAppScanner].GetMethod(
    'SelectUniqueOutputChange',
    [Reflection.BindingFlags]::NonPublic -bor [Reflection.BindingFlags]::Static
)
if ($null -eq $selector) { throw 'The hardware cold-path output selector is missing.' }
function Invoke-OutputSelector {
    param([bool[]]$Personal, [bool[]]$Audience, [int]$Mask)
    return [int]$selector.Invoke($null, [object[]]@($Personal, $Audience, $Mask))
}
if ((Invoke-OutputSelector @($false,$true,$false) @($false,$false,$false) 5) -ne 1) {
    throw 'A unique Mute All output edge must select its fader.'
}
if ((Invoke-OutputSelector @($false,$true) @($false,$true) 5) -ne 1) {
    throw 'Mute All must accept the expected paired Personal/Audience edge.'
}
if ((Invoke-OutputSelector @($false,$false) @($false,$true) 5) -ne -1) {
    throw 'Mute All must reject an Audience-only edge.'
}
if ((Invoke-OutputSelector @($false,$false) @($false,$false) 5) -ne -1) {
    throw 'No output edge must not guess a fader.'
}
if ((Invoke-OutputSelector @($true,$false,$true) @($false,$false,$false) 5) -ne -1) {
    throw 'Multiple output edges must fail closed.'
}
if ((Invoke-OutputSelector @($true,$false) @($false,$false) 10) -ne -1) {
    throw 'An Audience action must ignore a personal-only edge.'
}
if ((Invoke-OutputSelector @($true,$false) @($false,$true) 10) -ne 1) {
    throw 'A unique Audience output edge must select its fader.'
}
if ((Invoke-OutputSelector @($false,$true) @($false,$true) 10) -ne -1) {
    throw 'An Audience action must reject a paired Mute All edge.'
}

$preferredCompletion = [BeacnMuteOverlay.BeacnAppScanner].GetMethod(
    'ShouldCompletePreferredHardwareRead',
    [Reflection.BindingFlags]::NonPublic -bor [Reflection.BindingFlags]::Static
)
if ($null -eq $preferredCompletion) { throw 'The correlated hardware completion gate is missing.' }
function Test-PreferredCompletion {
    param([bool]$Read, [bool]$Changed, [bool]$Confident, [bool]$Correlated)
    return [bool]$preferredCompletion.Invoke($null, [object[]]@($Read, $Changed, $Confident, $Correlated))
}
if (-not (Test-PreferredCompletion $true $true $false $false)) {
    throw 'A directly observed action-row change must complete hardware calibration.'
}
if (-not (Test-PreferredCompletion $true $false $false $true)) {
    throw 'A uniquely correlated output edge must survive an earlier urgent row reconciliation.'
}
if (Test-PreferredCompletion $true $false $true $true) {
    throw 'A confident mapping must not use the unknown-page correlation exception.'
}
if (Test-PreferredCompletion $false $true $false $true) {
    throw 'A failed exact row read must never calibrate a hardware page.'
}

$scannerType = [BeacnMuteOverlay.BeacnAppScanner]
$privateStatic = [Reflection.BindingFlags]::NonPublic -bor [Reflection.BindingFlags]::Static
$refreshActions = $scannerType.GetMethod('RefreshActionStates', $privateStatic)
$trackedFaders = $scannerType.GetField('trackedFaders', $privateStatic)
$discoveryGeneration = $scannerType.GetField('discoveryGeneration', $privateStatic)
$missingDeadlines = $scannerType.GetField('missingRefreshDeadlineGeneration', $privateStatic)
$postUrgent = $scannerType.GetField('postDiscoveryUrgentRefreshes', $privateStatic)
$postOrdinary = $scannerType.GetField('postDiscoveryRefreshes', $privateStatic)
foreach ($requiredMember in @($refreshActions,$trackedFaders,$discoveryGeneration,$missingDeadlines,$postUrgent,$postOrdinary)) {
    if ($null -eq $requiredMember) { throw 'The bounded action-refresh lifecycle could not be inspected.' }
}
function Invoke-RefreshLifecycle {
    param([Collections.Generic.Dictionary[string,int]]$Requested, [bool]$Urgent)
    $arguments = [object[]]::new(2)
    $arguments[0] = $Requested
    $arguments[1] = $Urgent
    return [bool]$refreshActions.Invoke($null, $arguments)
}

$originalTrackedFaders = $trackedFaders.GetValue($null)
$originalDiscoveryGeneration = [int]$discoveryGeneration.GetValue($null)
try {
    $trackedFaders.SetValue($null, [Activator]::CreateInstance($trackedFaders.FieldType))
    $discoveryGeneration.SetValue($null, 0)
    $missingDeadlines.GetValue($null).Clear()
    $postUrgent.GetValue($null).Clear()
    $postOrdinary.GetValue($null).Clear()
    $coldRequest = [Collections.Generic.Dictionary[string,int]]::new([StringComparer]::OrdinalIgnoreCase)
    $coldRequest['Cold Fader'] = 5

    if (Invoke-RefreshLifecycle -Requested $coldRequest -Urgent $true) {
        throw 'A zero-fader shortcut must be retained while its bounded discovery is pending.'
    }
    if ($missingDeadlines.GetValue($null).Count -ne 1 -or $postUrgent.GetValue($null).Count -ne 1) {
        throw 'A zero-fader shortcut must enter the urgent post-discovery queue exactly once.'
    }

    $discoveryGeneration.SetValue($null, 1)
    if (-not (Invoke-RefreshLifecycle -Requested $coldRequest -Urgent $true)) {
        throw 'A missing shortcut must retire after one completed discovery generation.'
    }
    if ($missingDeadlines.GetValue($null).Count -ne 0 -or $postUrgent.GetValue($null).Count -ne 0) {
        throw 'Retiring a missing shortcut must clear its deadline and deferred queue entry.'
    }

    if (Invoke-RefreshLifecycle -Requested $coldRequest -Urgent $true) {
        throw 'A later independent shortcut must receive a fresh bounded discovery attempt.'
    }
    if ([int]$missingDeadlines.GetValue($null)['Cold Fader'] -ne 2) {
        throw 'A fresh shortcut must receive a deadline relative to the current generation.'
    }
} finally {
    $missingDeadlines.GetValue($null).Clear()
    $postUrgent.GetValue($null).Clear()
    $postOrdinary.GetValue($null).Clear()
    $trackedFaders.SetValue($null, $originalTrackedFaders)
    $discoveryGeneration.SetValue($null, $originalDiscoveryGeneration)
}

"Embedded C# sources: PASS"
