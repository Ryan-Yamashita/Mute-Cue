using System;
using System.IO;
using System.Security;
using System.Threading;
using Microsoft.Win32;

namespace MuteCue.Desktop.Services;

internal static class LegacyInstallMigration
{
    private const string LegacyUninstallKey = @"Software\Microsoft\Windows\CurrentVersion\Uninstall\{5A0EE8CF-044B-4E7C-8E76-EF10C5D0E94B}_is1";

    internal static void CleanupPerUserInstallation()
    {
        var legacyRoot = Path.GetFullPath(Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "Programs",
            "MuteCue"));
        var currentRoot = Path.GetFullPath(AppContext.BaseDirectory);
        if (!IsInstalledStableRoot(currentRoot, legacyRoot))
        {
            return;
        }

        for (var attempt = 0; attempt < 20 && Directory.Exists(legacyRoot); attempt++)
        {
            try
            {
                Directory.Delete(legacyRoot, recursive: true);
            }
            catch (Exception exception) when (exception is IOException or UnauthorizedAccessException or SecurityException)
            {
                // The previous process may have released its mutex before Windows
                // finished releasing the executable image or antivirus scan.
            }

            if (Directory.Exists(legacyRoot))
            {
                Thread.Sleep(250);
            }
        }

        try
        {
            Registry.CurrentUser.DeleteSubKeyTree(LegacyUninstallKey, throwOnMissingSubKey: false);
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException or SecurityException)
        {
            // A stale uninstall entry is harmless and can be retried on the next launch.
        }
    }

    internal static bool IsInstalledStableRoot(string currentRoot, string legacyRoot)
    {
        if (AppChannel.IsDevelopment ||
            string.Equals(
                Path.TrimEndingDirectorySeparator(Path.GetFullPath(currentRoot)),
                Path.TrimEndingDirectorySeparator(Path.GetFullPath(legacyRoot)),
                StringComparison.OrdinalIgnoreCase))
        {
            return false;
        }

        return File.Exists(Path.Combine(currentRoot, "unins000.exe")) &&
            File.Exists(Path.Combine(currentRoot, "MuteCue.DiscordPublicClient.json"));
    }
}
