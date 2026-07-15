using System;
using System.Diagnostics.CodeAnalysis;
using System.Threading;
using System.Windows;
using MuteCue.Desktop.Services;

namespace MuteCue.Desktop;

[SuppressMessage("Design", "CA1001:Types that own disposable fields should be disposable", Justification = "WPF owns the application lifetime; the mutex is released and disposed in OnExit.")]
public partial class App : System.Windows.Application
{
    private const string InstanceName = "MuteCue.Native.Preview.0.6";
    private Mutex? _instanceMutex;

    protected override void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);

        _instanceMutex = new Mutex(initiallyOwned: true, InstanceName, out var ownsInstance);
        if (!ownsInstance)
        {
            Shutdown();
            return;
        }

        ShutdownMode = ShutdownMode.OnExplicitShutdown;
        if (!RuntimeLauncher.TryStart(e.Args, out var runtime, out var error))
        {
            System.Windows.MessageBox.Show(error, "Mute Cue", MessageBoxButton.OK, MessageBoxImage.Error);
            Shutdown();
            return;
        }
        runtime!.EnableRaisingEvents = true;
        runtime.Exited += (_, _) => Dispatcher.Invoke(Shutdown);
    }

    protected override void OnExit(ExitEventArgs e)
    {
        _instanceMutex?.ReleaseMutex();
        _instanceMutex?.Dispose();
        base.OnExit(e);
    }
}
