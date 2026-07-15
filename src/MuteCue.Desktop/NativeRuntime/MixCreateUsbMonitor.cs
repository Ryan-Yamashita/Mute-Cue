#pragma warning disable
using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Threading;
using System.Threading.Tasks;
using Microsoft.Win32.SafeHandles;

namespace BeacnMuteOverlay {
    public sealed class UsbPacket {
        public ushort DeviceAddress { get; private set; }
        public byte Endpoint { get; private set; }
        public byte[] Data { get; private set; }
        public DateTime CapturedAtUtc { get; private set; }

        public UsbPacket(ushort deviceAddress, byte endpoint, byte[] data) {
            DeviceAddress = deviceAddress;
            Endpoint = endpoint;
            Data = data;
            CapturedAtUtc = DateTime.UtcNow;
        }

        public UsbPacket(ushort deviceAddress, byte endpoint, byte[] data, DateTime capturedAtUtc) {
            DeviceAddress = deviceAddress;
            Endpoint = endpoint;
            Data = data;
            CapturedAtUtc = capturedAtUtc.Kind == DateTimeKind.Utc
                ? capturedAtUtc
                : capturedAtUtc.ToUniversalTime();
        }
    }

    public sealed class MixCreateUsbRoute {
        public string CaptureDevice { get; private set; }
        public int DeviceAddress { get; private set; }

        public MixCreateUsbRoute(string captureDevice, int deviceAddress) {
            CaptureDevice = captureDevice;
            DeviceAddress = deviceAddress;
        }
    }

    public sealed class MixCreateUsbMonitor : IDisposable {
        private const int MaximumQueuedPackets = 4096;
        private const uint JobObjectLimitKillOnJobClose = 0x00002000;
        private const int JobObjectExtendedLimitInformationClass = 9;
        private readonly ConcurrentQueue<UsbPacket> packets = new ConcurrentQueue<UsbPacket>();
        private Process process;
        private Thread readerThread;
        private volatile bool stopping;
        private bool captureAllPackets;
        private bool captureRootHub;
        private ushort targetUsbAddress;
        private int queuedPacketCount;
        private long droppedPacketCount;
        private IntPtr jobHandle = IntPtr.Zero;
        private string lastError = String.Empty;

