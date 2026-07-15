namespace MuteCue.Desktop;

/// <summary>
/// Compile-time product identity. A development binary remains isolated even
/// when it is copied outside the repository or launched without special flags.
/// </summary>
public static class AppChannel
{
#if MUTECUE_DEVELOPMENT
    public static bool IsDevelopment => true;
    public const string ProductName = "Mute Cue Dev";
    public const string ExecutableName = "MuteCue-Dev.exe";
    public const string DataDirectoryName = "MuteCue-Dev";
    public const string InstanceName = "Local\\MuteCue.Dev.NativeRuntime.0.6";
    public const string ShutdownEventName = "Local\\MuteCue.Dev.ShutdownForUpdate.0.6";
    public static bool SupportsStartupRegistration => false;
#else
    public static bool IsDevelopment => false;
    public const string ProductName = "Mute Cue";
    public const string ExecutableName = "MuteCue.exe";
    public const string DataDirectoryName = "MuteCue";
    public const string InstanceName = "Local\\MuteCue.NativeRuntime.0.6";
    public const string ShutdownEventName = "Local\\MuteCue.ShutdownForUpdate.0.6";
    public static bool SupportsStartupRegistration => true;
#endif
}
