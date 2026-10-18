using System;
using System.Diagnostics;
using System.Runtime.InteropServices;

namespace MuteCue.Desktop.NativeRuntime;

/// <summary>
/// Read-only, opt-in Dev diagnostic for Windows accessibility change notifications
/// originating from the BEACN app only. Does not inject code, open USB devices,
/// inspect game processes, or alter mute state.
/// </summary>
internal sealed class BeacnWinEventProbe : IDisposable
{
    private const uint EventObjectReorder = 0x8004;
    private const uint EventObjectStateChange = 0x800A;
    private const uint EventObjectNameChange = 0x800C;
    private const uint EventObjectDescriptionChange = 0x800D;
    private const uint EventObjectValueChange = 0x800E;
    private const uint EventObjectInvoked = 0x8013;
    private const uint WinEventOutOfContext = 0;
    private const uint WinEventSkipOwnProcess = 2;

    private delegate void WinEventCallback(
        IntPtr hook,
        uint eventType,
        IntPtr window,
        int objectId,
        int childId,
        uint eventThread,
        uint eventTime);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern IntPtr SetWinEventHook(
        uint eventMin,
        uint eventMax,
        IntPtr module,
        WinEventCallback callback,
        uint processId,
        uint threadId,
        uint flags);

    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool UnhookWinEvent(IntPtr hook);

    private readonly WinEventCallback _callback;
    private IntPtr _hook;
    private int _processId;
    private DateTime _lastAttemptUtc = DateTime.MinValue;
    private DateTime _lastProcessCheckUtc = DateTime.MinValue;
    private bool _disposed;

    internal BeacnWinEventProbe()
    {
        // Retaining this delegate for the lifetime of the native hook is required.
        _callback = OnWinEvent;
    }

    internal bool EnsureStarted()
    {
        if (_disposed || !AppChannel.IsDevelopment || !BeacnTimingTrace.Enabled)
        {
            return false;
        }

        if (_hook != IntPtr.Zero)
        {
            // Avoid querying OS process handles on the fast overlay timer.
            if ((DateTime.UtcNow - _lastProcessCheckUtc).TotalSeconds < 5)
            {
                return true;
            }

            _lastProcessCheckUtc = DateTime.UtcNow;
            if (IsBeacnProcessRunning(_processId))
            {
                return true;
            }
        }

        Stop();
        if ((DateTime.UtcNow - _lastAttemptUtc).TotalSeconds < 5)
        {
            return false;
        }

        _lastAttemptUtc = DateTime.UtcNow;
        var processes = Process.GetProcessesByName("BEACN");
        try
        {
            foreach (var process in processes)
            {
                if (process.HasExited)
                {
                    continue;
                }

                // Process ID is required, so this never listens to all desktop
                // processes. The callback remains in Mute Cue, not in BEACN.
                var handle = SetWinEventHook(
                    EventObjectReorder,
                    EventObjectInvoked,
                    IntPtr.Zero,
                    _callback,
                    checked((uint)process.Id),
                    0,
                    WinEventOutOfContext | WinEventSkipOwnProcess);

                if (handle != IntPtr.Zero)
                {
                    _hook = handle;
                    _processId = process.Id;
                    _lastProcessCheckUtc = DateTime.UtcNow;
                    BeacnTimingTrace.Record("win-hook", "", "BEACN process-scoped listener started");
                    return true;
                }
            }
        }
        catch (System.ComponentModel.Win32Exception)
        {
            // Diagnostics fail softly and never affect mute-state monitoring.
        }
        catch (InvalidOperationException)
        {
            // BEACN can exit during process discovery.
        }
        finally
        {
            foreach (var process in processes)
            {
                process.Dispose();
            }
        }

        BeacnTimingTrace.Record("win-hook", "", "No accessible BEACN event source yet");
        return false;
    }

    private static bool IsBeacnProcessRunning(int processId)
    {
        if (processId <= 0)
        {
            return false;
        }

        try
        {
            using var process = Process.GetProcessById(processId);
            return !process.HasExited &&
                string.Equals(process.ProcessName, "BEACN", StringComparison.OrdinalIgnoreCase);
        }
        catch (ArgumentException)
        {
            return false;
        }
        catch (InvalidOperationException)
        {
            return false;
        }
    }

    internal static string? EventLabel(uint eventType) => eventType switch
    {
        EventObjectReorder => "reorder",
        EventObjectStateChange => "state",
        EventObjectNameChange => "name",
        EventObjectDescriptionChange => "description",
        EventObjectValueChange => "value",
        EventObjectInvoked => "invoke",
        _ => null,
    };

    private void OnWinEvent(
        IntPtr hook,
        uint eventType,
        IntPtr window,
        int objectId,
        int childId,
        uint eventThread,
        uint eventTime)
    {
        // Never call into BEACN, the game, UI Automation, or a driver here.
        // Only record the small event type + accessibility object identifiers.
        var label = EventLabel(eventType);
        if (!_disposed && label is not null)
        {
            BeacnTimingTrace.Record("win-event", "", $"{label};object={objectId};child={childId}");
        }
    }

    private void Stop()
    {
        if (_hook != IntPtr.Zero)
        {
            _ = UnhookWinEvent(_hook);
            _hook = IntPtr.Zero;
        }

        _processId = 0;
    }

    public void Dispose()
    {
        if (_disposed)
        {
            return;
        }

        _disposed = true;
        Stop();
    }
}
