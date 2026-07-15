function Get-MuteCueBeacnKeyMappingsPath {
    param(
        [string]$DocumentsDirectory = $([Environment]::GetFolderPath([Environment+SpecialFolder]::MyDocuments))
    )

    if ([string]::IsNullOrWhiteSpace($DocumentsDirectory)) { return $null }
    return Join-Path $DocumentsDirectory "BEACN\keyMappings\keyMappings.xml"
}

function ConvertTo-MuteCueBeacnHotkeyKey {
    param([AllowEmptyString()][string]$Key)

    if ([string]::IsNullOrWhiteSpace($Key)) { return $null }

    $normalized = [regex]::Replace($Key.Trim(), '\s+', ' ')
    if ($normalized.Length -gt 64 -or $normalized.IndexOfAny([char[]]@("`r", "`n", "`t", [char]0)) -ge 0) {
        return $null
    }
    if ($normalized -match '^(?i:none|unassigned|not\s+set)$') { return $null }

    # Canonicalize only modifier separators. Keeping the remaining key text
    # intact is important for valid JUCE names such as "numpad +" and "+".
    $normalized = [regex]::Replace(
        $normalized,
        '(?i)\b(ctrl|control|shift|alt|option)\s*\+\s*',
        '$1 + '
    )
    return $normalized.ToUpperInvariant()
}

function ConvertTo-MuteCueBeacnHotkeyGesture {
    param([AllowEmptyString()][string]$Key)

    $normalized = ConvertTo-MuteCueBeacnHotkeyKey -Key $Key
    if ([string]::IsNullOrWhiteSpace($normalized)) { return $null }

    # These bit values are shared with the bounded low-level listener in the
    # overlay. Extra modifiers intentionally prevent a match, just as JUCE does.
    $modifiers = 0
    $keyName = $normalized.Trim()
    $modifierCount = 0
    while ($true) {
        $prefix = [regex]::Match(
            $keyName,
            '^(?<Modifier>CTRL|CONTROL|SHIFT|ALT|OPTION)\s*\+\s*(?<Rest>.+)$',
            [Text.RegularExpressions.RegexOptions]::IgnoreCase -bor
                [Text.RegularExpressions.RegexOptions]::CultureInvariant
        )
        if (-not $prefix.Success) { break }
        $modifierCount++
        if ($modifierCount -gt 3) { return $null }
        $modifier = $prefix.Groups['Modifier'].Value.ToUpperInvariant()
        $flag = switch ($modifier) {
            { $_ -in @('CTRL', 'CONTROL') } { 2; break }
            'SHIFT' { 1; break }
            { $_ -in @('ALT', 'OPTION') } { 4; break }
            default { 0 }
        }
        if ($flag -eq 0 -or ($modifiers -band $flag) -ne 0) { return $null }
        $modifiers = $modifiers -bor $flag
        $keyName = $prefix.Groups['Rest'].Value.Trim()
    }

    if ([string]::IsNullOrWhiteSpace($keyName)) { return $null }
    $virtualKey = 0
    $functionMatch = [regex]::Match($keyName, '^F(?<Number>[1-9]|1[0-9]|2[0-4])$')
    if ($functionMatch.Success) {
        $virtualKey = 0x70 + [int]$functionMatch.Groups['Number'].Value - 1
    } elseif ($keyName.Length -eq 1 -and $keyName -match '^[A-Z0-9]$') {
        $virtualKey = [int][char]$keyName
    } else {
        $virtualKey = switch ($keyName) {
            { $_ -in @('SPACE', 'SPACEBAR') } { 0x20; break }
            { $_ -in @('RETURN', 'ENTER') } { 0x0D; break }
            { $_ -in @('ESC', 'ESCAPE') } { 0x1B; break }
            'TAB' { 0x09; break }
            'BACKSPACE' { 0x08; break }
            'DELETE' { 0x2E; break }
            'INSERT' { 0x2D; break }
            'HOME' { 0x24; break }
            'END' { 0x23; break }
            { $_ -in @('PAGE UP', 'PAGEUP') } { 0x21; break }
            { $_ -in @('PAGE DOWN', 'PAGEDOWN') } { 0x22; break }
            { $_ -in @('LEFT', 'CURSOR LEFT') } { 0x25; break }
            { $_ -in @('UP', 'CURSOR UP') } { 0x26; break }
            { $_ -in @('RIGHT', 'CURSOR RIGHT') } { 0x27; break }
            { $_ -in @('DOWN', 'CURSOR DOWN') } { 0x28; break }
            'NUMPAD 0' { 0x60; break }
            'NUMPAD 1' { 0x61; break }
            'NUMPAD 2' { 0x62; break }
            'NUMPAD 3' { 0x63; break }
            'NUMPAD 4' { 0x64; break }
            'NUMPAD 5' { 0x65; break }
            'NUMPAD 6' { 0x66; break }
            'NUMPAD 7' { 0x67; break }
            'NUMPAD 8' { 0x68; break }
            'NUMPAD 9' { 0x69; break }
            'NUMPAD *' { 0x6A; break }
            'NUMPAD +' { 0x6B; break }
            'NUMPAD SEPARATOR' { 0x6C; break }
            'NUMPAD -' { 0x6D; break }
            { $_ -in @('NUMPAD .', 'NUMPAD DELETE') } { 0x6E; break }
            'NUMPAD /' { 0x6F; break }
            'NUMPAD =' { 0x92; break }
            'PLAY' { 0xB3; break }
            'STOP' { 0xB2; break }
            'FAST FORWARD' { 0xB0; break }
            'REWIND' { 0xB1; break }
            { $_ -in @('PRINT SCREEN', 'PRINTSCREEN') } { 0x2C; break }
            'PAUSE' { 0x13; break }
            # Printable punctuation is keyboard-layout dependent. It is safer
            # to ignore it than to listen for the wrong physical key.
            default { 0 }
        }
    }

    if ($virtualKey -le 0 -or $virtualKey -gt 255) { return $null }
    return [pscustomobject]@{
        Key = $normalized
        VirtualKey = [int]$virtualKey
        Modifiers = [int]$modifiers
        GestureCode = [int](($modifiers -shl 16) -bor $virtualKey)
    }
}

