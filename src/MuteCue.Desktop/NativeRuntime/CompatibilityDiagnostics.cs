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
    bool DisableOverlay,
    bool EnableFastBeacnFallback = false,
    bool EnableBeacnTiming = false,
    bool EnableBeacnWinEvents = false,
    bool EnableBeacnOutputProbe = false,
    bool EnableBeacnEventRefresh = false)
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
            DisableOverlay: switches.Contains("--dev-no-overlay"),
            EnableFastBeacnFallback: switches.Contains("--dev-no-usb-capture") &&
                switches.Contains("--dev-fast-beacn-fallback"),
            EnableBeacnTiming: switches.Contains("--dev-no-usb-capture") &&
                switches.Contains("--dev-fast-beacn-fallback") &&
                switches.Contains("--dev-beacn-timing"),
            EnableBeacnWinEvents: switches.Contains("--dev-no-usb-capture") &&
                switches.Contains("--dev-fast-beacn-fallback") &&
                switches.Contains("--dev-beacn-timing") &&
                switches.Contains("--dev-beacn-win-events"),
            EnableBeacnOutputProbe: switches.Contains("--dev-no-usb-capture") &&
                switches.Contains("--dev-fast-beacn-fallback") &&
                switches.Contains("--dev-beacn-timing") &&
                switches.Contains("--dev-beacn-win-events") &&
                switches.Contains("--dev-beacn-output-probe"),
            EnableBeacnEventRefresh: switches.Contains("--dev-no-usb-capture") &&
                switches.Contains("--dev-fast-beacn-fallback") &&
                switches.Contains("--dev-beacn-timing") &&
                switches.Contains("--dev-beacn-win-events") &&
                switches.Contains("--dev-beacn-output-probe") &&
                switches.Contains("--dev-beacn-event-refresh"));
    }

    internal string StatusDescription
    {
        get
        {
            var disabled = new List<string>();
            if (DisableGlobalHooks) disabled.Add("global input hooks");
            if (DisableUsbCapture) disabled.Add("USB capture");
            if (DisableOverlay) disabled.Add("overlay rendering");
            if (EnableFastBeacnFallback) disabled.Add("USB-free BEACN fallback enabled");
            if (EnableBeacnTiming) disabled.Add("BEACN timing trace enabled");
            if (EnableBeacnWinEvents) disabled.Add("BEACN Windows-event diagnostic enabled");
            if (EnableBeacnOutputProbe) disabled.Add("BEACN output-edge feasibility probe enabled");
            if (EnableBeacnEventRefresh) disabled.Add("event-prioritized BEACN verification enabled");

            return disabled.Count == 0
                ? string.Empty
                : $"Dev compatibility test — disabled: {string.Join(", ", disabled)}.";
        }
    }
}
