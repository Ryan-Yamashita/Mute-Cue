using System.Collections.Concurrent;
using System.Globalization;
using System.IO;
using System.Text;
using System.Threading;

namespace MuteCue.Desktop.NativeRuntime;

/// <summary>
/// Opt-in, local-only diagnostics for the Dev USB-free BEACN experiment.
/// Does not capture USB data, microphone audio, game information or Discord credentials.
/// </summary>
internal static class BeacnTimingTrace
{
    private const int MaximumQueuedLines = 512;
    private const long MaximumFileBytes = 256 * 1024;
    private static readonly ConcurrentQueue<string> Queue = new();
    private static int _queuedLines;
    private static bool _enabled;
    private static string? _filePath;

    internal static bool Enabled => _enabled;

    internal static string? FilePath => Enabled ? _filePath : null;

    internal static void Start(bool requested)
    {
        _enabled = false;
        _filePath = null;
        while (Queue.TryDequeue(out _)) { }
        Interlocked.Exchange(ref _queuedLines, 0);
        if (!requested || !AppChannel.IsDevelopment)
        {
            return;
        }

        try
        {
            var directory = Path.Combine(AppPaths.DataDirectory, "Diagnostics");
            Directory.CreateDirectory(directory);
            _filePath = Path.Combine(directory, "beacn-timing.csv");
            File.WriteAllText(_filePath, "utc,event,fader,detail" + Environment.NewLine, Encoding.UTF8);
            _enabled = true;
            Record("session-start", "", "USB-free BEACN diagnostic; no hardware capture");
        }
        catch (IOException)
        {
            _enabled = false;
            _filePath = null;
        }
        catch (UnauthorizedAccessException)
        {
            _enabled = false;
            _filePath = null;
        }
    }

    internal static void Record(string eventName, string fader, string detail)
    {
        if (!Enabled)
        {
            return;
        }

        if (Interlocked.Increment(ref _queuedLines) > MaximumQueuedLines)
        {
            Interlocked.Decrement(ref _queuedLines);
            return;
        }

        var line = string.Join(",",
            Csv(DateTimeOffset.UtcNow.ToString("O", CultureInfo.InvariantCulture)),
            Csv(eventName),
            Csv(fader),
            Csv(detail));
        Queue.Enqueue(line);
    }

    internal static void Flush()
    {
        if (!Enabled || _filePath is null)
        {
            return;
        }

        try
        {
            if (new FileInfo(_filePath).Length >= MaximumFileBytes)
            {
                return;
            }

            var lines = new StringBuilder();
            for (var i = 0; i < 128 && Queue.TryDequeue(out var line); i++)
            {
                Interlocked.Decrement(ref _queuedLines);
                lines.AppendLine(line);
            }

            if (lines.Length > 0)
            {
                File.AppendAllText(_filePath, lines.ToString(), Encoding.UTF8);
            }
        }
        catch (IOException)
        {
            // Diagnostics must never interrupt the normal mute indicator.
            _enabled = false;
        }
        catch (UnauthorizedAccessException)
        {
            _enabled = false;
        }
    }

    private static string Csv(string value)
    {
        // Protect line-oriented output from custom BEACN fader names.
        var cleaned = value.Replace("\r", " ", StringComparison.Ordinal)
            .Replace("\n", " ", StringComparison.Ordinal)
            .Replace('"', ' ');
        return "\"" + cleaned + "\"";
    }
}
