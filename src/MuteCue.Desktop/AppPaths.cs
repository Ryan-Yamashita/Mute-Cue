using System;
using System.IO;

namespace MuteCue.Desktop;

public static class AppPaths
{
    public static string DataDirectory => Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "MuteCue");

    public static string SettingsPath => Path.Combine(DataDirectory, "settings.json");
}