        [StructLayout(LayoutKind.Sequential)]
        private struct JobObjectBasicLimitInformation {
            public long PerProcessUserTimeLimit;
            public long PerJobUserTimeLimit;
            public uint LimitFlags;
            public UIntPtr MinimumWorkingSetSize;
            public UIntPtr MaximumWorkingSetSize;
            public uint ActiveProcessLimit;
            public UIntPtr Affinity;
            public uint PriorityClass;
            public uint SchedulingClass;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct IoCounters {
            public ulong ReadOperationCount;
            public ulong WriteOperationCount;
            public ulong OtherOperationCount;
            public ulong ReadTransferCount;
            public ulong WriteTransferCount;
            public ulong OtherTransferCount;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct JobObjectExtendedLimitInformation {
            public JobObjectBasicLimitInformation BasicLimitInformation;
            public IoCounters IoInfo;
            public UIntPtr ProcessMemoryLimit;
            public UIntPtr JobMemoryLimit;
            public UIntPtr PeakProcessMemoryUsed;
            public UIntPtr PeakJobMemoryUsed;
        }

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern SafeFileHandle CreateFile(
            string fileName,
            uint desiredAccess,
            uint shareMode,
            IntPtr securityAttributes,
            uint creationDisposition,
            uint flagsAndAttributes,
            IntPtr templateFile
        );

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern IntPtr CreateJobObject(IntPtr securityAttributes, string name);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool SetInformationJobObject(
            IntPtr job,
            int informationClass,
            ref JobObjectExtendedLimitInformation information,
            uint informationLength
        );

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool AssignProcessToJobObject(IntPtr job, IntPtr processHandle);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool CloseHandle(IntPtr handle);

        private void OwnChildProcess(Process child) {
            IntPtr candidate = CreateJobObject(IntPtr.Zero, null);
            if (candidate == IntPtr.Zero) return;
            try {
                JobObjectExtendedLimitInformation information = new JobObjectExtendedLimitInformation();
                information.BasicLimitInformation.LimitFlags = JobObjectLimitKillOnJobClose;
                if (!SetInformationJobObject(
                    candidate,
                    JobObjectExtendedLimitInformationClass,
                    ref information,
                    (uint)Marshal.SizeOf(typeof(JobObjectExtendedLimitInformation))
                )) return;
                if (!AssignProcessToJobObject(candidate, child.Handle)) return;
                jobHandle = candidate;
                candidate = IntPtr.Zero;
            } finally {
                if (candidate != IntPtr.Zero) CloseHandle(candidate);
            }
        }

        private static string[] GetCaptureDevices() {
            List<string> devices = new List<string>();
            for (int index = 1; index <= 32; index++) {
                string path = "\\\\.\\USBPcap" + index;
                using (SafeFileHandle handle = CreateFile(path, 0, 3, IntPtr.Zero, 3, 0, IntPtr.Zero)) {
                    if (!handle.IsInvalid) devices.Add(path);
                }
            }
            return devices.ToArray();
        }

        private static bool IsMixCreateStatusPacket(UsbPacket packet) {
            byte[] data = packet.Data;
            return packet.Endpoint == 0x83 && data != null && data.Length >= 10 &&
                data[0] == 0x00 && data[1] == 0x00 &&
                data[2] == 0x00 && data[3] == 0x06;
        }

        public static Task<MixCreateUsbRoute> DiscoverRouteAsync(string executable, int timeoutPerDeviceMs) {
            return Task.Factory.StartNew<MixCreateUsbRoute>(() => DiscoverRoute(executable, timeoutPerDeviceMs));
        }

        private static MixCreateUsbRoute DiscoverRoute(string executable, int timeoutPerDeviceMs) {
            foreach (string captureDevice in GetCaptureDevices()) {
                using (MixCreateUsbMonitor monitor = new MixCreateUsbMonitor()) {
                    try {
                        monitor.Start(executable, captureDevice, 0, true, true);
                    } catch {
                        continue;
                    }

                    Dictionary<ushort, int> matches = new Dictionary<ushort, int>();
                    DateTime deadline = DateTime.UtcNow.AddMilliseconds(Math.Max(250, timeoutPerDeviceMs));
                    while (DateTime.UtcNow < deadline && monitor.IsRunning) {
                        UsbPacket packet;
                        while (monitor.TryDequeue(out packet)) {
                            if (!IsMixCreateStatusPacket(packet)) continue;
                            int count;
                            matches.TryGetValue(packet.DeviceAddress, out count);
                            count++;
                            if (count >= 3) {
                                return new MixCreateUsbRoute(captureDevice, packet.DeviceAddress);
                            }
                            matches[packet.DeviceAddress] = count;
                        }
                        Thread.Sleep(10);
                    }
                }
            }
            return null;
        }

        public bool IsRunning {
            get { return process != null && !process.HasExited; }
        }

        public long DroppedPacketCount { get { return Interlocked.Read(ref droppedPacketCount); } }
        public string LastError { get { return lastError; } }

        public void Start(string executable, string captureDevice, int usbAddress, bool captureAllPackets, bool captureRootHub) {
            Stop();

            ProcessStartInfo info = new ProcessStartInfo();
            info.FileName = executable;
            info.Arguments = "-d " + captureDevice + (captureRootHub ? " -A" : " --devices " + usbAddress) + " -o -";
            info.UseShellExecute = false;
            info.CreateNoWindow = true;
            info.RedirectStandardOutput = true;
            // Never redirect a stream that is not consumed: a full stderr pipe can
            // deadlock an otherwise healthy long-running capture process.
            info.RedirectStandardError = false;

            this.captureAllPackets = captureAllPackets;
            this.captureRootHub = captureRootHub;
            this.targetUsbAddress = (ushort)usbAddress;
            stopping = false;
            lastError = String.Empty;
            process = Process.Start(info);
            if (process == null) throw new InvalidOperationException("USBPcap did not start.");
            OwnChildProcess(process);
            readerThread = new Thread(ReadLoop);
            readerThread.IsBackground = true;
            readerThread.Name = "Mute Cue USB capture reader";
            readerThread.Start();
        }

        public bool TryDequeue(out UsbPacket packet) {
            if (!packets.TryDequeue(out packet)) return false;
            Interlocked.Decrement(ref queuedPacketCount);
            return true;
        }

        private void EnqueuePacket(UsbPacket packet) {
            packets.Enqueue(packet);
            int count = Interlocked.Increment(ref queuedPacketCount);
            while (count > MaximumQueuedPackets) {
                UsbPacket discarded;
                if (!packets.TryDequeue(out discarded)) break;
                Interlocked.Decrement(ref queuedPacketCount);
                Interlocked.Increment(ref droppedPacketCount);
                count = Volatile.Read(ref queuedPacketCount);
            }
        }

        private static bool ReadExactly(Stream stream, byte[] buffer, int offset, int count) {
            int total = 0;
            while (total < count) {
                int read;
                try {
                    read = stream.Read(buffer, offset + total, count - total);
                } catch {
                    return false;
                }
                if (read == 0) return false;
                total += read;
            }
            return true;
        }

        private static uint ReadUInt32(byte[] bytes, int offset) {
            return (uint)(bytes[offset] | (bytes[offset + 1] << 8) | (bytes[offset + 2] << 16) | (bytes[offset + 3] << 24));
        }

        private void ReadLoop() {
            try {
                Process captureProcess = process;
                if (captureProcess == null) return;
                Stream stream = captureProcess.StandardOutput.BaseStream;
                byte[] globalHeader = new byte[24];
                if (!ReadExactly(stream, globalHeader, 0, globalHeader.Length)) return;

                byte[] recordHeader = new byte[16];
                while (!stopping && ReadExactly(stream, recordHeader, 0, recordHeader.Length)) {
                    uint includedLength = ReadUInt32(recordHeader, 8);
                    if (includedLength < 27 || includedLength > 1048576) return;

                    byte[] record = new byte[(int)includedLength];
                    if (!ReadExactly(stream, record, 0, record.Length)) return;

                    int usbHeaderLength = record[0] | (record[1] << 8);
                    if (usbHeaderLength < 27 || usbHeaderLength > record.Length) continue;

                    ushort deviceAddress = (ushort)(record[19] | (record[20] << 8));
                    // Root-hub diagnostic captures intentionally include every device
                    // so the current Mix Create address can be discovered.
                    if (!captureRootHub && targetUsbAddress != 0 && deviceAddress != targetUsbAddress) continue;

                    byte endpoint = record[21];

                    int payloadLength = record.Length - usbHeaderLength;
                    if (payloadLength <= 0) continue;
                    if (endpoint != 0x03 && endpoint != 0x83 && (!captureAllPackets || payloadLength > 64)) continue;

                    byte[] payload = new byte[payloadLength];
                    Buffer.BlockCopy(record, usbHeaderLength, payload, 0, payloadLength);
                    EnqueuePacket(new UsbPacket(deviceAddress, endpoint, payload, DateTime.UtcNow));
                }
            } catch (Exception error) {
                // The overlay treats a stopped capture as unavailable and may retry it.
                if (!stopping) lastError = error.GetType().Name + ": " + error.Message;
            }
        }

        public void Stop() {
            stopping = true;
            Process current = process;
            process = null;
            IntPtr currentJob = jobHandle;
            jobHandle = IntPtr.Zero;
            if (currentJob != IntPtr.Zero) {
                try { CloseHandle(currentJob); } catch { }
            }
            if (current != null) {
                try {
                    if (!current.HasExited) current.Kill();
                } catch { }
            }
            if (readerThread != null && readerThread.IsAlive) {
                try { readerThread.Join(1000); } catch { }
            }
            readerThread = null;
            if (current != null) {
                try { current.Dispose(); } catch { }
            }
            UsbPacket discarded;
            while (packets.TryDequeue(out discarded)) { }
            Interlocked.Exchange(ref queuedPacketCount, 0);
        }

        public void Dispose() {
            Stop();
        }
    }
}
