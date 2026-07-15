using System;
using System.IO;

namespace MuteCue.Desktop.Services;

public static class StartupRegistrationService
{
    private const string ShortcutName = "Mute Cue.lnk";

    private static string ShortcutPath => Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Startup), ShortcutName);

    public static bool IsSupported => AppChannel.SupportsStartupRegistration;

    public static bool IsRegistered() => IsSupported && File.Exists(ShortcutPath);

    public static void RepairExistingRegistration()
    {
        if (!IsRegistered())
        {
            return;
        }

        try
        {
            SetRegistered(enabled: true);
        }
        catch
        {
            // A stale shortcut must never prevent the application from opening.
        }
    }

    public static void SetRegistered(bool enabled)
    {
        if (!IsSupported)
        {
            if (enabled)
            {
                throw new InvalidOperationException("Development builds cannot register themselves to run on startup.");
            }

            return;
        }

        if (!enabled)
        {
            if (File.Exists(ShortcutPath))
            {
                File.Delete(ShortcutPath);
            }

            return;
        }

        var executablePath = Environment.ProcessPath ?? throw new InvalidOperationException("Could not determine the native executable path.");
        var shellType = Type.GetTypeFromProgID("WScript.Shell") ?? throw new InvalidOperationException("Windows Script Host is unavailable.");
        dynamic shell = Activator.CreateInstance(shellType) ?? throw new InvalidOperationException("Could not create the Windows shortcut service.");
        dynamic shortcut = shell.CreateShortcut(ShortcutPath);
        shortcut.TargetPath = executablePath;
        shortcut.Arguments = "--startup";
        shortcut.WorkingDirectory = Path.GetDirectoryName(executablePath) ?? AppContext.BaseDirectory;
        shortcut.Description = "Start Mute Cue";
        shortcut.Save();
    }
}
