using System.Diagnostics;
using System.IO;

namespace MuteCue.Desktop;

internal static class RuntimeLauncher
{
    internal static bool TryStart(string[] args, out Process? runtime, out string error)
    {
        var runtimeDirectory = Path.Combine(AppContext.BaseDirectory, "Runtime");
        var overlayPath = Path.Combine(runtimeDirectory, "BeacnMuteOverlay.ps1");
        if (!File.Exists(overlayPath))
        {
            error = "Mute Cue could not find its bundled runtime. Reinstall Mute Cue.";
            runtime = null;
            return false;
        }

        var powerShellPath = Path.Combine(Environment.SystemDirectory, "WindowsPowerShell", "v1.0", "powershell.exe");
        if (!File.Exists(powerShellPath))
        {
            error = "Windows PowerShell is unavailable on this computer.";
            runtime = null;
            return false;
        }

        var command = $"-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File \"{overlayPath}\" -StartupLauncherPath \"{Environment.ProcessPath}\"";
        if (args.Contains("--startup", StringComparer.OrdinalIgnoreCase)) command += " -StartedAtLogin";

        try
        {
            runtime = Process.Start(new ProcessStartInfo(powerShellPath, command)
            {
                UseShellExecute = false,
                CreateNoWindow = true,
                WorkingDirectory = runtimeDirectory,
            });
            error = string.Empty;
            return runtime is not null;
        }
        catch (Exception exception)
        {
            runtime = null;
            error = $"Mute Cue could not start: {exception.Message}";
            return false;
        }
    }
}