function ConvertFrom-MuteCueBeacnKeyMappingsXml {
    param(
        [AllowEmptyString()][string]$XmlText,
        [switch]$Strict
    )

    if ([string]::IsNullOrWhiteSpace($XmlText)) {
        if ($Strict) { throw 'The BEACN hotkey mapping file is empty.' }
        return @()
    }

    $document = New-Object System.Xml.XmlDocument
    $document.XmlResolver = $null
    $settings = New-Object System.Xml.XmlReaderSettings
    $settings.DtdProcessing = [System.Xml.DtdProcessing]::Prohibit
    $settings.XmlResolver = $null
    $settings.MaxCharactersInDocument = 1048576
    $stringReader = $null
    $xmlReader = $null
    try {
        $stringReader = New-Object System.IO.StringReader($XmlText)
        $xmlReader = [System.Xml.XmlReader]::Create($stringReader, $settings)
        $document.Load($xmlReader)
    } catch {
        if ($Strict) { throw }
        return @()
    } finally {
        if ($null -ne $xmlReader) { $xmlReader.Dispose() }
        if ($null -ne $stringReader) { $stringReader.Dispose() }
    }

    if ($null -eq $document.DocumentElement -or
        -not [string]::Equals($document.DocumentElement.LocalName, 'KEYMAPPINGS', [StringComparison]::OrdinalIgnoreCase)) {
        if ($Strict) { throw 'The BEACN hotkey mapping root is invalid.' }
        return @()
    }

    $assignments = New-Object System.Collections.Generic.List[object]
    foreach ($node in @($document.DocumentElement.ChildNodes)) {
        if ($node.NodeType -ne [System.Xml.XmlNodeType]::Element -or
            -not [string]::Equals($node.LocalName, 'MAPPING', [StringComparison]::OrdinalIgnoreCase)) {
            continue
        }

        $key = ConvertTo-MuteCueBeacnHotkeyKey -Key ([string]$node.GetAttribute('key'))
        if ([string]::IsNullOrWhiteSpace($key)) { continue }

        $description = ([string]$node.GetAttribute('description')).Trim()
        $descriptionMatch = [regex]::Match(
            $description,
            '^Toggles\s+The\s+Knob\s+Press\s+Mute\s+For\s+(?<Name>.+?)\s*$',
            [System.Text.RegularExpressions.RegexOptions]::IgnoreCase -bor
                [System.Text.RegularExpressions.RegexOptions]::CultureInvariant
        )
        if (-not $descriptionMatch.Success) { continue }

        $name = $descriptionMatch.Groups['Name'].Value.Trim()
        if ([string]::IsNullOrWhiteSpace($name) -or $name.Length -gt 128 -or
            $name.IndexOfAny([char[]]@("`r", "`n", "`t", [char]0)) -ge 0) {
            continue
        }

        $commandId = 0L
        $hasCommandId = [long]::TryParse(
            [string]$node.GetAttribute('commandId'),
            [Globalization.NumberStyles]::Integer,
            [Globalization.CultureInfo]::InvariantCulture,
            [ref]$commandId
        )
        $assignments.Add([pscustomobject]@{
            Key = $key
            Name = $name
            Mode = 'All'
            CommandId = $(if ($hasCommandId) { $commandId } else { $null })
        })
    }

    return @($assignments.ToArray())
}

