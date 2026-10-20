# Read-only BEACN Mix Create device-interface discovery.
# This script never opens, captures, disables, modifies, or installs device drivers.
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

try {
    $devices = @(Get-PnpDevice -PresentOnly -ErrorAction Stop)
}
catch {
    Write-Error 'Windows Plug and Play information could not be read. Try Windows PowerShell (not an elevated shell).'
    exit 1
}

$beacn = @($devices | Where-Object {
    ([string]$_.FriendlyName -match '(?i)BEACN|Mix Create') -or
    ([string]$_.InstanceId -match '(?i)BEACN')
})

Write-Host ''
Write-Host 'BEACN devices (read-only)' -ForegroundColor Cyan
if ($beacn.Count -eq 0) {
    Write-Host 'No BEACN devices were found by their display names. Ensure Mix Create is connected.'
    return
}

$beacn | Sort-Object Class, FriendlyName | Select-Object Class, FriendlyName, Status, InstanceId |
    Format-Table -AutoSize -Wrap

$usbIds = @($beacn | ForEach-Object {
    [regex]::Matches([string]$_.InstanceId, '(?i)VID_[0-9A-F]{4}&PID_[0-9A-F]{4}') |
        ForEach-Object { $_.Value.ToUpperInvariant() }
} | Select-Object -Unique)

Write-Host ''
Write-Host 'USB vendor/product identifiers from named BEACN devices' -ForegroundColor Cyan
if ($usbIds.Count -eq 0) {
    Write-Host 'No USB VID/PID was present in the named device IDs. HID capability cannot be concluded.'
    return
}
$usbIds | ForEach-Object { Write-Host $_ }

# Match HID interface entries by full VID+PID, not just manufacturer/Vendor ID.
$hidMatches = @(
    foreach ($device in $devices) {
        if ([string]$device.Class -ne 'HIDClass') {
            continue
        }
        $instanceId = ([string]$device.InstanceId).ToUpperInvariant()
        foreach ($usbId in $usbIds) {
            if ($instanceId.Contains($usbId)) {
                $device
                break
            }
        }
    }
)

Write-Host ''
Write-Host 'Related Windows HID device interfaces' -ForegroundColor Cyan
if ($hidMatches.Count -gt 0) {
    $hidMatches | Sort-Object InstanceId -Unique |
        Select-Object Class, FriendlyName, Status, InstanceId |
        Format-Table -AutoSize -Wrap
}
else {
    Write-Host 'None found for those VID/PID pairs.'
}

Write-Host ''
Write-Host 'This is inventory only. A matching HID interface does NOT prove it reports Mix Create button presses or can be observed while BEACN runs.' -ForegroundColor Yellow
Write-Host 'Review the output before sharing; device instance IDs may contain identifiers specific to your PC.' -ForegroundColor Yellow
