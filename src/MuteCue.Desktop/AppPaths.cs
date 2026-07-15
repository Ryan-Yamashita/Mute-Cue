using System;
using System.IO;

namespace MuteCue.Desktop;

public static class AppPaths
{
    private const long MaximumSeedSettingsLength = 1024 * 1024;

    private static string LocalDataRoot => Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);

    public static string DataDirectory => Path.Combine(LocalDataRoot, AppChannel.DataDirectoryName);

    public static string StableDataDirectory => Path.Combine(LocalDataRoot, "MuteCue");

    public static string SettingsPath => Path.Combine(DataDirectory, "Settings", "settings.json");

    public static string DiscordAuthorizationPath => Path.Combine(DataDirectory, "Credentials", "discord-authorization.dat");

    public static string StableDiscordAuthorizationPath => Path.Combine(StableDataDirectory, "Credentials", "discord-authorization.dat");

    public static void PrepareDataDirectory()
    {
        if (!AppChannel.IsDevelopment)
        {
            return;
        }

        var stableSettingsPath = Path.Combine(StableDataDirectory, "Settings", "settings.json");
        TrySeedDevelopmentSettings(stableSettingsPath, SettingsPath);
        TrySeedDevelopmentFile(StableDiscordAuthorizationPath, DiscordAuthorizationPath);
    }

    internal static bool TrySeedDevelopmentSettings(string stableSettingsPath, string developmentSettingsPath)
        => TrySeedDevelopmentFile(stableSettingsPath, developmentSettingsPath);

    internal static bool TrySeedDevelopmentFile(string stablePath, string developmentPath)
    {
        if (File.Exists(developmentPath) || !File.Exists(stablePath))
        {
            return false;
        }

        var source = new FileInfo(stablePath);
        if (source.Length is <= 0 or > MaximumSeedSettingsLength)
        {
            return false;
        }

        var destinationDirectory = Path.GetDirectoryName(developmentPath)
            ?? throw new InvalidOperationException("The development data path must have a directory.");
        Directory.CreateDirectory(destinationDirectory);
        var temporaryPath = Path.Combine(destinationDirectory, $".{Path.GetFileName(developmentPath)}.{Guid.NewGuid():N}.tmp");
        try
        {
            File.Copy(stablePath, temporaryPath, overwrite: false);
            File.Move(temporaryPath, developmentPath, overwrite: false);
            return true;
        }
        catch (IOException)
        {
            // Another development instance may have won the first-run race.
            return false;
        }
        finally
        {
            if (File.Exists(temporaryPath))
            {
                File.Delete(temporaryPath);
            }
        }
    }
}
