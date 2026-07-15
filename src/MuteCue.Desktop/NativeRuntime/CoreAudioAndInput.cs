#pragma warning disable
using System;
using System.Collections.Concurrent;
using System.Runtime.InteropServices;
using System.Threading;

namespace BeacnMuteOverlay {
    public static class AudioMute {
        private enum EDataFlow { eRender = 0, eCapture = 1, eAll = 2 }
        private enum ERole { eConsole = 0, eMultimedia = 1, eCommunications = 2 }

        [ComImport, Guid("BCDE0395-E52F-467C-8E3D-C4579291692E")]
        private class MMDeviceEnumerator { }

        [ComImport, InterfaceType(ComInterfaceType.InterfaceIsIUnknown), Guid("A95664D2-9614-4F35-A746-DE8DB63617E6")]
        private interface IMMDeviceEnumerator {
            int NotImpl1();
            [PreserveSig]
            int GetDefaultAudioEndpoint(EDataFlow dataFlow, ERole role, out IMMDevice ppDevice);
        }

        [ComImport, InterfaceType(ComInterfaceType.InterfaceIsIUnknown), Guid("D666063F-1587-4E43-81F1-B948E807363F")]
        private interface IMMDevice {
            [PreserveSig]
            int Activate(ref Guid iid, int dwClsCtx, IntPtr pActivationParams, out IAudioEndpointVolume ppInterface);
        }

        [ComImport, InterfaceType(ComInterfaceType.InterfaceIsIUnknown), Guid("5CDF2C82-841E-4546-9722-0CF74078229A")]
        private interface IAudioEndpointVolume {
            int RegisterControlChangeNotify(IntPtr pNotify);
            int UnregisterControlChangeNotify(IntPtr pNotify);
            int GetChannelCount(out uint pnChannelCount);
            int SetMasterVolumeLevel(float fLevelDB, Guid pguidEventContext);
            int SetMasterVolumeLevelScalar(float fLevel, Guid pguidEventContext);
            int GetMasterVolumeLevel(out float pfLevelDB);
            int GetMasterVolumeLevelScalar(out float pfLevel);
            int SetChannelVolumeLevel(uint nChannel, float fLevelDB, Guid pguidEventContext);
            int SetChannelVolumeLevelScalar(uint nChannel, float fLevel, Guid pguidEventContext);
            int GetChannelVolumeLevel(uint nChannel, out float pfLevelDB);
            int GetChannelVolumeLevelScalar(uint nChannel, out float pfLevel);
            int SetMute([MarshalAs(UnmanagedType.Bool)] bool bMute, Guid pguidEventContext);
            int GetMute(out bool pbMute);
        }

        public static bool IsDefaultCommunicationsMicMuted() {
            IMMDeviceEnumerator enumerator = (IMMDeviceEnumerator)(new MMDeviceEnumerator());
            IMMDevice device;
            int result = enumerator.GetDefaultAudioEndpoint(EDataFlow.eCapture, ERole.eCommunications, out device);
            if (result != 0 || device == null) return false;

            Guid endpointVolumeId = typeof(IAudioEndpointVolume).GUID;
            IAudioEndpointVolume volume;
            device.Activate(ref endpointVolumeId, 23, IntPtr.Zero, out volume);
            bool muted;
            volume.GetMute(out muted);
            return muted;
        }
    }

    public static class KeyboardInput {
        private const int WH_KEYBOARD_LL = 13;
        private const int WH_MOUSE_LL = 14;
        private const int WM_KEYDOWN = 0x0100;
        private const int WM_KEYUP = 0x0101;
        private const int WM_SYSKEYDOWN = 0x0104;
        private const int WM_SYSKEYUP = 0x0105;
        private const int WM_LBUTTONDOWN = 0x0201;
        private const int VK_SHIFT = 0x10;
        private const int VK_CONTROL = 0x11;
        private const int VK_MENU = 0x12;
        private const int VK_LWIN = 0x5B;
        private const int VK_RWIN = 0x5C;
        private const int ShiftModifier = 1;
        private const int ControlModifier = 2;
        private const int AltModifier = 4;
        private const int UnmappedWindowsModifier = 8;

        private delegate IntPtr LowLevelMouseProc(int nCode, IntPtr wParam, IntPtr lParam);
        private delegate IntPtr LowLevelKeyboardProc(int nCode, IntPtr wParam, IntPtr lParam);

