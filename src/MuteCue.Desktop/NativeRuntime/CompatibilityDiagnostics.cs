using System;
using System.Collections.Generic;

namespace MuteCue.Desktop.NativeRuntime;

/// <summary>
/// Startup-only diagnostic switches for isolating conflicts with protected games.
/// Intentionally unavailable in Stable: production behavior is unchanged.
/// </summary>
internal readonly record struct CompatibilityDiagnostics(
    bool DisableGlobalHooks,
    bool DisableUsbCapture,
    bool DisableOverlay)
{
    internal static CompatibilityDiagnostics FromArguments(IEnumerable<string> arguments, bool isDevelopment)
    {
        if (!isDevelopment)
        {
            return default;
        }

        var switches = new HashSet<string>(arguments, StringComparer.OrdinalIgnoreCase);
        return new CompatibilityDiagnostics(
            DisableGlobalHooks: switches.Contains("--dev-no-global-hooks"),
            DisableUsbCapture: switches.Contains("--dev-no-usb-capture"),
            DisableOverlay: switches.Contains("--dev-no-overlay"));
    }

    internal string StatusDescription
    {
        get
        {
            var disabled = new List<string>();
            if (DisableGlobalHooks) disabled.Add("global input hooks");
            if (DisableUsbCapture) disabled.Add("USB capture");
            if (DisableOverlay) disabled.Add("overlay rendering");

            return disabled.Count == 0
                ? string.Empty
                : $"Dev compatibility test — disabled: {string.Join(", ", disabled)}.";
        }
    }
}
