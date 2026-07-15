namespace MuteCue.Desktop.Services;

internal static class WindowCloseBehavior
{
    internal static bool ShouldHideToTray(bool closeToSystemTray, bool explicitExitRequested) =>
        closeToSystemTray && !explicitExitRequested;
}