        [StructLayout(LayoutKind.Sequential)]
        private struct PointStruct {
            public int X;
            public int Y;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct MouseLlHookStruct {
            public PointStruct Point;
            public uint MouseData;
            public uint Flags;
            public uint Time;
            public IntPtr ExtraInfo;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct KeyboardLlHookStruct {
            public uint VirtualKeyCode;
            public uint ScanCode;
            public uint Flags;
            public uint Time;
            public IntPtr ExtraInfo;
        }

        [DllImport("user32.dll", EntryPoint = "SetWindowsHookEx", SetLastError = true)]
        private static extern IntPtr SetMouseHook(int idHook, LowLevelMouseProc callback, IntPtr module, uint threadId);

        [DllImport("user32.dll", EntryPoint = "SetWindowsHookEx", SetLastError = true)]
        private static extern IntPtr SetKeyboardHook(int idHook, LowLevelKeyboardProc callback, IntPtr module, uint threadId);

        [DllImport("user32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool UnhookWindowsHookEx(IntPtr hook);

        [DllImport("user32.dll")]
        private static extern IntPtr CallNextHookEx(IntPtr hook, int nCode, IntPtr wParam, IntPtr lParam);

        [DllImport("user32.dll")]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool GetCursorPos(out PointStruct point);

        [DllImport("user32.dll")]
        private static extern short GetAsyncKeyState(int virtualKey);

        private static readonly ConcurrentQueue<long> leftClicks = new ConcurrentQueue<long>();
        private static readonly ConcurrentQueue<int> keyGestures = new ConcurrentQueue<int>();
        private const int MaximumQueuedInputEvents = 256;
        private static int leftClickCount;
        private static int keyGestureCount;
        private static readonly LowLevelMouseProc mouseHookCallback = MouseHookCallback;
        private static readonly LowLevelKeyboardProc keyboardHookCallback = KeyboardHookCallback;
        private static IntPtr mouseHook = IntPtr.Zero;
        private static IntPtr keyboardHook = IntPtr.Zero;
        private static volatile int[] configuredGestureCodes = new int[0];
        private static readonly int[] keyDown = new int[256];

        public static bool StartMouseListener() {
            if (mouseHook != IntPtr.Zero) return true;
            mouseHook = SetMouseHook(WH_MOUSE_LL, mouseHookCallback, IntPtr.Zero, 0);
            return mouseHook != IntPtr.Zero;
        }

        public static void StopMouseListener() {
            if (mouseHook == IntPtr.Zero) return;
            UnhookWindowsHookEx(mouseHook);
            mouseHook = IntPtr.Zero;
            long ignored;
            while (leftClicks.TryDequeue(out ignored)) { }
            Interlocked.Exchange(ref leftClickCount, 0);
        }

        public static bool ConsumeLeftClick(out int x, out int y) {
            long packed;
            if (!leftClicks.TryDequeue(out packed)) {
                x = 0;
                y = 0;
                return false;
            }
            Interlocked.Decrement(ref leftClickCount);
            x = unchecked((int)(packed >> 32));
            y = unchecked((int)(packed & 0xFFFFFFFFL));
            return true;
        }

        public static bool StartKeyboardListener(int[] gestureCodes) {
            int[] normalized = NormalizeGestureCodes(gestureCodes);
            configuredGestureCodes = normalized;
            ClearKeyGestureState();
            if (normalized.Length == 0) {
                if (keyboardHook != IntPtr.Zero) {
                    UnhookWindowsHookEx(keyboardHook);
                    keyboardHook = IntPtr.Zero;
                }
                return true;
            }
            if (keyboardHook != IntPtr.Zero) return true;
            keyboardHook = SetKeyboardHook(WH_KEYBOARD_LL, keyboardHookCallback, IntPtr.Zero, 0);
            return keyboardHook != IntPtr.Zero;
        }

        public static void StopKeyboardListener() {
            configuredGestureCodes = new int[0];
            if (keyboardHook != IntPtr.Zero) {
                UnhookWindowsHookEx(keyboardHook);
                keyboardHook = IntPtr.Zero;
            }
            ClearKeyGestureState();
        }

        public static bool ConsumeKeyGesture(out int gestureCode) {
            if (!keyGestures.TryDequeue(out gestureCode)) {
                gestureCode = 0;
                return false;
            }
            Interlocked.Decrement(ref keyGestureCount);
            return true;
        }

        public static bool GetCursorPosition(out int x, out int y) {
            PointStruct point;
            if (!GetCursorPos(out point)) {
                x = 0;
                y = 0;
                return false;
            }
            x = point.X;
            y = point.Y;
            return true;
        }

        private static IntPtr MouseHookCallback(int nCode, IntPtr wParam, IntPtr lParam) {
            if (nCode >= 0 && wParam.ToInt32() == WM_LBUTTONDOWN) {
                MouseLlHookStruct mouse = (MouseLlHookStruct)Marshal.PtrToStructure(lParam, typeof(MouseLlHookStruct));
                long packed = ((long)(uint)mouse.Point.X << 32) | (uint)mouse.Point.Y;
                EnqueueBounded(leftClicks, packed, ref leftClickCount);
            }
            return CallNextHookEx(mouseHook, nCode, wParam, lParam);
        }

        private static IntPtr KeyboardHookCallback(int nCode, IntPtr wParam, IntPtr lParam) {
            if (nCode >= 0) {
                int message = wParam.ToInt32();
                KeyboardLlHookStruct keyboard = (KeyboardLlHookStruct)Marshal.PtrToStructure(lParam, typeof(KeyboardLlHookStruct));
                int virtualKey = unchecked((int)keyboard.VirtualKeyCode);
                if (virtualKey >= 0 && virtualKey < keyDown.Length) {
                    if (message == WM_KEYUP || message == WM_SYSKEYUP) {
                        Interlocked.Exchange(ref keyDown[virtualKey], 0);
                    } else if (message == WM_KEYDOWN || message == WM_SYSKEYDOWN) {
                        int[] snapshot = configuredGestureCodes;
                        if (ContainsVirtualKey(snapshot, virtualKey)) {
                            bool firstPress = Interlocked.Exchange(ref keyDown[virtualKey], 1) == 0;
                            if (firstPress) {
                                int gestureCode = (GetModifierBits() << 16) | virtualKey;
                                if (Array.BinarySearch(snapshot, gestureCode) >= 0) {
                                    EnqueueBounded(keyGestures, gestureCode, ref keyGestureCount);
                                }
                            }
                        }
                    }
                }
            }
            return CallNextHookEx(keyboardHook, nCode, wParam, lParam);
        }

        private static int GetModifierBits() {
            int modifiers = 0;
            if ((GetAsyncKeyState(VK_SHIFT) & 0x8000) != 0) modifiers |= ShiftModifier;
            if ((GetAsyncKeyState(VK_CONTROL) & 0x8000) != 0) modifiers |= ControlModifier;
            if ((GetAsyncKeyState(VK_MENU) & 0x8000) != 0) modifiers |= AltModifier;
            if ((GetAsyncKeyState(VK_LWIN) & 0x8000) != 0 || (GetAsyncKeyState(VK_RWIN) & 0x8000) != 0) {
                modifiers |= UnmappedWindowsModifier;
            }
            return modifiers;
        }

        private static int[] NormalizeGestureCodes(int[] gestureCodes) {
            if (gestureCodes == null || gestureCodes.Length == 0) return new int[0];
            int[] copy = new int[gestureCodes.Length];
            int count = 0;
            for (int index = 0; index < gestureCodes.Length; index++) {
                int gestureCode = gestureCodes[index];
                int virtualKey = gestureCode & 0xFFFF;
                int modifiers = (gestureCode >> 16) & 0xFFFF;
                if (virtualKey <= 0 || virtualKey >= 256 || (modifiers & ~7) != 0) continue;
                copy[count++] = gestureCode;
            }
            if (count == 0) return new int[0];
            Array.Sort(copy, 0, count);
            int uniqueCount = 1;
            for (int index = 1; index < count; index++) {
                if (copy[index] != copy[uniqueCount - 1]) copy[uniqueCount++] = copy[index];
            }
            int[] normalized = new int[uniqueCount];
            Array.Copy(copy, normalized, uniqueCount);
            return normalized;
        }

        private static bool ContainsVirtualKey(int[] gestureCodes, int virtualKey) {
            for (int index = 0; index < gestureCodes.Length; index++) {
                if ((gestureCodes[index] & 0xFFFF) == virtualKey) return true;
            }
            return false;
        }

        private static void ClearKeyGestureState() {
            int ignored;
            while (keyGestures.TryDequeue(out ignored)) { }
            Interlocked.Exchange(ref keyGestureCount, 0);
            for (int index = 0; index < keyDown.Length; index++) {
                Interlocked.Exchange(ref keyDown[index], 0);
            }
        }

        private static void EnqueueBounded<T>(ConcurrentQueue<T> queue, T value, ref int count) {
            queue.Enqueue(value);
            int current = Interlocked.Increment(ref count);
            while (current > MaximumQueuedInputEvents) {
                T discarded;
                if (!queue.TryDequeue(out discarded)) break;
                Interlocked.Decrement(ref count);
                current = Volatile.Read(ref count);
            }
        }
    }
}
