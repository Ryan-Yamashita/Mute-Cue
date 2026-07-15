using System;
using System.IO;
using System.Linq;
using MuteCue.Desktop.Services;

var directory = Path.Combine(Path.GetTempPath(), "MuteCue.Native.Tests", Guid.NewGuid().ToString("N"));
var settingsPath = Path.Combine(directory, "settings.json");
Directory.CreateDirectory(directory);

try
{
    await File.WriteAllTextAsync(settingsPath, """
    {
      "SchemaVersion": 5,
      "Size": 500,
      "Opacity": 0.6,
      "BeacnFaderNames": "Mic, System, Mic",
      "FutureSetting": "must-survive"
    }
    """);

    var settings = NativeSettingsDocument.Load(settingsPath);
    Assert(settings.GetInteger("Size", 420, 220, 900) == 500, "The native settings layer must read existing sizes.");
    Assert(Math.Abs(settings.GetDouble("Opacity", 0.88, 0.25, 1.0) - 0.6) < 0.001, "The native settings layer must read existing opacity.");
    var faders = FaderSourceParser.Parse(settings.GetString("BeacnFaderNames", ""));
    Assert(faders.Count == 2 && faders[0] == "Mic" && faders[1] == "System", "Fader names must be trimmed and deduplicated.");

    settings.SetBoolean("StartInSystemTray", true);
    settings.SetString("BeacnAllFaderNames", "Mic,System");
    settings.Save();
    var written = await File.ReadAllTextAsync(settingsPath);
    Assert(written.Contains("must-survive", StringComparison.Ordinal), "Unknown settings must survive native writes.");
    Assert(NativeSettingsDocument.Load(settingsPath).GetBoolean("StartInSystemTray", false), "Saved settings must round-trip.");
    Assert(FaderSourceParser.Merge("Mic,System", "System,Chat").SequenceEqual(["Mic", "System", "Chat"]), "Merged fader sources must preserve display order without duplicates.");

    settings.SetString("BeacnAllFaderKeys", "profile:0,profile:1");
    settings.SetString("BeacnAudienceFaderKeys", "profile:0,profile:1");
    FaderSelectionSettings.Apply(settings, [], []);
    Assert(settings.GetString("BeacnAllFaderNames", "missing") == string.Empty, "Clearing All selections must persist an explicit empty list.");
    Assert(settings.GetString("BeacnAudienceFaderNames", "missing") == string.Empty, "Clearing Audience selections must persist an explicit empty list.");
    Assert(settings.GetString("BeacnAllFaderKeys", "missing") == string.Empty, "Native name selections must clear stale All stable keys.");
    Assert(settings.GetString("BeacnAudienceFaderKeys", "missing") == string.Empty, "Native name selections must clear stale Audience stable keys.");
    Assert(settings.GetInteger("BeacnFaderSelectionFormat", 0, 0, 3) == 2, "Native name selections must make names authoritative.");
    Console.WriteLine("Native settings compatibility tests: PASS");
}
finally
{
    if (Directory.Exists(directory))
    {
        Directory.Delete(directory, recursive: true);
    }
}

static void Assert(bool condition, string message)
{
    if (!condition)
    {
        throw new InvalidOperationException(message);
    }
}
