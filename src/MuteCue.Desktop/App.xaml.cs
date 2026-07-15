using System;
using System.Diagnostics.CodeAnalysis;
using System.Threading;
using System.Windows;
using MuteCue.Desktop.NativeRuntime;
using MuteCue.Desktop.Services;

namespace MuteCue.Desktop;

[SuppressMessage("Design", "CA1001:Types that own disposable fields should be disposable", Justification = "WPF owns the application lifetime; the mutex is released and disposed in OnExit.")]
public partial class App : System.Windows.Application
{
    private Mutex? _instanceMutex;
    private bool _ownsInstance;
    private EventWaitHandle? _shutdownEvent;
    private RegisteredWaitHandle? _shutdownRegistration;
    private EventWaitHandle? _activationEvent;
    private RegisteredWaitHandle? _activationRegistration;
    private NativeMuteCueRuntime? _runtime;
    private bool _activationRequested;

    protected override void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);

        var shutdownRequested = e.Args.Contains("--shutdown-for-update", StringComparer.OrdinalIgnoreCase);
        _instanceMutex = new Mutex(initiallyOwned: true, AppChannel.InstanceName, out var ownsInstance);
        _ownsInstance = ownsInstance;
        if (!ownsInstance)
        {
            if (shutdownRequested)
            {
                SignalRunningInstanceToStop();
                WaitForRunningInstanceToStop();
                Shutdown(_ownsInstance ? 0 : 2);
                return;
            }

            SignalRunningInstanceToActivate();
            Shutdown();
            return;
        }

        if (shutdownRequested)
        {
            Shutdown();
            return;
        }

        ShutdownMode = ShutdownMode.OnExplicitShutdown;
        _shutdownEvent = new EventWaitHandle(false, EventResetMode.AutoReset, AppChannel.ShutdownEventName);
        _shutdownRegistration = ThreadPool.RegisterWaitForSingleObject(
            _shutdownEvent,
            (_, _) => Dispatcher.BeginInvoke(() => Shutdown()),
            null,
            Timeout.Infinite,
            executeOnlyOnce: true);
        _activationEvent = new EventWaitHandle(false, EventResetMode.AutoReset, AppChannel.ActivationEventName);
        _activationRegistration = ThreadPool.RegisterWaitForSingleObject(
            _activationEvent,
            (_, _) => Dispatcher.BeginInvoke(ActivateSettingsWindow),
            null,
            Timeout.Infinite,
            executeOnlyOnce: false);

        AppPaths.PrepareDataDirectory();
        var settings = NativeSettingsDocument.Load(AppPaths.SettingsPath);
        StartupRegistrationService.RepairExistingRegistration();
        _runtime = new NativeMuteCueRuntime(settings);
        _runtime.Start();

        var startInTray = e.Args.Contains("--startup", StringComparer.OrdinalIgnoreCase) && settings.GetBoolean("StartInSystemTray", false);
        var settingsWindow = new MainWindow(settings, _runtime, startInTray);
        MainWindow = settingsWindow;
        settingsWindow.Show();
        if (_activationRequested)
        {
            ActivateSettingsWindow();
        }
        if (e.Args.Contains("--preview-overlay", StringComparer.OrdinalIgnoreCase))
        {
            _runtime.PreviewOverlay(centerOnPrimaryScreen: true);
        }
    }

    protected override void OnExit(ExitEventArgs e)
    {
        _runtime?.Dispose();
        _activationRegistration?.Unregister(null);
        _activationEvent?.Dispose();
        _shutdownRegistration?.Unregister(null);
        _shutdownEvent?.Dispose();
        if (_ownsInstance)
        {
            try
            {
                _instanceMutex?.ReleaseMutex();
            }
            catch (ApplicationException)
            {
                // Shutdown must remain safe even if Windows already abandoned the named mutex.
            }
        }

        _instanceMutex?.Dispose();
        base.OnExit(e);
    }

    private static void SignalRunningInstanceToStop()
    {
        try
        {
            using var shutdownEvent = EventWaitHandle.OpenExisting(AppChannel.ShutdownEventName);
            shutdownEvent.Set();
        }
        catch (WaitHandleCannotBeOpenedException)
        {
            // The existing instance is still starting or is already closing.
        }
    }

    private static void SignalRunningInstanceToActivate()
    {
        try
        {
            using var activationEvent = EventWaitHandle.OpenExisting(AppChannel.ActivationEventName);
            activationEvent.Set();
        }
        catch (WaitHandleCannotBeOpenedException)
        {
            // The first instance is still starting or is already closing.
        }
    }

    private void ActivateSettingsWindow()
    {
        if (MainWindow is MuteCue.Desktop.MainWindow settingsWindow)
        {
            _activationRequested = false;
            settingsWindow.RestoreFromExternalLaunch();
            return;
        }

        _activationRequested = true;
    }

    private void WaitForRunningInstanceToStop()
    {
        try
        {
            _ownsInstance = _instanceMutex?.WaitOne(TimeSpan.FromSeconds(15)) == true;
        }
        catch (AbandonedMutexException)
        {
            // The previous process ended without releasing the mutex. This process
            // now owns it and can allow the build to proceed safely.
            _ownsInstance = true;
        }
    }
}
