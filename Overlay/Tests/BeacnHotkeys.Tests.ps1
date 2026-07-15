$ErrorActionPreference = 'Stop'
$overlayDirectory = Split-Path -Parent $PSScriptRoot
. (Join-Path $overlayDirectory 'MuteCue.BeacnHotkeys.ps1')

function Assert-Hotkey {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

$realFormatFixture = @'
<?xml version="1.0" encoding="UTF-8"?>
<KEYMAPPINGS basedOnDefaults="0">
  <MAPPING commandId="53" description="Toggles The Knob Press Mute For Mic" key="F24"/>
  <MAPPING commandId="57" description="Toggles The Knob Press Mute For Chat" key="F13"/>
</KEYMAPPINGS>
'@

$assignments = @(ConvertFrom-MuteCueBeacnKeyMappingsXml -XmlText $realFormatFixture)
Assert-Hotkey ($assignments.Count -eq 2) 'Every valid BEACN knob-mute assignment must be retained.'
Assert-Hotkey ($assignments[0].CommandId -eq 53) 'The BEACN command ID should be preserved for diagnostics.'

$micTarget = Resolve-MuteCueBeacnHotkeyTarget -Assignments $assignments -Key 'f24'
Assert-Hotkey ($null -ne $micTarget) 'F24 must resolve to its configured BEACN fader.'
Assert-Hotkey ($micTarget.Name -eq 'Mic' -and $micTarget.Mode -eq 'All') 'F24 must target Mic / Mute All.'

$chatTarget = Resolve-MuteCueBeacnHotkeyTarget -Assignments $assignments -Key ' F13 '
Assert-Hotkey ($null -ne $chatTarget) 'A second configured key must resolve independently.'
Assert-Hotkey ($chatTarget.Name -eq 'Chat' -and $chatTarget.Mode -eq 'All') 'F13 must target Chat / Mute All.'
Assert-Hotkey ($null -eq (Resolve-MuteCueBeacnHotkeyTarget -Assignments $assignments -Key 'F12')) 'Unassigned keys must not refresh a fader.'

$f24Gesture = ConvertTo-MuteCueBeacnHotkeyGesture -Key 'F24'
Assert-Hotkey ($null -ne $f24Gesture) 'F24 must be accepted as a BEACN hotkey gesture.'
Assert-Hotkey ($f24Gesture.VirtualKey -eq 0x87 -and $f24Gesture.Modifiers -eq 0) 'F24 must map to virtual-key 0x87 with no modifiers.'
Assert-Hotkey ($f24Gesture.GestureCode -eq 0x00000087) 'F24 must have the exact listener gesture code 0x00000087.'

$modifiedGesture = ConvertTo-MuteCueBeacnHotkeyGesture -Key 'Ctrl + Shift + F13'
Assert-Hotkey ($null -ne $modifiedGesture) 'Ctrl+Shift+F13 must be accepted as a BEACN hotkey gesture.'
Assert-Hotkey ($modifiedGesture.VirtualKey -eq 0x7C -and $modifiedGesture.Modifiers -eq 3) 'Ctrl+Shift+F13 must map to virtual-key 0x7C and modifier bits 0x3.'
Assert-Hotkey ($modifiedGesture.GestureCode -eq 0x0003007C) 'Ctrl+Shift+F13 must have the exact listener gesture code 0x0003007C.'

$numpadAddGesture = ConvertTo-MuteCueBeacnHotkeyGesture -Key 'numpad +'
Assert-Hotkey ($null -ne $numpadAddGesture -and $numpadAddGesture.VirtualKey -eq 0x6B) 'JUCE numpad + must remain intact while modifier separators are parsed.'
foreach ($cursorCase in @(
    @{ Key = 'cursor left'; VirtualKey = 0x25 },
    @{ Key = 'cursor up'; VirtualKey = 0x26 },
    @{ Key = 'cursor right'; VirtualKey = 0x27 },
    @{ Key = 'cursor down'; VirtualKey = 0x28 }
)) {
    $cursorGesture = ConvertTo-MuteCueBeacnHotkeyGesture -Key $cursorCase.Key
    Assert-Hotkey ($null -ne $cursorGesture -and $cursorGesture.VirtualKey -eq $cursorCase.VirtualKey) "JUCE $($cursorCase.Key) must map to its Windows navigation key."
}

foreach ($unsupportedGesture in @('Win+F24', 'Ctrl+Ctrl+F24', 'F25', 'Ctrl++F13', 'Mouse 1', 'Shift + +')) {
    Assert-Hotkey ($null -eq (ConvertTo-MuteCueBeacnHotkeyGesture -Key $unsupportedGesture)) "Unsupported gesture '$unsupportedGesture' must fail closed."
}

$linkAlias = Resolve-MuteCueBeacnHotkeyFaderName -Name 'Link In 2' -AvailableNames @('Mic', 'Link 2 In', 'Chat')
Assert-Hotkey ($linkAlias -eq 'Link 2 In') 'The BEACN hotkey label Link In 2 must resolve to the scanner fader name Link 2 In.'

$duplicateFixture = @'
<KEYMAPPINGS>
  <MAPPING commandId="53" description="Toggles The Knob Press Mute For Mic" key="F24"/>
  <MAPPING commandId="153" description="Toggles The Knob Press Mute For Mic" key="F24"/>
</KEYMAPPINGS>
'@
$duplicateAssignments = @(ConvertFrom-MuteCueBeacnKeyMappingsXml -XmlText $duplicateFixture)
$duplicateTarget = Resolve-MuteCueBeacnHotkeyTarget -Assignments $duplicateAssignments -Key 'F24'
Assert-Hotkey ($null -ne $duplicateTarget -and $duplicateTarget.Name -eq 'Mic') 'Identical duplicate records must remain safe and deterministic.'

$ambiguousFixture = @'
<KEYMAPPINGS>
  <MAPPING commandId="53" description="Toggles The Knob Press Mute For Mic" key="F24"/>
  <MAPPING commandId="54" description="Toggles The Knob Press Mute For System" key="F24"/>
</KEYMAPPINGS>
'@
$ambiguousAssignments = @(ConvertFrom-MuteCueBeacnKeyMappingsXml -XmlText $ambiguousFixture)
Assert-Hotkey ($null -eq (Resolve-MuteCueBeacnHotkeyTarget -Assignments $ambiguousAssignments -Key 'F24')) 'One key assigned to different faders must fail closed.'

$normalBindings = @(Get-MuteCueBeacnHotkeyBindings -Assignments @(
    [pscustomobject]@{ Key = 'F24'; Name = 'Mic'; Mode = 'All' }
    [pscustomobject]@{ Key = 'Ctrl+Shift+F13'; Name = 'Link In 2'; Mode = 'All' }
))
Assert-Hotkey ($normalBindings.Count -eq 2) 'Valid, distinct BEACN gestures must each produce a listener binding.'
$normalF24Binding = @($normalBindings | Where-Object { $_.GestureCode -eq 0x00000087 })
Assert-Hotkey ($normalF24Binding.Count -eq 1 -and $normalF24Binding[0].Name -eq 'Mic') 'The normal F24 binding must target Mic.'
$normalModifiedBinding = @($normalBindings | Where-Object { $_.GestureCode -eq 0x0003007C })
Assert-Hotkey ($normalModifiedBinding.Count -eq 1 -and $normalModifiedBinding[0].Name -eq 'Link 2 In') 'The modified binding must preserve the exact gesture and canonical Link 2 In target.'

$ambiguousBindings = @(Get-MuteCueBeacnHotkeyBindings -Assignments @(
    [pscustomobject]@{ Key = 'Ctrl+F13'; Name = 'Mic'; Mode = 'All' }
    [pscustomobject]@{ Key = 'Control+F13'; Name = 'Chat'; Mode = 'All' }
))
Assert-Hotkey ($ambiguousBindings.Count -eq 0) 'Different BEACN labels that collide on one listener gesture must fail closed when their targets differ.'
Assert-Hotkey (@(Get-MuteCueBeacnHotkeyBindings -Assignments $ambiguousAssignments).Count -eq 0) 'An ambiguous exact-key assignment must not produce a listener binding.'

$invalidRecordsFixture = @'
<KEYMAPPINGS>
  <MAPPING commandId="1" description="Toggles Personal Mix Device" key="F23"/>
  <MAPPING commandId="2" description="Toggles The Knob Press Mute For System" key=""/>
  <MAPPING commandId="3" description="Toggles The Knob Press Mute For Game" key="Unassigned"/>
  <MAPPING commandId="4" description="Toggles The Audience Mute For Chat" key="F20"/>
  <MAPPING commandId="5" key="F19"/>
  <MAPPING commandId="not-a-number" description="Toggles The Knob Press Mute For Link In 2" key="F18"/>
</KEYMAPPINGS>
'@
$validSubset = @(ConvertFrom-MuteCueBeacnKeyMappingsXml -XmlText $invalidRecordsFixture)
Assert-Hotkey ($validSubset.Count -eq 1 -and $validSubset[0].Name -eq 'Link In 2') 'Unrelated, unassigned, and malformed records must be ignored without rejecting a valid fader name.'
Assert-Hotkey ($null -eq $validSubset[0].CommandId) 'A malformed optional command ID must not become a false numeric ID.'

foreach ($invalidXml in @(
    '<KEYMAPPINGS><MAPPING',
    '<NOT_KEYMAPPINGS><MAPPING description="Toggles The Knob Press Mute For Mic" key="F24"/></NOT_KEYMAPPINGS>',
    '<!DOCTYPE KEYMAPPINGS [<!ENTITY xxe SYSTEM "file:///C:/Windows/win.ini">]><KEYMAPPINGS><MAPPING description="Toggles The Knob Press Mute For &xxe;" key="F24"/></KEYMAPPINGS>'
)) {
    Assert-Hotkey (@(ConvertFrom-MuteCueBeacnKeyMappingsXml -XmlText $invalidXml).Count -eq 0) 'Malformed or unsafe XML must fail closed.'
}

$resolvedPath = Get-MuteCueBeacnKeyMappingsPath -DocumentsDirectory 'C:\Users\Example\Documents'
Assert-Hotkey ($resolvedPath -eq 'C:\Users\Example\Documents\BEACN\keyMappings\keyMappings.xml') 'The default BEACN mapping path is incorrect.'

$tempDirectory = Join-Path ([IO.Path]::GetTempPath()) ('MuteCue-BeacnHotkeys-{0}' -f [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($tempDirectory)
try {
    $tempPath = Join-Path $tempDirectory 'keyMappings.xml'
    [IO.File]::WriteAllText($tempPath, $realFormatFixture, (New-Object Text.UTF8Encoding($false)))
    $imported = @(Import-MuteCueBeacnHotkeyMappings -Path $tempPath)
    Assert-Hotkey ($imported.Count -eq 2) 'The on-disk BEACN mapping file must use the same parser.'
    Assert-Hotkey (@(Import-MuteCueBeacnHotkeyMappings -Path (Join-Path $tempDirectory 'missing.xml')).Count -eq 0) 'A missing mapping file must fail safely.'

    $validEmptyPath = Join-Path $tempDirectory 'valid-empty.xml'
    [IO.File]::WriteAllText($validEmptyPath, '<KEYMAPPINGS/>', (New-Object Text.UTF8Encoding($false)))
    $validEmptySnapshot = Read-MuteCueBeacnHotkeyMappings -Path $validEmptyPath
    Assert-Hotkey ($validEmptySnapshot.Success -and $validEmptySnapshot.Exists) 'A valid mapping file with no assignments must be a successful snapshot.'
    Assert-Hotkey (@($validEmptySnapshot.Assignments).Count -eq 0 -and [string]::IsNullOrWhiteSpace($validEmptySnapshot.ErrorMessage)) 'A valid-empty snapshot must not report a parse error.'

    $malformedPath = Join-Path $tempDirectory 'malformed.xml'
    [IO.File]::WriteAllText($malformedPath, '<KEYMAPPINGS><MAPPING', (New-Object Text.UTF8Encoding($false)))
    $malformedSnapshot = Read-MuteCueBeacnHotkeyMappings -Path $malformedPath
    Assert-Hotkey (-not $malformedSnapshot.Success -and $malformedSnapshot.Exists) 'Malformed XML must be distinguishable from a valid-empty mapping snapshot.'
    Assert-Hotkey (@($malformedSnapshot.Assignments).Count -eq 0 -and -not [string]::IsNullOrWhiteSpace($malformedSnapshot.ErrorMessage)) 'A malformed snapshot must retain an actionable parse error.'
} finally {
    if ([IO.Directory]::Exists($tempDirectory)) {
        [IO.Directory]::Delete($tempDirectory, $true)
    }
}

'BEACN hotkey tests: PASS'
