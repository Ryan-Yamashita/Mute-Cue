using System.Globalization;
using System.IO;
using System.Text;
using System.Text.RegularExpressions;
using System.Xml;

namespace MuteCue.Desktop.NativeRuntime;

internal sealed record BeacnHotkeyBinding(int GestureCode, string Name, string Mode);

internal static partial class BeacnHotkeyMappings
{
    private const long MaximumFileSize = 1024 * 1024;

    internal static string DefaultPath => Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.MyDocuments),
        "BEACN",
        "keyMappings",
        "keyMappings.xml");

    internal static IReadOnlyList<BeacnHotkeyBinding> Load(string path, IEnumerable<string>? availableNames = null)
    {
        if (string.IsNullOrWhiteSpace(path) || !File.Exists(path))
        {
            return [];
        }

        try
        {
            using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
            if (stream.Length > MaximumFileSize)
            {
                return [];
            }

            using var reader = new StreamReader(stream, Encoding.UTF8, detectEncodingFromByteOrderMarks: true);
            return Parse(reader.ReadToEnd(), availableNames);
        }
        catch (IOException)
        {
            return [];
        }
        catch (UnauthorizedAccessException)
        {
            return [];
        }
        catch (XmlException)
        {
            return [];
        }
    }

    internal static IReadOnlyList<BeacnHotkeyBinding> Parse(string xml, IEnumerable<string>? availableNames = null)
    {
        if (string.IsNullOrWhiteSpace(xml))
        {
            return [];
        }

        var settings = new XmlReaderSettings
        {
            DtdProcessing = DtdProcessing.Prohibit,
            XmlResolver = null,
            MaxCharactersInDocument = MaximumFileSize,
        };
        var document = new XmlDocument { XmlResolver = null };
        using (var textReader = new StringReader(xml))
        using (var xmlReader = XmlReader.Create(textReader, settings))
        {
            document.Load(xmlReader);
        }

        var root = document.DocumentElement;
        if (root is null || !string.Equals(root.LocalName, "KEYMAPPINGS", StringComparison.OrdinalIgnoreCase))
        {
            return [];
        }

        var names = availableNames?.Where(name => !string.IsNullOrWhiteSpace(name)).ToArray() ?? [];
        var candidates = new List<BeacnHotkeyBinding>();
        foreach (XmlNode child in root.ChildNodes)
        {
            if (child is not XmlElement element || !string.Equals(element.LocalName, "MAPPING", StringComparison.OrdinalIgnoreCase))
            {
                continue;
            }

            var match = ToggleDescriptionRegex().Match(element.GetAttribute("description").Trim());
            if (!match.Success || !TryConvertGesture(element.GetAttribute("key"), out var gestureCode))
            {
                continue;
            }

            var name = match.Groups["Name"].Value.Trim();
            if (name.Length is 0 or > 128 || name.IndexOfAny(['\r', '\n', '\t', '\0']) >= 0)
            {
                continue;
            }

            candidates.Add(new BeacnHotkeyBinding(gestureCode, ResolveFaderName(name, names), "All"));
        }

        return candidates
            .GroupBy(binding => binding.GestureCode)
            .Where(group => group.Select(binding => $"{binding.Name}\0{binding.Mode}").Distinct(StringComparer.OrdinalIgnoreCase).Count() == 1)
            .Select(group => group.First())
            .OrderBy(binding => binding.GestureCode)
            .ToArray();
    }

    internal static bool TryConvertGesture(string key, out int gestureCode)
    {
        gestureCode = 0;
        if (string.IsNullOrWhiteSpace(key))
        {
            return false;
        }

        var normalized = WhitespaceRegex().Replace(key.Trim(), " ").ToUpperInvariant();
        if (normalized.Length > 64 || normalized is "NONE" or "UNASSIGNED" or "NOT SET")
        {
            return false;
        }

        var modifiers = 0;
        var keyName = normalized;
        for (var count = 0; count < 3; count++)
        {
            var modifier = ModifierRegex().Match(keyName);
            if (!modifier.Success)
            {
                break;
            }

            var flag = modifier.Groups["Modifier"].Value switch
            {
                "CTRL" or "CONTROL" => 2,
                "SHIFT" => 1,
                "ALT" or "OPTION" => 4,
                _ => 0,
            };
            if (flag == 0 || (modifiers & flag) != 0)
            {
                return false;
            }

            modifiers |= flag;
            keyName = modifier.Groups["Rest"].Value.Trim();
        }

        int virtualKey;
        var function = FunctionKeyRegex().Match(keyName);
        if (function.Success)
        {
            virtualKey = 0x70 + int.Parse(function.Groups["Number"].Value, CultureInfo.InvariantCulture) - 1;
        }
        else if (keyName.Length == 1 && ((keyName[0] >= 'A' && keyName[0] <= 'Z') || char.IsAsciiDigit(keyName[0])))
        {
            virtualKey = keyName[0];
        }
        else
        {
            virtualKey = keyName switch
            {
                "SPACE" or "SPACEBAR" => 0x20,
                "RETURN" or "ENTER" => 0x0D,
                "ESC" or "ESCAPE" => 0x1B,
                "TAB" => 0x09,
                "BACKSPACE" => 0x08,
                "DELETE" => 0x2E,
                "INSERT" => 0x2D,
                "HOME" => 0x24,
                "END" => 0x23,
                "PAGE UP" or "PAGEUP" => 0x21,
                "PAGE DOWN" or "PAGEDOWN" => 0x22,
                "LEFT" or "CURSOR LEFT" => 0x25,
                "UP" or "CURSOR UP" => 0x26,
                "RIGHT" or "CURSOR RIGHT" => 0x27,
                "DOWN" or "CURSOR DOWN" => 0x28,
                "NUMPAD 0" => 0x60,
                "NUMPAD 1" => 0x61,
                "NUMPAD 2" => 0x62,
                "NUMPAD 3" => 0x63,
                "NUMPAD 4" => 0x64,
                "NUMPAD 5" => 0x65,
                "NUMPAD 6" => 0x66,
                "NUMPAD 7" => 0x67,
                "NUMPAD 8" => 0x68,
                "NUMPAD 9" => 0x69,
                "NUMPAD *" => 0x6A,
                "NUMPAD +" => 0x6B,
                "NUMPAD SEPARATOR" => 0x6C,
                "NUMPAD -" => 0x6D,
                "NUMPAD ." or "NUMPAD DELETE" => 0x6E,
                "NUMPAD /" => 0x6F,
                "NUMPAD =" => 0x92,
                "PLAY" => 0xB3,
                "STOP" => 0xB2,
                "FAST FORWARD" => 0xB0,
                "REWIND" => 0xB1,
                "PRINT SCREEN" or "PRINTSCREEN" => 0x2C,
                "PAUSE" => 0x13,
                _ => 0,
            };
        }

        if (virtualKey is <= 0 or > 255)
        {
            return false;
        }

        gestureCode = (modifiers << 16) | virtualKey;
        return true;
    }

    private static string ResolveFaderName(string requested, IEnumerable<string> availableNames)
    {
        var exact = availableNames.FirstOrDefault(name => string.Equals(name.Trim(), requested, StringComparison.OrdinalIgnoreCase));
        if (exact is not null)
        {
            return exact.Trim();
        }

        var canonical = LinkInRegex().Replace(requested, match => $"Link {match.Groups["Number"].Value} In");
        canonical = AuxRegex().Replace(canonical, match => $"Aux {match.Groups["Number"].Value}");
        return availableNames.FirstOrDefault(name => string.Equals(name.Trim(), canonical, StringComparison.OrdinalIgnoreCase))?.Trim() ?? canonical;
    }

    [GeneratedRegex("^Toggles\\s+The\\s+Knob\\s+Press\\s+Mute\\s+For\\s+(?<Name>.+?)\\s*$", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant)]
    private static partial Regex ToggleDescriptionRegex();

    [GeneratedRegex("\\s+")]
    private static partial Regex WhitespaceRegex();

    [GeneratedRegex("^(?<Modifier>CTRL|CONTROL|SHIFT|ALT|OPTION)\\s*\\+\\s*(?<Rest>.+)$", RegexOptions.CultureInvariant)]
    private static partial Regex ModifierRegex();

    [GeneratedRegex("^F(?<Number>[1-9]|1[0-9]|2[0-4])$", RegexOptions.CultureInvariant)]
    private static partial Regex FunctionKeyRegex();

    [GeneratedRegex("^Link\\s+In\\s+(?<Number>[2-4])$", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant)]
    private static partial Regex LinkInRegex();

    [GeneratedRegex("^Aux\\s*(?<Number>[1-2])$", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant)]
    private static partial Regex AuxRegex();
}