function Read-MuteCueBeacnHotkeyMappings {
    param(
        [string]$Path = $(Get-MuteCueBeacnKeyMappingsPath)
    )

    $result = [ordered]@{
        Success = $false
        Exists = $false
        Path = [string]$Path
        Assignments = @()
        ErrorMessage = ''
    }
    if ([string]::IsNullOrWhiteSpace($Path)) {
        $result.ErrorMessage = 'The BEACN hotkey mapping path is unavailable.'
        return [pscustomobject]$result
    }
    $stream = $null
    $reader = $null
    try {
        $stream = New-Object System.IO.FileStream(
            $Path,
            [IO.FileMode]::Open,
            [IO.FileAccess]::Read,
            ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete)
        )
        $result.Exists = $true
        if ($stream.Length -gt 1MB) { throw 'The BEACN hotkey mapping file is larger than 1 MB.' }
        $reader = New-Object System.IO.StreamReader($stream, [Text.Encoding]::UTF8, $true)
        $text = $reader.ReadToEnd()
        $result.Assignments = @(ConvertFrom-MuteCueBeacnKeyMappingsXml -XmlText $text -Strict)
        $result.Success = $true
    } catch [System.IO.FileNotFoundException] {
        $result.Success = $true
    } catch [System.IO.DirectoryNotFoundException] {
        $result.Success = $true
    } catch {
        $result.ErrorMessage = [string]$_.Exception.Message
    } finally {
        if ($null -ne $reader) { $reader.Dispose() }
        elseif ($null -ne $stream) { $stream.Dispose() }
    }
    return [pscustomobject]$result
}

function Import-MuteCueBeacnHotkeyMappings {
    param(
        [string]$Path = $(Get-MuteCueBeacnKeyMappingsPath)
    )

    $snapshot = Read-MuteCueBeacnHotkeyMappings -Path $Path
    if (-not [bool]$snapshot.Success) { return @() }
    return @($snapshot.Assignments)
}

function Resolve-MuteCueBeacnHotkeyTarget {
    param(
        [AllowNull()][object[]]$Assignments,
        [AllowEmptyString()][string]$Key
    )

    $normalizedKey = ConvertTo-MuteCueBeacnHotkeyKey -Key $Key
    if ([string]::IsNullOrWhiteSpace($normalizedKey)) { return $null }

    $uniqueTargets = @{}
    foreach ($assignment in @($Assignments)) {
        if ($null -eq $assignment) { continue }
        $assignmentKey = ConvertTo-MuteCueBeacnHotkeyKey -Key ([string]$assignment.Key)
        if (-not [string]::Equals($assignmentKey, $normalizedKey, [StringComparison]::OrdinalIgnoreCase)) {
            continue
        }

        $name = ([string]$assignment.Name).Trim()
        $mode = ([string]$assignment.Mode).Trim()
        if ([string]::IsNullOrWhiteSpace($name) -or $mode -notin @('All', 'Audience')) { continue }

        $identity = ('{0}{1}{2}' -f $name.ToUpperInvariant(), [char]0, $mode.ToUpperInvariant())
        if (-not $uniqueTargets.ContainsKey($identity)) {
            $uniqueTargets[$identity] = [pscustomobject]@{
                Key = $normalizedKey
                Name = $name
                Mode = $mode
            }
        }
    }

    if ($uniqueTargets.Count -ne 1) { return $null }
    return @($uniqueTargets.Values)[0]
}

function Resolve-MuteCueBeacnHotkeyFaderName {
    param(
        [AllowEmptyString()][string]$Name,
        [AllowNull()][string[]]$AvailableNames
    )

    $trimmed = ([string]$Name).Trim()
    if ([string]::IsNullOrWhiteSpace($trimmed)) { return $null }
    foreach ($available in @($AvailableNames)) {
        if ([string]::Equals(([string]$available).Trim(), $trimmed, [StringComparison]::OrdinalIgnoreCase)) {
            return ([string]$available).Trim()
        }
    }

    $canonical = $trimmed
    $linkMatch = [regex]::Match($trimmed, '^Link\s+In\s+(?<Number>[2-4])$', [Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if ($linkMatch.Success) {
        $canonical = 'Link {0} In' -f $linkMatch.Groups['Number'].Value
    }
    $auxMatch = [regex]::Match($canonical, '^Aux\s*(?<Number>[1-2])$', [Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if ($auxMatch.Success) {
        $canonical = 'Aux {0}' -f $auxMatch.Groups['Number'].Value
    }

    foreach ($available in @($AvailableNames)) {
        if ([string]::Equals(([string]$available).Trim(), $canonical, [StringComparison]::OrdinalIgnoreCase)) {
            return ([string]$available).Trim()
        }
    }
    return $canonical
}

function Get-MuteCueBeacnHotkeyBindings {
    param([AllowNull()][object[]]$Assignments)

    $candidates = New-Object System.Collections.Generic.List[object]
    foreach ($key in @($Assignments | ForEach-Object { [string]$_.Key } | Sort-Object -Unique)) {
        $target = Resolve-MuteCueBeacnHotkeyTarget -Assignments $Assignments -Key $key
        $gesture = ConvertTo-MuteCueBeacnHotkeyGesture -Key $key
        if ($null -eq $target -or $null -eq $gesture) { continue }
        $candidates.Add([pscustomobject]@{
            Key = [string]$gesture.Key
            VirtualKey = [int]$gesture.VirtualKey
            Modifiers = [int]$gesture.Modifiers
            GestureCode = [int]$gesture.GestureCode
            Name = Resolve-MuteCueBeacnHotkeyFaderName -Name ([string]$target.Name)
            Mode = [string]$target.Mode
        })
    }

    $bindings = New-Object System.Collections.Generic.List[object]
    foreach ($group in @($candidates.ToArray() | Group-Object GestureCode)) {
        $identities = @(
            $group.Group |
                ForEach-Object { '{0}|{1}' -f ([string]$_.Name).ToUpperInvariant(), ([string]$_.Mode).ToUpperInvariant() } |
                Sort-Object -Unique
        )
        if ($identities.Count -eq 1) { $bindings.Add($group.Group[0]) }
    }
    return @($bindings.ToArray())
}
