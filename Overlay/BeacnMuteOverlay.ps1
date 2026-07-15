param(
    [switch]$CaptureMixCreate,
    [switch]$CaptureBeacnState,
    [switch]$CaptureBeacnWindowMove,
    [switch]$CaptureBeacnPageMap,
    [switch]$CaptureDiscordAccessibility,
    [switch]$CaptureDiscordState,
    [switch]$CaptureDiscordToggleEvents,
    [switch]$CaptureDiscordInvokeEvents,
    [switch]$LogBeacnState,
    [switch]$StartedAtLogin,
    [string]$StartupLauncherPath = "",
    [int]$CaptureSeconds = 20
)

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes
Add-Type -AssemblyName System.Security
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$ErrorActionPreference = "Stop"
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$CaptureSeconds = [Math]::Max(5, [Math]::Min(300, $CaptureSeconds))
. (Join-Path $scriptDir "MuteCue.Paths.ps1")
. (Join-Path $scriptDir "MuteCue.Diagnostics.ps1")
. (Join-Path $scriptDir "MuteCue.Configuration.ps1")
. (Join-Path $scriptDir "MuteCue.Startup.ps1")
. (Join-Path $scriptDir "MuteCue.DiscordPublicClient.ps1")
. (Join-Path $scriptDir "MuteCue.BeacnHotkeys.ps1")
. (Join-Path $scriptDir "BeacnActionState.ps1")
. (Join-Path $scriptDir "BeacnAdapter.ps1")
. (Join-Path $scriptDir "BeacnHardwareLayout.ps1")
. (Join-Path $scriptDir "BeacnStateCoordinator.ps1")
. (Join-Path $scriptDir "BeacnAccessibilityClient.ps1")
. (Join-Path $scriptDir "MuteCue.AccessibilityRuntime.ps1")
. (Join-Path $scriptDir "MuteCue.Readiness.ps1")
. (Join-Path $scriptDir "BeacnHealthReport.ps1")
$script:muteCuePaths = Get-MuteCueDataPaths
$script:muteCuePathInitialization = Initialize-MuteCueDataPaths -Paths $script:muteCuePaths -LegacyDirectory $scriptDir
$script:muteCueStaticReadiness = Get-MuteCueStaticReadiness -Paths $script:muteCuePaths
$script:muteCueBeacnReadiness = $null
$script:startupLauncherPath = ""
if (-not [string]::IsNullOrWhiteSpace($StartupLauncherPath)) {
    try { $script:startupLauncherPath = [System.IO.Path]::GetFullPath($StartupLauncherPath) } catch {}
}
if ([string]::IsNullOrWhiteSpace($script:startupLauncherPath)) {
    $versionsDirectory = Split-Path -Parent $scriptDir
    $installedRoot = Split-Path -Parent $versionsDirectory
    $installedLauncher = Join-Path $installedRoot "Mute Cue.vbs"
    $portableLauncher = Join-Path $scriptDir "Start Beacn Mute Overlay Hidden.vbs"
    if (
        (Split-Path -Leaf $versionsDirectory) -eq "versions" -and
        (Test-Path -LiteralPath $installedLauncher)
    ) {
        $script:startupLauncherPath = $installedLauncher
    } else {
        $script:startupLauncherPath = $portableLauncher
    }
}
$settingsPath = [string]$script:muteCuePaths.SettingsPath
$discordAuthorizationPath = [string]$script:muteCuePaths.DiscordAuthorizationPath
Initialize-MuteCueDiagnostics -Path ([string]$script:muteCuePaths.DiagnosticPath)
$script:discordPublicClient = Get-MuteCueDiscordPublicClient -Path (Join-Path $scriptDir "MuteCue.DiscordPublicClient.json")
if (Test-Path -LiteralPath ([string]$script:muteCuePaths.DiscordSecretPath)) {
    try {
        Remove-Item -LiteralPath ([string]$script:muteCuePaths.DiscordSecretPath) -Force
        Write-MuteCueDiagnostic -Level Info -Component "Discord" -Message "Removed the obsolete local Discord client secret."
    } catch {
        Write-MuteCueDiagnostic -Level Warning -Component "Discord" -Message "The obsolete local Discord client secret could not be removed." -Exception $_.Exception
    }
}
$script:overlayInstanceMutex = $null
$script:overlayInstanceLock = $null
$script:beacnStateLogPath = [string]$script:muteCuePaths.BeacnStateLogPath
$script:lastBeacnRawLogSignature = ""
$script:lastBeacnStableLogSignature = ""
$script:lastBeacnSourceLogSignature = ""
$script:lastBeacnHardwareLogSignature = ""
$script:lastBeacnHeartbeatLog = [DateTime]::MinValue

if ($LogBeacnState) {
    try { [System.IO.File]::WriteAllText($script:beacnStateLogPath, "") } catch {}
}

function Write-BeacnStateLog {
    param([string]$Message)

    if (-not $LogBeacnState) { return }
    try {
        [System.IO.File]::AppendAllText(
            $script:beacnStateLogPath,
            ("{0:HH:mm:ss.fff} {1}{2}" -f [DateTime]::Now, $Message, [Environment]::NewLine)
        )
    } catch {}
}

$isDiagnosticRun = (
    $CaptureMixCreate -or
    $CaptureBeacnState -or
    $CaptureBeacnWindowMove -or
    $CaptureBeacnPageMap -or
    $CaptureDiscordAccessibility -or
    $CaptureDiscordState -or
    $CaptureDiscordToggleEvents -or
    $CaptureDiscordInvokeEvents
)
if (-not $isDiagnosticRun) {
    try {
        $createdNewInstance = $false
        $script:overlayInstanceMutex = New-Object System.Threading.Mutex(
            $true,
            "Local\MuteCue.BeacnMuteOverlay",
            [ref]$createdNewInstance
        )
        if (-not $createdNewInstance) {
            $script:overlayInstanceMutex.Dispose()
            exit
        }
    } catch {
        $script:overlayInstanceMutex = $null
        Write-MuteCueDiagnostic -Level Warning -Component "Startup" -Message "The Windows single-instance mutex was unavailable; using a file lock." -Exception $_.Exception
        try {
            $lockPath = [string]$script:muteCuePaths.LockPath
            $script:overlayInstanceLock = New-Object System.IO.FileStream(
                $lockPath,
                [System.IO.FileMode]::OpenOrCreate,
                [System.IO.FileAccess]::ReadWrite,
                [System.IO.FileShare]::None
            )
        } catch {
            Write-MuteCueDiagnostic -Level Error -Component "Startup" -Message "Another Mute Cue instance may already be running." -Exception $_.Exception
            exit
        }
    }
}

# Start the isolated BEACN provider as soon as single-instance ownership is known.
# Its cold JUCE discovery can then overlap compilation of the unrelated audio,
# USB, Discord, and WPF helpers instead of beginning after the UI is constructed.
$script:useBeacnAccessibilityWorker = (-not $isDiagnosticRun)
$script:beacnAccessibilityClient = if ($script:useBeacnAccessibilityWorker) {
    New-BeacnAccessibilityClient -OverlayDirectory $scriptDir
} else {
    $null
}
if ($script:useBeacnAccessibilityWorker) {
    try {
        [void](Start-BeacnAccessibilityClient -Client $script:beacnAccessibilityClient)
    } catch {
        Write-MuteCueDiagnosticThrottled -Key "beacn-worker-early-start" -Level Warning -Component "BEACN" -Message "The early accessibility worker start failed; the watchdog will retry." -Exception $_.Exception
    }
}

$defaultSettings = Get-MuteCueDefaultSettings

function Read-OverlaySettings {
    return Read-MuteCueSettings -Path $settingsPath -Defaults $defaultSettings
}

function Get-OverlaySettingsWriteStamp {
    try {
        $file = [System.IO.FileInfo]::new($settingsPath)
        if (-not $file.Exists) { return "missing" }
        return "{0}:{1}" -f $file.LastWriteTimeUtc.Ticks, $file.Length
    } catch {
        return "unavailable"
    }
}

function Set-ObservedOverlaySettingsWriteStamp {
    $script:lastObservedSettingsWriteStamp = Get-OverlaySettingsWriteStamp
}

function Save-OverlaySettings {
    param(
        [object]$Settings,
        [switch]$Immediate
    )

    if ($Immediate) {
        if ($null -ne $script:settingsSaveTimer) { $script:settingsSaveTimer.Stop() }
        $script:settingsSavePending = $false
        try {
            [void](Save-MuteCueSettings -Path $settingsPath -Settings $Settings -Defaults $defaultSettings)
            Set-ObservedOverlaySettingsWriteStamp
        } catch {
            Write-MuteCueDiagnosticThrottled `
                -Key "settings-save" `
                -Level Error `
                -Component "Configuration" `
                -Message "Settings could not be saved." `
                -Exception $_.Exception
        }
        return
    }

    $script:settingsSavePending = $true
    $script:settingsSaveObject = $Settings
    if ($null -eq $script:settingsSaveTimer) {
        $script:settingsSaveTimer = New-Object System.Windows.Threading.DispatcherTimer
        $script:settingsSaveTimer.Interval = [TimeSpan]::FromMilliseconds(300)
        $script:settingsSaveTimer.Add_Tick({
            $script:settingsSaveTimer.Stop()
            if (-not $script:settingsSavePending) { return }
            $script:settingsSavePending = $false
            try {
                [void](Save-MuteCueSettings `
                    -Path $settingsPath `
                    -Settings $script:settingsSaveObject `
                    -Defaults $defaultSettings)
                Set-ObservedOverlaySettingsWriteStamp
            } catch {
                Write-MuteCueDiagnosticThrottled `
                    -Key "settings-save" `
                    -Level Error `
                    -Component "Configuration" `
                    -Message "Settings could not be saved." `
                    -Exception $_.Exception
            }
        })
    }
    $script:settingsSaveTimer.Stop()
    $script:settingsSaveTimer.Start()
}

function Get-SavedDiscordAuthorization {
    $empty = [pscustomobject]@{
        AccessToken = ""
        RefreshToken = ""
        ExpiresAtUnixSeconds = [int64]0
    }
    if (-not (Test-Path -LiteralPath $discordAuthorizationPath)) { return $empty }
    try {
        $file = New-Object System.IO.FileInfo($discordAuthorizationPath)
        if ($file.Length -le 0 -or $file.Length -gt 1MB) { throw "Saved Discord authorization has an invalid size." }
        $encrypted = [Convert]::FromBase64String(([System.IO.File]::ReadAllText($discordAuthorizationPath)).Trim())
        $plain = [System.Security.Cryptography.ProtectedData]::Unprotect(
            $encrypted,
            $null,
            [System.Security.Cryptography.DataProtectionScope]::CurrentUser
        )
        try { $savedJson = [System.Text.Encoding]::UTF8.GetString($plain) } finally { [Array]::Clear($plain, 0, $plain.Length) }
        $saved = $savedJson | ConvertFrom-Json
        $accessToken = [string]$saved.AccessToken
        $refreshToken = [string]$saved.RefreshToken
        if ($accessToken.Length -gt 65536 -or $refreshToken.Length -gt 65536) { throw "Saved Discord authorization is invalid." }
        return [pscustomobject]@{
            AccessToken = $accessToken
            RefreshToken = $refreshToken
            ExpiresAtUnixSeconds = [Math]::Max([int64]0, [int64]$saved.ExpiresAtUnixSeconds)
        }
    } catch {
        Write-MuteCueDiagnostic -Level Warning -Component "Discord" -Message "Saved Discord authorization could not be read." -Exception $_.Exception
        return $empty
    }
}

function Save-DiscordAuthorization {
    param(
        [string]$AccessToken,
        [string]$RefreshToken,
        [int64]$ExpiresAtUnixSeconds
    )

    $payload = [ordered]@{
        AccessToken = $AccessToken
        RefreshToken = $RefreshToken
        ExpiresAtUnixSeconds = $ExpiresAtUnixSeconds
    } | ConvertTo-Json -Compress
    $plain = [System.Text.Encoding]::UTF8.GetBytes($payload)
    try {
        $encrypted = [System.Security.Cryptography.ProtectedData]::Protect(
            $plain,
            $null,
            [System.Security.Cryptography.DataProtectionScope]::CurrentUser
        )
        Write-MuteCueAtomicText -Path $discordAuthorizationPath -Content ([Convert]::ToBase64String($encrypted))
    } finally {
        [Array]::Clear($plain, 0, $plain.Length)
    }
}

$coreAudioSource = @"
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
"@

try {
    Add-Type -TypeDefinition $coreAudioSource
    $mouseHookAvailable = $false
    $script:keyboardHookAvailable = $false
} catch {
    $mouseHookAvailable = $false
    $script:keyboardHookAvailable = $false
    Write-MuteCueDiagnostic -Level Error -Component "Startup" -Message "Input helper compilation failed." -Exception $_.Exception
}
Write-BeacnStateLog -Message ("STARTUP input hooks available={0}" -f [int]($null -ne ("BeacnMuteOverlay.KeyboardInput" -as [type])))

$usbCaptureSource = @"
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

        public UsbPacket(ushort deviceAddress, byte endpoint, byte[] data) {
            DeviceAddress = deviceAddress;
            Endpoint = endpoint;
            Data = data;
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
                    EnqueuePacket(new UsbPacket(deviceAddress, endpoint, payload));
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
"@

try {
    Add-Type -TypeDefinition $usbCaptureSource
    $usbCaptureAvailable = $true
} catch {
    $usbCaptureAvailable = $false
    Write-MuteCueDiagnostic -Level Error -Component "Startup" -Message "USB capture helper compilation failed." -Exception $_.Exception
}
$script:usbPcapCommandPath = Join-Path $env:ProgramFiles "USBPcap\USBPcapCMD.exe"
if (-not (Test-Path -LiteralPath $script:usbPcapCommandPath)) {
    $programFilesX86 = [Environment]::GetEnvironmentVariable("ProgramFiles(x86)")
    if (-not [string]::IsNullOrWhiteSpace($programFilesX86)) {
        $candidateUsbPcapPath = Join-Path $programFilesX86 "USBPcap\USBPcapCMD.exe"
        if (Test-Path -LiteralPath $candidateUsbPcapPath) {
            $script:usbPcapCommandPath = $candidateUsbPcapPath
        }
    }
}
Write-BeacnStateLog -Message ("STARTUP USB capture available={0}" -f [int]$usbCaptureAvailable)

$discordScannerSource = @"
using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Automation;

namespace BeacnMuteOverlay {
    public sealed class DiscordLocalState {
        public bool ClientFound { get; set; }
        public bool MicStateKnown { get; set; }
        public bool MicMuted { get; set; }
        public bool DeafenStateKnown { get; set; }
        public bool Deafened { get; set; }
    }

    public sealed class BeacnFaderState {
        public int Order { get; set; }
        public string Name { get; set; }
        public bool PersonalMuted { get; set; }
        public bool AudienceMuted { get; set; }
        public bool IsLocked { get; set; }
        public bool AllActionStateKnown { get; set; }
        public bool AllActionActive { get; set; }
        public bool AudienceActionStateKnown { get; set; }
        public bool AudienceActionActive { get; set; }
        public bool HasAllActionBounds { get; set; }
        public double AllActionLeft { get; set; }
        public double AllActionTop { get; set; }
        public double AllActionRight { get; set; }
        public double AllActionBottom { get; set; }
        public bool HasAudienceActionBounds { get; set; }
        public double AudienceActionLeft { get; set; }
        public double AudienceActionTop { get; set; }
        public double AudienceActionRight { get; set; }
        public double AudienceActionBottom { get; set; }
    }

    public sealed class BeacnActionTarget {
        public string Name { get; set; }
        public string Mode { get; set; }
    }

    public static class BeacnAppScanner {
        public const int ContractVersion = 1;

        [StructLayout(LayoutKind.Sequential)]
        private struct NativePoint {
            public int X;
            public int Y;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct NativeRect {
            public int Left;
            public int Top;
            public int Right;
            public int Bottom;
        }

        [DllImport("user32.dll")]
        private static extern bool GetCursorPos(out NativePoint point);

        [DllImport("user32.dll")]
        private static extern bool GetWindowRect(IntPtr window, out NativeRect bounds);

        [DllImport("user32.dll", SetLastError = true)]
        private static extern bool SetWindowPos(
            IntPtr window,
            IntPtr insertAfter,
            int x,
            int y,
            int width,
            int height,
            uint flags
        );

        private sealed class TrackedFader {
            public string Name;
            public int DiscoveryOrder;
            public int ProcessId;
            public Rect HeaderBounds = Rect.Empty;
            public AutomationElement LockButton;
            public AutomationElement PersonalButton;
            public AutomationElement AudienceButton;
            public AutomationElement AllActionLabel;
            public AutomationElement AllActionContainer;
            public AutomationElement AllActionMenuButton;
            public AutomationElement AudienceActionLabel;
            public AutomationElement AudienceActionContainer;
            public AutomationElement AudienceActionMenuButton;
            public Rect AllActionBounds = Rect.Empty;
            public Rect AllActionRowBounds = Rect.Empty;
            public Rect AllActionProbeBounds = Rect.Empty;
            public Rect AudienceActionBounds = Rect.Empty;
            public Rect AudienceActionRowBounds = Rect.Empty;
            public Rect AudienceActionProbeBounds = Rect.Empty;
            public bool AllActionSeen;
            public bool AllActionMenuButtonSeen;
            public bool AudienceActionSeen;
            public bool AudienceActionMenuButtonSeen;
            public DateTime AllVerifiedUtc = DateTime.MinValue;
            public DateTime AudienceVerifiedUtc = DateTime.MinValue;
            public bool PersonalMuted;
            public bool AudienceMuted;
            public bool IsLocked;
            public AutomationPropertyChangedEventHandler PersonalChangedHandler;
            public AutomationPropertyChangedEventHandler AudienceChangedHandler;
            public AutomationPropertyChangedEventHandler LockChangedHandler;
            public StructureChangedEventHandler AllStructureChangedHandler;
            public StructureChangedEventHandler AudienceStructureChangedHandler;
        }

        private sealed class TrackedFaderStateCheckpoint {
            public TrackedFader Fader;
            public AutomationElement AllActionContainer;
            public AutomationElement AllActionMenuButton;
            public AutomationElement AudienceActionContainer;
            public AutomationElement AudienceActionMenuButton;
            public bool AllActionSeen;
            public bool AllActionMenuButtonSeen;
            public bool AudienceActionSeen;
            public bool AudienceActionMenuButtonSeen;
            public DateTime AllVerifiedUtc;
            public DateTime AudienceVerifiedUtc;
            public bool PersonalMuted;
            public bool AudienceMuted;
            public bool IsLocked;
        }

        private sealed class TextCandidate {
            public string Name;
            public int ProcessId;
            public Rect Bounds;
        }

        private sealed class HardwareRefreshRequest {
            public string PreferredName;
            public string OutputCandidateName;
            public int Mask;
            public int Position;
            public long RequestId;
            public long MappingGeneration;
            public bool MappingConfident;
            public int Attempt;
            public int FallbackIndex;
            public DateTime NotBeforeUtc;
        }

        private sealed class HardwareRefreshCompletion {
            public HardwareRefreshRequest Request;
            public string ChangedName;
        }

        private static readonly object compatibilityGate = new object();
        private static HashSet<string> configuredFaderNames =
            new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        private static HashSet<string> allActionLabels =
            new HashSet<string>(new string[] { "Knob: Mute to All" }, StringComparer.OrdinalIgnoreCase);
        private static HashSet<string> audienceActionLabels =
            new HashSet<string>(new string[] { "Mute to Audience" }, StringComparer.OrdinalIgnoreCase);
        private static readonly HashSet<string> ignoredHeaderLabels = new HashSet<string>(
            new string[] {
                "Personal", "Audience", "Mute", "Muted", "Unmuted", "Lock", "Unlock",
                "Add Fader", "Faders", "Mute to All", "Knob"
            },
            StringComparer.OrdinalIgnoreCase
        );
        private static volatile List<TrackedFader> trackedFaders = new List<TrackedFader>();
        private static DateTime lastDiscovery = DateTime.MinValue;
        private static DateTime lastActionRefresh = DateTime.MinValue;
        private static DateTime lastSafetySweep = DateTime.MinValue;
        private static double lastSafetySweepDurationMilliseconds;
        private static string lastDiagnostic = "not scanned";
        private static double lastScanMilliseconds;
        private static int actionRefreshRequested = 1;
        private static int discoveryRequested;
        private static int geometryRefreshRequested;
        private static int geometryRefreshIndex = -1;
        private static readonly ConcurrentDictionary<string, int> pendingActionRefreshes =
            new ConcurrentDictionary<string, int>(StringComparer.OrdinalIgnoreCase);
        private static readonly ConcurrentDictionary<string, int> pendingUrgentActionRefreshes =
            new ConcurrentDictionary<string, int>(StringComparer.OrdinalIgnoreCase);
        private const int MaximumFaderRefreshesPerScan = 1;
        private static readonly ConcurrentQueue<HardwareRefreshRequest> pendingHardwareRefreshes =
            new ConcurrentQueue<HardwareRefreshRequest>();
        private const int MaximumPendingHardwareRefreshes = 128;
        private static int pendingHardwareRefreshCount;
        private static readonly ConcurrentDictionary<string, int> postDiscoveryRefreshes =
            new ConcurrentDictionary<string, int>(StringComparer.OrdinalIgnoreCase);
        private static readonly ConcurrentDictionary<string, int> postDiscoveryUrgentRefreshes =
            new ConcurrentDictionary<string, int>(StringComparer.OrdinalIgnoreCase);
        private static readonly ConcurrentDictionary<string, int> missingRefreshDeadlineGeneration =
            new ConcurrentDictionary<string, int>(StringComparer.OrdinalIgnoreCase);
        private static readonly object discoveryGate = new object();
        private static Task discoveryTask;
        private static DateTime lastDiscoveryStarted = DateTime.MinValue;
        private const double SafetySweepCadenceMilliseconds = 750;
        private const double MaximumSafetySweepCadenceMilliseconds = 5000;
        private const double SafetySweepCostMultiplier = 10;
        private const double MaximumActionStateAgeSeconds = 10;
        private static string lastActionEventSummary = "none";
        private static string lastHardwareRefreshSummary = "none";
        private static string lastCompatibilityStatus = "Discovering";
        private static string lastCompatibilityDetail = "Waiting for the BEACN mixer layout.";
        private static string lastBeacnVersion = String.Empty;
        private static string lastLayoutFingerprint = String.Empty;
        private static int discoveryGeneration;
        private static int structurallyDiscoveredNameCount;
        private static long possibleLayoutChangeUtcTicks;
        private static long geometryChangeSuppressionUntilUtcTicks;
        private static long nativeGeometryGeneration;
        private static long lastActionEventUtcTicks;
        private static DateTime lastLivenessCheck = DateTime.MinValue;
        private static bool lastLivenessResult = true;
        private static string lastHardwareChangedName = String.Empty;
        private static string lastHardwarePreferredName = String.Empty;
        private static string lastHardwareChangedMode = String.Empty;
        private static int lastHardwarePosition = -1;
        private static long lastHardwareRequestId;
        private static long lastHardwareMappingGeneration;
        private static long hardwareResultSequence;
        private static AutomationElement subscribedWindow;
        private static IntPtr subscribedWindowHandle = IntPtr.Zero;
        private static readonly object geometryGate = new object();
        private static Rect lastWindowBounds = Rect.Empty;
        private const int WindowGeometrySettleMilliseconds = 3000;
        private static readonly StructureChangedEventHandler rootStructureChangedHandler = HandleRootStructureChanged;
        private static readonly Condition ButtonElementCondition = new PropertyCondition(
            AutomationElement.ControlTypeProperty,
            ControlType.Button
        );

        public static string DiagnosticSummary { get { return lastDiagnostic; } }
        public static string LastActionEventSummary { get { return lastActionEventSummary; } }
        public static string LastHardwareRefreshSummary { get { return lastHardwareRefreshSummary; } }
        public static string CompatibilityStatus { get { return lastCompatibilityStatus; } }
        public static string CompatibilityDetail { get { return lastCompatibilityDetail; } }
        public static string BeacnVersion { get { return lastBeacnVersion; } }
        public static string LayoutFingerprint { get { return lastLayoutFingerprint; } }
        public static int DiscoveryGeneration { get { return Volatile.Read(ref discoveryGeneration); } }
        public static int StructurallyDiscoveredNameCount { get { return Volatile.Read(ref structurallyDiscoveredNameCount); } }
        public static string LastHardwareChangedName { get { return lastHardwareChangedName; } }
        public static string LastHardwarePreferredName { get { return lastHardwarePreferredName; } }
        public static string LastHardwareChangedMode { get { return lastHardwareChangedMode; } }
        public static int LastHardwarePosition { get { return lastHardwarePosition; } }
        public static long LastHardwareRequestId { get { return Interlocked.Read(ref lastHardwareRequestId); } }
        public static long LastHardwareMappingGeneration { get { return Interlocked.Read(ref lastHardwareMappingGeneration); } }
        public static long HardwareResultSequence { get { return Interlocked.Read(ref hardwareResultSequence); } }
        public static double LastScanMilliseconds { get { return lastScanMilliseconds; } }
        public static long NativeGeometryGeneration { get { return Interlocked.Read(ref nativeGeometryGeneration); } }
        public static bool GeometryRefreshInProgress {
            get {
                return Volatile.Read(ref geometryRefreshIndex) >= 0 ||
                    DateTime.UtcNow.Ticks < Interlocked.Read(ref geometryChangeSuppressionUntilUtcTicks);
            }
        }
        public static int GeometryRefreshRemaining {
            get {
                int index = Volatile.Read(ref geometryRefreshIndex);
                if (index < 0) return 0;
                return Math.Max(0, trackedFaders.Count - index);
            }
        }
        public static bool HasPendingChanges {
            get {
                return Volatile.Read(ref actionRefreshRequested) != 0 ||
                    Volatile.Read(ref discoveryRequested) != 0 ||
                    Volatile.Read(ref geometryRefreshRequested) != 0 ||
                    Volatile.Read(ref geometryRefreshIndex) >= 0 ||
                    DateTime.UtcNow.Ticks < Interlocked.Read(ref geometryChangeSuppressionUntilUtcTicks) ||
                    !pendingUrgentActionRefreshes.IsEmpty ||
                    !pendingActionRefreshes.IsEmpty ||
                    !postDiscoveryUrgentRefreshes.IsEmpty ||
                    !postDiscoveryRefreshes.IsEmpty ||
                    !pendingHardwareRefreshes.IsEmpty;
            }
        }

        public static void ConfigureCompatibility(string[] faderNames, string[] allLabels, string[] audienceLabels) {
            lock (compatibilityGate) {
                configuredFaderNames = ToNameSet(faderNames);
                HashSet<string> configuredAllLabels = ToNameSet(allLabels);
                HashSet<string> configuredAudienceLabels = ToNameSet(audienceLabels);
                if (configuredAllLabels.Count > 0) allActionLabels = configuredAllLabels;
                if (configuredAudienceLabels.Count > 0) audienceActionLabels = configuredAudienceLabels;
            }
            RequestDiscovery();
        }

        private static HashSet<string> ToNameSet(IEnumerable<string> values) {
            HashSet<string> result = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            if (values == null) return result;
            foreach (string value in values) {
                if (!String.IsNullOrWhiteSpace(value)) result.Add(value.Trim());
            }
            return result;
        }

        public static void Shutdown() {
            List<TrackedFader> previous = trackedFaders;
            trackedFaders = new List<TrackedFader>();
            UnsubscribeFaderHandlers(previous);
            SetSubscribedWindow(null);
            pendingActionRefreshes.Clear();
            pendingUrgentActionRefreshes.Clear();
            postDiscoveryRefreshes.Clear();
            postDiscoveryUrgentRefreshes.Clear();
            missingRefreshDeadlineGeneration.Clear();
            HardwareRefreshRequest discarded;
            while (pendingHardwareRefreshes.TryDequeue(out discarded)) { }
            Interlocked.Exchange(ref pendingHardwareRefreshCount, 0);
            Interlocked.Exchange(ref actionRefreshRequested, 0);
            Interlocked.Exchange(ref discoveryRequested, 0);
            Interlocked.Exchange(ref geometryRefreshRequested, 0);
            Interlocked.Exchange(ref geometryRefreshIndex, -1);
        }

        public static void RequestDiscovery() {
            Interlocked.Exchange(ref discoveryRequested, 1);
            Interlocked.Exchange(ref actionRefreshRequested, 1);
        }

        public static void RequestGeometryRefresh() {
            Interlocked.Exchange(ref geometryRefreshRequested, 1);
            Interlocked.Exchange(ref actionRefreshRequested, 1);
        }

        public static bool PollWindowGeometry() {
            return ObserveNativeWindowGeometry(DateTime.UtcNow);
        }

        public static void RequestFaderRefresh(string name, string mode) {
            if (String.IsNullOrWhiteSpace(name)) return;
            int mask = String.Equals(mode, "All", StringComparison.OrdinalIgnoreCase)
                ? 1
                : String.Equals(mode, "Audience", StringComparison.OrdinalIgnoreCase) ? 2 : 3;
            QueueFaderRefresh(name, mask);
        }

        public static void RequestUrgentFaderRefresh(string name, string mode) {
            if (String.IsNullOrWhiteSpace(name)) return;
            int mask = String.Equals(mode, "All", StringComparison.OrdinalIgnoreCase)
                ? 5
                : String.Equals(mode, "Audience", StringComparison.OrdinalIgnoreCase) ? 10 : 15;
            QueueUrgentFaderRefresh(name, mask);
        }

        public static void RequestHardwareRefresh(string preferredName, string mode, int position, long requestId, long mappingGeneration, bool mappingConfident) {
            int mask = String.Equals(mode, "All", StringComparison.OrdinalIgnoreCase)
                ? 5
                : String.Equals(mode, "Audience", StringComparison.OrdinalIgnoreCase) ? 10 : 0;
            if (mask == 0) return;
            EnqueueHardwareRefresh(new HardwareRefreshRequest {
                PreferredName = preferredName ?? String.Empty,
                OutputCandidateName = String.Empty,
                Mask = mask,
                Position = position,
                RequestId = requestId,
                MappingGeneration = mappingGeneration,
                MappingConfident = mappingConfident,
                Attempt = 0,
                FallbackIndex = -1,
                // Let BEACN finish applying the USB action before reading its row.
                NotBeforeUtc = DateTime.UtcNow.AddMilliseconds(30)
            });
            Interlocked.Exchange(ref actionRefreshRequested, 1);
        }

        private static void EnqueueHardwareRefresh(HardwareRefreshRequest request) {
            pendingHardwareRefreshes.Enqueue(request);
            int count = Interlocked.Increment(ref pendingHardwareRefreshCount);
            while (count > MaximumPendingHardwareRefreshes) {
                HardwareRefreshRequest discarded;
                if (!pendingHardwareRefreshes.TryDequeue(out discarded)) break;
                Interlocked.Decrement(ref pendingHardwareRefreshCount);
                count = Volatile.Read(ref pendingHardwareRefreshCount);
            }
        }

        private static bool TryDequeueHardwareRefresh(out HardwareRefreshRequest request) {
            if (!pendingHardwareRefreshes.TryDequeue(out request)) return false;
            Interlocked.Decrement(ref pendingHardwareRefreshCount);
            return true;
        }

        private static void PublishHardwareResult(HardwareRefreshRequest request, string changedName) {
            lastHardwareChangedName = changedName ?? String.Empty;
            lastHardwarePreferredName = request.PreferredName ?? String.Empty;
            lastHardwareChangedMode = (request.Mask & 1) != 0 ? "All" : "Audience";
            lastHardwarePosition = request.Position;
            Interlocked.Exchange(ref lastHardwareRequestId, request.RequestId);
            Interlocked.Exchange(ref lastHardwareMappingGeneration, request.MappingGeneration);
            Interlocked.Increment(ref hardwareResultSequence);
        }

        private static void CommitHardwareCompletion(HardwareRefreshCompletion completion) {
            if (completion == null || completion.Request == null) return;
            PublishHardwareResult(completion.Request, completion.ChangedName);
            if (!String.IsNullOrWhiteSpace(completion.ChangedName)) {
                QueueFaderRefresh(completion.ChangedName, completion.Request.Mask);
            }
        }

        private static void RequeueHardwareCompletion(HardwareRefreshCompletion completion) {
            if (completion == null || completion.Request == null) return;
            completion.Request.NotBeforeUtc = DateTime.UtcNow.AddMilliseconds(40);
            EnqueueHardwareRefresh(completion.Request);
            Interlocked.Exchange(ref actionRefreshRequested, 1);
        }

        public static void RequestRenderedFaderRefresh(string name, string mode) {
            if (String.IsNullOrWhiteSpace(name)) return;
            int mask = String.Equals(mode, "All", StringComparison.OrdinalIgnoreCase)
                ? 5
                : String.Equals(mode, "Audience", StringComparison.OrdinalIgnoreCase) ? 10 : 15;
            QueueFaderRefresh(name, mask);
        }

        public static void RequestDiscoveryThenRenderedRefresh(string name, string mode) {
            if (String.IsNullOrWhiteSpace(name)) return;
            int mask = String.Equals(mode, "All", StringComparison.OrdinalIgnoreCase)
                ? 5
                : String.Equals(mode, "Audience", StringComparison.OrdinalIgnoreCase) ? 10 : 15;
            postDiscoveryRefreshes.AddOrUpdate(name, mask, delegate(string key, int current) {
                return current | mask;
            });
            RequestDiscovery();
        }

        private static void QueueFaderRefresh(string name, int mask) {
            pendingActionRefreshes.AddOrUpdate(name, mask, delegate(string key, int current) {
                return current | mask;
            });
            Interlocked.Exchange(ref actionRefreshRequested, 1);
        }

        private static void QueueUrgentFaderRefresh(string name, int mask) {
            int ordinaryMask;
            if (pendingActionRefreshes.TryRemove(name, out ordinaryMask)) mask |= ordinaryMask;
            pendingUrgentActionRefreshes.AddOrUpdate(name, mask, delegate(string key, int current) {
                return current | mask;
            });
            Interlocked.Exchange(ref actionRefreshRequested, 1);
        }

        public static BeacnActionTarget ResolveCachedActionAtPoint(double screenX, double screenY) {
            Point point = new Point(screenX, screenY);
            BeacnActionTarget best = null;
            double bestArea = Double.MaxValue;
            lock (geometryGate) {
                foreach (TrackedFader fader in trackedFaders) {
                    if (fader == null) continue;
                    ResolveCachedActionCandidate(fader, "All", point, ref best, ref bestArea);
                    ResolveCachedActionCandidate(fader, "Audience", point, ref best, ref bestArea);
                }
            }
            return best;
        }

        public static BeacnActionTarget ResolveActionAtPoint(double screenX, double screenY) {
            Point point = new Point(screenX, screenY);
            int hitProcessId;
            try {
                AutomationElement hit = AutomationElement.FromPoint(point);
                hitProcessId = hit == null ? 0 : hit.Current.ProcessId;
            } catch {
                return null;
            }
            if (hitProcessId <= 0) return null;

            BeacnActionTarget best = null;
            double bestArea = Double.MaxValue;
            foreach (TrackedFader fader in trackedFaders) {
                if (fader == null || fader.ProcessId != hitProcessId) continue;
                ResolveActionCandidate(fader, "All", point, ref best, ref bestArea);
                ResolveActionCandidate(fader, "Audience", point, ref best, ref bestArea);
            }
            return best;
        }

        private static void ResolveCachedActionCandidate(
            TrackedFader fader,
            string mode,
            Point point,
            ref BeacnActionTarget best,
            ref double bestArea
        ) {
            bool all = String.Equals(mode, "All", StringComparison.OrdinalIgnoreCase);
            Rect labelBounds = all ? fader.AllActionBounds : fader.AudienceActionBounds;
            Rect rowBounds = all ? fader.AllActionRowBounds : fader.AudienceActionRowBounds;
            Rect probeBounds = all ? fader.AllActionProbeBounds : fader.AudienceActionProbeBounds;
            if (labelBounds.IsEmpty) return;

            Rect targetBounds = labelBounds;
            if (IsAdjacentActionBounds(labelBounds, probeBounds)) targetBounds.Union(probeBounds);
            if (IsBoundedActionRow(rowBounds, labelBounds)) targetBounds = rowBounds;
            targetBounds.Inflate(6, 5);
            if (!targetBounds.Contains(point)) return;

            double area = Math.Max(1.0, targetBounds.Width * targetBounds.Height);
            if (area >= bestArea) return;
            bestArea = area;
            best = new BeacnActionTarget { Name = fader.Name, Mode = mode };
        }

        public static bool IsTrackedBeacnPoint(double screenX, double screenY) {
            int hitProcessId;
            try {
                AutomationElement hit = AutomationElement.FromPoint(new Point(screenX, screenY));
                hitProcessId = hit == null ? 0 : hit.Current.ProcessId;
            } catch {
                return false;
            }
            if (hitProcessId <= 0) return false;
            foreach (TrackedFader fader in trackedFaders) {
                if (fader != null && fader.ProcessId == hitProcessId) return true;
            }
            return false;
        }

        public static string[] ValidateTargetsAfterWindowMove(int requestedDeltaX, int requestedDeltaY) {
            List<string> results = new List<string>();
            HashSet<int> processIds = new HashSet<int>();
            foreach (TrackedFader fader in trackedFaders) {
                if (fader != null && fader.ProcessId > 0) processIds.Add(fader.ProcessId);
            }
            List<AutomationElement> windows = FindVisibleBeacnWindows(processIds);
            if (windows.Count == 0) return new string[] { "MOVE|error=window-not-found" };

            int nativeHandle;
            try { nativeHandle = windows[0].Current.NativeWindowHandle; }
            catch { nativeHandle = 0; }
            if (nativeHandle == 0) return new string[] { "MOVE|error=window-handle-unavailable" };

            IntPtr window = new IntPtr(nativeHandle);
            NativeRect original;
            if (!GetWindowRect(window, out original)) return new string[] { "MOVE|error=window-bounds-unavailable" };

            const uint noSize = 0x0001;
            const uint noZOrder = 0x0004;
            const uint noActivate = 0x0010;
            bool moved = false;
            try {
                moved = SetWindowPos(
                    window,
                    IntPtr.Zero,
                    original.Left + requestedDeltaX,
                    original.Top + requestedDeltaY,
                    0,
                    0,
                    noSize | noZOrder | noActivate
                );
                if (!moved) return new string[] { "MOVE|error=set-window-position-failed" };
                Thread.Sleep(300);

                NativeRect current;
                if (!GetWindowRect(window, out current)) return new string[] { "MOVE|error=moved-bounds-unavailable" };
                int actualDeltaX = current.Left - original.Left;
                int actualDeltaY = current.Top - original.Top;
                results.Add(String.Format("MOVE|deltaX={0}|deltaY={1}", actualDeltaX, actualDeltaY));

                foreach (TrackedFader fader in trackedFaders) {
                    ValidateMovedTarget(fader, "All", fader.AllActionBounds, actualDeltaX, actualDeltaY, results);
                    ValidateMovedTarget(fader, "Audience", fader.AudienceActionBounds, actualDeltaX, actualDeltaY, results);
                }
            } finally {
                if (moved) {
                    SetWindowPos(
                        window,
                        IntPtr.Zero,
                        original.Left,
                        original.Top,
                        0,
                        0,
                        noSize | noZOrder | noActivate
                    );
                    Thread.Sleep(300);
                }
            }
            return results.ToArray();
        }

        private static void ValidateMovedTarget(
            TrackedFader fader,
            string mode,
            Rect originalBounds,
            int deltaX,
            int deltaY,
            List<string> results
        ) {
            if (fader == null || originalBounds.IsEmpty) {
                results.Add(String.Format("MOVE_TARGET|expected={0}/{1}|actual=missing-bounds", fader == null ? "" : fader.Name, mode));
                return;
            }
            double x = ((originalBounds.Left + originalBounds.Right) / 2.0) + deltaX;
            double y = ((originalBounds.Top + originalBounds.Bottom) / 2.0) + deltaY;
            BeacnActionTarget actual = ResolveActionAtPoint(x, y);
            results.Add(String.Format(
                "MOVE_TARGET|expected={0}/{1}|actual={2}/{3}",
                fader.Name,
                mode,
                actual == null ? "" : actual.Name,
                actual == null ? "" : actual.Mode
            ));
        }

        private static void ResolveActionCandidate(
            TrackedFader fader,
            string mode,
            Point point,
            ref BeacnActionTarget best,
            ref double bestArea
        ) {
            AutomationElement label = String.Equals(mode, "All", StringComparison.OrdinalIgnoreCase)
                ? fader.AllActionLabel
                : fader.AudienceActionLabel;
            if (label == null) return;

            Rect labelBounds;
            int processId;
            try {
                AutomationElement.AutomationElementInformation info = label.Current;
                bool expectedLabel = String.Equals(mode, "All", StringComparison.OrdinalIgnoreCase)
                    ? IsAllActionLabel(info.Name)
                    : IsAudienceActionLabel(info.Name);
                if (!expectedLabel) return;
                labelBounds = info.BoundingRectangle;
                processId = info.ProcessId;
            } catch {
                return;
            }
            if (processId != fader.ProcessId || labelBounds.IsEmpty) return;

            AutomationElement container = String.Equals(mode, "All", StringComparison.OrdinalIgnoreCase)
                ? fader.AllActionContainer
                : fader.AudienceActionContainer;
            if (!IsLiveElement(container)) container = FindActionRowContainer(label);
            Rect rowBounds = IsLiveElement(container) ? GetElementBounds(container) : Rect.Empty;
            Rect previousLabelBounds = String.Equals(mode, "All", StringComparison.OrdinalIgnoreCase)
                ? fader.AllActionBounds
                : fader.AudienceActionBounds;
            Rect previousProbeBounds = String.Equals(mode, "All", StringComparison.OrdinalIgnoreCase)
                ? fader.AllActionProbeBounds
                : fader.AudienceActionProbeBounds;
            AutomationElement menuButton = String.Equals(mode, "All", StringComparison.OrdinalIgnoreCase)
                ? fader.AllActionMenuButton
                : fader.AudienceActionMenuButton;

            // JUCE can expose the whole fader panel as the nearest common ancestor.
            // Such a rectangle overlaps every action and cannot identify a click.
            // Prefer a genuinely bounded row; otherwise use the live named label
            // plus the adjacent menu/status-button area for this exact action.
            Rect targetBounds = labelBounds;
            Rect menuBounds = IsLiveElement(menuButton) ? GetElementBounds(menuButton) : Rect.Empty;
            if (!IsAdjacentActionBounds(labelBounds, menuBounds) &&
                !previousLabelBounds.IsEmpty && !previousProbeBounds.IsEmpty) {
                double deltaX = labelBounds.Left - previousLabelBounds.Left;
                double deltaY = labelBounds.Top - previousLabelBounds.Top;
                menuBounds = new Rect(
                    previousProbeBounds.Left + deltaX,
                    previousProbeBounds.Top + deltaY,
                    previousProbeBounds.Width,
                    previousProbeBounds.Height
                );
            }
            if (IsAdjacentActionBounds(labelBounds, menuBounds)) targetBounds.Union(menuBounds);
            if (IsBoundedActionRow(rowBounds, labelBounds)) targetBounds = rowBounds;
            targetBounds.Inflate(6, 5);
            if (!targetBounds.Contains(point)) return;

            if (String.Equals(mode, "All", StringComparison.OrdinalIgnoreCase)) {
                fader.AllActionBounds = labelBounds;
                fader.AllActionRowBounds = rowBounds;
                fader.AllActionContainer = container;
                if (!menuBounds.IsEmpty) fader.AllActionProbeBounds = menuBounds;
            } else {
                fader.AudienceActionBounds = labelBounds;
                fader.AudienceActionRowBounds = rowBounds;
                fader.AudienceActionContainer = container;
                if (!menuBounds.IsEmpty) fader.AudienceActionProbeBounds = menuBounds;
            }

            double area = Math.Max(1.0, targetBounds.Width * targetBounds.Height);
            if (area >= bestArea) return;
            bestArea = area;
            best = new BeacnActionTarget { Name = fader.Name, Mode = mode };
        }

        private static bool IsBoundedActionRow(Rect rowBounds, Rect labelBounds) {
            if (
                rowBounds.IsEmpty || labelBounds.IsEmpty ||
                rowBounds.Height <= 0 || rowBounds.Height > 56 ||
                rowBounds.Width <= 0 || rowBounds.Width > 280
            ) return false;
            Point labelCenter = new Point(
                (labelBounds.Left + labelBounds.Right) / 2.0,
                (labelBounds.Top + labelBounds.Bottom) / 2.0
            );
            return rowBounds.Contains(labelCenter);
        }

        private static bool IsAdjacentActionBounds(Rect labelBounds, Rect candidateBounds) {
            if (labelBounds.IsEmpty || candidateBounds.IsEmpty) return false;
            double labelCenterY = (labelBounds.Top + labelBounds.Bottom) / 2.0;
            double candidateCenterY = (candidateBounds.Top + candidateBounds.Bottom) / 2.0;
            return Math.Abs(labelCenterY - candidateCenterY) <= 14 &&
                candidateBounds.Left <= labelBounds.Right + 90 &&
                candidateBounds.Right >= labelBounds.Left - 8;
        }

        public static Task<BeacnFaderState[]> ScanAsync() {
            return Task.Factory.StartNew<BeacnFaderState[]>(Scan);
        }

        private static List<TrackedFaderStateCheckpoint> CaptureTrackedFaderState() {
            List<TrackedFaderStateCheckpoint> checkpoints = new List<TrackedFaderStateCheckpoint>();
            foreach (TrackedFader fader in trackedFaders) {
                if (fader == null) continue;
                checkpoints.Add(new TrackedFaderStateCheckpoint {
                    Fader = fader,
                    AllActionContainer = fader.AllActionContainer,
                    AllActionMenuButton = fader.AllActionMenuButton,
                    AudienceActionContainer = fader.AudienceActionContainer,
                    AudienceActionMenuButton = fader.AudienceActionMenuButton,
                    AllActionSeen = fader.AllActionSeen,
                    AllActionMenuButtonSeen = fader.AllActionMenuButtonSeen,
                    AudienceActionSeen = fader.AudienceActionSeen,
                    AudienceActionMenuButtonSeen = fader.AudienceActionMenuButtonSeen,
                    AllVerifiedUtc = fader.AllVerifiedUtc,
                    AudienceVerifiedUtc = fader.AudienceVerifiedUtc,
                    PersonalMuted = fader.PersonalMuted,
                    AudienceMuted = fader.AudienceMuted,
                    IsLocked = fader.IsLocked
                });
            }
            return checkpoints;
        }

        private static void RestoreTrackedFaderState(List<TrackedFaderStateCheckpoint> checkpoints) {
            if (checkpoints == null) return;
            foreach (TrackedFaderStateCheckpoint checkpoint in checkpoints) {
                TrackedFader fader = checkpoint.Fader;
                if (fader == null) continue;
                fader.AllActionContainer = checkpoint.AllActionContainer;
                fader.AllActionMenuButton = checkpoint.AllActionMenuButton;
                fader.AudienceActionContainer = checkpoint.AudienceActionContainer;
                fader.AudienceActionMenuButton = checkpoint.AudienceActionMenuButton;
                fader.AllActionSeen = checkpoint.AllActionSeen;
                fader.AllActionMenuButtonSeen = checkpoint.AllActionMenuButtonSeen;
                fader.AudienceActionSeen = checkpoint.AudienceActionSeen;
                fader.AudienceActionMenuButtonSeen = checkpoint.AudienceActionMenuButtonSeen;
                fader.AllVerifiedUtc = checkpoint.AllVerifiedUtc;
                fader.AudienceVerifiedUtc = checkpoint.AudienceVerifiedUtc;
                fader.PersonalMuted = checkpoint.PersonalMuted;
                fader.AudienceMuted = checkpoint.AudienceMuted;
                fader.IsLocked = checkpoint.IsLocked;
            }
            pendingActionRefreshes.Clear();
            Interlocked.Exchange(ref actionRefreshRequested, 0);
        }

        private static BeacnFaderState[] Scan() {
            Stopwatch timer = Stopwatch.StartNew();
            HardwareRefreshCompletion hardwareCompletion = null;
            bool hardwareCompletionHandled = false;
            try {
                DateTime now = DateTime.UtcNow;
                ObserveNativeWindowGeometry(now);
                long scanGeometryGeneration = Interlocked.Read(ref nativeGeometryGeneration);
                List<TrackedFaderStateCheckpoint> stateCheckpoint = CaptureTrackedFaderState();
                bool geometrySettling = IsWindowGeometrySettling(now);
                bool refreshGeometry = Interlocked.Exchange(ref geometryRefreshRequested, 0) != 0;
                if (refreshGeometry) Interlocked.Exchange(ref geometryRefreshIndex, 0);
                if (!geometrySettling && Volatile.Read(ref geometryRefreshIndex) >= 0) RefreshNextTrackedGeometry();
                if (!geometrySettling) PromotePossibleLayoutChange(now);
                bool forceDiscovery = !geometrySettling && Interlocked.Exchange(ref discoveryRequested, 0) != 0;
                if (
                    !geometrySettling &&
                    (!postDiscoveryUrgentRefreshes.IsEmpty || !postDiscoveryRefreshes.IsEmpty)
                ) forceDiscovery = true;
                bool refreshRequested = !geometrySettling && Interlocked.Exchange(ref actionRefreshRequested, 0) != 0;
                List<TrackedFader> currentFaders = trackedFaders;
                if (!geometrySettling && currentFaders.Count > 0 && (now - lastLivenessCheck).TotalSeconds >= 2) {
                    lastLivenessCheck = now;
                    lastLivenessResult = IsLiveElement(currentFaders[0].PersonalButton);
                    if (!lastLivenessResult) {
                        lastCompatibilityStatus = "Reconnecting";
                        lastCompatibilityDetail = "The cached BEACN controls expired; rebuilding the layout.";
                        forceDiscovery = true;
                    }
                }
                if (!geometrySettling && (forceDiscovery || trackedFaders.Count == 0)) StartDiscovery(forceDiscovery);

                // The lower action rows change independently from the comparatively
                // stable fader layout. Refresh only their small accessibility subset
                // on every monitor cycle instead of waiting for full rediscovery.
                if (!geometrySettling && trackedFaders.Count > 0) {
                    HardwareRefreshRequest hardwareRequest;
                    bool hardwareRefreshDequeued = TryDequeueHardwareRefresh(out hardwareRequest);
                    if (hardwareRefreshDequeued) {
                        if (hardwareRequest.NotBeforeUtc > now) {
                            EnqueueHardwareRefresh(hardwareRequest);
                            Interlocked.Exchange(ref actionRefreshRequested, 1);
                            // A delayed hardware retry must not occupy the lane while
                            // an exact-name keyboard request is ready right now.
                            hardwareRefreshDequeued = false;
                        } else {
                            hardwareCompletion = RefreshHardwareActionState(hardwareRequest);
                        }
                    }

                    bool urgentRefresh = false;
                    Dictionary<string, int> requested = new Dictionary<string, int>(StringComparer.OrdinalIgnoreCase);
                    if (!hardwareRefreshDequeued) {
                        requested = DrainActionRefreshes(pendingUrgentActionRefreshes, MaximumFaderRefreshesPerScan);
                        urgentRefresh = requested.Count > 0;
                        if (!urgentRefresh) {
                            requested = DrainActionRefreshes(pendingActionRefreshes, MaximumFaderRefreshesPerScan);
                        }
                    }
                    if (requested.Count > 0) {
                        if (!RefreshActionStates(requested, urgentRefresh)) RequestDiscovery();
                    } else if (
                        !hardwareRefreshDequeued &&
                        (now - lastSafetySweep).TotalMilliseconds >= Math.Max(
                            SafetySweepCadenceMilliseconds,
                            Math.Min(
                                MaximumSafetySweepCadenceMilliseconds,
                                lastSafetySweepDurationMilliseconds * SafetySweepCostMultiplier
                            )
                        )
                    ) {
                        // Accessibility providers can occasionally miss a property event. Refresh
                        // only the stalest fader and only after its authority lease has aged out.
                        // This gives every fader a bounded reconciliation window without repeatedly
                        // traversing the entire JUCE tree.
                        TrackedFader stalest = null;
                        DateTime stalestVerified = DateTime.MaxValue;
                        foreach (TrackedFader candidate in trackedFaders) {
                            DateTime verified = candidate.AllVerifiedUtc < candidate.AudienceVerifiedUtc
                                ? candidate.AllVerifiedUtc
                                : candidate.AudienceVerifiedUtc;
                            if (verified < stalestVerified) {
                                stalest = candidate;
                                stalestVerified = verified;
                            }
                        }
                        if (
                            stalest != null &&
                            (stalestVerified == DateTime.MinValue || (now - stalestVerified).TotalSeconds >= MaximumActionStateAgeSeconds)
                        ) {
                            Stopwatch safetyTimer = Stopwatch.StartNew();
                            Dictionary<string, int> one = new Dictionary<string, int>(StringComparer.OrdinalIgnoreCase);
                            // Prefer the fast rendered hit-test for both rows. Hidden
                            // or occluded rows still fall back to the same subtree read.
                            one[stalest.Name] = 15;
                            if (!RefreshActionStates(one, false)) RequestDiscovery();
                            safetyTimer.Stop();
                            lastSafetySweepDurationMilliseconds = safetyTimer.Elapsed.TotalMilliseconds;
                        }
                        lastSafetySweep = now;
                    } else if (refreshRequested) {
                        lastActionRefresh = now;
                    }
                } else if (!geometrySettling) {
                    // A shortcut can arrive before the first BEACN layout is ready.
                    // Drain it into the same one-generation retention path instead of
                    // leaving the worker in a permanently hot polling loop.
                    bool urgentRefresh = false;
                    Dictionary<string, int> requested =
                        DrainActionRefreshes(pendingUrgentActionRefreshes, MaximumFaderRefreshesPerScan);
                    urgentRefresh = requested.Count > 0;
                    if (!urgentRefresh) {
                        requested = DrainActionRefreshes(pendingActionRefreshes, MaximumFaderRefreshesPerScan);
                    }
                    if (requested.Count > 0) {
                        if (!RefreshActionStates(requested, urgentRefresh)) RequestDiscovery();
                    } else if (refreshRequested) {
                        lastActionRefresh = now;
                    }
                }

                ObserveNativeWindowGeometry(DateTime.UtcNow);
                if (Interlocked.Read(ref nativeGeometryGeneration) != scanGeometryGeneration) {
                    RestoreTrackedFaderState(stateCheckpoint);
                    if (hardwareCompletion != null) {
                        RequeueHardwareCompletion(hardwareCompletion);
                        hardwareCompletionHandled = true;
                    }
                    lastActionEventSummary = DateTime.Now.ToString("HH:mm:ss.fff") +
                        " discarded state read across window movement";
                }

                BeacnFaderState[] result;
                if (TryReadTrackedFaders(out result)) {
                    if (hardwareCompletion != null && !hardwareCompletionHandled) {
                        CommitHardwareCompletion(hardwareCompletion);
                        hardwareCompletionHandled = true;
                    }
                    return result;
                }
                if (hardwareCompletion != null && !hardwareCompletionHandled) {
                    RequeueHardwareCompletion(hardwareCompletion);
                    hardwareCompletionHandled = true;
                }

                // Never put JUCE's multi-second full-tree query on the response path.
                // Startup and an explicit Faders-settings refresh own discovery.
            } catch (Exception ex) {
                if (hardwareCompletion != null && !hardwareCompletionHandled) {
                    RequeueHardwareCompletion(hardwareCompletion);
                    hardwareCompletionHandled = true;
                }
                lastDiagnostic = "scan error: " + ex.GetType().Name + ": " + ex.Message;
            } finally {
                timer.Stop();
                lastScanMilliseconds = timer.Elapsed.TotalMilliseconds;
            }
            return new BeacnFaderState[0];
        }

        private static void PromotePossibleLayoutChange(DateTime now) {
            long possibleTicks = Interlocked.Read(ref possibleLayoutChangeUtcTicks);
            if (possibleTicks <= 0) return;
            DateTime possibleAt = new DateTime(possibleTicks, DateTimeKind.Utc);
            if ((now - possibleAt).TotalMilliseconds < 350) return;
            if (Interlocked.CompareExchange(ref possibleLayoutChangeUtcTicks, 0, possibleTicks) != possibleTicks) return;

            // Row-specific events mark ordinary mute redraws. A root-only change
            // after the quiet period represents an add/remove/reorder/page layout
            // mutation and is safe to rediscover off the response path.
            long actionTicks = Interlocked.Read(ref lastActionEventUtcTicks);
            if (actionTicks < possibleTicks) RequestDiscovery();
        }

        private static void StartDiscovery(bool force) {
            lock (discoveryGate) {
                if (discoveryTask != null && !discoveryTask.IsCompleted) return;
                DateTime now = DateTime.UtcNow;
                if (!force && (now - lastDiscoveryStarted).TotalSeconds < 2) return;
                lastDiscoveryStarted = now;
                discoveryTask = Task.Factory.StartNew(DiscoverFaders);
                discoveryTask.ContinueWith(delegate(Task failedTask) {
                    Exception error = failedTask.Exception == null
                        ? null
                        : failedTask.Exception.GetBaseException();
                    lastCompatibilityStatus = "Unavailable";
                    lastCompatibilityDetail = error == null
                        ? "BEACN layout discovery failed."
                        : "BEACN layout discovery failed: " + error.GetType().Name;
                    lastDiagnostic = lastCompatibilityDetail;
                }, TaskContinuationOptions.OnlyOnFaulted);
            }
        }

        private static void DiscoverFaders() {
            ObserveNativeWindowGeometry(DateTime.UtcNow);
            long discoveryGeometryGeneration = Interlocked.Read(ref nativeGeometryGeneration);
            Dictionary<string, TrackedFader> discovered = new Dictionary<string, TrackedFader>(StringComparer.OrdinalIgnoreCase);
            Process[] processes = Process.GetProcessesByName("BEACN");
            int processCount = processes.Length;
            int windowCount = 0;
            int elementCount = 0;
            int detectedNameCount = 0;
            int structuralNameCount = 0;
            int outputButtonCount = 0;
            double windowLeft = Double.NaN;
            double lockedRegionRight = Double.NaN;
            double horizontalScrollWidth = 0;
            string detectedBeacnVersion = String.Empty;
            IntPtr discoveryWindowHandle = IntPtr.Zero;
            Rect discoveryWindowBounds = Rect.Empty;

            HashSet<int> processIds = new HashSet<int>();
            foreach (Process process in processes) {
                processIds.Add(process.Id);
                if (String.IsNullOrWhiteSpace(detectedBeacnVersion)) {
                    try { detectedBeacnVersion = process.MainModule.FileVersionInfo.FileVersion ?? String.Empty; }
                    catch { }
                }
            }
            lastBeacnVersion = detectedBeacnVersion;
            List<AutomationElement> windows = FindVisibleBeacnWindows(processIds);
            windowCount = windows.Count;
            if (windows.Count > 0) {
                try { discoveryWindowHandle = new IntPtr(windows[0].Current.NativeWindowHandle); } catch { }
                discoveryWindowBounds = GetNativeWindowBounds(discoveryWindowHandle);
            }
            for (int windowIndex = 0; windowIndex < windows.Count; windowIndex++) {
                try {
                        Rect windowBounds = windows[windowIndex].Current.BoundingRectangle;
                        if (!windowBounds.IsEmpty) windowLeft = windowBounds.Left;
                        lastDiagnostic = String.Format("discover: reading window {0}/{1}", windowIndex + 1, windows.Count);
                        // JUCE handles a bulk unfiltered snapshot far more efficiently
                        // than a filtered provider-side query. This runs only for the
                        // infrequent layout discovery path; action refreshes use the
                        // cached row controls below.
                        CacheRequest cacheRequest = new CacheRequest();
                        cacheRequest.Add(AutomationElement.NameProperty);
                        cacheRequest.Add(AutomationElement.ControlTypeProperty);
                        cacheRequest.Add(AutomationElement.AutomationIdProperty);
                        cacheRequest.Add(AutomationElement.ProcessIdProperty);
                        cacheRequest.Add(AutomationElement.BoundingRectangleProperty);
                        AutomationElementCollection elements;
                        using (cacheRequest.Activate()) {
                            elements = windows[windowIndex].FindAll(
                                TreeScope.Descendants,
                                Condition.TrueCondition
                            );
                        }
                        lastDiagnostic = String.Format("discover: parsing {0} elements", elements.Count);
                        elementCount += elements.Count;
                        string currentFaderName = null;
                        string currentAction = null;
                        List<TextCandidate> recentTexts = new List<TextCandidate>();
                        for (int index = 0; index < elements.Count; index++) {
                            AutomationElement element = elements[index];
                            AutomationElement.AutomationElementInformation info;
                            try { info = element.Cached; } catch { continue; }

                            if (
                                info.ControlType == ControlType.ScrollBar &&
                                !info.BoundingRectangle.IsEmpty &&
                                info.BoundingRectangle.Width > 120 &&
                                info.BoundingRectangle.Height > 0 &&
                                info.BoundingRectangle.Height <= 30 &&
                                info.BoundingRectangle.Width > horizontalScrollWidth
                            ) {
                                horizontalScrollWidth = info.BoundingRectangle.Width;
                                lockedRegionRight = info.BoundingRectangle.Left;
                            }

                            if (info.ControlType == ControlType.Text) {
                                string text = (info.Name ?? String.Empty).Trim();
                                if (IsAllActionLabel(text)) {
                                    TextCandidate structuralHeader = FindHeaderCandidate(recentTexts, info.BoundingRectangle);
                                    bool configuredCurrent = IsConfiguredFaderName(currentFaderName);
                                    bool configuredStructural = structuralHeader != null && IsConfiguredFaderName(structuralHeader.Name);
                                    if (structuralHeader != null && (!configuredCurrent || configuredStructural)) {
                                        if (!IsConfiguredFaderName(structuralHeader.Name)) structuralNameCount++;
                                        currentFaderName = structuralHeader.Name;
                                        TrackedFader structuralFader = GetOrCreateFader(
                                            discovered,
                                            structuralHeader.Name,
                                            structuralHeader.ProcessId,
                                            structuralHeader.Bounds,
                                            ref detectedNameCount
                                        );
                                        structuralFader.AllActionLabel = element;
                                        structuralFader.AllActionContainer = FindActionRowContainer(element);
                                        structuralFader.AllActionBounds = info.BoundingRectangle;
                                        structuralFader.AllActionRowBounds = GetElementBounds(structuralFader.AllActionContainer);
                                        structuralFader.AllActionSeen = true;
                                        currentAction = "All";
                                    } else {
                                        TrackedFader configuredFader;
                                        if (
                                            !String.IsNullOrWhiteSpace(currentFaderName) &&
                                            discovered.TryGetValue(currentFaderName, out configuredFader)
                                        ) {
                                            configuredFader.AllActionLabel = element;
                                            configuredFader.AllActionContainer = FindActionRowContainer(element);
                                            configuredFader.AllActionBounds = info.BoundingRectangle;
                                            configuredFader.AllActionRowBounds = GetElementBounds(configuredFader.AllActionContainer);
                                            configuredFader.AllActionSeen = true;
                                            currentAction = "All";
                                        }
                                    }
                                    continue;
                                }
                                if (IsAudienceActionLabel(text)) {
                                    TrackedFader actionFader;
                                    if (!String.IsNullOrWhiteSpace(currentFaderName) && discovered.TryGetValue(currentFaderName, out actionFader)) {
                                        actionFader.AudienceActionLabel = element;
                                        actionFader.AudienceActionContainer = FindActionRowContainer(element);
                                        actionFader.AudienceActionBounds = info.BoundingRectangle;
                                        actionFader.AudienceActionRowBounds = GetElementBounds(actionFader.AudienceActionContainer);
                                        actionFader.AudienceActionSeen = true;
                                        currentAction = "Audience";
                                    }
                                    continue;
                                }

                                if (!String.IsNullOrWhiteSpace(text)) {
                                    recentTexts.Add(new TextCandidate {
                                        Name = text,
                                        ProcessId = info.ProcessId,
                                        Bounds = info.BoundingRectangle
                                    });
                                    if (recentTexts.Count > 24) recentTexts.RemoveAt(0);
                                    if (IsConfiguredFaderName(text)) {
                                        currentFaderName = text;
                                        currentAction = null;
                                        GetOrCreateFader(
                                            discovered,
                                            text,
                                            info.ProcessId,
                                            info.BoundingRectangle,
                                            ref detectedNameCount
                                        );
                                    }
                                }
                                continue;
                            }
                            if (String.IsNullOrWhiteSpace(currentFaderName) || info.ControlType != ControlType.Button) continue;

                            string automationId = info.AutomationId ?? String.Empty;
                            if (automationId.StartsWith("mutemenubutton", StringComparison.Ordinal)) {
                                TrackedFader actionFader;
                                if (!String.IsNullOrWhiteSpace(currentFaderName) && discovered.TryGetValue(currentFaderName, out actionFader)) {
                                    if (String.Equals(currentAction, "All", StringComparison.Ordinal)) {
                                        actionFader.AllActionMenuButton = element;
                                        actionFader.AllActionProbeBounds = info.BoundingRectangle;
                                        AutomationElement commonParent = FindCommonAncestor(actionFader.AllActionLabel, element);
                                        if (commonParent != null) {
                                            actionFader.AllActionContainer = commonParent;
                                            actionFader.AllActionRowBounds = GetElementBounds(commonParent);
                                        }
                                        actionFader.AllActionMenuButtonSeen = true;
                                    } else if (String.Equals(currentAction, "Audience", StringComparison.Ordinal)) {
                                        actionFader.AudienceActionMenuButton = element;
                                        actionFader.AudienceActionProbeBounds = info.BoundingRectangle;
                                        AutomationElement commonParent = FindCommonAncestor(actionFader.AudienceActionLabel, element);
                                        if (commonParent != null) {
                                            actionFader.AudienceActionContainer = commonParent;
                                            actionFader.AudienceActionRowBounds = GetElementBounds(commonParent);
                                        }
                                        actionFader.AudienceActionMenuButtonSeen = true;
                                    }
                                }
                                continue;
                            }
                            if (automationId.StartsWith("lockButton", StringComparison.Ordinal)) {
                                TrackedFader lockFader;
                                if (!discovered.TryGetValue(currentFaderName, out lockFader)) {
                                    lockFader = new TrackedFader { Name = currentFaderName };
                                    discovered[currentFaderName] = lockFader;
                                }
                                lockFader.LockButton = element;
                                continue;
                            }
                            bool isPersonal = automationId.StartsWith("headphonesMixToggleButton", StringComparison.Ordinal);
                            bool isAudience = automationId.StartsWith("broadcastMixToggleButton", StringComparison.Ordinal);
                            if (!isPersonal && !isAudience) continue;
                            outputButtonCount++;

                            TrackedFader fader;
                            if (!discovered.TryGetValue(currentFaderName, out fader)) {
                                fader = new TrackedFader { Name = currentFaderName };
                                discovered[currentFaderName] = fader;
                            }
                            if (isPersonal) fader.PersonalButton = element;
                            if (isAudience) fader.AudienceButton = element;
                        }
                } catch { }
            }

            List<TrackedFader> complete = new List<TrackedFader>();
            foreach (TrackedFader fader in discovered.Values) {
                if (fader.PersonalButton != null && fader.AudienceButton != null) {
                    bool currentValue;
                    if (TryGetToggleState(fader.PersonalButton, out currentValue)) {
                        fader.PersonalMuted = currentValue;
                    }
                    if (TryGetToggleState(fader.AudienceButton, out currentValue)) {
                        fader.AudienceMuted = currentValue;
                    }
                    Rect personalBounds = GetElementBounds(fader.PersonalButton);
                    if (
                        !Double.IsNaN(windowLeft) &&
                        !Double.IsNaN(lockedRegionRight) &&
                        !personalBounds.IsEmpty
                    ) {
                        double centerX = (personalBounds.Left + personalBounds.Right) / 2.0;
                        fader.IsLocked =
                            personalBounds.Left >= windowLeft &&
                            centerX < lockedRegionRight &&
                            IsRenderedFaderHeader(fader);
                    } else if (fader.LockButton != null && TryGetToggleState(fader.LockButton, out currentValue)) {
                        fader.IsLocked = currentValue;
                    }
                    complete.Add(fader);
                }
            }
            complete.Sort(delegate(TrackedFader left, TrackedFader right) {
                if (left.IsLocked != right.IsLocked) return left.IsLocked ? -1 : 1;
                if (left.IsLocked && right.IsLocked) {
                    try {
                        int position = left.PersonalButton.Current.BoundingRectangle.Left.CompareTo(
                            right.PersonalButton.Current.BoundingRectangle.Left
                        );
                        if (position != 0) return position;
                    } catch { }
                }
                int order = left.DiscoveryOrder.CompareTo(right.DiscoveryOrder);
                return order != 0 ? order : StringComparer.OrdinalIgnoreCase.Compare(left.Name, right.Name);
            });
            ObserveNativeWindowGeometry(DateTime.UtcNow);
            Rect finalDiscoveryWindowBounds = GetNativeWindowBounds(discoveryWindowHandle);
            bool discoveryWindowMoved =
                !discoveryWindowBounds.IsEmpty &&
                !finalDiscoveryWindowBounds.IsEmpty &&
                (
                    !AreClose(discoveryWindowBounds.Left, finalDiscoveryWindowBounds.Left) ||
                    !AreClose(discoveryWindowBounds.Top, finalDiscoveryWindowBounds.Top) ||
                    !AreClose(discoveryWindowBounds.Width, finalDiscoveryWindowBounds.Width) ||
                    !AreClose(discoveryWindowBounds.Height, finalDiscoveryWindowBounds.Height)
                );
            if (discoveryWindowMoved || Interlocked.Read(ref nativeGeometryGeneration) != discoveryGeometryGeneration) {
                lastDiagnostic = "discovery discarded across window movement";
                RequestDiscovery();
                return;
            }
            UnsubscribeFaderHandlers(trackedFaders);
            foreach (TrackedFader fader in complete) SubscribeFaderHandlers(fader);
            trackedFaders = complete;
            Interlocked.Exchange(ref geometryRefreshIndex, -1);
            SetSubscribedWindow(windows.Count > 0 ? windows[0] : null);
            lastDiscovery = DateTime.UtcNow;
            lastActionRefresh = lastDiscovery;
            lastSafetySweep = lastDiscovery;
            foreach (TrackedFader fader in complete) {
                fader.AllVerifiedUtc = lastDiscovery;
                fader.AudienceVerifiedUtc = lastDiscovery;
            }
            lastLivenessCheck = lastDiscovery;
            lastLivenessResult = complete.Count > 0;
            List<string> layoutParts = new List<string>();
            int completeActionRows = 0;
            foreach (TrackedFader fader in complete) {
                layoutParts.Add(fader.Name.Trim().ToLowerInvariant() + ":" + (fader.IsLocked ? "1" : "0"));
                if (fader.AllActionSeen && fader.AudienceActionSeen) completeActionRows++;
            }
            lastLayoutFingerprint = String.Join("|", layoutParts.ToArray());
            Interlocked.Increment(ref discoveryGeneration);
            if (processCount == 0) {
                lastBeacnVersion = String.Empty;
                lastCompatibilityStatus = "Unavailable";
                lastCompatibilityDetail = "The BEACN application is not running.";
            } else if (windowCount == 0) {
                lastCompatibilityStatus = "Unavailable";
                lastCompatibilityDetail = "The BEACN mixer window is not accessible.";
            } else if (complete.Count == 0) {
                lastCompatibilityStatus = "Incompatible";
                lastCompatibilityDetail = "No complete BEACN fader cards were discovered.";
            } else if (completeActionRows != complete.Count) {
                lastCompatibilityStatus = "Degraded";
                lastCompatibilityDetail = String.Format(
                    "Independent mute rows were readable for {0} of {1} faders.",
                    completeActionRows,
                    complete.Count
                );
            } else {
                lastCompatibilityStatus = "Ready";
                lastCompatibilityDetail = String.Format("{0} faders are structurally compatible.", complete.Count);
            }
            lastDiagnostic = String.Format(
                "processes={0}; windows={1}; elements={2}; names={3}; structuralNames={4}; outputButtons={5}; completeFaders={6}; compatibility={7}",
                processCount,
                windowCount,
                elementCount,
                detectedNameCount,
                structuralNameCount,
                outputButtonCount,
                complete.Count,
                lastCompatibilityStatus
            );
            Volatile.Write(ref structurallyDiscoveredNameCount, structuralNameCount);
            foreach (KeyValuePair<string, int> pair in postDiscoveryRefreshes) {
                int mask;
                if (postDiscoveryRefreshes.TryRemove(pair.Key, out mask)) QueueFaderRefresh(pair.Key, mask);
            }
            foreach (KeyValuePair<string, int> pair in postDiscoveryUrgentRefreshes) {
                int mask;
                if (postDiscoveryUrgentRefreshes.TryRemove(pair.Key, out mask)) QueueUrgentFaderRefresh(pair.Key, mask);
            }
        }

        private static bool IsConfiguredFaderName(string value) {
            if (String.IsNullOrWhiteSpace(value)) return false;
            lock (compatibilityGate) return configuredFaderNames.Contains(value.Trim());
        }

        private static bool IsAllActionLabel(string value) {
            if (String.IsNullOrWhiteSpace(value)) return false;
            lock (compatibilityGate) return allActionLabels.Contains(value.Trim());
        }

        private static bool IsAudienceActionLabel(string value) {
            if (String.IsNullOrWhiteSpace(value)) return false;
            lock (compatibilityGate) return audienceActionLabels.Contains(value.Trim());
        }

        private static TrackedFader GetOrCreateFader(
            Dictionary<string, TrackedFader> discovered,
            string name,
            int processId,
            Rect headerBounds,
            ref int detectedNameCount
        ) {
            TrackedFader fader;
            if (!discovered.TryGetValue(name, out fader)) {
                fader = new TrackedFader {
                    Name = name,
                    DiscoveryOrder = detectedNameCount,
                    ProcessId = processId,
                    HeaderBounds = headerBounds
                };
                discovered[name] = fader;
                detectedNameCount++;
            } else {
                fader.ProcessId = processId;
                if (!headerBounds.IsEmpty) fader.HeaderBounds = headerBounds;
            }
            return fader;
        }

        private static TextCandidate FindHeaderCandidate(List<TextCandidate> recentTexts, Rect actionBounds) {
            if (recentTexts == null || recentTexts.Count == 0) return null;
            TextCandidate best = null;
            double bestScore = Double.MaxValue;
            for (int index = recentTexts.Count - 1; index >= 0; index--) {
                TextCandidate candidate = recentTexts[index];
                string name = (candidate.Name ?? String.Empty).Trim();
                if (
                    String.IsNullOrWhiteSpace(name) ||
                    ignoredHeaderLabels.Contains(name) ||
                    IsAllActionLabel(name) ||
                    IsAudienceActionLabel(name) ||
                    Regex.IsMatch(name, @"^[\d\s%+\-.,:]+$")
                ) continue;

                Rect bounds = candidate.Bounds;
                if (bounds.IsEmpty || actionBounds.IsEmpty) continue;
                if (bounds.Bottom > actionBounds.Top + 6) continue;
                double verticalGap = actionBounds.Top - bounds.Bottom;
                if (verticalGap < -6 || verticalGap > 260) continue;
                double candidateCenter = (bounds.Left + bounds.Right) / 2.0;
                double actionCenter = (actionBounds.Left + actionBounds.Right) / 2.0;
                double horizontalGap = Math.Abs(candidateCenter - actionCenter);
                bool overlaps = bounds.Right >= actionBounds.Left - 40 && bounds.Left <= actionBounds.Right + 40;
                if (!overlaps && horizontalGap > 120) continue;

                double score = verticalGap + (horizontalGap * 0.25);
                if (IsConfiguredFaderName(name)) score -= 1000;
                if (score < bestScore) {
                    best = candidate;
                    bestScore = score;
                }
            }
            return best;
        }

        private static void SubscribeFaderHandlers(TrackedFader fader) {
            if (fader == null) return;
            try {
                if (fader.PersonalButton != null) {
                    fader.PersonalChangedHandler = delegate(object sender, AutomationPropertyChangedEventArgs args) {
                        MarkActionEvent("output " + fader.Name + "/All");
                        RequestFaderRefresh(fader.Name, "All");
                    };
                    Automation.AddAutomationPropertyChangedEventHandler(
                        fader.PersonalButton,
                        TreeScope.Element,
                        fader.PersonalChangedHandler,
                        TogglePattern.ToggleStateProperty
                    );
                }
            } catch { }
            try {
                if (fader.AudienceButton != null) {
                    fader.AudienceChangedHandler = delegate(object sender, AutomationPropertyChangedEventArgs args) {
                        MarkActionEvent("output " + fader.Name + "/Audience");
                        RequestFaderRefresh(fader.Name, "Audience");
                    };
                    Automation.AddAutomationPropertyChangedEventHandler(
                        fader.AudienceButton,
                        TreeScope.Element,
                        fader.AudienceChangedHandler,
                        TogglePattern.ToggleStateProperty
                    );
                }
            } catch { }
            try {
                if (fader.LockButton != null) {
                    fader.LockChangedHandler = delegate(object sender, AutomationPropertyChangedEventArgs args) {
                        lastActionEventSummary = DateTime.Now.ToString("HH:mm:ss.fff") + " layout " + fader.Name + "/Lock";
                        RequestDiscovery();
                    };
                    Automation.AddAutomationPropertyChangedEventHandler(
                        fader.LockButton,
                        TreeScope.Element,
                        fader.LockChangedHandler,
                        TogglePattern.ToggleStateProperty
                    );
                }
            } catch { }
            try {
                if (fader.AllActionContainer != null) {
                    fader.AllStructureChangedHandler = delegate(object sender, StructureChangedEventArgs args) {
                        if (IsWindowGeometrySettling(DateTime.UtcNow)) {
                            lastActionEventSummary = DateTime.Now.ToString("HH:mm:ss.fff") +
                                " row " + fader.Name + "/All geometry settling";
                            return;
                        }
                        MarkActionEvent("row " + fader.Name + "/All " + args.StructureChangeType.ToString());
                        RequestFaderRefresh(fader.Name, "All");
                    };
                    Automation.AddStructureChangedEventHandler(
                        fader.AllActionContainer,
                        TreeScope.Subtree,
                        fader.AllStructureChangedHandler
                    );
                }
            } catch { }
            try {
                if (fader.AudienceActionContainer != null) {
                    fader.AudienceStructureChangedHandler = delegate(object sender, StructureChangedEventArgs args) {
                        if (IsWindowGeometrySettling(DateTime.UtcNow)) {
                            lastActionEventSummary = DateTime.Now.ToString("HH:mm:ss.fff") +
                                " row " + fader.Name + "/Audience geometry settling";
                            return;
                        }
                        MarkActionEvent("row " + fader.Name + "/Audience " + args.StructureChangeType.ToString());
                        RequestFaderRefresh(fader.Name, "Audience");
                    };
                    Automation.AddStructureChangedEventHandler(
                        fader.AudienceActionContainer,
                        TreeScope.Subtree,
                        fader.AudienceStructureChangedHandler
                    );
                }
            } catch { }
        }

        private static void UnsubscribeFaderHandlers(IEnumerable<TrackedFader> faders) {
            if (faders == null) return;
            foreach (TrackedFader fader in faders) {
                try {
                    if (fader.PersonalButton != null && fader.PersonalChangedHandler != null) {
                        Automation.RemoveAutomationPropertyChangedEventHandler(
                            fader.PersonalButton,
                            fader.PersonalChangedHandler
                        );
                    }
                } catch { }
                try {
                    if (fader.AudienceButton != null && fader.AudienceChangedHandler != null) {
                        Automation.RemoveAutomationPropertyChangedEventHandler(
                            fader.AudienceButton,
                            fader.AudienceChangedHandler
                        );
                    }
                } catch { }
                try {
                    if (fader.LockButton != null && fader.LockChangedHandler != null) {
                        Automation.RemoveAutomationPropertyChangedEventHandler(
                            fader.LockButton,
                            fader.LockChangedHandler
                        );
                    }
                } catch { }
                try {
                    if (fader.AllActionContainer != null && fader.AllStructureChangedHandler != null) {
                        Automation.RemoveStructureChangedEventHandler(
                            fader.AllActionContainer,
                            fader.AllStructureChangedHandler
                        );
                    }
                } catch { }
                try {
                    if (fader.AudienceActionContainer != null && fader.AudienceStructureChangedHandler != null) {
                        Automation.RemoveStructureChangedEventHandler(
                            fader.AudienceActionContainer,
                            fader.AudienceStructureChangedHandler
                        );
                    }
                } catch { }
            }
        }

        private static Dictionary<string, int> DrainActionRefreshes(
            ConcurrentDictionary<string, int> source,
            int maximumFaders
        ) {
            Dictionary<string, int> result = new Dictionary<string, int>(StringComparer.OrdinalIgnoreCase);
            maximumFaders = Math.Max(1, maximumFaders);
            foreach (KeyValuePair<string, int> pair in source) {
                if (result.Count >= maximumFaders) break;
                int mask;
                if (source.TryRemove(pair.Key, out mask)) result[pair.Key] = mask;
            }
            if (!source.IsEmpty) Interlocked.Exchange(ref actionRefreshRequested, 1);
            return result;
        }

        private static void HandleRootStructureChanged(object sender, StructureChangedEventArgs args) {
            DateTime now = DateTime.UtcNow;
            if (ObserveNativeWindowGeometry(now)) return;
            if (IsWindowGeometrySettling(now)) {
                lastActionEventSummary = DateTime.Now.ToString("HH:mm:ss.fff") + " window geometry settling";
                return;
            }
            Interlocked.Exchange(ref possibleLayoutChangeUtcTicks, now.Ticks);
            try {
                int[] runtimeId = args.GetRuntimeId();
                string id = runtimeId == null ? "none" : String.Join(".", runtimeId);
                lastActionEventSummary = DateTime.Now.ToString("HH:mm:ss.fff") +
                    " root " + args.StructureChangeType.ToString() + " " + id;
            } catch {
                lastActionEventSummary = DateTime.Now.ToString("HH:mm:ss.fff") + " root unreadable";
            }
        }

        private static void MarkActionEvent(string summary) {
            Interlocked.Exchange(ref lastActionEventUtcTicks, DateTime.UtcNow.Ticks);
            lastActionEventSummary = DateTime.Now.ToString("HH:mm:ss.fff") + " " + summary;
        }

        private static void SetSubscribedWindow(AutomationElement window) {
            if (subscribedWindow != null) {
                try {
                    Automation.RemoveStructureChangedEventHandler(subscribedWindow, rootStructureChangedHandler);
                } catch { }
            }
            subscribedWindow = window;
            subscribedWindowHandle = IntPtr.Zero;
            if (subscribedWindow != null) {
                try { subscribedWindowHandle = new IntPtr(subscribedWindow.Current.NativeWindowHandle); } catch { }
            }
            lock (geometryGate) {
                lastWindowBounds = GetSubscribedWindowBounds();
            }
            if (subscribedWindow != null) {
                try {
                    Automation.AddStructureChangedEventHandler(
                        subscribedWindow,
                        TreeScope.Descendants,
                        rootStructureChangedHandler
                    );
                } catch { }
            }
        }

        private static bool AreClose(double left, double right) {
            return Math.Abs(left - right) < 0.5;
        }

        private static bool IsWindowGeometrySettling(DateTime now) {
            return now.Ticks < Interlocked.Read(ref geometryChangeSuppressionUntilUtcTicks);
        }

        private static bool ObserveNativeWindowGeometry(DateTime now) {
            if (subscribedWindowHandle == IntPtr.Zero) return false;
            NativeRect nativeBounds;
            if (!GetWindowRect(subscribedWindowHandle, out nativeBounds)) return false;
            Rect current = new Rect(
                nativeBounds.Left,
                nativeBounds.Top,
                Math.Max(0, nativeBounds.Right - nativeBounds.Left),
                Math.Max(0, nativeBounds.Bottom - nativeBounds.Top)
            );
            if (current.IsEmpty || current.Width <= 0 || current.Height <= 0) return false;

            Rect previous;
            lock (geometryGate) {
                previous = lastWindowBounds;
                if (previous.IsEmpty) {
                    lastWindowBounds = current;
                    return false;
                }
                if (
                    AreClose(current.Left, previous.Left) &&
                    AreClose(current.Top, previous.Top) &&
                    AreClose(current.Width, previous.Width) &&
                    AreClose(current.Height, previous.Height)
                ) return false;

                TranslateTrackedGeometry(previous, current);
                lastWindowBounds = current;
            }

            // BEACN/JUCE can briefly stop answering UI Automation while its window is
            // crossing monitors. Keep the last confirmed mute state authoritative and
            // translate the cached click hints immediately using native window bounds.
            // UIA reads resume only after the provider has settled.
            Interlocked.Exchange(
                ref geometryChangeSuppressionUntilUtcTicks,
                now.AddMilliseconds(WindowGeometrySettleMilliseconds).Ticks
            );
            Interlocked.Exchange(ref geometryRefreshRequested, 0);
            Interlocked.Exchange(ref geometryRefreshIndex, -1);
            // Named action requests remain valid across a move. Scan() parks them
            // during the settle interval and resumes against refreshed geometry.
            if (!pendingActionRefreshes.IsEmpty || !pendingUrgentActionRefreshes.IsEmpty) {
                Interlocked.Exchange(ref actionRefreshRequested, 1);
            }
            Interlocked.Exchange(ref possibleLayoutChangeUtcTicks, 0);
            Interlocked.Increment(ref nativeGeometryGeneration);
            lastActionEventSummary = DateTime.Now.ToString("HH:mm:ss.fff") + " window geometry changed";
            return true;
        }

        private static void TranslateTrackedGeometry(Rect previousWindow, Rect currentWindow) {
            foreach (TrackedFader fader in trackedFaders) {
                if (fader == null) continue;
                fader.HeaderBounds = TransformWindowRect(fader.HeaderBounds, previousWindow, currentWindow);
                fader.AllActionBounds = TransformWindowRect(fader.AllActionBounds, previousWindow, currentWindow);
                fader.AllActionRowBounds = TransformWindowRect(fader.AllActionRowBounds, previousWindow, currentWindow);
                fader.AllActionProbeBounds = TransformWindowRect(fader.AllActionProbeBounds, previousWindow, currentWindow);
                fader.AudienceActionBounds = TransformWindowRect(fader.AudienceActionBounds, previousWindow, currentWindow);
                fader.AudienceActionRowBounds = TransformWindowRect(fader.AudienceActionRowBounds, previousWindow, currentWindow);
                fader.AudienceActionProbeBounds = TransformWindowRect(fader.AudienceActionProbeBounds, previousWindow, currentWindow);
            }
        }

        private static Rect TransformWindowRect(Rect value, Rect previousWindow, Rect currentWindow) {
            if (value.IsEmpty) return Rect.Empty;
            double scaleX = previousWindow.Width > 0 ? currentWindow.Width / previousWindow.Width : 1.0;
            double scaleY = previousWindow.Height > 0 ? currentWindow.Height / previousWindow.Height : 1.0;
            return new Rect(
                currentWindow.Left + ((value.Left - previousWindow.Left) * scaleX),
                currentWindow.Top + ((value.Top - previousWindow.Top) * scaleY),
                Math.Max(0, value.Width * scaleX),
                Math.Max(0, value.Height * scaleY)
            );
        }

        private static Rect GetSubscribedWindowBounds() {
            Rect nativeBounds = GetNativeWindowBounds(subscribedWindowHandle);
            if (!nativeBounds.IsEmpty) return nativeBounds;
            return GetElementBounds(subscribedWindow);
        }

        private static Rect GetNativeWindowBounds(IntPtr windowHandle) {
            if (windowHandle == IntPtr.Zero) return Rect.Empty;
            NativeRect nativeBounds;
            if (!GetWindowRect(windowHandle, out nativeBounds)) return Rect.Empty;
            int width = Math.Max(0, nativeBounds.Right - nativeBounds.Left);
            int height = Math.Max(0, nativeBounds.Bottom - nativeBounds.Top);
            if (width <= 0 || height <= 0) return Rect.Empty;
            return new Rect(nativeBounds.Left, nativeBounds.Top, width, height);
        }

        private static void RefreshNextTrackedGeometry() {
            int index = Volatile.Read(ref geometryRefreshIndex);
            List<TrackedFader> current = trackedFaders;
            if (index < 0) return;
            if (index >= current.Count) {
                Interlocked.Exchange(ref geometryRefreshIndex, -1);
                lock (geometryGate) {
                    lastWindowBounds = GetSubscribedWindowBounds();
                }
                return;
            }

            TrackedFader fader = current[index];
            RefreshActionGeometry(
                fader.AllActionLabel,
                "All",
                ref fader.AllActionContainer,
                fader.AllActionMenuButton,
                ref fader.AllActionBounds,
                ref fader.AllActionRowBounds,
                ref fader.AllActionProbeBounds
            );
            RefreshActionGeometry(
                fader.AudienceActionLabel,
                "Audience",
                ref fader.AudienceActionContainer,
                fader.AudienceActionMenuButton,
                ref fader.AudienceActionBounds,
                ref fader.AudienceActionRowBounds,
                ref fader.AudienceActionProbeBounds
            );

            int next = index + 1;
            if (next >= current.Count) {
                Interlocked.Exchange(ref geometryRefreshIndex, -1);
                lock (geometryGate) {
                    lastWindowBounds = GetSubscribedWindowBounds();
                }
            } else {
                Interlocked.Exchange(ref geometryRefreshIndex, next);
            }
        }

        private static void RefreshActionGeometry(
            AutomationElement label,
            string mode,
            ref AutomationElement container,
            AutomationElement menuButton,
            ref Rect labelBounds,
            ref Rect rowBounds,
            ref Rect probeBounds
        ) {
            if (label == null) return;
            try {
                AutomationElement.AutomationElementInformation info = label.Current;
                bool expected = String.Equals(mode, "All", StringComparison.OrdinalIgnoreCase)
                    ? IsAllActionLabel(info.Name)
                    : IsAudienceActionLabel(info.Name);
                if (!expected || info.BoundingRectangle.IsEmpty) return;
                labelBounds = info.BoundingRectangle;
            } catch { return; }

            if (!IsLiveElement(container)) container = FindActionRowContainer(label);
            Rect currentRowBounds = GetElementBounds(container);
            if (!currentRowBounds.IsEmpty) rowBounds = currentRowBounds;
            Rect currentProbeBounds = GetElementBounds(menuButton);
            if (!currentProbeBounds.IsEmpty) probeBounds = currentProbeBounds;
        }

        private static List<AutomationElement> FindVisibleBeacnWindows(HashSet<int> processIds) {
            List<AutomationElement> result = new List<AutomationElement>();
            if (processIds == null || processIds.Count == 0) return result;

            AutomationElement bestWindow = null;
            double bestArea = 0;
            AutomationElement root = AutomationElement.RootElement;
            foreach (int processId in processIds) {
                try {
                    PropertyCondition condition = new PropertyCondition(
                        AutomationElement.ProcessIdProperty,
                        processId
                    );
                    AutomationElementCollection candidates = root.FindAll(TreeScope.Children, condition);
                    for (int index = 0; index < candidates.Count; index++) {
                        Rect bounds;
                        try { bounds = candidates[index].Current.BoundingRectangle; }
                        catch { continue; }
                        double area = Math.Max(0, bounds.Width) * Math.Max(0, bounds.Height);
                        if (bestWindow == null || area > bestArea) {
                            bestWindow = candidates[index];
                            bestArea = area;
                        }
                    }
                } catch { }
            }

            if (bestWindow != null) {
                result.Add(bestWindow);
            }
            return result;
        }

        private static bool IsRenderedFaderHeader(TrackedFader fader) {
            if (fader == null || fader.HeaderBounds.IsEmpty) return false;
            Point point = new Point(
                (fader.HeaderBounds.Left + fader.HeaderBounds.Right) / 2.0,
                (fader.HeaderBounds.Top + fader.HeaderBounds.Bottom) / 2.0
            );
            AutomationElement hit;
            try { hit = AutomationElement.FromPoint(point); }
            catch { return false; }
            for (int depth = 0; hit != null && depth < 5; depth++) {
                try {
                    AutomationElement.AutomationElementInformation info = hit.Current;
                    if (
                        info.ProcessId == fader.ProcessId &&
                        String.Equals(info.Name, fader.Name, StringComparison.OrdinalIgnoreCase)
                    ) return true;
                } catch { break; }
                hit = TryGetParent(hit);
            }
            return false;
        }

        private static void ClearDeferredActionRefresh(string name) {
            int ignored;
            missingRefreshDeadlineGeneration.TryRemove(name, out ignored);
            postDiscoveryRefreshes.TryRemove(name, out ignored);
            postDiscoveryUrgentRefreshes.TryRemove(name, out ignored);
        }

        private static bool RetainActionRefreshUntilNextDiscovery(string name, int mask, bool urgent) {
            int currentGeneration = Volatile.Read(ref discoveryGeneration);
            int deadlineGeneration;
            if (missingRefreshDeadlineGeneration.TryGetValue(name, out deadlineGeneration)) {
                if (currentGeneration >= deadlineGeneration) {
                    // This gesture already received its one bounded discovery. Remove
                    // the tombstone so a later independent press can try again.
                    ClearDeferredActionRefresh(name);
                    return false;
                }
            } else {
                deadlineGeneration = currentGeneration + 1;
                missingRefreshDeadlineGeneration[name] = deadlineGeneration;
            }

            ConcurrentDictionary<string, int> postDiscovery = urgent
                ? postDiscoveryUrgentRefreshes
                : postDiscoveryRefreshes;
            postDiscovery.AddOrUpdate(name, mask, delegate(string key, int current) {
                return current | mask;
            });
            return true;
        }

        private static bool RefreshActionStates(Dictionary<string, int> requested, bool urgent) {
            if (requested == null || requested.Count == 0) return false;
            bool allSucceeded = true;
            HashSet<string> matchedNames = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            try {
                foreach (TrackedFader fader in trackedFaders) {
                    int mask;
                    if (!requested.TryGetValue(fader.Name, out mask)) continue;
                    matchedNames.Add(fader.Name);
                    bool changed;
                    if (!TryRefreshFaderAction(fader, mask, out changed)) {
                        if (RetainActionRefreshUntilNextDiscovery(fader.Name, mask, urgent)) {
                            allSucceeded = false;
                        }
                    } else {
                        ClearDeferredActionRefresh(fader.Name);
                        if (changed) {
                            // Require a second real UIA read, not merely a repeated cached snapshot.
                            // HasPendingChanges keeps the worker on its 15 ms confirmation cadence.
                            if (urgent) QueueUrgentFaderRefresh(fader.Name, mask);
                            else QueueFaderRefresh(fader.Name, mask);
                        }
                    }
                }
                foreach (KeyValuePair<string, int> pair in requested) {
                    if (matchedNames.Contains(pair.Key)) continue;
                    if (RetainActionRefreshUntilNextDiscovery(pair.Key, pair.Value, urgent)) {
                        allSucceeded = false;
                    }
                }
                lastActionRefresh = DateTime.UtcNow;
                return allSucceeded;
            } catch {
                return false;
            }
        }

        private static bool TryRefreshFaderAction(TrackedFader fader, int mask, out bool changed) {
            changed = false;
            bool succeeded = true;

            if ((mask & 1) != 0) {
                bool wasKnown = fader.AllActionSeen;
                bool wasActive = wasKnown && !fader.AllActionMenuButtonSeen;
                Rect allBounds = fader.AllActionBounds;
                Rect allRowBounds = fader.AllActionRowBounds;
                Rect allProbeBounds = fader.AllActionProbeBounds;
                bool allMenuButtonSeen;
                bool allRead = TryReadActionRow(
                    fader.AllActionLabel,
                    "All",
                    fader.ProcessId,
                    ref fader.AllActionContainer,
                    ref fader.AllActionMenuButton,
                    ref allBounds,
                    ref allRowBounds,
                    ref allProbeBounds,
                    (mask & 4) != 0,
                    out allMenuButtonSeen
                );
                if (allRead) {
                    bool isActive = !allMenuButtonSeen;
                    fader.AllActionBounds = allBounds;
                    fader.AllActionRowBounds = allRowBounds;
                    fader.AllActionProbeBounds = allProbeBounds;
                    fader.AllActionSeen = true;
                    fader.AllActionMenuButtonSeen = allMenuButtonSeen;
                    fader.AllVerifiedUtc = DateTime.UtcNow;
                    if (wasKnown && wasActive != isActive) changed = true;
                } else {
                    succeeded = false;
                }
            }

            if ((mask & 2) != 0) {
                bool wasKnown = fader.AudienceActionSeen;
                bool wasActive = wasKnown && !fader.AudienceActionMenuButtonSeen;
                Rect audienceBounds = fader.AudienceActionBounds;
                Rect audienceRowBounds = fader.AudienceActionRowBounds;
                Rect audienceProbeBounds = fader.AudienceActionProbeBounds;
                bool audienceMenuButtonSeen;
                bool audienceRead = TryReadActionRow(
                    fader.AudienceActionLabel,
                    "Audience",
                    fader.ProcessId,
                    ref fader.AudienceActionContainer,
                    ref fader.AudienceActionMenuButton,
                    ref audienceBounds,
                    ref audienceRowBounds,
                    ref audienceProbeBounds,
                    (mask & 8) != 0,
                    out audienceMenuButtonSeen
                );
                if (audienceRead) {
                    bool isActive = !audienceMenuButtonSeen;
                    fader.AudienceActionBounds = audienceBounds;
                    fader.AudienceActionRowBounds = audienceRowBounds;
                    fader.AudienceActionProbeBounds = audienceProbeBounds;
                    fader.AudienceActionSeen = true;
                    fader.AudienceActionMenuButtonSeen = audienceMenuButtonSeen;
                    fader.AudienceVerifiedUtc = DateTime.UtcNow;
                    if (wasKnown && wasActive != isActive) changed = true;
                } else {
                    succeeded = false;
                }
            }

            return succeeded;
        }

        private static int SelectUniqueOutputChange(bool[] personalChanged, bool[] audienceChanged, int mask) {
            if (
                personalChanged == null || audienceChanged == null ||
                personalChanged.Length != audienceChanged.Length
            ) return -1;
            int selected = -1;
            for (int index = 0; index < personalChanged.Length; index++) {
                bool compatible = ((mask & 1) != 0 && personalChanged[index]) ||
                    ((mask & 2) != 0 && audienceChanged[index] && !personalChanged[index]);
                if (!compatible) continue;
                if (selected >= 0) return -1;
                selected = index;
            }
            return selected;
        }

        private static TrackedFader FindUniqueOutputChange(int mask) {
            List<TrackedFader> snapshot = trackedFaders;
            bool[] personalChanged = new bool[snapshot.Count];
            bool[] audienceChanged = new bool[snapshot.Count];
            for (int index = 0; index < snapshot.Count; index++) {
                TrackedFader fader = snapshot[index];
                bool current;
                if (TryGetToggleState(fader.PersonalButton, out current)) {
                    personalChanged[index] = current != fader.PersonalMuted;
                    fader.PersonalMuted = current;
                }
                if (TryGetToggleState(fader.AudienceButton, out current)) {
                    audienceChanged[index] = current != fader.AudienceMuted;
                    fader.AudienceMuted = current;
                }
            }
            int selected = SelectUniqueOutputChange(personalChanged, audienceChanged, mask);
            return selected >= 0 && selected < snapshot.Count ? snapshot[selected] : null;
        }

        private static TrackedFader FindTrackedFader(string name) {
            if (String.IsNullOrWhiteSpace(name)) return null;
            foreach (TrackedFader fader in trackedFaders) {
                if (String.Equals(fader.Name, name, StringComparison.OrdinalIgnoreCase)) return fader;
            }
            return null;
        }

        private static HardwareRefreshCompletion RefreshHardwareActionState(HardwareRefreshRequest request) {
            Stopwatch timer = Stopwatch.StartNew();
            // A page hint can become stale without a page-button packet reaching us.
            // The top output toggles provide a cheap, source-specific edge, so consult
            // them even for a previously confident mapping before reading lower rows.
            if (request.FallbackIndex < 0 && String.IsNullOrWhiteSpace(request.OutputCandidateName)) {
                TrackedFader outputCandidate = FindUniqueOutputChange(request.Mask);
                if (outputCandidate != null) request.OutputCandidateName = outputCandidate.Name;
            }
            TrackedFader preferred = FindTrackedFader(request.OutputCandidateName);
            if (preferred == null) {
                preferred = FindTrackedFader(request.PreferredName);
            }

            if (preferred != null) {
                bool preferredChanged;
                bool preferredRead = TryRefreshFaderAction(preferred, request.Mask, out preferredChanged);
                bool outputLocated = !String.IsNullOrWhiteSpace(request.OutputCandidateName) &&
                    String.Equals(preferred.Name, request.OutputCandidateName, StringComparison.OrdinalIgnoreCase);
                if (preferredRead && preferredChanged) {
                    timer.Stop();
                    lastActionRefresh = DateTime.UtcNow;
                    lastHardwareRefreshSummary = String.Format(
                        "preferred {0} attempt={1} elapsed={2:0}ms",
                        preferred.Name,
                        request.Attempt + 1,
                        timer.Elapsed.TotalMilliseconds
                    );
                    return new HardwareRefreshCompletion { Request = request, ChangedName = preferred.Name };
                }

                // A first read can race BEACN's JUCE redraw. Retry the same named
                // software row once before treating the page/position hint as stale.
                if (request.FallbackIndex < 0 && (request.Attempt == 0 || (outputLocated && request.Attempt < 2))) {
                    request.Attempt++;
                    request.NotBeforeUtc = DateTime.UtcNow.AddMilliseconds(40);
                    EnqueueHardwareRefresh(request);
                    Interlocked.Exchange(ref actionRefreshRequested, 1);
                    timer.Stop();
                    lastActionRefresh = DateTime.UtcNow;
                    lastHardwareRefreshSummary = String.Format(
                        "waiting {0} elapsed={1:0}ms",
                        preferred.Name,
                        timer.Elapsed.TotalMilliseconds
                    );
                    return null;
                }
            }

            // A stale page hint used to make one scan synchronously inspect every
            // fader, blocking new presses for close to a second on some JUCE builds.
            // Inspect at most one fallback row per scan and requeue at the tail. This
            // keeps recovery bounded while allowing newer hardware/hotkey work ahead.
            if (request.FallbackIndex < 0) request.FallbackIndex = 0;
            List<TrackedFader> fallbackFaders = trackedFaders;
            TrackedFader fallbackFader = null;
            while (request.FallbackIndex < fallbackFaders.Count) {
                TrackedFader candidate = fallbackFaders[request.FallbackIndex++];
                if (candidate != preferred) {
                    fallbackFader = candidate;
                    break;
                }
            }
            if (fallbackFader != null) {
                bool changed;
                if (TryRefreshFaderAction(fallbackFader, request.Mask, out changed) && changed) {
                    timer.Stop();
                    lastActionRefresh = DateTime.UtcNow;
                    lastHardwareRefreshSummary = String.Format(
                        "fallback {0} preferred={1} step={2}/{3} elapsed={4:0}ms",
                        fallbackFader.Name,
                        request.PreferredName,
                        request.FallbackIndex,
                        fallbackFaders.Count,
                        timer.Elapsed.TotalMilliseconds
                    );
                    return new HardwareRefreshCompletion { Request = request, ChangedName = fallbackFader.Name };
                }
            }

            while (request.FallbackIndex < fallbackFaders.Count && fallbackFaders[request.FallbackIndex] == preferred) {
                request.FallbackIndex++;
            }
            if (request.FallbackIndex < fallbackFaders.Count) {
                request.NotBeforeUtc = DateTime.UtcNow.AddMilliseconds(10);
                EnqueueHardwareRefresh(request);
                Interlocked.Exchange(ref actionRefreshRequested, 1);
                timer.Stop();
                lastActionRefresh = DateTime.UtcNow;
                lastHardwareRefreshSummary = String.Format(
                    "fallback waiting preferred={0} step={1}/{2} elapsed={3:0}ms",
                    request.PreferredName,
                    request.FallbackIndex,
                    fallbackFaders.Count,
                    timer.Elapsed.TotalMilliseconds
                );
                return null;
            }

            // Complete even when no row changed so PowerShell can immediately retract
            // this request's incorrect prediction instead of waiting on its lease.
            HardwareRefreshCompletion completion = new HardwareRefreshCompletion {
                Request = request,
                ChangedName = String.Empty
            };
            timer.Stop();
            lastActionRefresh = DateTime.UtcNow;
            lastHardwareRefreshSummary = String.Format(
                "no change preferred={0} attempt={1} fallbackSteps={2} elapsed={3:0}ms",
                request.PreferredName,
                request.Attempt + 1,
                request.FallbackIndex,
                timer.Elapsed.TotalMilliseconds
            );
            return completion;
        }

        private static bool TryReadActionRow(
            AutomationElement label,
            string actionMode,
            int processId,
            ref AutomationElement container,
            ref AutomationElement menuButton,
            ref Rect bounds,
            ref Rect rowBounds,
            ref Rect probeBounds,
            bool forceRenderedProbe,
            out bool menuButtonSeen
        ) {
            menuButtonSeen = false;
            AutomationElement previousMenuButton = menuButton;
            menuButton = null;

            // Always refresh the named label and its row before using geometry.
            // BEACN keeps these UI Automation elements alive when its window moves,
            // but every screen rectangle cached before that move is invalid.
            bool labelLive = false;
            if (label != null) {
                try {
                    AutomationElement.AutomationElementInformation labelInfo = label.Current;
                    bool expectedLabel = String.Equals(actionMode, "All", StringComparison.OrdinalIgnoreCase)
                        ? IsAllActionLabel(labelInfo.Name)
                        : IsAudienceActionLabel(labelInfo.Name);
                    if (expectedLabel) {
                        bounds = labelInfo.BoundingRectangle;
                        processId = labelInfo.ProcessId;
                        labelLive = !bounds.IsEmpty;
                    }
                } catch { }
            }
            if (!labelLive) return false;

            bool containerLive = IsLiveElement(container);
            if (!containerLive) {
                container = FindActionRowContainer(label);
                containerLive = IsLiveElement(container);
            }
            if (containerLive) {
                Rect currentRowBounds = GetElementBounds(container);
                if (!currentRowBounds.IsEmpty) rowBounds = currentRowBounds;
            }
            if (IsLiveElement(previousMenuButton)) {
                Rect currentProbeBounds = GetElementBounds(previousMenuButton);
                if (!currentProbeBounds.IsEmpty) probeBounds = currentProbeBounds;
            }

            // JUCE's accessibility children remain stale only for the row currently
            // hovered by the mouse. Probe that rendered row first; all other rows use
            // their much faster targeted accessibility subtree below.
            bool hitTestMenuButtonSeen;
            bool cursorInsideRow = IsCursorInside(rowBounds);
            if (
                (forceRenderedProbe || cursorInsideRow) &&
                TryHitTestActionMenu(probeBounds, rowBounds, bounds, processId, out hitTestMenuButtonSeen)
            ) {
                menuButtonSeen = hitTestMenuButtonSeen;
                return true;
            }

            // Away from the pointer, JUCE's row subtree is current. Query its one
            // menu button directly before asking for label/container properties.
            AutomationElement replacement = null;
            bool treeMenuButtonSeen;
            if (
                !cursorInsideRow &&
                container != null &&
                TryReadRowMenuState(container, bounds, out replacement, out treeMenuButtonSeen)
            ) {
                menuButton = replacement;
                menuButtonSeen = treeMenuButtonSeen;
                if (replacement != null) probeBounds = GetElementBounds(replacement);
                return true;
            }

            replacement = null;
            if (containerLive && TryReadRowMenuState(container, bounds, out replacement, out treeMenuButtonSeen)) {
                menuButton = replacement;
                menuButtonSeen = treeMenuButtonSeen;
                if (replacement != null) probeBounds = GetElementBounds(replacement);
                return true;
            }
            if (
                !cursorInsideRow &&
                TryHitTestActionMenu(probeBounds, rowBounds, bounds, processId, out hitTestMenuButtonSeen)
            ) {
                menuButtonSeen = hitTestMenuButtonSeen;
                return true;
            }
            return false;
        }

        private static bool IsCursorInside(Rect bounds) {
            if (bounds.IsEmpty) return false;
            NativePoint point;
            if (!GetCursorPos(out point)) return false;
            return bounds.Contains(new Point(point.X, point.Y));
        }

        private static bool TryHitTestActionMenu(
            Rect probeBounds,
            Rect rowBounds,
            Rect labelBounds,
            int processId,
            out bool menuButtonSeen
        ) {
            menuButtonSeen = false;
            if (
                processId <= 0 ||
                rowBounds.IsEmpty ||
                rowBounds.Height <= 0 || rowBounds.Height > 56 ||
                rowBounds.Width <= 0 || rowBounds.Width > 280
            ) return false;

            double x = probeBounds.IsEmpty
                ? rowBounds.Right - 10
                : (probeBounds.Left + probeBounds.Right) / 2.0;
            double y = probeBounds.IsEmpty
                ? (rowBounds.Top + rowBounds.Bottom) / 2.0
                : (probeBounds.Top + probeBounds.Bottom) / 2.0;
            x = Math.Max(rowBounds.Left + 2, Math.Min(rowBounds.Right - 2, x));
            y = Math.Max(rowBounds.Top + 2, Math.Min(rowBounds.Bottom - 2, y));

            bool beacnElementSeen = false;
            AutomationElement hit;
            try { hit = AutomationElement.FromPoint(new Point(x, y)); }
            catch { return false; }
            for (int depth = 0; hit != null && depth < 5; depth++) {
                try {
                    AutomationElement.AutomationElementInformation info = hit.Current;
                    if (info.ProcessId == processId) beacnElementSeen = true;
                    string automationId = info.AutomationId ?? String.Empty;
                    if (automationId.StartsWith("mutemenubutton", StringComparison.Ordinal)) {
                        menuButtonSeen = true;
                        return true;
                    }
                } catch { break; }
                hit = TryGetParent(hit);
            }

            // A valid BEACN hit with no menu button is the active slash/status icon.
            return beacnElementSeen;
        }

        private static bool TryReadRowMenuState(
            AutomationElement container,
            Rect labelBounds,
            out AutomationElement result,
            out bool menuButtonSeen
        ) {
            result = null;
            menuButtonSeen = false;
            try {
                AutomationElementCollection buttons = container.FindAll(TreeScope.Descendants, ButtonElementCondition);
                for (int index = 0; index < buttons.Count; index++) {
                    AutomationElement.AutomationElementInformation info;
                    try { info = buttons[index].Current; } catch { continue; }
                    string automationId = info.AutomationId ?? String.Empty;
                    if (!automationId.StartsWith("mutemenubutton", StringComparison.Ordinal)) continue;
                    Rect buttonBounds = info.BoundingRectangle;
                    bool sameRow = (
                        !labelBounds.IsEmpty &&
                        !buttonBounds.IsEmpty &&
                        Math.Abs(
                            (buttonBounds.Top + buttonBounds.Bottom) / 2.0 -
                            (labelBounds.Top + labelBounds.Bottom) / 2.0
                        ) <= 12 &&
                        buttonBounds.Left <= labelBounds.Right + 80 &&
                        buttonBounds.Right >= labelBounds.Left - 8
                    );
                    if (sameRow) {
                        result = buttons[index];
                        menuButtonSeen = true;
                        return true;
                    }
                }
                // A live row that contains no menu button is BEACN's active state.
                return true;
            } catch { return false; }
        }

        private static Rect GetElementBounds(AutomationElement element) {
            if (element == null) return Rect.Empty;
            try { return element.Current.BoundingRectangle; }
            catch { return Rect.Empty; }
        }

        private static bool IsLiveElement(AutomationElement element) {
            if (element == null) return false;
            try {
                AutomationElement.AutomationElementInformation ignored = element.Current;
                return true;
            } catch { return false; }
        }

        private static AutomationElement TryGetParent(AutomationElement element) {
            if (element == null) return null;
            try { return TreeWalker.RawViewWalker.GetParent(element); }
            catch { return null; }
        }

        private static AutomationElement FindActionRowContainer(AutomationElement label) {
            if (label == null) return null;
            Rect labelBounds;
            try { labelBounds = label.Current.BoundingRectangle; }
            catch { return null; }

            AutomationElement firstParent = TryGetParent(label);
            AutomationElement current = firstParent;
            for (int depth = 0; current != null && depth < 6; depth++) {
                try {
                    Rect bounds = current.Current.BoundingRectangle;
                    if (
                        !bounds.IsEmpty &&
                        bounds.Height > 0 && bounds.Height <= 48 &&
                        bounds.Width > 0 && bounds.Width <= 260 &&
                        (labelBounds.IsEmpty || (
                            bounds.Left <= labelBounds.Left &&
                            bounds.Right >= labelBounds.Right &&
                            bounds.Top <= labelBounds.Top &&
                            bounds.Bottom >= labelBounds.Bottom
                        ))
                    ) {
                        return current;
                    }
                } catch { }
                current = TryGetParent(current);
            }
            return firstParent;
        }

        private static AutomationElement FindCommonAncestor(AutomationElement first, AutomationElement second) {
            if (first == null || second == null) return null;
            List<AutomationElement> firstAncestors = new List<AutomationElement>();
            AutomationElement current = first;
            for (int depth = 0; current != null && depth < 8; depth++) {
                firstAncestors.Add(current);
                current = TryGetParent(current);
            }
            current = second;
            for (int depth = 0; current != null && depth < 8; depth++) {
                foreach (AutomationElement candidate in firstAncestors) {
                    if (SameElement(candidate, current)) return current;
                }
                current = TryGetParent(current);
            }
            return TryGetParent(first);
        }

        private static bool SameElement(AutomationElement left, AutomationElement right) {
            if (left == null || right == null) return false;
            try {
                int[] leftId = left.GetRuntimeId();
                int[] rightId = right.GetRuntimeId();
                if (leftId == null || rightId == null || leftId.Length != rightId.Length) return false;
                for (int index = 0; index < leftId.Length; index++) {
                    if (leftId[index] != rightId[index]) return false;
                }
                return true;
            } catch { return false; }
        }

        private static bool TryReadTrackedFaders(out BeacnFaderState[] states) {
            List<BeacnFaderState> result = new List<BeacnFaderState>();
            try {
                lock (geometryGate) {
                    for (int index = 0; index < trackedFaders.Count; index++) {
                        TrackedFader fader = trackedFaders[index];
                        result.Add(new BeacnFaderState {
                            Order = index,
                            Name = fader.Name,
                            PersonalMuted = fader.PersonalMuted,
                            AudienceMuted = fader.AudienceMuted,
                            IsLocked = fader.IsLocked,
                            AllActionStateKnown = fader.AllActionSeen,
                            AllActionActive = fader.AllActionSeen && !fader.AllActionMenuButtonSeen,
                            AudienceActionStateKnown = fader.AudienceActionSeen,
                            AudienceActionActive = fader.AudienceActionSeen && !fader.AudienceActionMenuButtonSeen,
                            HasAllActionBounds = !fader.AllActionBounds.IsEmpty,
                            AllActionLeft = fader.AllActionBounds.IsEmpty ? 0 : fader.AllActionBounds.Left,
                            AllActionTop = fader.AllActionBounds.IsEmpty ? 0 : fader.AllActionBounds.Top,
                            AllActionRight = fader.AllActionBounds.IsEmpty ? 0 : fader.AllActionBounds.Right,
                            AllActionBottom = fader.AllActionBounds.IsEmpty ? 0 : fader.AllActionBounds.Bottom,
                            HasAudienceActionBounds = !fader.AudienceActionBounds.IsEmpty,
                            AudienceActionLeft = fader.AudienceActionBounds.IsEmpty ? 0 : fader.AudienceActionBounds.Left,
                            AudienceActionTop = fader.AudienceActionBounds.IsEmpty ? 0 : fader.AudienceActionBounds.Top,
                            AudienceActionRight = fader.AudienceActionBounds.IsEmpty ? 0 : fader.AudienceActionBounds.Right,
                            AudienceActionBottom = fader.AudienceActionBounds.IsEmpty ? 0 : fader.AudienceActionBounds.Bottom
                        });
                    }
                }
                states = result.ToArray();
                return states.Length > 0;
            } catch {
                states = new BeacnFaderState[0];
                return false;
            }
        }

        private static bool TryGetToggleState(AutomationElement element, out bool toggled) {
            try {
                object pattern;
                if (element.TryGetCurrentPattern(TogglePattern.Pattern, out pattern)) {
                    toggled = ((TogglePattern)pattern).Current.ToggleState == ToggleState.On;
                    return true;
                }
                if (element.TryGetCurrentPattern(ValuePattern.Pattern, out pattern)) {
                    toggled = String.Equals(((ValuePattern)pattern).Current.Value, "On", StringComparison.OrdinalIgnoreCase);
                    return true;
                }
            } catch { }
            toggled = false;
            return false;
        }
    }

    public static class DiscordMuteScanner {
        private static AutomationElement micControl;
        private static AutomationElement deafenControl;

        public static Task<DiscordLocalState> ScanAsync(bool detectMic, bool detectDeafen) {
            return Task.Factory.StartNew<DiscordLocalState>(() => Scan(detectMic, detectDeafen));
        }

        private static DiscordLocalState Scan(bool detectMic, bool detectDeafen) {
            DiscordLocalState state = new DiscordLocalState();
            if (!detectMic && !detectDeafen) return state;

            try {
                List<Process> processes = new List<Process>();
                foreach (string processName in new string[] { "Discord", "DiscordPTB", "DiscordCanary" }) {
                    processes.AddRange(Process.GetProcessesByName(processName));
                }
                if (processes.Count == 0) return state;
                state.ClientFound = true;

                bool toggled;
                if (detectMic && TryReadCachedMicState(out toggled)) {
                    state.MicStateKnown = true;
                    state.MicMuted = toggled;
                }
                if (detectDeafen && TryReadCachedDeafenState(out toggled)) {
                    state.DeafenStateKnown = true;
                    state.Deafened = toggled;
                }
                if ((!detectMic || state.MicStateKnown) && (!detectDeafen || state.DeafenStateKnown)) return state;

                AutomationElement root = AutomationElement.RootElement;
                List<AutomationElement> windows = new List<AutomationElement>();
                foreach (Process process in processes) {
                    try {
                        PropertyCondition condition = new PropertyCondition(AutomationElement.ProcessIdProperty, process.Id);
                        AutomationElementCollection processWindows = root.FindAll(TreeScope.Children, condition);
                        for (int index = 0; index < processWindows.Count; index++) {
                            windows.Add(processWindows[index]);
                        }
                    } catch { }
                }
                if (windows.Count == 0) return state;

                foreach (AutomationElement window in windows) {
                    try {
                        bool detectedToggle;
                        AutomationElement control;
                        if (detectMic && !state.MicStateKnown && TryFindToggleControl(window, "Mute", out control, out detectedToggle)) {
                            state.MicStateKnown = true;
                            state.MicMuted = detectedToggle;
                            micControl = control;
                        }
                        if (detectDeafen && !state.DeafenStateKnown && TryFindToggleControl(window, "Deafen", out control, out detectedToggle)) {
                            state.DeafenStateKnown = true;
                            state.Deafened = detectedToggle;
                            deafenControl = control;
                        }
                    } catch { }

                    if ((!detectMic || state.MicStateKnown) && (!detectDeafen || state.DeafenStateKnown)) break;
                }
            } catch { }

            return state;
        }

        private static bool TryFindToggleControl(AutomationElement window, string name, out AutomationElement control, out bool toggled) {
            try {
                Condition buttonCondition = new AndCondition(
                    new PropertyCondition(AutomationElement.ControlTypeProperty, ControlType.Button),
                    new PropertyCondition(AutomationElement.NameProperty, name)
                );
                control = window.FindFirst(TreeScope.Descendants, buttonCondition);
                if (control != null && TryGetToggleState(control, out toggled)) return true;
            } catch { }
            control = null;
            toggled = false;
            return false;
        }

        private static bool TryReadCachedMicState(out bool muted) {
            try {
                if (micControl != null && TryReadMicState(GetAccessibleLabel(micControl.Current), micControl, out muted)) return true;
            } catch { micControl = null; }
            muted = false;
            return false;
        }

        private static bool TryReadCachedDeafenState(out bool deafened) {
            try {
                if (deafenControl != null && TryReadDeafenState(GetAccessibleLabel(deafenControl.Current), deafenControl, out deafened)) return true;
            } catch { deafenControl = null; }
            deafened = false;
            return false;
        }

        private static string GetAccessibleLabel(AutomationElement.AutomationElementInformation current) {
            try {
                return (current.Name + " " + current.HelpText + " " + current.ItemStatus).Trim().ToLowerInvariant();
            } catch { return String.Empty; }
        }

        private static bool TryReadMicState(string label, AutomationElement element, out bool muted) {
            bool toggleState;
            if (TryGetToggleState(element, out toggleState) && Regex.IsMatch(label, @"\b(mic|microphone|mute)\b")) {
                muted = toggleState;
                return true;
            }
            if (Regex.IsMatch(label, @"\b(unmute|turn on microphone|enable microphone|microphone muted|mic muted)\b")) {
                muted = true;
                return true;
            }
            if (Regex.IsMatch(label, @"^(mute|mute microphone|mute mic|turn off microphone|disable microphone)\b")) {
                muted = false;
                return true;
            }
            muted = false;
            return false;
        }

        private static bool TryReadDeafenState(string label, AutomationElement element, out bool deafened) {
            bool toggleState;
            if (TryGetToggleState(element, out toggleState) && Regex.IsMatch(label, @"\b(deafen|audio|sound)\b")) {
                deafened = toggleState;
                return true;
            }
            if (Regex.IsMatch(label, @"\b(undeafen|turn on audio|enable audio|deafened|audio off|sound off)\b")) {
                deafened = true;
                return true;
            }
            if (Regex.IsMatch(label, @"^(deafen|turn off audio|disable audio)\b")) {
                deafened = false;
                return true;
            }
            deafened = false;
            return false;
        }

        private static bool TryGetToggleState(AutomationElement element, out bool toggled) {
            try {
                object pattern;
                if (element.TryGetCurrentPattern(TogglePattern.Pattern, out pattern)) {
                    toggled = ((TogglePattern)pattern).Current.ToggleState == ToggleState.On;
                    return true;
                }
            } catch { }
            toggled = false;
            return false;
        }

        public static string[] DescribeAccessibleControls() {
            List<string> rows = new List<string>();
            try {
                AutomationElement root = AutomationElement.RootElement;
                foreach (string processName in new string[] { "Discord", "DiscordPTB", "DiscordCanary" }) {
                    foreach (Process process in Process.GetProcessesByName(processName)) {
                        try {
                            PropertyCondition processCondition = new PropertyCondition(AutomationElement.ProcessIdProperty, process.Id);
                            AutomationElementCollection windows = root.FindAll(TreeScope.Children, processCondition);
                            for (int windowIndex = 0; windowIndex < windows.Count; windowIndex++) {
                                AutomationElement window = windows[windowIndex];
                                AutomationElement.AutomationElementInformation windowInfo = window.Current;
                                Condition controlCondition = new OrCondition(
                                    new PropertyCondition(AutomationElement.ControlTypeProperty, ControlType.Button),
                                    new PropertyCondition(AutomationElement.ControlTypeProperty, ControlType.CheckBox)
                                );
                                AutomationElementCollection controls = window.FindAll(TreeScope.Descendants, controlCondition);
                                for (int controlIndex = 0; controlIndex < controls.Count && rows.Count < 600; controlIndex++) {
                                    try {
                                        AutomationElement control = controls[controlIndex];
                                        AutomationElement.AutomationElementInformation info = control.Current;
                                        string label = GetAccessibleLabel(info);
                                        if (String.IsNullOrWhiteSpace(label)) continue;
                                        bool toggleState;
                                        string toggle = TryGetToggleState(control, out toggleState) ? toggleState.ToString() : "none";
                                        rows.Add(String.Format(
                                            "PID={0};WINDOW={1};NAME={2};HELP={3};STATUS={4};ID={5};BOUNDS={6},{7},{8},{9};OFFSCREEN={10};TOGGLE={11}",
                                            process.Id,
                                            Clean(windowInfo.Name),
                                            Clean(info.Name),
                                            Clean(info.HelpText),
                                            Clean(info.ItemStatus),
                                            Clean(info.AutomationId),
                                            info.BoundingRectangle.Left,
                                            info.BoundingRectangle.Top,
                                            info.BoundingRectangle.Width,
                                            info.BoundingRectangle.Height,
                                            info.IsOffscreen,
                                            toggle
                                        ));
                                    } catch { }
                                }
                            }
                        } catch { }
                    }
                }
            } catch (Exception error) {
                rows.Add("ERROR=" + Clean(error.Message));
            }
            return rows.ToArray();
        }

        public static string[] CaptureToggleEvents(int milliseconds) {
            List<string> rows = new List<string>();
            List<AutomationElement> windows = new List<AutomationElement>();
            AutomationPropertyChangedEventHandler handler = null;
            try {
                AutomationElement root = AutomationElement.RootElement;
                foreach (string processName in new string[] { "Discord", "DiscordPTB", "DiscordCanary" }) {
                    foreach (Process process in Process.GetProcessesByName(processName)) {
                        try {
                            PropertyCondition condition = new PropertyCondition(AutomationElement.ProcessIdProperty, process.Id);
                            AutomationElementCollection processWindows = root.FindAll(TreeScope.Children, condition);
                            for (int index = 0; index < processWindows.Count; index++) windows.Add(processWindows[index]);
                        } catch { }
                    }
                }

                handler = delegate(object sender, AutomationPropertyChangedEventArgs args) {
                    try {
                        AutomationElement element = sender as AutomationElement;
                        string name = element == null ? String.Empty : element.Current.Name;
                        if (String.Equals(name, "Mute", StringComparison.OrdinalIgnoreCase) || String.Equals(name, "Deafen", StringComparison.OrdinalIgnoreCase)) {
                            lock (rows) rows.Add("EVENT=" + name + ";VALUE=" + Convert.ToString(args.NewValue));
                        }
                    } catch { }
                };
                foreach (AutomationElement window in windows) {
                    Automation.AddAutomationPropertyChangedEventHandler(window, TreeScope.Subtree, handler, TogglePattern.ToggleStateProperty);
                }
                Thread.Sleep(Math.Max(1000, milliseconds));
            } catch (Exception error) {
                lock (rows) rows.Add("ERROR=" + Clean(error.Message));
            } finally {
                if (handler != null) {
                    foreach (AutomationElement window in windows) {
                        try { Automation.RemoveAutomationPropertyChangedEventHandler(window, handler); } catch { }
                    }
                }
            }
            if (rows.Count == 0) rows.Add("NO_TOGGLE_EVENTS");
            return rows.ToArray();
        }

        public static string[] CaptureInvokeEvents(int milliseconds) {
            List<string> rows = new List<string>();
            List<AutomationElement> windows = new List<AutomationElement>();
            AutomationEventHandler handler = null;
            try {
                AutomationElement root = AutomationElement.RootElement;
                foreach (string processName in new string[] { "Discord", "DiscordPTB", "DiscordCanary" }) {
                    foreach (Process process in Process.GetProcessesByName(processName)) {
                        try {
                            PropertyCondition condition = new PropertyCondition(AutomationElement.ProcessIdProperty, process.Id);
                            AutomationElementCollection processWindows = root.FindAll(TreeScope.Children, condition);
                            for (int index = 0; index < processWindows.Count; index++) windows.Add(processWindows[index]);
                        } catch { }
                    }
                }

                handler = delegate(object sender, AutomationEventArgs args) {
                    try {
                        AutomationElement element = sender as AutomationElement;
                        string name = element == null ? String.Empty : element.Current.Name;
                        if (String.Equals(name, "Mute", StringComparison.OrdinalIgnoreCase) || String.Equals(name, "Deafen", StringComparison.OrdinalIgnoreCase)) {
                            lock (rows) rows.Add("INVOKED=" + name);
                        }
                    } catch { }
                };
                foreach (AutomationElement window in windows) {
                    Automation.AddAutomationEventHandler(InvokePattern.InvokedEvent, window, TreeScope.Subtree, handler);
                }
                Thread.Sleep(Math.Max(1000, milliseconds));
            } catch (Exception error) {
                lock (rows) rows.Add("ERROR=" + Clean(error.Message));
            } finally {
                if (handler != null) {
                    foreach (AutomationElement window in windows) {
                        try { Automation.RemoveAutomationEventHandler(InvokePattern.InvokedEvent, window, handler); } catch { }
                    }
                }
            }
            if (rows.Count == 0) rows.Add("NO_INVOKE_EVENTS");
            return rows.ToArray();
        }

        private static string Clean(string value) {
            return (value ?? String.Empty).Replace("\r", " ").Replace("\n", " ").Replace(";", ",");
        }
    }
}
"@

try {
    $script:muteCueAccessibilityRuntime = Import-MuteCueAccessibilityRuntime `
        -OverlayDirectory $scriptDir `
        -SourceText $discordScannerSource `
        -AllowSourceFallback:(Test-MuteCueAccessibilitySourceFallbackAllowed -OverlayDirectory $scriptDir)
    $discordScannerAvailable = $true
    $beacnAppScannerAvailable = $true
} catch {
    $discordScannerAvailable = $false
    $beacnAppScannerAvailable = $false
    $script:muteCueAccessibilityRuntime = $null
    Write-MuteCueDiagnostic -Level Error -Component "Startup" -Message "Accessibility runtime loading failed." -Exception $_.Exception
}
Write-BeacnStateLog -Message ("STARTUP accessibility mode={0}; version={1}; integrity={2}; available={3}" -f `
    $(if ($null -ne $script:muteCueAccessibilityRuntime) { [string]$script:muteCueAccessibilityRuntime.Mode } else { "Unavailable" }), `
    $(if ($null -ne $script:muteCueAccessibilityRuntime) { [string]$script:muteCueAccessibilityRuntime.AssemblyVersion } else { "" }), `
    $(if ($null -ne $script:muteCueAccessibilityRuntime) { [int][bool]$script:muteCueAccessibilityRuntime.IntegrityVerified } else { 0 }), `
    [int]$beacnAppScannerAvailable)
if ($beacnAppScannerAvailable) {
    try {
        Initialize-BeacnScannerAdapter
    } catch {
        $beacnAppScannerAvailable = $false
        Write-MuteCueDiagnostic -Level Error -Component "BEACN" -Message "The BEACN compatibility adapter could not initialize." -Exception $_.Exception
    }
}

$discordRpcSource = @"
using System;
using System.Collections;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.IO;
using System.IO.Pipes;
using System.Net;
using System.Security;
using System.Security.Cryptography;
using System.Text;
using System.Threading;
using System.Web.Script.Serialization;

namespace BeacnMuteOverlay {
    public sealed class DiscordRpcMonitorEvent {
        public string Kind { get; set; }
        public string Status { get; set; }
        public bool Known { get; set; }
        public bool MicMuted { get; set; }
        public bool Deafened { get; set; }
        public string AccessToken { get; set; }
        public string RefreshToken { get; set; }
        public long ExpiresAtUnixSeconds { get; set; }
    }

    public static class DiscordRpcMonitor {
        private const int MaximumQueuedEvents = 256;
        private static readonly ConcurrentQueue<DiscordRpcMonitorEvent> events = new ConcurrentQueue<DiscordRpcMonitorEvent>();
        private static int queuedEventCount;
        private static readonly object lifecycleLock = new object();
        private static volatile bool stopRequested;
        private static Thread worker;
        private static int runGeneration;
        private static NamedPipeClientStream activePipe;
        private static string currentChannelId;
        private static string currentUserId;
        private static string pendingCodeVerifier;
        private static string pendingRedirectUri;

        public static bool IsRunning {
            get { return worker != null && worker.IsAlive; }
        }

        public static string Start(string applicationId, string redirectUri, string accessToken, string refreshToken, long expiresAtUnixSeconds) {
            if (String.IsNullOrWhiteSpace(applicationId)) return "Discord sign-in is not configured in this build.";
            foreach (char character in applicationId) {
                if (!Char.IsDigit(character)) return "The Discord application ID should contain only numbers.";
            }
            if (String.IsNullOrWhiteSpace(redirectUri)) return "Discord sign-in is not configured in this build.";

            Stop();
            ClearEvents();
            int generation = Interlocked.Increment(ref runGeneration);
            stopRequested = false;
            worker = new Thread(delegate() { Run(applicationId.Trim(), redirectUri.Trim(), accessToken, refreshToken, expiresAtUnixSeconds, generation); });
            worker.IsBackground = true;
            worker.Name = "Discord RPC voice monitor";
            worker.Start();
            return "Connecting to Discord...";
        }

        public static void Stop() {
            Thread workerToJoin;
            lock (lifecycleLock) {
                stopRequested = true;
                Interlocked.Increment(ref runGeneration);
                if (activePipe != null) {
                    try { activePipe.Dispose(); } catch { }
                    activePipe = null;
                }
                workerToJoin = worker;
                worker = null;
                currentChannelId = null;
                currentUserId = null;
            }
            if (workerToJoin != null && workerToJoin.IsAlive && Thread.CurrentThread != workerToJoin) {
                try { workerToJoin.Join(1000); } catch { }
            }
        }

        public static bool TryDequeue(out DiscordRpcMonitorEvent update) {
            if (!events.TryDequeue(out update)) return false;
            Interlocked.Decrement(ref queuedEventCount);
            return true;
        }

        private static void EnqueueEvent(DiscordRpcMonitorEvent update) {
            events.Enqueue(update);
            int count = Interlocked.Increment(ref queuedEventCount);
            while (count > MaximumQueuedEvents) {
                DiscordRpcMonitorEvent discarded;
                if (!events.TryDequeue(out discarded)) break;
                Interlocked.Decrement(ref queuedEventCount);
                count = Volatile.Read(ref queuedEventCount);
            }
        }

        private static void ClearEvents() {
            DiscordRpcMonitorEvent discarded;
            while (events.TryDequeue(out discarded)) { }
            Interlocked.Exchange(ref queuedEventCount, 0);
        }

        private static string CreateCodeVerifier() {
            byte[] bytes = new byte[48];
            using (RandomNumberGenerator generator = RandomNumberGenerator.Create()) generator.GetBytes(bytes);
            return ToBase64Url(bytes);
        }

        private static string CreateCodeChallenge(string verifier) {
            using (SHA256 hash = SHA256.Create()) return ToBase64Url(hash.ComputeHash(Encoding.ASCII.GetBytes(verifier)));
        }

        private static string ToBase64Url(byte[] bytes) {
            return Convert.ToBase64String(bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_');
        }

        private static void Run(string applicationId, string redirectUri, string accessToken, string refreshToken, long expiresAtUnixSeconds, int generation) {
            try {
                EmitStatus("Finding Discord's local connection...");
                using (NamedPipeClientStream pipe = OpenPipe(generation)) {
                    if (pipe == null) {
                        EmitStatus("Discord's local connection was not found.");
                        return;
                    }
                    lock (lifecycleLock) { activePipe = pipe; }
                    SendFrame(pipe, 0, "{\"v\":1,\"client_id\":" + Quote(applicationId) + "}");
                    IDictionary<string, object> ready = ReadPayload(pipe);
                    if (!String.Equals(GetString(ready, "evt"), "READY", StringComparison.OrdinalIgnoreCase)) {
                        EmitStatus("Discord did not accept this application ID.");
                        return;
                    }

                    if (!String.IsNullOrWhiteSpace(accessToken) && expiresAtUnixSeconds > DateTimeOffset.UtcNow.ToUnixTimeSeconds() + 30) {
                        EmitStatus("Restoring the saved Discord connection...");
                        SendCommand(pipe, "AUTHENTICATE", null, "{\"access_token\":" + Quote(accessToken) + "}");
                    } else if (!String.IsNullOrWhiteSpace(refreshToken)) {
                        EmitStatus("Refreshing the saved Discord connection...");
                        string refreshedAccessToken;
                        string refreshedRefreshToken;
                        long refreshedExpiresAt;
                        string refreshError;
                        if (RefreshToken(applicationId, refreshToken, out refreshedAccessToken, out refreshedRefreshToken, out refreshedExpiresAt, out refreshError)) {
                            EmitCredentials(refreshedAccessToken, refreshedRefreshToken, refreshedExpiresAt);
                            SendCommand(pipe, "AUTHENTICATE", null, "{\"access_token\":" + Quote(refreshedAccessToken) + "}");
                        } else {
                            EmitStatus("Saved Discord connection expired. Waiting for authorization...");
                            BeginAuthorization(pipe, applicationId, redirectUri);
                        }
                    } else {
                        EmitStatus("Waiting for Discord authorization...");
                        BeginAuthorization(pipe, applicationId, redirectUri);
                    }
                    while (!stopRequested && generation == runGeneration) {
                        IDictionary<string, object> payload = ReadPayload(pipe);
                        HandlePayload(pipe, applicationId, redirectUri, payload);
                    }
                }
            } catch (Exception error) {
                if (!stopRequested && generation == runGeneration) EmitStatus("Discord connection stopped: " + CleanError(error.Message));
            } finally {
                lock (lifecycleLock) { activePipe = null; }
                if (generation == runGeneration) SetVoiceState(false, false, false);
            }
        }

        private static NamedPipeClientStream OpenPipe(int generation) {
            for (int index = 0; index < 10 && !stopRequested && generation == runGeneration; index++) {
                try {
                    NamedPipeClientStream pipe = new NamedPipeClientStream(".", "discord-ipc-" + index, PipeDirection.InOut, PipeOptions.None);
                    pipe.Connect(350);
                    return pipe;
                } catch {
                }
            }
            return null;
        }

        private static void HandlePayload(NamedPipeClientStream pipe, string applicationId, string redirectUri, IDictionary<string, object> payload) {
            string command = GetString(payload, "cmd");
            string eventName = GetString(payload, "evt");
            IDictionary<string, object> data = AsDictionary(GetValue(payload, "data"));

            if (String.Equals(eventName, "ERROR", StringComparison.OrdinalIgnoreCase)) {
                if (String.Equals(command, "AUTHENTICATE", StringComparison.OrdinalIgnoreCase)) {
                    EmitStatus("Saved Discord connection needs approval. Waiting for authorization...");
                    BeginAuthorization(pipe, applicationId, redirectUri);
                    return;
                }
                EmitStatus("Discord: " + CleanError(GetString(data, "message")));
                return;
            }

            if (String.Equals(command, "AUTHORIZE", StringComparison.OrdinalIgnoreCase)) {
                string code = GetString(data, "code");
                if (String.IsNullOrWhiteSpace(code)) {
                    EmitStatus("Discord did not return an authorization code.");
                    return;
                }
                EmitStatus("Discord approved the connection. Signing in...");
                string token;
                string refreshToken;
                long expiresAt;
                string tokenError;
                if (!ExchangeCode(applicationId, redirectUri, code, out token, out refreshToken, out expiresAt, out tokenError)) {
                    EmitStatus("Discord sign-in could not finish: " + tokenError);
                    return;
                }
                EmitCredentials(token, refreshToken, expiresAt);
                SendCommand(pipe, "AUTHENTICATE", null, "{\"access_token\":" + Quote(token) + "}");
                return;
            }

            if (String.Equals(command, "AUTHENTICATE", StringComparison.OrdinalIgnoreCase)) {
                IDictionary<string, object> user = AsDictionary(GetValue(data, "user"));
                currentUserId = GetString(user, "id");
                if (String.IsNullOrWhiteSpace(currentUserId)) {
                    EmitStatus("Discord did not return the signed-in user.");
                    return;
                }
                EmitStatus("Discord connected. Watching voice state.");
                SendCommand(pipe, "SUBSCRIBE", "VOICE_CHANNEL_SELECT", "{}");
                SendCommand(pipe, "GET_SELECTED_VOICE_CHANNEL", null, "{}");
                return;
            }

            if (String.Equals(eventName, "VOICE_CHANNEL_SELECT", StringComparison.OrdinalIgnoreCase)) {
                string channelId = GetString(data, "channel_id");
                if (String.IsNullOrWhiteSpace(channelId)) {
                    UnsubscribeCurrentChannel(pipe);
                    SetVoiceState(false, false, false);
                    EmitStatus("Discord connected. Not in a voice channel.");
                } else {
                    SubscribeToChannel(pipe, channelId);
                    SendCommand(pipe, "GET_CHANNEL", null, "{\"channel_id\":" + Quote(channelId) + "}");
                }
                return;
            }

            if (String.Equals(command, "GET_SELECTED_VOICE_CHANNEL", StringComparison.OrdinalIgnoreCase) ||
                String.Equals(command, "GET_CHANNEL", StringComparison.OrdinalIgnoreCase)) {
                string channelId = GetString(data, "id");
                if (String.IsNullOrWhiteSpace(channelId)) {
                    SetVoiceState(false, false, false);
                    EmitStatus("Discord connected. Not in a voice channel.");
                } else {
                    SubscribeToChannel(pipe, channelId);
                    SyncVoiceState(data);
                }
                return;
            }

            if (String.Equals(eventName, "VOICE_STATE_CREATE", StringComparison.OrdinalIgnoreCase) ||
                String.Equals(eventName, "VOICE_STATE_UPDATE", StringComparison.OrdinalIgnoreCase)) {
                IDictionary<string, object> user = AsDictionary(GetValue(data, "user"));
                if (String.Equals(GetString(user, "id"), currentUserId, StringComparison.Ordinal)) {
                    ApplyVoiceState(AsDictionary(GetValue(data, "voice_state")));
                }
                return;
            }

            if (String.Equals(eventName, "VOICE_STATE_DELETE", StringComparison.OrdinalIgnoreCase)) {
                IDictionary<string, object> user = AsDictionary(GetValue(data, "user"));
                if (String.Equals(GetString(user, "id"), currentUserId, StringComparison.Ordinal)) {
                    UnsubscribeCurrentChannel(pipe);
                    SetVoiceState(false, false, false);
                    EmitStatus("Discord connected. Not in a voice channel.");
                }
            }
        }

        private static void SubscribeToChannel(NamedPipeClientStream pipe, string channelId) {
            if (String.Equals(currentChannelId, channelId, StringComparison.Ordinal)) return;
            UnsubscribeCurrentChannel(pipe);
            currentChannelId = channelId;
            string[] names = { "VOICE_STATE_CREATE", "VOICE_STATE_UPDATE", "VOICE_STATE_DELETE" };
            foreach (string name in names) {
                SendCommand(pipe, "SUBSCRIBE", name, "{\"channel_id\":" + Quote(channelId) + "}");
            }
        }

        private static void UnsubscribeCurrentChannel(NamedPipeClientStream pipe) {
            if (String.IsNullOrWhiteSpace(currentChannelId)) return;
            string[] names = { "VOICE_STATE_CREATE", "VOICE_STATE_UPDATE", "VOICE_STATE_DELETE" };
            foreach (string name in names) {
                try { SendCommand(pipe, "UNSUBSCRIBE", name, "{\"channel_id\":" + Quote(currentChannelId) + "}"); } catch { }
            }
            currentChannelId = null;
        }

        private static void SyncVoiceState(IDictionary<string, object> channel) {
            IEnumerable voiceStates = GetValue(channel, "voice_states") as IEnumerable;
            if (voiceStates == null) {
                SetVoiceState(false, false, false);
                return;
            }
            foreach (object item in voiceStates) {
                IDictionary<string, object> entry = AsDictionary(item);
                IDictionary<string, object> user = AsDictionary(GetValue(entry, "user"));
                if (String.Equals(GetString(user, "id"), currentUserId, StringComparison.Ordinal)) {
                    ApplyVoiceState(AsDictionary(GetValue(entry, "voice_state")));
                    return;
                }
            }
            SetVoiceState(false, false, false);
        }

        private static void ApplyVoiceState(IDictionary<string, object> voiceState) {
            SetVoiceState(true, GetBoolean(voiceState, "self_mute"), GetBoolean(voiceState, "self_deaf"));
        }

        private static void SetVoiceState(bool known, bool micMuted, bool deafened) {
            DiscordRpcMonitorEvent update = new DiscordRpcMonitorEvent();
            update.Kind = "state";
            update.Known = known;
            update.MicMuted = micMuted;
            update.Deafened = deafened;
            EnqueueEvent(update);
        }

        private static void BeginAuthorization(Stream pipe, string applicationId, string redirectUri) {
            string verifier = CreateCodeVerifier();
            string challenge = CreateCodeChallenge(verifier);
            SendCommand(pipe, "AUTHORIZE", null, "{\"client_id\":" + Quote(applicationId) + ",\"scopes\":[\"identify\",\"rpc\"],\"code_challenge\":" + Quote(challenge) + ",\"code_challenge_method\":\"S256\"}");
            pendingCodeVerifier = verifier;
            pendingRedirectUri = redirectUri;
        }

        private static void EmitCredentials(string accessToken, string refreshToken, long expiresAtUnixSeconds) {
            DiscordRpcMonitorEvent update = new DiscordRpcMonitorEvent();
            update.Kind = "credentials";
            update.AccessToken = accessToken;
            update.RefreshToken = refreshToken;
            update.ExpiresAtUnixSeconds = expiresAtUnixSeconds;
            EnqueueEvent(update);
        }

        private static void EmitStatus(string status) {
            DiscordRpcMonitorEvent update = new DiscordRpcMonitorEvent();
            update.Kind = "status";
            update.Status = status;
            EnqueueEvent(update);
        }

        private static bool ExchangeCode(string applicationId, string redirectUri, string code, out string token, out string refreshToken, out long expiresAtUnixSeconds, out string error) {
            List<string> values = new List<string>();
            values.Add("grant_type=authorization_code");
            values.Add("code=" + Uri.EscapeDataString(code));
            if (!String.IsNullOrWhiteSpace(redirectUri)) values.Add("redirect_uri=" + Uri.EscapeDataString(redirectUri));
            values.Add("code_verifier=" + Uri.EscapeDataString(pendingCodeVerifier ?? String.Empty));
            return RequestToken(applicationId, values, out token, out refreshToken, out expiresAtUnixSeconds, out error);
        }

        private static bool RefreshToken(string applicationId, string refreshToken, out string token, out string returnedRefreshToken, out long expiresAtUnixSeconds, out string error) {
            List<string> values = new List<string>();
            values.Add("grant_type=refresh_token");
            values.Add("refresh_token=" + Uri.EscapeDataString(refreshToken));
            return RequestToken(applicationId, values, out token, out returnedRefreshToken, out expiresAtUnixSeconds, out error);
        }

        private static bool RequestToken(string applicationId, List<string> values, out string token, out string refreshToken, out long expiresAtUnixSeconds, out string error) {
            token = null;
            refreshToken = null;
            expiresAtUnixSeconds = 0;
            error = null;
            try {
                ServicePointManager.SecurityProtocol |= SecurityProtocolType.Tls12;
                values.Add("client_id=" + Uri.EscapeDataString(applicationId));
                byte[] body = Encoding.UTF8.GetBytes(String.Join("&", values.ToArray()));
                HttpWebRequest request = (HttpWebRequest)WebRequest.Create("https://discord.com/api/oauth2/token");
                request.Method = "POST";
                request.ContentType = "application/x-www-form-urlencoded";
                request.Accept = "application/json";
                request.UserAgent = "Mute-Cue/1.0";
                request.Timeout = 10000;
                request.ReadWriteTimeout = 10000;
                request.KeepAlive = false;
                request.ContentLength = body.Length;
                using (Stream stream = request.GetRequestStream()) stream.Write(body, 0, body.Length);
                using (HttpWebResponse response = (HttpWebResponse)request.GetResponse())
                using (StreamReader reader = new StreamReader(response.GetResponseStream())) {
                    IDictionary<string, object> payload = AsDictionary(new JavaScriptSerializer().DeserializeObject(reader.ReadToEnd()));
                    token = GetString(payload, "access_token");
                    refreshToken = GetString(payload, "refresh_token");
                    long expiresIn;
                    if (!Int64.TryParse(GetString(payload, "expires_in"), out expiresIn) || expiresIn <= 0) expiresIn = 3600;
                    expiresAtUnixSeconds = DateTimeOffset.UtcNow.ToUnixTimeSeconds() + expiresIn;
                    if (String.IsNullOrWhiteSpace(token)) {
                        error = "Discord did not return an access token.";
                        return false;
                    }
                    return true;
                }
            } catch (WebException webError) {
                error = ReadWebError(webError);
                return false;
            } catch (Exception generalError) {
                error = CleanError(generalError.Message);
                return false;
            }
        }

        private static string ReadWebError(WebException error) {
            try {
                if (error.Response != null) {
                    using (StreamReader reader = new StreamReader(error.Response.GetResponseStream())) {
                        IDictionary<string, object> payload = AsDictionary(new JavaScriptSerializer().DeserializeObject(reader.ReadToEnd()));
                        string description = GetString(payload, "error_description");
                        if (!String.IsNullOrWhiteSpace(description)) return CleanError(description);
                        string code = GetString(payload, "error");
                        if (!String.IsNullOrWhiteSpace(code)) return CleanError(code);
                    }
                }
            } catch { }
            return CleanError(error.Message);
        }

        private static void SendCommand(Stream stream, string command, string eventName, string args) {
            StringBuilder payload = new StringBuilder();
            payload.Append("{\"cmd\":").Append(Quote(command)).Append(",\"nonce\":").Append(Quote(Guid.NewGuid().ToString()));
            if (!String.IsNullOrWhiteSpace(eventName)) payload.Append(",\"evt\":").Append(Quote(eventName));
            payload.Append(",\"args\":").Append(args).Append("}");
            SendFrame(stream, 1, payload.ToString());
        }

        private static IDictionary<string, object> ReadPayload(Stream stream) {
            string json = ReadFrame(stream);
            object payload = new JavaScriptSerializer().DeserializeObject(json);
            IDictionary<string, object> dictionary = AsDictionary(payload);
            if (dictionary == null) throw new InvalidDataException("Discord sent an invalid message.");
            return dictionary;
        }

        private static IDictionary<string, object> AsDictionary(object value) {
            return value as IDictionary<string, object>;
        }

        private static object GetValue(IDictionary<string, object> dictionary, string key) {
            if (dictionary == null) return null;
            object value;
            return dictionary.TryGetValue(key, out value) ? value : null;
        }

        private static string GetString(IDictionary<string, object> dictionary, string key) {
            object value = GetValue(dictionary, key);
            return value == null ? null : Convert.ToString(value);
        }

        private static bool GetBoolean(IDictionary<string, object> dictionary, string key) {
            object value = GetValue(dictionary, key);
            if (value is bool) return (bool)value;
            bool result;
            return value != null && Boolean.TryParse(Convert.ToString(value), out result) && result;
        }

        private static string Quote(string value) {
            return "\"" + (value ?? String.Empty).Replace("\\", "\\\\").Replace("\"", "\\\"").Replace("\r", "\\r").Replace("\n", "\\n") + "\"";
        }

        private static string CleanError(string value) {
            if (String.IsNullOrWhiteSpace(value)) return "Unknown error.";
            return value.Replace("\r", " ").Replace("\n", " ").Trim();
        }

        private static void SendFrame(Stream stream, int opcode, string payload) {
            byte[] body = Encoding.UTF8.GetBytes(payload);
            stream.Write(BitConverter.GetBytes(opcode), 0, 4);
            stream.Write(BitConverter.GetBytes(body.Length), 0, 4);
            stream.Write(body, 0, body.Length);
            stream.Flush();
        }

        private static string ReadFrame(Stream stream) {
            byte[] header = ReadExactly(stream, 8);
            int length = BitConverter.ToInt32(header, 4);
            if (length < 0 || length > 1024 * 1024) throw new InvalidDataException("Discord sent an invalid response.");
            return Encoding.UTF8.GetString(ReadExactly(stream, length));
        }

        private static byte[] ReadExactly(Stream stream, int length) {
            byte[] data = new byte[length];
            int offset = 0;
            while (offset < length) {
                int read = stream.Read(data, offset, length - offset);
                if (read == 0) throw new EndOfStreamException("Discord closed the local connection.");
                offset += read;
            }
            return data;
        }
    }
}
"@

try {
    Add-Type -TypeDefinition $discordRpcSource -ReferencedAssemblies "System.Web.Extensions.dll"
    $discordRpcAvailable = $true
} catch {
    $discordRpcAvailable = $false
    Write-MuteCueDiagnostic -Level Error -Component "Startup" -Message "Discord RPC helper compilation failed." -Exception $_.Exception
}
Write-BeacnStateLog -Message ("STARTUP Discord RPC available={0}" -f [int]$discordRpcAvailable)

$settings = Read-OverlaySettings
$script:lastObservedSettingsWriteStamp = Get-OverlaySettingsWriteStamp
$script:lastExternalSettingsCheckUtc = [DateTime]::MinValue
$script:applyingBeacnFaderRows = $false
$script:settingsSaveTimer = $null
$script:settingsSavePending = $false
$script:settingsSaveObject = $settings
$script:mixCreateMonitor = $null
$script:lastMixCreateStartAttempt = [DateTime]::MinValue
$script:mixCreateUsbAddress = $null
$script:mixCreateUsbCaptureDevice = $null
$script:mixCreateRouteDiscoveryTask = $null
$script:lastMixCreateDiscoveryAttempt = [DateTime]::MinValue
$script:mixCreateMonitorStarted = [DateTime]::MinValue
$script:lastMixCreateStatusPacket = [DateTime]::MinValue
$script:lastMixCreateDroppedPacketCount = 0L
$script:beacnAppScanTask = $null
$script:beacnAppFaderStates = @()
$script:beacnAppFaderStatesByName = @{}
$script:beacnAdapterState = New-BeacnAdapterState
$script:beacnStateCoordinator = New-BeacnStateCoordinator -Adapter $script:beacnAdapterState
$script:lastBeacnIdentityCatalogRefresh = [DateTime]::MinValue
$script:lastBeacnWorkerRestartCount = 0L
$script:beacnAppStateTrackers = $script:beacnAdapterState.Trackers
$script:beacnAppHasAuthority = $false
$script:beacnAppHasActionAuthority = $false
$script:lastBeacnAppScanStart = [DateTime]::MinValue
$script:lastBeacnAppScanSuccess = [DateTime]::MinValue
$script:beacnAppNeedsConfirmation = $false
$script:mixCreateAudienceMute = @{}
$script:mixCreateAllMuteByName = @{}
$script:mixCreateActionModesByName = @{}
$script:pendingBeacnPhysicalActions = New-Object 'System.Collections.Generic.List[object]'
$script:pendingBeacnAllAction = $null
$script:mixCreatePressedKnobButton = 0
$script:mixCreatePressedAudienceButton = 0
$script:mixCreatePressedPageButton = 0
$script:mixCreateHardwarePage = 0
$script:mixCreateHardwarePageKnown = $false
$script:mixCreateHardwareRequestId = 0L
$script:mixCreateMappingGeneration = 0L
$script:beacnHardwareLayoutSignature = ""
$script:lastBeacnHardwareResultSequence = 0L
$script:beacnOptimisticActionStates = @{}
$script:mixCreateAudienceFaderIds = @()
$script:mixCreateAllFaderIds = @()
$script:mixCreateFaderDefinitions = @{}
$script:mixCreateFaderDefinitionsByName = @{}
$script:mixCreateFaderNames = @{}
$script:lastMixCreateFaderLookup = [DateTime]::MinValue
$script:mixCreateFaderConfiguration = $null
$script:discordMuteSources = @()
$script:discordRpcConnected = $false
$script:discordRpcConnecting = $false
$script:discordAuthorization = Get-SavedDiscordAuthorization
$script:beacnHotkeyMappingsPath = Get-MuteCueBeacnKeyMappingsPath
$script:beacnHotkeyBindingsByCode = @{}
$script:beacnHotkeyBindingSignature = $null
$script:lastBeacnHotkeyMappingCheckUtc = [DateTime]::MinValue
$script:beacnHotkeyMissingSinceUtc = [DateTime]::MinValue
$script:beacnHotkeyEmptySinceUtc = [DateTime]::MinValue
$script:pendingBeacnHotkeyRefreshes = @{}

if ($beacnAppScannerAvailable -and -not $script:useBeacnAccessibilityWorker) {
    try { [void](Update-BeacnScannerAdapterConfiguration -Adapter $script:beacnAdapterState -Force) } catch {
        Write-MuteCueDiagnostic -Level Warning -Component "BEACN" -Message "The active BEACN profile could not be loaded into the compatibility adapter." -Exception $_.Exception
    }
}

# Begin the first BEACN read while the settings UI is being constructed. This
# removes the otherwise visible cold-start delay on the user's first mute action.
if ($beacnAppScannerAvailable -and -not $script:useBeacnAccessibilityWorker) {
    try {
        $script:lastBeacnAppScanStart = [DateTime]::UtcNow
        $script:beacnAppScanTask = [BeacnMuteOverlay.BeacnAppScanner]::ScanAsync()
    } catch {
        Write-MuteCueDiagnostic -Level Warning -Component "BEACN" -Message "Initial BEACN state scan could not start." -Exception $_.Exception
    }
}

if ($beacnAppScannerAvailable -and $script:useBeacnAccessibilityWorker) {
    if (-not (Start-BeacnAccessibilityClient -Client $script:beacnAccessibilityClient)) {
        Write-MuteCueDiagnostic -Level Warning -Component "BEACN" -Message "The isolated BEACN accessibility worker could not start; its watchdog will retry."
    }
}

function Get-BeacnScannerTelemetry {
    if ($script:useBeacnAccessibilityWorker -and $null -ne $script:beacnAccessibilityClient) {
        return $script:beacnAccessibilityClient.LastSnapshot
    }
    if (-not $beacnAppScannerAvailable) { return $null }
    try {
        return [pscustomobject]@{
            ScannerStatus = [string][BeacnMuteOverlay.BeacnAppScanner]::CompatibilityStatus
            ScannerDetail = [string][BeacnMuteOverlay.BeacnAppScanner]::CompatibilityDetail
            BeacnVersion = [string][BeacnMuteOverlay.BeacnAppScanner]::BeacnVersion
            DiagnosticSummary = [string][BeacnMuteOverlay.BeacnAppScanner]::DiagnosticSummary
            LastActionEventSummary = [string][BeacnMuteOverlay.BeacnAppScanner]::LastActionEventSummary
            LastScanMilliseconds = [double][BeacnMuteOverlay.BeacnAppScanner]::LastScanMilliseconds
            HasPendingChanges = [bool][BeacnMuteOverlay.BeacnAppScanner]::HasPendingChanges
            GeometryRefreshInProgress = [bool][BeacnMuteOverlay.BeacnAppScanner]::GeometryRefreshInProgress
            GeometryRefreshRemaining = [int][BeacnMuteOverlay.BeacnAppScanner]::GeometryRefreshRemaining
            NativeGeometryGeneration = [long][BeacnMuteOverlay.BeacnAppScanner]::NativeGeometryGeneration
            ScanInProgress = $false
            ScanInProgressMilliseconds = 0.0
            HardwareResultSequence = [long][BeacnMuteOverlay.BeacnAppScanner]::HardwareResultSequence
            LastHardwareChangedName = [string][BeacnMuteOverlay.BeacnAppScanner]::LastHardwareChangedName
            LastHardwarePreferredName = [string][BeacnMuteOverlay.BeacnAppScanner]::LastHardwarePreferredName
            LastHardwareChangedMode = [string][BeacnMuteOverlay.BeacnAppScanner]::LastHardwareChangedMode
            LastHardwarePosition = [int][BeacnMuteOverlay.BeacnAppScanner]::LastHardwarePosition
            LastHardwareRequestId = [long][BeacnMuteOverlay.BeacnAppScanner]::LastHardwareRequestId
            LastHardwareMappingGeneration = [long][BeacnMuteOverlay.BeacnAppScanner]::LastHardwareMappingGeneration
            LastHardwareRefreshSummary = [string][BeacnMuteOverlay.BeacnAppScanner]::LastHardwareRefreshSummary
        }
    } catch { return $null }
}

function Request-BeacnDiscovery {
    if ($script:useBeacnAccessibilityWorker) {
        return Send-BeacnAccessibilityCommand -Client $script:beacnAccessibilityClient -Type Discovery
    }
    try { [BeacnMuteOverlay.BeacnAppScanner]::RequestDiscovery(); return $true } catch { return $false }
}

function Request-BeacnGeometryRefresh {
    if ($script:useBeacnAccessibilityWorker) {
        return Send-BeacnAccessibilityCommand -Client $script:beacnAccessibilityClient -Type GeometryRefresh
    }
    try { [BeacnMuteOverlay.BeacnAppScanner]::RequestGeometryRefresh(); return $true } catch { return $false }
}

function Request-BeacnFaderRefresh {
    param(
        [string]$Name,
        [ValidateSet('All','Audience')][string]$Mode,
        [switch]$Rendered,
        [switch]$Urgent
    )
    if ($script:useBeacnAccessibilityWorker) {
        return Send-BeacnAccessibilityCommand `
            -Client $script:beacnAccessibilityClient `
            -Type $(if ($Urgent) { 'UrgentFaderRefresh' } elseif ($Rendered) { 'RenderedRefresh' } else { 'FaderRefresh' }) `
            -Data @{ Name = $Name; Mode = $Mode }
    }
    try {
        if ($Urgent) {
            [BeacnMuteOverlay.BeacnAppScanner]::RequestUrgentFaderRefresh($Name, $Mode)
        } elseif ($Rendered) {
            [BeacnMuteOverlay.BeacnAppScanner]::RequestRenderedFaderRefresh($Name, $Mode)
        } else {
            [BeacnMuteOverlay.BeacnAppScanner]::RequestFaderRefresh($Name, $Mode)
        }
        return $true
    } catch { return $false }
}

function Request-BeacnPointRefresh {
    param([double]$X, [double]$Y)
    if ($script:useBeacnAccessibilityWorker) {
        return Send-BeacnAccessibilityCommand -Client $script:beacnAccessibilityClient -Type PointRefresh -Data @{ X = $X; Y = $Y }
    }
    try {
        $target = [BeacnMuteOverlay.BeacnAppScanner]::ResolveActionAtPoint($X, $Y)
        if ($null -ne $target) {
            [BeacnMuteOverlay.BeacnAppScanner]::RequestRenderedFaderRefresh($target.Name, $target.Mode)
            return $true
        }
        if ([BeacnMuteOverlay.BeacnAppScanner]::IsTrackedBeacnPoint($X, $Y)) {
            [BeacnMuteOverlay.BeacnAppScanner]::RequestGeometryRefresh()
        }
        return $false
    } catch { return $false }
}

function Request-BeacnHardwareRefresh {
    param(
        [string]$PreferredName,
        [ValidateSet('All','Audience')][string]$Mode,
        [int]$Position,
        [long]$RequestId,
        [long]$MappingGeneration,
        [bool]$MappingConfident
    )
    if ($script:useBeacnAccessibilityWorker) {
        return Send-BeacnAccessibilityCommand -Client $script:beacnAccessibilityClient -Type HardwareRefresh -Data @{
            PreferredName = $PreferredName
            Mode = $Mode
            Position = $Position
            RequestId = $RequestId
            MappingGeneration = $MappingGeneration
            MappingConfident = $MappingConfident
        }
    }
    try {
        [BeacnMuteOverlay.BeacnAppScanner]::RequestHardwareRefresh(
            $PreferredName, $Mode, $Position, $RequestId, $MappingGeneration, $MappingConfident
        )
        return $true
    } catch { return $false }
}

function Get-ToggleStateName {
    param([System.Windows.Automation.AutomationElement]$Element)

    try {
        $pattern = $null
        if (-not $Element.TryGetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern, [ref]$pattern)) {
            return $null
        }
        return [string]$pattern.Current.ToggleState
    } catch {
        return $null
    }
}

function Add-AutomationElements {
    param(
        [System.Collections.Generic.List[System.Windows.Automation.AutomationElement]]$Elements,
        [System.Windows.Automation.AutomationElement]$Element,
        [int]$Depth,
        [int]$MaxDepth
    )

    if ($null -eq $Element -or $Depth -gt $MaxDepth) { return }
    $Elements.Add($Element)
    if ($Depth -eq $MaxDepth) { return }

    try {
        $walker = [System.Windows.Automation.TreeWalker]::ControlViewWalker
        $child = $walker.GetFirstChild($Element)
        $count = 0
        while ($child -ne $null -and $count -lt 700) {
            Add-AutomationElements -Elements $Elements -Element $child -Depth ($Depth + 1) -MaxDepth $MaxDepth
            $child = $walker.GetNextSibling($child)
            $count++
        }
    } catch {}
}

function Get-WatchedFaderNames {
    $rawNames = [string]$settings.BeacnFaderNames
    if ([string]::IsNullOrWhiteSpace($rawNames)) { $rawNames = "Mic" }

    return @(
        $rawNames -split "," |
            ForEach-Object { $_.Trim() } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
            Select-Object -Unique
    )
}

function Update-ExternalFaderSelectionSettings {
    $now = [DateTime]::UtcNow
    if (($now - $script:lastExternalSettingsCheckUtc).TotalMilliseconds -lt 250) { return }
    $script:lastExternalSettingsCheckUtc = $now

    $writeStamp = Get-OverlaySettingsWriteStamp
    if ($writeStamp -eq $script:lastObservedSettingsWriteStamp) { return }
    $script:lastObservedSettingsWriteStamp = $writeStamp

    try {
        $externalSettings = Read-OverlaySettings
        $currentSignature = Get-MuteCueFaderSelectionSignature -Settings $settings
        $externalSignature = Get-MuteCueFaderSelectionSignature -Settings $externalSettings
        if ($currentSignature -eq $externalSignature) { return }

        [void](Copy-MuteCueFaderSelectionSettings -Source $externalSettings -Destination $settings)
        $script:mixCreateFaderConfiguration = $null
        if ($null -ne $script:beacnOptimisticActionStates) {
            $script:beacnOptimisticActionStates.Clear()
        }
        if ($null -ne (Get-Command Update-BeacnFaderRows -ErrorAction SilentlyContinue)) {
            Update-BeacnFaderRows
        }
        Write-MuteCueDiagnosticThrottled `
            -Key "external-fader-settings" `
            -Level Info `
            -Component "Configuration" `
            -Message "Applied fader selections saved by the native settings window." `
            -MinimumIntervalSeconds 1
    } catch {
        Write-MuteCueDiagnosticThrottled `
            -Key "external-fader-settings" `
            -Level Warning `
            -Component "Configuration" `
            -Message "A fader selection update could not be applied yet; Mute Cue will retry." `
            -Exception $_.Exception `
            -MinimumIntervalSeconds 30
    }
}

function Test-BeacnAppStateFresh {
    return (
        $script:beacnAppHasAuthority -and
        $script:beacnAppFaderStates.Count -gt 0 -and
        ([DateTime]::UtcNow - $script:lastBeacnAppScanSuccess).TotalSeconds -lt 15
    )
}

function Test-BeacnAppActionStateFresh {
    return (
        (Test-BeacnAppStateFresh) -and
        $script:beacnAppHasActionAuthority
    )
}

function Update-BeacnDesktopClickActions {
    if (-not $mouseHookAvailable) { return }
    if ($script:useBeacnAccessibilityWorker) {
        $workerClickX = 0
        $workerClickY = 0
        while ([BeacnMuteOverlay.KeyboardInput]::ConsumeLeftClick([ref]$workerClickX, [ref]$workerClickY)) {
            [void](Request-BeacnPointRefresh -X ([double]$workerClickX) -Y ([double]$workerClickY))
            $workerClickX = 0
            $workerClickY = 0
        }
        return
    }
    $stateIsAuthoritative = (Test-BeacnAppStateFresh) -and (Test-BeacnAppActionStateFresh)
    $clickX = 0
    $clickY = 0
    while ([BeacnMuteOverlay.KeyboardInput]::ConsumeLeftClick([ref]$clickX, [ref]$clickY)) {
        if ($stateIsAuthoritative) {
            $target = $null
            try {
                $target = [BeacnMuteOverlay.BeacnAppScanner]::ResolveActionAtPoint(
                    [double]$clickX,
                    [double]$clickY
                )
            } catch { }
            if ($null -ne $target -and -not [string]::IsNullOrWhiteSpace([string]$target.Name)) {
                Write-BeacnStateLog -Message ("REQUEST desktop named row {0}/{1} at {2},{3}" -f $target.Name, $target.Mode, $clickX, $clickY)
                [BeacnMuteOverlay.BeacnAppScanner]::RequestRenderedFaderRefresh(
                    [string]$target.Name,
                    [string]$target.Mode
                )
            } elseif ([BeacnMuteOverlay.BeacnAppScanner]::IsTrackedBeacnPoint([double]$clickX, [double]$clickY)) {
                # An unresolved click can mean BEACN rebuilt its accessibility tree.
                # Reacquire controls, but never guess a source or mute mode.
                [void](Request-BeacnGeometryRefresh)
            }
        } elseif ([BeacnMuteOverlay.BeacnAppScanner]::IsTrackedBeacnPoint([double]$clickX, [double]$clickY)) {
            [void](Request-BeacnGeometryRefresh)
        }
        $clickX = 0
        $clickY = 0
    }
}

function Set-BeacnHotkeyListenerBindings {
    param([AllowNull()][object[]]$Bindings)

    $bindingMap = @{}
    foreach ($binding in @($Bindings)) {
        if ($null -eq $binding) { continue }
        $bindingMap[[int]$binding.GestureCode] = [pscustomobject]@{
            Name = [string]$binding.Name
            Mode = [string]$binding.Mode
        }
    }
    $signature = @(
        $bindingMap.GetEnumerator() |
            Sort-Object { [int]$_.Key } |
            ForEach-Object { '{0}|{1}|{2}' -f [int]$_.Key, [string]$_.Value.Name, [string]$_.Value.Mode }
    ) -join ';'
    $configurationChanged = -not [string]::Equals(
        [string]$script:beacnHotkeyBindingSignature,
        $signature,
        [StringComparison]::Ordinal
    )
    if (-not $configurationChanged -and ($bindingMap.Count -eq 0 -or $script:keyboardHookAvailable)) {
        return
    }

    $script:beacnHotkeyBindingsByCode = $bindingMap
    $script:beacnHotkeyBindingSignature = $signature
    try {
        $gestureCodes = [int[]]@($bindingMap.Keys | ForEach-Object { [int]$_ } | Sort-Object)
        $listenerStarted = [BeacnMuteOverlay.KeyboardInput]::StartKeyboardListener($gestureCodes)
        $script:keyboardHookAvailable = ($bindingMap.Count -gt 0 -and $listenerStarted)
        if ($bindingMap.Count -gt 0 -and -not $script:keyboardHookAvailable) {
            Write-MuteCueDiagnosticThrottled `
                -Key 'beacn-hotkey-listener' `
                -Level Warning `
                -Component 'BEACN' `
                -Message 'BEACN knob-mute shortcuts were found, but the shortcut listener could not start.' `
                -MinimumIntervalSeconds 30
        }
    } catch {
        $script:keyboardHookAvailable = $false
        Write-MuteCueDiagnosticThrottled `
            -Key 'beacn-hotkey-listener' `
            -Level Warning `
            -Component 'BEACN' `
            -Message 'The BEACN shortcut listener could not be configured.' `
            -Exception $_.Exception `
            -MinimumIntervalSeconds 30
    }

    if ($configurationChanged) {
        Write-BeacnStateLog -Message ('CONFIG BEACN knob-mute shortcuts={0}' -f $bindingMap.Count)
        Write-MuteCueDiagnostic `
            -Level Info `
            -Component 'BEACN' `
            -Message ('Following {0} BEACN knob-mute shortcut assignment(s).' -f $bindingMap.Count)
    }
}

function Update-BeacnHotkeyConfiguration {
    param([switch]$Force)

    $now = [DateTime]::UtcNow
    if (-not $Force -and ($now - $script:lastBeacnHotkeyMappingCheckUtc).TotalSeconds -lt 2) { return }
    $script:lastBeacnHotkeyMappingCheckUtc = $now

    if (-not [bool]$settings.BeacnDirectDetect) {
        Set-BeacnHotkeyListenerBindings -Bindings @()
        return
    }

    $snapshot = Read-MuteCueBeacnHotkeyMappings -Path $script:beacnHotkeyMappingsPath
    if (-not [bool]$snapshot.Success) {
        Write-MuteCueDiagnosticThrottled `
            -Key 'beacn-hotkey-mappings-read' `
            -Level Warning `
            -Component 'BEACN' `
            -Message 'BEACN shortcut assignments could not be reread; the last working assignments remain active.' `
            -MinimumIntervalSeconds 30
        return
    }

    if (-not [bool]$snapshot.Exists) {
        $script:beacnHotkeyEmptySinceUtc = [DateTime]::MinValue
        if ($script:beacnHotkeyMissingSinceUtc -eq [DateTime]::MinValue) {
            $script:beacnHotkeyMissingSinceUtc = $now
        }
        if (
            $script:beacnHotkeyBindingsByCode.Count -gt 0 -and
            ($now - $script:beacnHotkeyMissingSinceUtc).TotalSeconds -lt 5
        ) {
            return
        }
        Set-BeacnHotkeyListenerBindings -Bindings @()
        return
    }
    $script:beacnHotkeyMissingSinceUtc = [DateTime]::MinValue

    $assignments = @($snapshot.Assignments)
    if ($assignments.Count -eq 0 -and $script:beacnHotkeyBindingsByCode.Count -gt 0) {
        if ($script:beacnHotkeyEmptySinceUtc -eq [DateTime]::MinValue) {
            $script:beacnHotkeyEmptySinceUtc = $now
            return
        }
        if (($now - $script:beacnHotkeyEmptySinceUtc).TotalSeconds -lt 1) { return }
    } else {
        $script:beacnHotkeyEmptySinceUtc = [DateTime]::MinValue
    }

    $bindings = @(Get-MuteCueBeacnHotkeyBindings -Assignments $assignments)
    $textualAssignmentCount = @($assignments | ForEach-Object { [string]$_.Key } | Sort-Object -Unique).Count
    if ($textualAssignmentCount -gt $bindings.Count) {
        Write-MuteCueDiagnosticThrottled `
            -Key 'beacn-hotkey-mappings-unsupported' `
            -Level Warning `
            -Component 'BEACN' `
            -Message 'One or more BEACN knob-mute shortcuts use an unsupported or conflicting key and were ignored.' `
            -MinimumIntervalSeconds 30
    }
    Set-BeacnHotkeyListenerBindings -Bindings $bindings
}

function Resolve-BeacnHotkeyLiveFaderName {
    param([string]$Name)

    $availableNames = [string[]]@(
        $script:beacnAppFaderStates |
            ForEach-Object { ([string]$_.Name).Trim() } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
            Select-Object -Unique
    )
    return Resolve-MuteCueBeacnHotkeyFaderName -Name $Name -AvailableNames $availableNames
}

function Test-BeacnHotkeyOptimisticActionAllowed {
    param([string]$Name)

    $telemetry = Get-BeacnScannerTelemetry
    if ($null -eq $telemetry) { return $false }
    $geometryProperty = $telemetry.PSObject.Properties['GeometryRefreshInProgress']
    if ($null -ne $geometryProperty -and [bool]$geometryProperty.Value) { return $false }
    if ($script:useBeacnAccessibilityWorker) {
        if (
            $null -eq $script:beacnAccessibilityClient -or
            -not (Test-BeacnAccessibilityClientRunning -Client $script:beacnAccessibilityClient)
        ) { return $false }
        $health = Get-BeacnCoordinatorHealth `
            -Coordinator $script:beacnStateCoordinator `
            -WorkerRunning $true `
            -Now ([DateTime]::UtcNow)
        if ([string]$health.Status -ne 'Healthy') { return $false }
    }

    $faderPresent = (
        -not [string]::IsNullOrWhiteSpace($Name) -and
        $script:beacnAppFaderStatesByName.ContainsKey($Name)
    )
    $actionStateKnown = $false
    if ($faderPresent) {
        $actionStateKnown = [bool]$script:beacnAppFaderStatesByName[$Name].ActionStateKnown
    }
    $stateAgeSeconds = if ($script:lastBeacnAppScanSuccess -eq [DateTime]::MinValue) {
        [double]::PositiveInfinity
    } else {
        ([DateTime]::UtcNow - $script:lastBeacnAppScanSuccess).TotalSeconds
    }
    return Test-BeacnAuthoritativePreviewAllowed `
        -HasActionAuthority ([bool]$script:beacnAppHasActionAuthority) `
        -NeedsConfirmation ([bool]$script:beacnAppNeedsConfirmation) `
        -StateAgeSeconds $stateAgeSeconds `
        -CompatibilityStatus ([string]$script:beacnAdapterState.CompatibilityStatus) `
        -FaderPresent $faderPresent `
        -ActionStateKnown $actionStateKnown
}

function Request-BeacnHotkeyFaderRefresh {
    param(
        [string]$Name,
        [ValidateSet('All','Audience')][string]$Mode,
        [switch]$ScheduleFollowUps
    )

    $resolvedName = Resolve-BeacnHotkeyLiveFaderName -Name $Name
    if ([string]::IsNullOrWhiteSpace($resolvedName)) { return }
    if (-not (Test-BeacnAppStateFresh)) { [void](Request-BeacnDiscovery) }
    # The explicit mapping gives us the exact row, so use the same rendered
    # hit-test-first path as a desktop click. It validates BEACN ownership and
    # safely falls back to the accessibility subtree when the row is occluded.
    [void](Request-BeacnFaderRefresh -Name $resolvedName -Mode $Mode -Rendered -Urgent)

    if ($ScheduleFollowUps) {
        $identity = '{0}{1}{2}' -f $resolvedName.ToUpperInvariant(), [char]0, $Mode.ToUpperInvariant()
        if ($script:pendingBeacnHotkeyRefreshes.Count -ge 32 -and -not $script:pendingBeacnHotkeyRefreshes.ContainsKey($identity)) {
            $oldest = @(
                $script:pendingBeacnHotkeyRefreshes.GetEnumerator() |
                    Sort-Object { [DateTime]$_.Value.CreatedUtc } |
                    Select-Object -First 1
            )
            if ($oldest.Count -gt 0) { [void]$script:pendingBeacnHotkeyRefreshes.Remove([string]$oldest[0].Key) }
        }
        $script:pendingBeacnHotkeyRefreshes[$identity] = [pscustomobject]@{
            Name = $resolvedName
            Mode = $Mode
            CreatedUtc = [DateTime]::UtcNow
            DueUtc = [DateTime]::UtcNow.AddMilliseconds(60)
            Remaining = 2
        }
    }
}

function Invoke-BeacnHotkeyGestureQueue {
    if ($script:keyboardHookAvailable -and $script:beacnHotkeyBindingsByCode.Count -gt 0) {
        $gestureCode = 0
        $processed = 0
        while (
            $processed -lt 64 -and
            [BeacnMuteOverlay.KeyboardInput]::ConsumeKeyGesture([ref]$gestureCode)
        ) {
            $processed++
            if ($script:beacnHotkeyBindingsByCode.ContainsKey([int]$gestureCode)) {
                $binding = $script:beacnHotkeyBindingsByCode[[int]$gestureCode]
                $resolvedName = Resolve-BeacnHotkeyLiveFaderName -Name ([string]$binding.Name)
                $optimistic = $false
                if (Test-BeacnHotkeyOptimisticActionAllowed -Name $resolvedName) {
                    $optimistic = [bool](Set-BeacnOptimisticAction `
                        -Name $resolvedName `
                        -Mode ([string]$binding.Mode))
                }
                Write-BeacnStateLog -Message ('REQUEST BEACN shortcut mapped to {0}/{1}; preview={2}' -f $resolvedName, $binding.Mode, [int]$optimistic)
                Request-BeacnHotkeyFaderRefresh `
                    -Name $resolvedName `
                    -Mode ([string]$binding.Mode) `
                    -ScheduleFollowUps
            }
            $gestureCode = 0
        }
    }
}

function Update-BeacnHotkeyActions {
    Update-BeacnHotkeyConfiguration
    Invoke-BeacnHotkeyGestureQueue

    $now = [DateTime]::UtcNow
    foreach ($identity in @($script:pendingBeacnHotkeyRefreshes.Keys)) {
        $pending = $script:pendingBeacnHotkeyRefreshes[$identity]
        if ($null -eq $pending -or $now -lt [DateTime]$pending.DueUtc) { continue }
        Request-BeacnHotkeyFaderRefresh -Name ([string]$pending.Name) -Mode ([string]$pending.Mode)
        $pending.Remaining = [int]$pending.Remaining - 1
        if ([int]$pending.Remaining -le 0) {
            [void]$script:pendingBeacnHotkeyRefreshes.Remove($identity)
        } else {
            $pending.DueUtc = [DateTime]::UtcNow.AddMilliseconds(90)
        }
    }
}

function Update-BeacnTrackerMode {
    param([object]$Tracker)

    if ($null -eq $Tracker) { return }
    $Tracker.Mode = if ([bool]$Tracker.AllActive -and [bool]$Tracker.AudienceActive) {
        "Both"
    } elseif ([bool]$Tracker.AllActive) {
        "All"
    } elseif ([bool]$Tracker.AudienceActive) {
        "Audience"
    } else {
        $null
    }
}

function Toggle-BeacnTrackedMuteLayer {
    param(
        [string]$Name,
        [ValidateSet("All", "Audience")][string]$Mode
    )

    if (-not $script:beacnAppStateTrackers.ContainsKey($Name)) { return $false }
    $tracker = $script:beacnAppStateTrackers[$Name]
    if ($Mode -eq "All") {
        $tracker.AllActive = -not [bool]$tracker.AllActive
    } else {
        $tracker.AudienceActive = -not [bool]$tracker.AudienceActive
    }
    Update-BeacnTrackerMode -Tracker $tracker
    return $true
}

function Get-BeacnPendingPhysicalAction {
    param(
        [ValidateSet("All", "Audience")][string]$Mode,
        [string]$ConfirmedSourceName = ""
    )

    $now = [DateTime]::UtcNow
    for ($index = $script:pendingBeacnPhysicalActions.Count - 1; $index -ge 0; $index--) {
        $candidate = $script:pendingBeacnPhysicalActions[$index]
        if (($now - [DateTime]$candidate.At).TotalSeconds -ge 3) {
            $script:pendingBeacnPhysicalActions.RemoveAt($index)
        }
    }

    for ($index = 0; $index -lt $script:pendingBeacnPhysicalActions.Count; $index++) {
        $candidate = $script:pendingBeacnPhysicalActions[$index]
        if ([string]$candidate.Mode -ne $Mode) { continue }
        if (-not [string]::IsNullOrWhiteSpace($ConfirmedSourceName)) {
            $sourceMatch = Get-BeacnPhysicalSourceMatch `
                -Position ([int]$candidate.Position) `
                -SourceName $ConfirmedSourceName
            if ($null -eq $sourceMatch) { continue }
            $candidate | Add-Member -NotePropertyName ConfirmedPage -NotePropertyValue $sourceMatch.Page -Force
        }
        $script:pendingBeacnPhysicalActions.RemoveAt($index)
        return $candidate
    }
    return $null
}

function Update-BeacnAppFaderStateLegacy {
    if (-not $beacnAppScannerAvailable) { return }

    $now = [DateTime]::UtcNow
    if (
        $null -ne $script:pendingBeacnAllAction -and
        ($now - [DateTime]$script:pendingBeacnAllAction.At).TotalSeconds -ge 3
    ) {
        $script:pendingBeacnAllAction = $null
    }
    $task = $script:beacnAppScanTask
    if ($null -ne $task) {
        if (-not $task.IsCompleted) { return }

        try {
            $result = @($task.Result | Sort-Object Order)
            Update-BeacnHardwareRefreshResult
            if ($result.Count -gt 0) {
                if ($LogBeacnState) {
                    $hardwareLogSignature = [string][BeacnMuteOverlay.BeacnAppScanner]::LastHardwareRefreshSummary
                    if ($hardwareLogSignature -ne $script:lastBeacnHardwareLogSignature) {
                        $script:lastBeacnHardwareLogSignature = $hardwareLogSignature
                        Write-BeacnStateLog -Message ("HARDWARE {0}" -f $hardwareLogSignature)
                    }
                    $rawLogSignature = @(
                        $result | ForEach-Object {
                            "{0}:A{1}{2}:U{3}{4}" -f `
                                [string]$_.Name, `
                                [int][bool]$_.AllActionStateKnown, `
                                [int][bool]$_.AllActionActive, `
                                [int][bool]$_.AudienceActionStateKnown, `
                                [int][bool]$_.AudienceActionActive
                        }
                    ) -join "|"
                    if ($rawLogSignature -ne $script:lastBeacnRawLogSignature) {
                        $script:lastBeacnRawLogSignature = $rawLogSignature
                        Write-BeacnStateLog -Message ("RAW {0} [{1}]" -f $rawLogSignature, [BeacnMuteOverlay.BeacnAppScanner]::DiagnosticSummary)
                    }
                }
                $stableStates = New-Object 'System.Collections.Generic.List[object]'
                $statesByName = @{}
                $needsConfirmation = $false
                foreach ($state in $result) {
                    $name = [string]$state.Name
                    if ([string]::IsNullOrWhiteSpace($name)) { continue }

                    # An active BEACN action row replaces its menu button with a
                    # non-button status icon. This structural state is independent
                    # for All and Audience, including when both output toggles alone
                    # would be ambiguous. Require two matching snapshots so a JUCE
                    # redraw cannot briefly expose an intermediate state.
                    $directActionStateKnown = (
                        [bool]$state.AllActionStateKnown -and
                        [bool]$state.AudienceActionStateKnown
                    )
                    if ($directActionStateKnown) {
                        if (-not $script:beacnAppStateTrackers.ContainsKey($name)) {
                            $script:beacnAppStateTrackers[$name] = New-BeacnActionTracker
                        }
                        $tracker = $script:beacnAppStateTrackers[$name]
                        $snapshotResult = Submit-BeacnDirectActionSnapshot `
                            -Tracker $tracker `
                            -AllActive ([bool]$state.AllActionActive) `
                            -AudienceActive ([bool]$state.AudienceActionActive)
                        if ([bool]$snapshotResult.NeedsConfirmation) {
                            $needsConfirmation = $true
                        }
                        if ([bool]$snapshotResult.Committed) {
                            $tracker.PersonalMuted = [bool]$state.PersonalMuted
                            $tracker.AudienceMuted = [bool]$state.AudienceMuted
                        }
                        if ($script:mixCreateActionModesByName.ContainsKey($name)) {
                            [void]$script:mixCreateActionModesByName.Remove($name)
                        }
                    } else {
                    $signature = if ($directActionStateKnown) {
                        # Aggregate Personal/Audience output toggles can change for
                        # unrelated reasons. Stabilize only the two independent rows.
                        "direct:{0}:{1}" -f `
                            [int][bool]$state.AllActionActive, `
                            [int][bool]$state.AudienceActionActive
                    } else {
                        "outputs:{0}:{1}" -f [int][bool]$state.PersonalMuted, [int][bool]$state.AudienceMuted
                    }
                    if (-not $script:beacnAppStateTrackers.ContainsKey($name)) {
                        $script:beacnAppStateTrackers[$name] = [pscustomobject]@{
                            Pending = $signature
                            Confirmations = 1
                            Known = $false
                            PersonalMuted = $false
                            AudienceMuted = $false
                            Mode = $null
                            AllActive = $false
                            AudienceActive = $false
                        }
                    } else {
                        $tracker = $script:beacnAppStateTrackers[$name]
                        if ([string]$tracker.Pending -eq $signature) {
                            $tracker.Confirmations++
                        } else {
                            $tracker.Pending = $signature
                            $tracker.Confirmations = 1
                        }
                    }

                    $tracker = $script:beacnAppStateTrackers[$name]
                    if ($tracker.Confirmations -lt 2) { $needsConfirmation = $true }
                    if ($tracker.Confirmations -ge 2) {
                        $newPersonalMuted = [bool]$state.PersonalMuted
                        $newAudienceMuted = [bool]$state.AudienceMuted
                        if ($directActionStateKnown) {
                            # The software rows are authoritative. Do not merge mouse,
                            # hotkey, USB, or previous-frame predictions into this state.
                            $tracker.AllActive = [bool]$state.AllActionActive
                            $tracker.AudienceActive = [bool]$state.AudienceActionActive
                            Update-BeacnTrackerMode -Tracker $tracker
                            if ($script:mixCreateActionModesByName.ContainsKey($name)) {
                                [void]$script:mixCreateActionModesByName.Remove($name)
                            }
                        } else {
                            $stateChanged = (
                                -not [bool]$tracker.Known -or
                                [bool]$tracker.PersonalMuted -ne $newPersonalMuted -or
                                [bool]$tracker.AudienceMuted -ne $newAudienceMuted
                            )

                            if ($stateChanged) {
                            $personalChanged = [bool]$tracker.Known -and ([bool]$tracker.PersonalMuted -ne $newPersonalMuted)
                            $audienceChanged = [bool]$tracker.Known -and ([bool]$tracker.AudienceMuted -ne $newAudienceMuted)
                            $recentActionMode = $null
                            $actionAppliedImmediately = $false
                            if ($script:mixCreateActionModesByName.ContainsKey($name)) {
                                $action = $script:mixCreateActionModesByName[$name]
                                if (([DateTime]::UtcNow - [DateTime]$action.At).TotalSeconds -lt 3) {
                                    $recentActionMode = [string]$action.Mode
                                    $appliedProperty = $action.PSObject.Properties["AppliedImmediately"]
                                    if ($null -ne $appliedProperty) {
                                        $actionAppliedImmediately = [bool]$appliedProperty.Value
                                    }
                                } else {
                                    [void]$script:mixCreateActionModesByName.Remove($name)
                                }
                            }

                            # A rapid page change can briefly make the predicted
                            # physical source differ from the source that BEACN
                            # actually changed. Reconcile that prediction against
                            # the first authoritative live-state edge. This rolls
                            # back the wrong overlay entry instead of leaving it on.
                            $physicalAction = $null
                            if ([bool]$tracker.Known) {
                                $physicalEdgeMode = if ($personalChanged) {
                                    "All"
                                } elseif ($audienceChanged) {
                                    "Audience"
                                } else {
                                    $null
                                }
                                if (-not [string]::IsNullOrWhiteSpace($physicalEdgeMode)) {
                                    $physicalAction = Get-BeacnPendingPhysicalAction `
                                        -Mode $physicalEdgeMode `
                                        -ConfirmedSourceName $name
                                }
                            }
                            if ($null -ne $physicalAction) {
                                $confirmedPageProperty = $physicalAction.PSObject.Properties["ConfirmedPage"]
                                if ($null -ne $confirmedPageProperty -and $null -ne $confirmedPageProperty.Value) {
                                    $script:mixCreateHardwarePage = [int]$confirmedPageProperty.Value
                                }
                                $predictedName = [string]$physicalAction.PredictedName
                                if ([string]::Equals($predictedName, $name, [StringComparison]::OrdinalIgnoreCase)) {
                                    $recentActionMode = [string]$physicalAction.Mode
                                    $actionAppliedImmediately = [bool]$physicalAction.AppliedImmediately
                                } else {
                                    [void](Toggle-BeacnTrackedMuteLayer -Name $predictedName -Mode ([string]$physicalAction.Mode))
                                    if ($script:mixCreateActionModesByName.ContainsKey($predictedName)) {
                                        $predictedMarker = $script:mixCreateActionModesByName[$predictedName]
                                        $markerIdProperty = $predictedMarker.PSObject.Properties["ActionId"]
                                        if (
                                            $null -ne $markerIdProperty -and
                                            [string]$markerIdProperty.Value -eq [string]$physicalAction.ActionId
                                        ) {
                                            [void]$script:mixCreateActionModesByName.Remove($predictedName)
                                        }
                                    }
                                    $recentActionMode = $null
                                    $actionAppliedImmediately = $false
                                }
                            }

                            # Fallback for a hardware press received during startup,
                            # before the live fader order and lock state were ready.
                            if (
                                $null -eq $physicalAction -and
                                [string]::IsNullOrWhiteSpace($recentActionMode) -and
                                $null -ne $script:pendingBeacnAllAction -and
                                [bool]$tracker.Known -and
                                ($personalChanged -or $audienceChanged) -and
                                ([DateTime]::UtcNow - [DateTime]$script:pendingBeacnAllAction.At).TotalSeconds -lt 3
                            ) {
                                $recentActionMode = "All"
                                $actionAppliedImmediately = $false
                                $script:pendingBeacnAllAction = $null
                            }

                            if (-not [bool]$tracker.Known) {
                                $tracker.AllActive = ($newPersonalMuted -and $newAudienceMuted)
                                $tracker.AudienceActive = (-not $newPersonalMuted -and $newAudienceMuted)
                            } elseif (-not [string]::IsNullOrWhiteSpace($recentActionMode)) {
                                if (-not $actionAppliedImmediately) {
                                    if ($recentActionMode -eq "All") {
                                        $tracker.AllActive = -not [bool]$tracker.AllActive
                                    } else {
                                        $tracker.AudienceActive = -not [bool]$tracker.AudienceActive
                                    }
                                }
                            } elseif ($personalChanged) {
                                # Mute to Audience never changes Personal. Any
                                # Personal edge is therefore an All action, whether
                                # Audience changed in the same render frame or not.
                                $tracker.AllActive = -not [bool]$tracker.AllActive
                            } elseif ($audienceChanged) {
                                # Audience is an independent action layer. When All
                                # is already active, BEACN's aggregate Audience bit
                                # may move in the opposite direction, so the edge—not
                                # the resulting aggregate value—is authoritative.
                                $tracker.AudienceActive = -not [bool]$tracker.AudienceActive
                            }

                            Update-BeacnTrackerMode -Tracker $tracker
                            if ($script:mixCreateActionModesByName.ContainsKey($name)) {
                                [void]$script:mixCreateActionModesByName.Remove($name)
                            }
                            }
                        }

                        $tracker.Known = $true
                        $tracker.PersonalMuted = $newPersonalMuted
                        $tracker.AudienceMuted = $newAudienceMuted
                    }
                    }

                    $stableState = [pscustomobject]@{
                        Order = [int]$state.Order
                        Name = $name
                        IsLocked = [bool]$state.IsLocked
                        PersonalMuted = ([bool]$tracker.Known -and [bool]$tracker.PersonalMuted)
                        AudienceMuted = ([bool]$tracker.Known -and [bool]$tracker.AudienceMuted)
                        Mode = if ([bool]$tracker.Known) { [string]$tracker.Mode } else { $null }
                        AllActive = ([bool]$tracker.Known -and [bool]$tracker.AllActive)
                        AudienceActive = ([bool]$tracker.Known -and [bool]$tracker.AudienceActive)
                        ActionStateKnown = ([bool]$tracker.Known -and $directActionStateKnown)
                        HasAllActionBounds = [bool]$state.HasAllActionBounds
                        AllActionLeft = [double]$state.AllActionLeft
                        AllActionTop = [double]$state.AllActionTop
                        AllActionRight = [double]$state.AllActionRight
                        AllActionBottom = [double]$state.AllActionBottom
                        HasAudienceActionBounds = [bool]$state.HasAudienceActionBounds
                        AudienceActionLeft = [double]$state.AudienceActionLeft
                        AudienceActionTop = [double]$state.AudienceActionTop
                        AudienceActionRight = [double]$state.AudienceActionRight
                        AudienceActionBottom = [double]$state.AudienceActionBottom
                    }
                    [void]$stableStates.Add($stableState)
                    $statesByName[$name] = $stableState

                    # Keep the USB/local fallback synchronized with BEACN's exact
                    # live state whenever the desktop app is available.
                    $faderId = [int]$stableState.Order
                    $script:mixCreateAudienceMute[$faderId] = [bool]$stableState.AudienceActive
                    $script:mixCreateAllMuteByName[$name] = [bool]$stableState.AllActive
                }
                $script:beacnAppFaderStates = @($stableStates.ToArray())
                Update-BeacnHardwareLayoutConfidence
                $script:beacnAppNeedsConfirmation = $needsConfirmation
                $script:beacnAppFaderStatesByName = $statesByName
                $script:beacnAppHasAuthority = $true
                $script:beacnAppHasActionAuthority = (
                    $script:beacnAppFaderStates.Count -gt 0 -and
                    @($script:beacnAppFaderStates | Where-Object { -not [bool]$_.ActionStateKnown }).Count -eq 0
                )
                if ($script:beacnAppHasActionAuthority) {
                    # Discard predictions left by the legacy USB/page fallback as
                    # soon as BEACN's own independent action state is available.
                    $script:pendingBeacnPhysicalActions.Clear()
                    $script:pendingBeacnAllAction = $null
                }
                if ($LogBeacnState) {
                    $stableLogSignature = @(
                        $script:beacnAppFaderStates | ForEach-Object {
                            "{0}:{1}{2}:K{3}" -f `
                                [string]$_.Name, `
                                [int][bool]$_.AllActive, `
                                [int][bool]$_.AudienceActive, `
                                [int][bool]$_.ActionStateKnown
                        }
                    ) -join "|"
                    if ($stableLogSignature -ne $script:lastBeacnStableLogSignature) {
                        $script:lastBeacnStableLogSignature = $stableLogSignature
                        Write-BeacnStateLog -Message ("STABLE authority={0}; {1}" -f [int]$script:beacnAppHasActionAuthority, $stableLogSignature)
                    }
                }
                $script:lastBeacnAppScanSuccess = [DateTime]::UtcNow
            } elseif (($now - $script:lastBeacnAppScanSuccess).TotalSeconds -ge 15) {
                $script:beacnAppHasAuthority = $false
                $script:beacnAppHasActionAuthority = $false
                $script:beacnAppFaderStates = @()
                $script:beacnAppFaderStatesByName = @{}
            }
        } catch {
            Write-MuteCueDiagnosticThrottled `
                -Key "beacn-scan-result" `
                -Level Warning `
                -Component "BEACN" `
                -Message "A completed BEACN state scan could not be processed." `
                -Exception $_.Exception
            if (($now - $script:lastBeacnAppScanSuccess).TotalSeconds -ge 15) {
                $script:beacnAppHasAuthority = $false
                $script:beacnAppHasActionAuthority = $false
                $script:beacnAppFaderStates = @()
                $script:beacnAppFaderStatesByName = @{}
            }
        }
        $script:beacnAppScanTask = $null
    }

    $scannerHasPendingChanges = $false
    try {
        $scannerHasPendingChanges = [BeacnMuteOverlay.BeacnAppScanner]::HasPendingChanges
    } catch {
        Write-MuteCueDiagnosticThrottled -Key "beacn-pending-state" -Level Warning -Component "BEACN" -Message "BEACN refresh status could not be read." -Exception $_.Exception
    }
    $scanIntervalMilliseconds = if (
        $scannerHasPendingChanges -or
        $script:beacnAppNeedsConfirmation
    ) { 20 } else { 500 }
    if (($now - $script:lastBeacnAppScanStart).TotalMilliseconds -lt $scanIntervalMilliseconds) { return }
    $script:lastBeacnAppScanStart = $now
    try {
        $script:beacnAppScanTask = [BeacnMuteOverlay.BeacnAppScanner]::ScanAsync()
    } catch {
        Write-MuteCueDiagnosticThrottled -Key "beacn-scan-start" -Level Warning -Component "BEACN" -Message "A BEACN state scan could not start." -Exception $_.Exception
    }
}

function Reset-BeacnPublishedAuthority {
    $script:beacnAppHasAuthority = $false
    $script:beacnAppHasActionAuthority = $false
    $script:beacnAppFaderStates = @()
    $script:beacnAppFaderStatesByName = @{}
}

function Invalidate-BeacnHardwareMapping {
    param([string]$Reason = "layout changed")

    $script:mixCreateMappingGeneration++
    $script:mixCreateHardwarePageKnown = $false
    $script:beacnHardwareLayoutSignature = ""
    $script:beacnOptimisticActionStates.Clear()
    $script:pendingBeacnPhysicalActions.Clear()
    $script:pendingBeacnAllAction = $null
    Write-BeacnStateLog -Message ("HARDWARE {0}; mapping generation advanced" -f $Reason)
}

function Publish-BeacnAdapterResult {
    param(
        [Parameter(Mandatory)][object]$AdapterResult,
        [DateTime]$Now = [DateTime]::UtcNow
    )

    if ([bool]$AdapterResult.LayoutInvalidated) {
        Invalidate-BeacnHardwareMapping -Reason "layout change detected"
    }
    $script:beacnAppFaderStates = @($AdapterResult.States)
    $script:beacnAppFaderStatesByName = $AdapterResult.ByName
    $script:beacnAppHasAuthority = [bool]$AdapterResult.HasAuthority
    $script:beacnAppHasActionAuthority = [bool]$AdapterResult.HasActionAuthority
    $script:beacnAppNeedsConfirmation = [bool]$AdapterResult.NeedsConfirmation
    $script:lastBeacnAppScanSuccess = $Now

    if ([bool]$AdapterResult.Accepted) {
        foreach ($state in @($script:beacnAppFaderStates)) {
            $name = [string]$state.Name
            if ([string]::IsNullOrWhiteSpace($name)) { continue }
            $faderId = [int]$state.Order
            $script:mixCreateAudienceMute[$faderId] = [bool]$state.AudienceActive
            $script:mixCreateAllMuteByName[$name] = [bool]$state.AllActive
            if ($script:mixCreateActionModesByName.ContainsKey($name)) {
                [void]$script:mixCreateActionModesByName.Remove($name)
            }
        }
        Update-BeacnHardwareLayoutConfidence
    }
    if ($script:beacnAppHasActionAuthority) {
        $script:pendingBeacnPhysicalActions.Clear()
        $script:pendingBeacnAllAction = $null
    }
}

function Update-BeacnAppFaderState {
    if (-not $beacnAppScannerAvailable) { return }

    $now = [DateTime]::UtcNow
    if ($script:useBeacnAccessibilityWorker) {
        if (($now - $script:lastBeacnIdentityCatalogRefresh).TotalSeconds -ge 5) {
            $script:lastBeacnIdentityCatalogRefresh = $now
            try { [void](Update-BeacnAdapterIdentityCatalog -Adapter $script:beacnAdapterState) } catch {}
        }
        $workerRunning = Update-BeacnAccessibilityClientWatchdog -Client $script:beacnAccessibilityClient -Now $now
        if ([long]$script:beacnAccessibilityClient.RestartCount -ne [long]$script:lastBeacnWorkerRestartCount) {
            $script:lastBeacnWorkerRestartCount = [long]$script:beacnAccessibilityClient.RestartCount
            Write-MuteCueDiagnosticThrottled `
                -Key "beacn-worker-restart" `
                -Level $(if ($script:lastBeacnWorkerRestartCount -le 1) { "Info" } else { "Warning" }) `
                -Component "BEACN" `
                -Message ("The isolated accessibility worker started generation {0}." -f $script:lastBeacnWorkerRestartCount) `
                -MinimumIntervalSeconds 1
        }
        $providerSnapshot = Receive-BeacnAccessibilitySnapshot -Client $script:beacnAccessibilityClient
        if ($null -ne $providerSnapshot) {
            try {
                $coordinatorResult = Submit-BeacnProviderSnapshot `
                    -Coordinator $script:beacnStateCoordinator `
                    -Snapshot $providerSnapshot `
                    -Now $now
                Update-BeacnHardwareRefreshResult -Telemetry $providerSnapshot
                if ([bool]$coordinatorResult.Accepted -and [bool]$coordinatorResult.Publishable) {
                    Publish-BeacnAdapterResult -AdapterResult $coordinatorResult.AdapterResult -Now $now
                    if ($LogBeacnState) {
                        $workerSignature = @(
                            $script:beacnAppFaderStates | ForEach-Object {
                                "{0}:{1}{2}:K{3}" -f [string]$_.Name, [int][bool]$_.AllActive, [int][bool]$_.AudienceActive, [int][bool]$_.ActionStateKnown
                            }
                        ) -join "|"
                        $workerLog = "{0}; authority={1}; worker={2}; layout={3}; geometry={4}; {5}" -f `
                            [string]$coordinatorResult.AdapterResult.CompatibilityStatus, `
                            [int][bool]$script:beacnAppHasActionAuthority, `
                            [long]$coordinatorResult.WorkerGeneration, `
                            [long]$script:beacnAdapterState.LayoutGeneration, `
                            [long]$coordinatorResult.GeometryGeneration, `
                            $workerSignature
                        if ($workerLog -ne $script:lastBeacnStableLogSignature) {
                            $script:lastBeacnStableLogSignature = $workerLog
                            Write-BeacnStateLog -Message ("STABLE {0}" -f $workerLog)
                        }
                    }
                } elseif ([bool]$coordinatorResult.Rejected) {
                    Write-MuteCueDiagnosticThrottled `
                        -Key "beacn-worker-snapshot-rejected" `
                        -Level Warning `
                        -Component "BEACN" `
                        -Message ("An isolated worker snapshot was rejected: {0}." -f $coordinatorResult.Reason) `
                        -MinimumIntervalSeconds 30
                }
            } catch {
                Write-MuteCueDiagnosticThrottled -Key "beacn-worker-snapshot" -Level Warning -Component "BEACN" -Message "The isolated BEACN snapshot could not be committed." -Exception $_.Exception
            }
        }
        $health = Get-BeacnCoordinatorHealth `
            -Coordinator $script:beacnStateCoordinator `
            -WorkerRunning $workerRunning `
            -Now $now
        if ($health.Status -in @('Unavailable','WorkerStopped') -and ($now - $script:lastBeacnAppScanSuccess).TotalSeconds -ge 15) {
            Reset-BeacnPublishedAuthority
            $script:beacnAdapterState.CompatibilityStatus = "Unavailable"
            $script:beacnAdapterState.CompatibilityDetail = "The isolated BEACN accessibility worker is recovering."
        }
        return
    }
    try {
        [void](Update-BeacnScannerAdapterConfiguration -Adapter $script:beacnAdapterState)
    } catch {
        Write-MuteCueDiagnosticThrottled `
            -Key "beacn-profile-catalog" `
            -Level Warning `
            -Component "BEACN" `
            -Message "The BEACN fader catalog could not be refreshed." `
            -Exception $_.Exception `
            -MinimumIntervalSeconds 30
    }
    $task = $script:beacnAppScanTask
    if ($null -ne $task) {
        if (-not $task.IsCompleted) { return }

        try {
            $rawStates = @($task.Result | Sort-Object Order)
            Update-BeacnHardwareRefreshResult
            if ($rawStates.Count -gt 0) {
                if ($LogBeacnState) {
                    $rawSignature = @(
                        $rawStates | ForEach-Object {
                            "{0}:A{1}{2}:U{3}{4}:L{5}" -f `
                                [string]$_.Name, `
                                [int][bool]$_.AllActionStateKnown, `
                                [int][bool]$_.AllActionActive, `
                                [int][bool]$_.AudienceActionStateKnown, `
                                [int][bool]$_.AudienceActionActive, `
                                [int][bool]$_.IsLocked
                        }
                    ) -join "|"
                    if ($rawSignature -ne $script:lastBeacnRawLogSignature) {
                        $script:lastBeacnRawLogSignature = $rawSignature
                        Write-BeacnStateLog -Message (
                            "RAW {0} [{1}]" -f $rawSignature, [BeacnMuteOverlay.BeacnAppScanner]::DiagnosticSummary
                        )
                    }
                }

                $adapterResult = Submit-BeacnAdapterSnapshot `
                    -Adapter $script:beacnAdapterState `
                    -RawStates $rawStates
                Publish-BeacnAdapterResult -AdapterResult $adapterResult -Now $now

                if ($LogBeacnState) {
                    $stableSignature = @(
                        $script:beacnAppFaderStates | ForEach-Object {
                            "{0}:{1}{2}:K{3}" -f `
                                [string]$_.Name, `
                                [int][bool]$_.AllActive, `
                                [int][bool]$_.AudienceActive, `
                                [int][bool]$_.ActionStateKnown
                        }
                    ) -join "|"
                    $adapterLog = "{0}; authority={1}; layoutGeneration={2}; {3}" -f `
                        [string]$adapterResult.CompatibilityStatus, `
                        [int][bool]$script:beacnAppHasActionAuthority, `
                        [long]$script:beacnAdapterState.LayoutGeneration, `
                        $stableSignature
                    if ($adapterLog -ne $script:lastBeacnStableLogSignature) {
                        $script:lastBeacnStableLogSignature = $adapterLog
                        Write-BeacnStateLog -Message ("STABLE {0}" -f $adapterLog)
                    }
                }
            } elseif (($now - $script:lastBeacnAppScanSuccess).TotalSeconds -ge 15) {
                Reset-BeacnPublishedAuthority
                $script:beacnAdapterState.CompatibilityStatus = "Unavailable"
                $script:beacnAdapterState.CompatibilityDetail = [BeacnMuteOverlay.BeacnAppScanner]::CompatibilityDetail
            }
        } catch {
            Write-MuteCueDiagnosticThrottled `
                -Key "beacn-adapter-result" `
                -Level Warning `
                -Component "BEACN" `
                -Message "A BEACN adapter snapshot could not be committed." `
                -Exception $_.Exception
            if (($now - $script:lastBeacnAppScanSuccess).TotalSeconds -ge 15) {
                Reset-BeacnPublishedAuthority
            }
        }
        $script:beacnAppScanTask = $null
    }

    $scannerHasPendingChanges = $false
    try {
        $scannerHasPendingChanges = [BeacnMuteOverlay.BeacnAppScanner]::HasPendingChanges
    } catch {
        Write-MuteCueDiagnosticThrottled `
            -Key "beacn-pending-state" `
            -Level Warning `
            -Component "BEACN" `
            -Message "BEACN refresh status could not be read." `
            -Exception $_.Exception
    }
    $scanIntervalMilliseconds = if (
        $scannerHasPendingChanges -or
        [bool]$script:beacnAdapterState.NeedsConfirmation
    ) { 20 } else { 500 }
    if (($now - $script:lastBeacnAppScanStart).TotalMilliseconds -lt $scanIntervalMilliseconds) { return }
    $script:lastBeacnAppScanStart = $now
    try {
        $script:beacnAppScanTask = [BeacnMuteOverlay.BeacnAppScanner]::ScanAsync()
    } catch {
        Write-MuteCueDiagnosticThrottled `
            -Key "beacn-scan-start" `
            -Level Warning `
            -Component "BEACN" `
            -Message "A BEACN state scan could not start." `
            -Exception $_.Exception
    }
}

function Get-BeacnPagedSourceStartIndexLegacy {
    param(
        [int]$Page,
        [int]$SourceCount,
        [int]$PagedSlots
    )

    if ($SourceCount -le 0 -or $PagedSlots -le 0) { return 0 }

    # BEACN fills the final hardware page by sliding its source window backward
    # when fewer than four total knobs would otherwise be populated. For example,
    # six unlocked sources are shown as 1-4 and then 3-6, not 1-4 and 5-6.
    $maximumStart = [Math]::Max(0, $SourceCount - $PagedSlots)
    $nominalStart = [Math]::Max(0, $Page) * $PagedSlots
    return [Math]::Min($nominalStart, $maximumStart)
}

function Get-BeacnHardwarePageLayoutLegacy {
    if (-not (Test-BeacnAppStateFresh)) { return $null }

    # Mix Create repeats locked faders at the beginning of every four-knob page.
    # BEACN supports at most three locked faders, leaving at least one slot for
    # the paged sources.
    $orderedStates = @($script:beacnAppFaderStates | Sort-Object Order)
    $lockedStates = @(
        $orderedStates |
            Where-Object { [bool]$_.IsLocked } |
            Select-Object -First 3
    )
    $unlockedStates = @($orderedStates | Where-Object { -not [bool]$_.IsLocked })
    $pagedSlots = [Math]::Max(1, 4 - $lockedStates.Count)
    $pageCount = [Math]::Max(1, [int][Math]::Ceiling($unlockedStates.Count / [double]$pagedSlots))

    $script:mixCreateHardwarePage = [Math]::Max(
        0,
        [Math]::Min([int]$script:mixCreateHardwarePage, $pageCount - 1)
    )

    $names = New-Object 'System.Collections.Generic.List[string]'
    foreach ($state in $lockedStates) {
        if (-not [string]::IsNullOrWhiteSpace([string]$state.Name)) {
            [void]$names.Add([string]$state.Name)
        }
    }

    $startIndex = Get-BeacnPagedSourceStartIndex `
        -Page ([int]$script:mixCreateHardwarePage) `
        -SourceCount $unlockedStates.Count `
        -PagedSlots $pagedSlots
    for ($offset = 0; $offset -lt $pagedSlots; $offset++) {
        $sourceIndex = $startIndex + $offset
        if ($sourceIndex -ge $unlockedStates.Count) { break }
        $name = [string]$unlockedStates[$sourceIndex].Name
        if (-not [string]::IsNullOrWhiteSpace($name)) {
            [void]$names.Add($name)
        }
    }

    return [pscustomobject]@{
        Page = [int]$script:mixCreateHardwarePage
        PageCount = $pageCount
        Names = @($names.ToArray())
    }
}

function Get-BeacnPhysicalSourceMatchLegacy {
    param(
        [int]$Position,
        [string]$SourceName
    )

    if (
        $Position -lt 0 -or
        $Position -gt 3 -or
        [string]::IsNullOrWhiteSpace($SourceName) -or
        -not (Test-BeacnAppStateFresh)
    ) {
        return $null
    }

    $orderedStates = @($script:beacnAppFaderStates | Sort-Object Order)
    $lockedStates = @(
        $orderedStates |
            Where-Object { [bool]$_.IsLocked } |
            Select-Object -First 3
    )
    $unlockedStates = @($orderedStates | Where-Object { -not [bool]$_.IsLocked })

    if ($Position -lt $lockedStates.Count) {
        if ([string]::Equals(
            [string]$lockedStates[$Position].Name,
            $SourceName,
            [StringComparison]::OrdinalIgnoreCase
        )) {
            return [pscustomobject]@{ Page = $null }
        }
        return $null
    }

    $pagedSlots = [Math]::Max(1, 4 - $lockedStates.Count)
    $pageOffset = $Position - $lockedStates.Count
    if ($pageOffset -lt 0 -or $pageOffset -ge $pagedSlots) { return $null }

    $confirmedSourceIndex = -1
    for ($sourceIndex = 0; $sourceIndex -lt $unlockedStates.Count; $sourceIndex++) {
        if (-not [string]::Equals(
            [string]$unlockedStates[$sourceIndex].Name,
            $SourceName,
            [StringComparison]::OrdinalIgnoreCase
        )) {
            continue
        }
        $confirmedSourceIndex = $sourceIndex
        break
    }
    if ($confirmedSourceIndex -lt 0) { return $null }

    $pageCount = [Math]::Max(
        1,
        [int][Math]::Ceiling($unlockedStates.Count / [double]$pagedSlots)
    )
    for ($page = 0; $page -lt $pageCount; $page++) {
        $startIndex = Get-BeacnPagedSourceStartIndex `
            -Page $page `
            -SourceCount $unlockedStates.Count `
            -PagedSlots $pagedSlots
        if (($startIndex + $pageOffset) -eq $confirmedSourceIndex) {
            return [pscustomobject]@{ Page = $page }
        }
    }
    return $null
}

function Get-BeacnHardwarePageLayout {
    if (-not (Test-BeacnAppStateFresh)) { return $null }
    $layout = Get-BeacnHardwareLayoutModel `
        -States @($script:beacnAppFaderStates) `
        -Page ([int]$script:mixCreateHardwarePage)
    $script:mixCreateHardwarePage = [int]$layout.Page
    return $layout
}

function Get-BeacnPhysicalSourceMatch {
    param(
        [int]$Position,
        [string]$SourceName
    )

    if (-not (Test-BeacnAppStateFresh)) { return $null }
    return Find-BeacnHardwareSourceMatch `
        -States @($script:beacnAppFaderStates) `
        -Position $Position `
        -SourceName $SourceName
}

function Update-BeacnHardwareLayoutConfidence {
    $signature = Get-BeacnHardwareLayoutFingerprint -States @($script:beacnAppFaderStates)
    if ([string]::IsNullOrWhiteSpace($signature)) { return }

    if (
        -not [string]::IsNullOrWhiteSpace($script:beacnHardwareLayoutSignature) -and
        $script:beacnHardwareLayoutSignature -ne $signature
    ) {
        # A reordered, added, removed, or relocked fader invalidates the absolute
        # hardware page. Locked positions remain independently deterministic.
        $script:mixCreateMappingGeneration++
        $script:mixCreateHardwarePageKnown = $false
        $script:beacnOptimisticActionStates.Clear()
        Write-BeacnStateLog -Message "HARDWARE layout changed; page confidence cleared"
    }
    $script:beacnHardwareLayoutSignature = $signature
}

function Test-MixCreatePhysicalMappingConfident {
    param([int]$Position)

    if ($Position -lt 0 -or $Position -gt 3 -or -not (Test-BeacnAppStateFresh)) { return $false }
    $telemetry = Get-BeacnScannerTelemetry
    if ($null -eq $telemetry) { return $false }
    $geometryProperty = $telemetry.PSObject.Properties['GeometryRefreshInProgress']
    if ($null -ne $geometryProperty -and [bool]$geometryProperty.Value) { return $false }
    $lockedCount = @(
        $script:beacnAppFaderStates |
            Sort-Object Order |
            Where-Object { [bool]$_.IsLocked } |
            Select-Object -First 3
    ).Count
    if ($Position -lt $lockedCount) { return $true }
    return [bool]$script:mixCreateHardwarePageKnown
}

function Test-BeacnOptimisticActionAllowed {
    param(
        [int]$Position,
        [string]$Name,
        [bool]$MappingConfident
    )

    if ([string]::IsNullOrWhiteSpace($Name) -or -not $MappingConfident) { return $false }
    $faderPresent = $script:beacnAppFaderStatesByName.ContainsKey($Name)
    $actionStateKnown = $faderPresent -and [bool]$script:beacnAppFaderStatesByName[$Name].ActionStateKnown
    $previewAllowed = Test-BeacnAuthoritativePreviewAllowed `
        -HasActionAuthority ([bool]$script:beacnAppHasActionAuthority) `
        -NeedsConfirmation ([bool]$script:beacnAppNeedsConfirmation) `
        -StateAgeSeconds (([DateTime]::UtcNow - $script:lastBeacnAppScanSuccess).TotalSeconds) `
        -CompatibilityStatus ([string]$script:beacnAdapterState.CompatibilityStatus) `
        -FaderPresent $faderPresent `
        -ActionStateKnown $actionStateKnown
    if (-not $previewAllowed) { return $false }
    $mappedName = Get-MixCreatePhysicalFaderName -Position $Position
    return [string]::Equals($mappedName, $Name, [StringComparison]::OrdinalIgnoreCase)
}

function Set-BeacnOptimisticAction {
    param(
        [string]$Name,
        [ValidateSet("All", "Audience")][string]$Mode,
        [long]$RequestId = 0,
        [int]$Position = -1
    )

    if (
        [string]::IsNullOrWhiteSpace($Name) -or
        -not $script:beacnAppFaderStatesByName.ContainsKey($Name)
    ) { return $false }

    $authoritative = $script:beacnAppFaderStatesByName[$Name]
    $existing = if ($script:beacnOptimisticActionStates.ContainsKey($Name)) {
        $script:beacnOptimisticActionStates[$Name]
    } else {
        $null
    }
    $script:beacnOptimisticActionStates[$Name] = New-BeacnOptimisticActionState `
        -AuthoritativeAllActive ([bool]$authoritative.AllActive) `
        -AuthoritativeAudienceActive ([bool]$authoritative.AudienceActive) `
        -ExistingState $existing `
        -Mode $Mode `
        -Now ([DateTime]::UtcNow) `
        -RequestId $RequestId `
        -Position $Position
    return $true
}

function Update-BeacnHardwareRefreshResult {
    param([AllowNull()][object]$Telemetry = $null)

    if ($null -eq $Telemetry) { $Telemetry = Get-BeacnScannerTelemetry }
    if ($null -eq $Telemetry) { return }
    $sequence = 0L
    try { $sequence = [long]$Telemetry.HardwareResultSequence } catch { return }
    if ($sequence -le [long]$script:lastBeacnHardwareResultSequence) { return }
    $script:lastBeacnHardwareResultSequence = $sequence

    $confirmedName = [string]$Telemetry.LastHardwareChangedName
    $predictedName = [string]$Telemetry.LastHardwarePreferredName
    $mode = [string]$Telemetry.LastHardwareChangedMode
    $position = [int]$Telemetry.LastHardwarePosition
    $requestId = [long]$Telemetry.LastHardwareRequestId
    $mappingGeneration = [long]$Telemetry.LastHardwareMappingGeneration
    if ($mode -notin @("All", "Audience") -or $requestId -le 0) {
        Write-MuteCueDiagnosticThrottled -Key "beacn-hardware-result" -Level Warning -Component "BEACN" -Message "An invalid hardware refresh result was ignored."
        return
    }
    if (
        -not [string]::IsNullOrWhiteSpace($confirmedName) -and
        $mappingGeneration -eq [long]$script:mixCreateMappingGeneration
    ) {
        $sourceMatch = Get-BeacnPhysicalSourceMatch -Position $position -SourceName $confirmedName
        if ($null -ne $sourceMatch) {
            $pageProperty = $sourceMatch.PSObject.Properties["Page"]
            if ($null -ne $pageProperty -and $null -ne $pageProperty.Value) {
                $script:mixCreateHardwarePage = [int]$pageProperty.Value
                $script:mixCreateHardwarePageKnown = $true
            }
        }
    }

    if (
        -not [string]::IsNullOrWhiteSpace($predictedName) -and
        (
            [string]::IsNullOrWhiteSpace($confirmedName) -or
            -not [string]::Equals($predictedName, $confirmedName, [StringComparison]::OrdinalIgnoreCase)
        )
    ) {
        if ($script:beacnOptimisticActionStates.ContainsKey($predictedName)) {
            $optimisticState = $script:beacnOptimisticActionStates[$predictedName]
            $ownedByResult = Test-BeacnOptimisticRequestOwnership `
                -State $optimisticState `
                -Mode $mode `
                -RequestId $requestId
            if ($ownedByResult) {
                $authoritativeState = if ($script:beacnAppFaderStatesByName.ContainsKey($predictedName)) {
                    $script:beacnAppFaderStatesByName[$predictedName]
                } else {
                    $null
                }
                if ($null -eq $authoritativeState) {
                    [void]$script:beacnOptimisticActionStates.Remove($predictedName)
                    Write-BeacnStateLog -Message (
                        "HARDWARE discarded orphan prediction={0}; request={1}" -f $predictedName, $requestId
                    )
                    return
                }
                if ($mode -eq "All") {
                    $optimisticState.AllActive = [bool]$authoritativeState.AllActive
                    $optimisticState.AllRequestId = 0L
                } else {
                    $optimisticState.AudienceActive = [bool]$authoritativeState.AudienceActive
                    $optimisticState.AudienceRequestId = 0L
                }
                if (
                    [long]$optimisticState.AllRequestId -eq 0 -and
                    [long]$optimisticState.AudienceRequestId -eq 0
                ) {
                    [void]$script:beacnOptimisticActionStates.Remove($predictedName)
                } else {
                    $optimisticState.At = [DateTime]::UtcNow
                }
            }
        }
    }
    Write-BeacnStateLog -Message (
        "HARDWARE confirmed={0}; predicted={1}; mode={2}; position={3}; request={4}; mapGeneration={5}/{6}; page={7}; pageKnown={8}" -f `
            $confirmedName, $predictedName, $mode, $position, `
            $requestId, $mappingGeneration, [long]$script:mixCreateMappingGeneration, `
            [int]$script:mixCreateHardwarePage, [int][bool]$script:mixCreateHardwarePageKnown
    )
}

function Get-MixCreateButtonPosition {
    param(
        [int]$Mask,
        [switch]$Audience
    )

    if ($Audience) {
        switch ($Mask) {
            16 { 0 }
            32 { 1 }
            64 { 2 }
            128 { 3 }
            default { -1 }
        }
        return
    }

    switch ($Mask) {
        1 { 0 }
        2 { 1 }
        4 { 2 }
        8 { 3 }
        default { -1 }
    }
}

function Get-MixCreatePhysicalFaderName {
    param([int]$Position)

    if ($Position -lt 0 -or $Position -gt 3) { return $null }
    $layout = Get-BeacnHardwarePageLayout
    if ($null -eq $layout) { return $null }
    $pageNames = @($layout.Names)
    if ($Position -ge $pageNames.Count) { return $null }

    $name = [string]$pageNames[$Position]
    if ([string]::IsNullOrWhiteSpace($name)) { return $null }
    return $name
}

function Invoke-MixCreatePhysicalMuteAction {
    param(
        [int]$Position,
        [ValidateSet("All", "Audience")][string]$Mode
    )

    if ($Position -lt 0 -or $Position -gt 3) { return $false }
    $name = Get-MixCreatePhysicalFaderName -Position $Position
    if ([string]::IsNullOrWhiteSpace($name)) { return $false }
    $actionId = [Guid]::NewGuid().ToString("N")
    Set-BeacnSourceActionMode -Name $name -Mode $Mode -ApplyImmediately -ActionId $actionId
    $actionMarker = $script:mixCreateActionModesByName[$name]
    [void]$script:pendingBeacnPhysicalActions.Add([pscustomobject]@{
        ActionId = $actionId
        Mode = $Mode
        PredictedName = $name
        Position = $Position
        At = [DateTime]::UtcNow
        AppliedImmediately = [bool]$actionMarker.AppliedImmediately
    })
    return $true
}

function Get-MixCreateFaderDefinitionsLegacy {
    # This order matches the BEACN application's mixer list. A profile can omit
    # sources that are not currently added; those rows remain visible but disabled.
    $knownNames = @(
        "Mic", "System", "Link In", "Game", "Link 2 In", "Chat", "Hardware",
        "Music", "Browser", "Aux 1", "Aux 2", "Link 3 In", "Link 4 In"
    )

    if (Test-BeacnAppStateFresh) {
        $liveStatesByName = $script:beacnAppFaderStatesByName
        $orderedNames = New-Object 'System.Collections.Generic.List[string]'
        foreach ($state in @($script:beacnAppFaderStates | Sort-Object Order)) {
            $name = [string]$state.Name
            if (-not [string]::IsNullOrWhiteSpace($name) -and -not $orderedNames.Contains($name)) {
                [void]$orderedNames.Add($name)
            }
        }
        foreach ($name in $knownNames) {
            if (-not $orderedNames.Contains($name)) { [void]$orderedNames.Add($name) }
        }

        return @(
            foreach ($name in $orderedNames) {
                if ($liveStatesByName.ContainsKey($name)) {
                    $state = $liveStatesByName[$name]
                    [pscustomobject]@{
                        Id = [int]$state.Order
                        Name = $name
                        IsAvailable = $true
                        CanMonitorAudience = $true
                    }
                } else {
                    [pscustomobject]@{
                        Id = $null
                        Name = $name
                        IsAvailable = $false
                        CanMonitorAudience = $false
                    }
                }
            }
        )
    }

    $profileFaders = @{}

    try {
        $profilePath = Get-BeacnMixerProfilePath
        if (-not [string]::IsNullOrWhiteSpace($profilePath)) {
            [xml]$profile = Get-Content -LiteralPath $profilePath -Raw
            $profileMixers = @(
                $profile.DSPData.mixerTree.ChildNodes |
                    Where-Object { $_.Name -match '^mixer\d+$' } |
                    Sort-Object { [int]($_.Name -replace '\D', '') }
            )
            $seenProfileNames = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
            foreach ($mixer in $profileMixers) {
                if ($mixer.Name -notmatch '^mixer(\d+)$') { continue }

                $id = [int]$Matches[1]
                $name = [string]$mixer.mixerName
                if ([string]::IsNullOrWhiteSpace($name)) { continue }

                # BEACN leaves stale mixer records after the live Add Fader card.
                # The first repeated name marks that boundary in affected profiles;
                # everything after it is not part of the current mixer surface.
                if (-not $seenProfileNames.Add($name)) { break }

                if ($id -ge 0 -and -not $profileFaders.ContainsKey($name)) {
                    $profileFaders[$name] = [pscustomobject]@{
                        Id = $id
                        Name = $name
                    }
                }
            }
        }
    } catch {}

    $faders = New-Object 'System.Collections.Generic.List[object]'
    foreach ($name in $knownNames) {
        if ($profileFaders.ContainsKey($name)) {
            $profileFader = $profileFaders[$name]
            [void]$faders.Add([pscustomobject]@{
                Id = [int]$profileFader.Id
                Name = $name
                IsAvailable = $true
                CanMonitorAudience = ([int]$profileFader.Id -le 7)
            })
        } else {
            [void]$faders.Add([pscustomobject]@{
                Id = $null
                Name = $name
                IsAvailable = $false
                CanMonitorAudience = $false
            })
        }
    }

    return @($faders.ToArray())
}

function Get-MixCreateFaderDefinitions {
    $liveStatesByName = if (Test-BeacnAppStateFresh) { $script:beacnAppFaderStatesByName } else { @{} }
    $profileByName = @{}
    $profileOrder = New-Object 'System.Collections.Generic.List[string]'
    foreach ($profileFader in @(Get-BeacnProfileFaderDefinitions)) {
        $name = ([string]$profileFader.Name).Trim()
        if ([string]::IsNullOrWhiteSpace($name) -or $profileByName.ContainsKey($name)) { continue }
        $profileByName[$name] = $profileFader
        [void]$profileOrder.Add($name)
    }

    $orderedNames = New-Object 'System.Collections.Generic.List[string]'
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($state in @($script:beacnAppFaderStates | Sort-Object Order)) {
        $name = ([string]$state.Name).Trim()
        if (-not [string]::IsNullOrWhiteSpace($name) -and $seen.Add($name)) {
            [void]$orderedNames.Add($name)
        }
    }
    foreach ($name in $profileOrder) {
        if ($seen.Add($name)) { [void]$orderedNames.Add($name) }
    }
    foreach ($name in @(Get-BeacnDefaultFaderNames)) {
        if ($seen.Add($name)) { [void]$orderedNames.Add($name) }
    }

    return @(
        foreach ($name in $orderedNames) {
            if ($liveStatesByName.ContainsKey($name)) {
                $state = $liveStatesByName[$name]
                [pscustomobject]@{
                    Id = [int]$state.Order
                    StableKey = [string]$state.StableKey
                    Name = $name
                    IsAvailable = $true
                    CanMonitorAudience = $true
                }
            } elseif (-not (Test-BeacnAppStateFresh) -and $profileByName.ContainsKey($name)) {
                [pscustomobject]@{
                    Id = [int]$profileByName[$name].Id
                    StableKey = [string]$profileByName[$name].StableKey
                    Name = $name
                    IsAvailable = $true
                    CanMonitorAudience = $true
                }
            } else {
                [pscustomobject]@{
                    Id = $null
                    StableKey = Get-BeacnStableFaderKey -Name $name
                    Name = $name
                    IsAvailable = $false
                    CanMonitorAudience = $false
                }
            }
        }
    )
}

function Get-ConfiguredMixCreateFaderIds {
    param([string]$PropertyName)

    $indices = New-Object 'System.Collections.Generic.List[int]'
    $property = $settings.PSObject.Properties[$PropertyName]
    $configuredIndices = if ($null -ne $property) { [string]$property.Value } else { $null }

    if ($null -ne $configuredIndices) {
        foreach ($value in ($configuredIndices -split ',')) {
            $index = 0
            if ([int]::TryParse($value.Trim(), [ref]$index) -and $index -ge 0 -and -not $indices.Contains($index)) {
                [void]$indices.Add($index)
            }
        }
        return @($indices.ToArray())
    }

    # One-time compatibility path for settings saved before per-fader selection.
    $watchedNames = @(Get-WatchedFaderNames)
    foreach ($fader in @(Get-MixCreateFaderDefinitions)) {
        if ($fader.IsAvailable -and $watchedNames -contains [string]$fader.Name) {
            [void]$indices.Add([int]$fader.Id)
        }
    }

    if ($indices.Count -eq 0 -and $watchedNames -contains "Mic") {
        # Mix Create's default Mic fader is index zero.
        [void]$indices.Add(0)
    }

    return @($indices.ToArray())
}

function Get-MixCreateAudienceFaderIds {
    $selectedNames = @(Get-ConfiguredMixCreateFaderNames -NamesProperty "BeacnAudienceFaderNames" -LegacyIdsProperty "BeacnAudienceFaderIds")
    return @(
        Get-MixCreateFaderDefinitions | Where-Object {
            $_.IsAvailable -and $_.CanMonitorAudience -and $selectedNames -contains [string]$_.Name
        } | ForEach-Object { [int]$_.Id }
    )
}

function Get-MixCreateAllFaderIds {
    $selectedNames = @(Get-ConfiguredMixCreateFaderNames -NamesProperty "BeacnAllFaderNames" -LegacyIdsProperty "BeacnAllFaderIds")
    return @(
        Get-MixCreateFaderDefinitions | Where-Object {
            $_.IsAvailable -and $selectedNames -contains [string]$_.Name
        } | ForEach-Object { [int]$_.Id }
    )
}

function Get-ConfiguredMixCreateFaderNames {
    param(
        [string]$NamesProperty,
        [string]$LegacyIdsProperty
    )

    $keysProperty = $NamesProperty -replace 'Names$', 'Keys'
    $keysSetting = $settings.PSObject.Properties[$keysProperty]
    if ([int]$settings.BeacnFaderSelectionFormat -ge 3 -and $null -ne $keysSetting) {
        $selectedKeys = @(
            [string]$keysSetting.Value -split ',' |
                ForEach-Object { $_.Trim().ToLowerInvariant() } |
                Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
                Select-Object -Unique
        )
        if ($selectedKeys.Count -gt 0) {
            return @(
                Get-MixCreateFaderDefinitions |
                    Where-Object { $selectedKeys -contains ([string]$_.StableKey).ToLowerInvariant() } |
                    ForEach-Object { [string]$_.Name } |
                    Select-Object -Unique
            )
        }
    }
    if ([int]$settings.BeacnFaderSelectionFormat -ge 2) {
        $namesValue = $settings.PSObject.Properties[$NamesProperty].Value
        return @(
            [string]$namesValue -split ',' |
                ForEach-Object { $_.Trim() } |
                Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
                Select-Object -Unique
        )
    }

    $legacyIds = @(Get-ConfiguredMixCreateFaderIds -PropertyName $LegacyIdsProperty)
    return @(
        Get-MixCreateFaderDefinitions |
            Where-Object { $_.IsAvailable -and $legacyIds -contains [int]$_.Id } |
            ForEach-Object { [string]$_.Name } |
            Select-Object -Unique
    )
}

function Start-MixCreateMonitor {
    param(
        [switch]$CaptureAllUsbPackets,
        [switch]$CaptureRootHub
    )
    if (-not $usbCaptureAvailable -or -not [bool]$settings.BeacnDirectDetect) { return }

    $usbPcapCommand = [string]$script:usbPcapCommandPath
    if (-not (Test-Path -LiteralPath $usbPcapCommand)) { return }

    if ($null -ne $script:mixCreateMonitor) {
        $monitorRunning = $false
        try { $monitorRunning = [bool]$script:mixCreateMonitor.IsRunning } catch {
            Write-MuteCueDiagnosticThrottled -Key "usb-monitor-status" -Level Warning -Component "USB" -Message "USB capture status could not be read." -Exception $_.Exception
        }
        if ($monitorRunning) { return }
        try {
            $monitorError = [string]$script:mixCreateMonitor.LastError
            if (-not [string]::IsNullOrWhiteSpace($monitorError)) {
                Write-MuteCueDiagnosticThrottled -Key "usb-monitor-stopped" -Level Warning -Component "USB" -Message ("USB capture stopped: {0}" -f $monitorError)
            }
        } catch {}
        try { $script:mixCreateMonitor.Dispose() } catch {}
        $script:mixCreateMonitor = $null
        $script:mixCreateUsbAddress = $null
        $script:mixCreateUsbCaptureDevice = $null
    }

    if ($null -ne $script:mixCreateRouteDiscoveryTask) {
        if (-not $script:mixCreateRouteDiscoveryTask.IsCompleted) { return }
        try {
            $route = $script:mixCreateRouteDiscoveryTask.Result
            if ($null -ne $route) {
                $script:mixCreateUsbCaptureDevice = [string]$route.CaptureDevice
                $script:mixCreateUsbAddress = [int]$route.DeviceAddress
            }
        } catch {
            Write-MuteCueDiagnosticThrottled -Key "usb-route-result" -Level Warning -Component "USB" -Message "USB route discovery did not complete successfully." -Exception $_.Exception
        }
        $script:mixCreateRouteDiscoveryTask = $null
    }

    if (
        [string]::IsNullOrWhiteSpace([string]$script:mixCreateUsbCaptureDevice) -or
        $null -eq $script:mixCreateUsbAddress
    ) {
        if (([DateTime]::UtcNow - $script:lastMixCreateDiscoveryAttempt).TotalSeconds -lt 5) { return }
        $script:lastMixCreateDiscoveryAttempt = [DateTime]::UtcNow
        try {
            $script:mixCreateRouteDiscoveryTask = [BeacnMuteOverlay.MixCreateUsbMonitor]::DiscoverRouteAsync(
                $usbPcapCommand,
                700
            )
        } catch {
            $script:mixCreateRouteDiscoveryTask = $null
            Write-MuteCueDiagnosticThrottled -Key "usb-route-start" -Level Warning -Component "USB" -Message "USB route discovery could not start." -Exception $_.Exception
        }
        return
    }

    if (([DateTime]::UtcNow - $script:lastMixCreateStartAttempt).TotalMilliseconds -lt 500) { return }
    $script:lastMixCreateStartAttempt = [DateTime]::UtcNow
    try {
        $script:mixCreateMonitor = New-Object BeacnMuteOverlay.MixCreateUsbMonitor
        $script:mixCreateMonitor.Start(
            $usbPcapCommand,
            [string]$script:mixCreateUsbCaptureDevice,
            [int]$script:mixCreateUsbAddress,
            [bool]$CaptureAllUsbPackets,
            [bool]$CaptureRootHub
        )
        $script:mixCreateMonitorStarted = [DateTime]::UtcNow
        $script:lastMixCreateStatusPacket = [DateTime]::MinValue
    } catch {
        if ($null -ne $script:mixCreateMonitor) {
            try { $script:mixCreateMonitor.Dispose() } catch {}
        }
        $script:mixCreateMonitor = $null
        $script:mixCreateUsbAddress = $null
        $script:mixCreateUsbCaptureDevice = $null
        Write-MuteCueDiagnosticThrottled -Key "usb-monitor-start" -Level Warning -Component "USB" -Message "USB capture could not start." -Exception $_.Exception
    }
}

function Update-MixCreateAudienceState {
    param([switch]$InputOnly)

    if (-not $InputOnly) {
    # Complete any pending desktop scan before deciding whether the USB fallback
    # is needed. This makes BEACN's named action rows the primary data source.
    Update-BeacnAppFaderState
    Update-BeacnDesktopClickActions
    Update-BeacnHotkeyActions
    Start-MixCreateMonitor
    $faderConfiguration = "{0}|{1}|{2}|{3}|{4}" -f `
        [string]$settings.BeacnAudienceFaderNames, `
        [string]$settings.BeacnAllFaderNames, `
        [string]$settings.BeacnAudienceFaderKeys, `
        [string]$settings.BeacnAllFaderKeys, `
        [int]$settings.BeacnFaderSelectionFormat
    $now = [DateTime]::UtcNow
    if (
        $script:mixCreateFaderConfiguration -ne $faderConfiguration -or
        ($now - $script:lastMixCreateFaderLookup).TotalSeconds -ge 2
    ) {
        $script:mixCreateFaderConfiguration = $faderConfiguration
        $script:lastMixCreateFaderLookup = $now
        $script:mixCreateFaderDefinitions = @{}
        $script:mixCreateFaderDefinitionsByName = @{}
        $script:mixCreateFaderNames = @{}
        foreach ($fader in @(Get-MixCreateFaderDefinitions)) {
            if (-not $fader.IsAvailable) { continue }
            $script:mixCreateFaderDefinitions[[int]$fader.Id] = $fader
            $script:mixCreateFaderDefinitionsByName[[string]$fader.Name] = $fader
            $script:mixCreateFaderNames[[int]$fader.Id] = [string]$fader.Name
        }
        $selectedAudienceNames = @(Get-ConfiguredMixCreateFaderNames -NamesProperty "BeacnAudienceFaderNames" -LegacyIdsProperty "BeacnAudienceFaderIds")
        $selectedAllNames = @(Get-ConfiguredMixCreateFaderNames -NamesProperty "BeacnAllFaderNames" -LegacyIdsProperty "BeacnAllFaderIds")
        $script:mixCreateAudienceFaderIds = @(
            $script:mixCreateFaderDefinitions.Values |
                Where-Object { $_.CanMonitorAudience -and $selectedAudienceNames -contains [string]$_.Name } |
                ForEach-Object { [int]$_.Id }
        )
        $script:mixCreateAllFaderIds = @(
            $script:mixCreateFaderDefinitions.Values |
                Where-Object { $selectedAllNames -contains [string]$_.Name } |
                ForEach-Object { [int]$_.Id }
        )
        Update-BeacnFaderRows
    }
    }
    if ($null -eq $script:mixCreateMonitor) {
        if (-not $InputOnly) { Update-BeacnAppFaderState }
        return
    }

    if (-not $InputOnly) { try {
        $droppedPacketCount = [long]$script:mixCreateMonitor.DroppedPacketCount
        if ($droppedPacketCount -gt $script:lastMixCreateDroppedPacketCount) {
            $newDrops = $droppedPacketCount - $script:lastMixCreateDroppedPacketCount
            $script:lastMixCreateDroppedPacketCount = $droppedPacketCount
            Write-MuteCueDiagnosticThrottled -Key "usb-queue-drops" -Level Warning -Component "Performance" -Message ("USB input fell behind and discarded {0} old packets." -f $newDrops) -MinimumIntervalSeconds 30
        }
    } catch {} }
    $packet = $null
    $processedPacketCount = 0
    while ($processedPacketCount -lt 512 -and $script:mixCreateMonitor.TryDequeue([ref]$packet)) {
        $processedPacketCount++
        $data = $packet.Data

        # Mix Create exposes independent physical controls in one status report:
        # the low nibble is knob presses (Mute to All), the high nibble is the
        # rectangular Audience buttons, and byte nine contains page navigation.
        # Repeated reports are emitted while held, so handle press edges only.
        if (
            $packet.Endpoint -eq 0x83 -and
            $data.Length -ge 10 -and
            $data[0] -eq 0x00 -and $data[1] -eq 0x00 -and
            $data[2] -eq 0x00 -and $data[3] -eq 0x06
        ) {
            $script:lastMixCreateStatusPacket = [DateTime]::UtcNow
            $pageButton = [int]$data[9] -band 0x06
            if ($pageButton -eq 0) {
                $script:mixCreatePressedPageButton = 0
            } elseif ($pageButton -ne $script:mixCreatePressedPageButton) {
                $script:mixCreatePressedPageButton = $pageButton
                # Results already in flight were created against the previous page.
                # Keep them eligible to reconcile their own optimistic state, but do
                # not let them recalibrate the new page when they eventually arrive.
                $script:mixCreateMappingGeneration++
                # Do not let an unconfirmed action from the previous page match a
                # later edge from an overlapping source on the new page (Chat can
                # legitimately appear on both of the final two pages).
                $script:pendingBeacnPhysicalActions.Clear()
                $layout = Get-BeacnHardwarePageLayout
                if ($null -ne $layout) {
                    if ($pageButton -eq 0x02) {
                        $script:mixCreateHardwarePage = [Math]::Max(0, [int]$layout.Page - 1)
                    } elseif ($pageButton -eq 0x04) {
                        $script:mixCreateHardwarePage = [Math]::Min(
                            [int]$layout.PageCount - 1,
                            [int]$layout.Page + 1
                        )
                    }
                }
            }

            $knobButton = [int]$data[8] -band 0x0F
            if ($knobButton -eq 0) {
                $script:mixCreatePressedKnobButton = 0
            } elseif ($knobButton -ne $script:mixCreatePressedKnobButton) {
                $script:mixCreatePressedKnobButton = $knobButton
                $position = Get-MixCreateButtonPosition -Mask $knobButton
                if (Test-BeacnAppActionStateFresh) {
                    # Position selects the first row to inspect; BEACN's displayed
                    # action state still decides the result. The scanner searches
                    # the other rows automatically if this page hint is stale.
                    $preferredName = Get-MixCreatePhysicalFaderName -Position $position
                    $script:mixCreateHardwareRequestId++
                    $requestId = [long]$script:mixCreateHardwareRequestId
                    $mappingGeneration = [long]$script:mixCreateMappingGeneration
                    $mappingConfident = Test-MixCreatePhysicalMappingConfident -Position $position
                    $optimistic = $false
                    if (Test-BeacnOptimisticActionAllowed -Position $position -Name $preferredName -MappingConfident $mappingConfident) {
                        $optimistic = [bool](Set-BeacnOptimisticAction `
                            -Name $preferredName `
                            -Mode "All" `
                            -RequestId $requestId `
                            -Position $position)
                    }
                    [void](Request-BeacnHardwareRefresh `
                        -PreferredName $preferredName `
                        -Mode "All" `
                        -Position $position `
                        -RequestId $requestId `
                        -MappingGeneration $mappingGeneration `
                        -MappingConfident $mappingConfident)
                    Write-BeacnStateLog -Message (
                        "REQUEST hardware All; position={0}; preferred={1}; optimistic={2}; confidence={3}; request={4}; mapGeneration={5}" -f `
                            $position, $preferredName, [int]$optimistic, [int]$mappingConfident, $requestId, $mappingGeneration
                    )
                } else {
                    # Fail closed while the adapter is learning the layout. BEACN's
                    # next authoritative snapshot will show the physical action.
                    [void](Request-BeacnDiscovery)
                }
            }

            $audienceButton = [int]$data[8] -band 0xF0
            if ($audienceButton -eq 0) {
                $script:mixCreatePressedAudienceButton = 0
            } elseif ($audienceButton -ne $script:mixCreatePressedAudienceButton) {
                $script:mixCreatePressedAudienceButton = $audienceButton
                $position = Get-MixCreateButtonPosition -Mask $audienceButton -Audience
                if (Test-BeacnAppActionStateFresh) {
                    $preferredName = Get-MixCreatePhysicalFaderName -Position $position
                    $script:mixCreateHardwareRequestId++
                    $requestId = [long]$script:mixCreateHardwareRequestId
                    $mappingGeneration = [long]$script:mixCreateMappingGeneration
                    $mappingConfident = Test-MixCreatePhysicalMappingConfident -Position $position
                    $optimistic = $false
                    if (Test-BeacnOptimisticActionAllowed -Position $position -Name $preferredName -MappingConfident $mappingConfident) {
                        $optimistic = [bool](Set-BeacnOptimisticAction `
                            -Name $preferredName `
                            -Mode "Audience" `
                            -RequestId $requestId `
                            -Position $position)
                    }
                    [void](Request-BeacnHardwareRefresh `
                        -PreferredName $preferredName `
                        -Mode "Audience" `
                        -Position $position `
                        -RequestId $requestId `
                        -MappingGeneration $mappingGeneration `
                        -MappingConfident $mappingConfident)
                    Write-BeacnStateLog -Message (
                        "REQUEST hardware Audience; position={0}; preferred={1}; optimistic={2}; confidence={3}; request={4}; mapGeneration={5}" -f `
                            $position, $preferredName, [int]$optimistic, [int]$mappingConfident, $requestId, $mappingGeneration
                    )
                } else {
                    [void](Request-BeacnDiscovery)
                }
            }
        }

        if ($data.Length -lt 8) { continue }

        # BEACN's fader-color update: 01 <fader> 00 04 <blue> <green> <red> 00.
        if ($data[0] -ne 0x01 -or $data[2] -ne 0x00 -or $data[3] -ne 0x04) { continue }
        $faderIndex = [int]$data[1]
        if ($script:mixCreateAudienceFaderIds -notcontains $faderIndex) { continue }

        # The calibrated audience-mute indicator is pure red. Any other fader color is unmuted.
        $isAudienceMuted = (
            $data[4] -eq 0x00 -and
            $data[5] -eq 0x00 -and
            $data[6] -eq 0xFF
        )
        $script:mixCreateAudienceMute[$faderIndex] = $isAudienceMuted
    }

    if ($InputOnly) { return }

    if (
        ([DateTime]::UtcNow - $script:mixCreateMonitorStarted).TotalSeconds -ge 5 -and
        $script:lastMixCreateStatusPacket -lt $script:mixCreateMonitorStarted
    ) {
        # USB device addresses can change after reconnects or restarts. A valid
        # Mix Create route emits idle status reports continuously, so silence here
        # means the cached route is stale and must be discovered again.
        try { $script:mixCreateMonitor.Dispose() } catch {}
        $script:mixCreateMonitor = $null
        $script:mixCreateUsbAddress = $null
        $script:mixCreateUsbCaptureDevice = $null
        $script:lastMixCreateDiscoveryAttempt = [DateTime]::MinValue
    }
    Update-BeacnAppFaderState
}

function Invoke-MixCreateUsbPacketQueue {
    Update-MixCreateAudienceState -InputOnly
}

function Set-BeacnMuteAllState {
    param([bool]$Muted)

    if ([bool]$settings.BeacnMuteAllMuted -eq $Muted) { return }
    $settings.BeacnMuteAllMuted = $Muted
    Save-OverlaySettings -Settings $settings
}

function Toggle-BeacnMuteAllState {
    Set-BeacnMuteAllState -Muted (-not [bool]$settings.BeacnMuteAllMuted)
}

function Set-BeacnSourceActionMode {
    param(
        [string]$Name,
        [ValidateSet("All", "Audience")][string]$Mode,
        [switch]$ApplyImmediately,
        [switch]$DesktopClick,
        [string]$ActionId = ""
    )

    if ([string]::IsNullOrWhiteSpace($Name)) { return }
    $appliedImmediately = $false
    if ($ApplyImmediately) {
        $appliedImmediately = [bool](Toggle-BeacnTrackedMuteLayer -Name $Name -Mode $Mode)
    }
    $script:mixCreateActionModesByName[$Name] = [pscustomobject]@{
        Mode = $Mode
        At = [DateTime]::UtcNow
        AppliedImmediately = $appliedImmediately
        DesktopClick = [bool]$DesktopClick
        ActionId = $ActionId
    }
}

function Toggle-BeacnSourceAllState {
    param(
        [string]$Name,
        [switch]$ConfirmedAllAction
    )

    if ([string]::IsNullOrWhiteSpace($Name)) { return }
    Set-BeacnSourceActionMode -Name $Name -Mode "All" -ApplyImmediately:$ConfirmedAllAction
    $wasMuted = $script:mixCreateAllMuteByName.ContainsKey($Name) -and
        $script:mixCreateAllMuteByName[$Name] -eq $true
    $script:mixCreateAllMuteByName[$Name] = -not $wasMuted

    # Preserve the legacy value for installations that still read it, while the
    # overlay itself now uses the source-specific state above.
    if ($Name -eq "Mic") {
        Set-BeacnMuteAllState -Muted (-not $wasMuted)
    }
}

function Get-MixCreateMutedSources {
    $sources = New-Object 'System.Collections.Generic.List[string]'
    if (-not [bool]$settings.BeacnDirectDetect) { return @() }

    if (Test-BeacnAppStateFresh) {
        $selectedAudienceNames = @(Get-ConfiguredMixCreateFaderNames -NamesProperty "BeacnAudienceFaderNames" -LegacyIdsProperty "BeacnAudienceFaderIds")
        $selectedAllNames = @(Get-ConfiguredMixCreateFaderNames -NamesProperty "BeacnAllFaderNames" -LegacyIdsProperty "BeacnAllFaderIds")

        foreach ($state in @($script:beacnAppFaderStates | Sort-Object Order)) {
            $name = [string]$state.Name
            if ([string]::IsNullOrWhiteSpace($name)) { continue }

            $allActive = [bool]$state.AllActive
            $audienceActive = [bool]$state.AudienceActive
            if ($script:beacnOptimisticActionStates.ContainsKey($name)) {
                $optimisticState = $script:beacnOptimisticActionStates[$name]
                $displayState = Resolve-BeacnDisplayedActionState `
                    -AuthoritativeAllActive $allActive `
                    -AuthoritativeAudienceActive $audienceActive `
                    -OptimisticState $optimisticState `
                    -Now ([DateTime]::UtcNow)
                if (-not [bool]$displayState.UseOptimistic) {
                    [void]$script:beacnOptimisticActionStates.Remove($name)
                } else {
                    $allActive = [bool]$displayState.AllActive
                    $audienceActive = [bool]$displayState.AudienceActive
                }
            }
            if ($allActive -and $selectedAllNames -contains $name) {
                [void]$sources.Add(("BEACN {0}: muted to all" -f $name))
            }
            if ($audienceActive -and $selectedAudienceNames -contains $name) {
                [void]$sources.Add(("BEACN {0}: muted to audience" -f $name))
            }
        }
        return @($sources)
    }

    foreach ($index in @($script:mixCreateAudienceFaderIds)) {
        if (-not $script:mixCreateFaderDefinitions.ContainsKey($index)) { continue }
        if ($script:mixCreateAudienceMute[$index] -ne $true) { continue }
        $name = if ($script:mixCreateFaderNames.ContainsKey($index)) { [string]$script:mixCreateFaderNames[$index] } else { "Fader $($index + 1)" }
        [void]$sources.Add(("BEACN {0}: muted to audience" -f $name))
    }

    foreach ($index in @($script:mixCreateAllFaderIds)) {
        if (-not $script:mixCreateFaderDefinitions.ContainsKey($index)) { continue }
        $name = [string]$script:mixCreateFaderDefinitions[$index].Name
        if (
            [string]::IsNullOrWhiteSpace($name) -or
            -not $script:mixCreateAllMuteByName.ContainsKey($name) -or
            $script:mixCreateAllMuteByName[$name] -ne $true
        ) { continue }
        if (-not [string]::IsNullOrWhiteSpace($name)) {
            [void]$sources.Add(("BEACN {0}: muted to all" -f $name))
        }
    }

    return @($sources)
}

if ($CaptureBeacnState -or $CaptureBeacnWindowMove) {
    try {
        $capturedBeacnStates = @()
        $captureDeadline = [DateTime]::UtcNow.AddSeconds(35)
        do {
            $capturedBeacnStates = @([BeacnMuteOverlay.BeacnAppScanner]::ScanAsync().GetAwaiter().GetResult() | Sort-Object Order)
            if ($capturedBeacnStates.Count -eq 0) { Start-Sleep -Milliseconds 150 }
        } while ($capturedBeacnStates.Count -eq 0 -and [DateTime]::UtcNow -lt $captureDeadline)
        if ($capturedBeacnStates.Count -eq 0) {
            "NO_STATES|$([BeacnMuteOverlay.BeacnAppScanner]::DiagnosticSummary)"
        }
        $adapterCapture = $null
        for ($confirmation = 0; $confirmation -lt 3 -and $capturedBeacnStates.Count -gt 0; $confirmation++) {
            $adapterCapture = Submit-BeacnAdapterSnapshot `
                -Adapter $script:beacnAdapterState `
                -RawStates $capturedBeacnStates
        }
        if ($null -ne $adapterCapture) {
            "ADAPTER|status={0}|authority={1}|layoutGeneration={2}|scanner={3}|version={4}" -f `
                [string]$adapterCapture.CompatibilityStatus, `
                [int][bool]$adapterCapture.HasActionAuthority, `
                [long]$script:beacnAdapterState.LayoutGeneration, `
                [string][BeacnMuteOverlay.BeacnAppScanner]::CompatibilityStatus, `
                [string][BeacnMuteOverlay.BeacnAppScanner]::BeacnVersion
        }
        foreach ($state in $capturedBeacnStates) {
            "{0}|{1}|locked={2}|all={3}|audience={4}|personalOutput={5}|audienceOutput={6}" -f `
                [int]$state.Order, `
                [string]$state.Name, `
                [int][bool]$state.IsLocked, `
                $(if ([bool]$state.AllActionStateKnown) { [int][bool]$state.AllActionActive } else { "unknown" }), `
                $(if ([bool]$state.AudienceActionStateKnown) { [int][bool]$state.AudienceActionActive } else { "unknown" }), `
                [int][bool]$state.PersonalMuted, `
                [int][bool]$state.AudienceMuted
        }
        if ($CaptureBeacnWindowMove -and $capturedBeacnStates.Count -gt 0) {
            foreach ($result in @([BeacnMuteOverlay.BeacnAppScanner]::ValidateTargetsAfterWindowMove(120, 80))) {
                $result
            }
        }
        if ($capturedBeacnStates.Count -gt 0) {
            foreach ($state in $capturedBeacnStates) {
                foreach ($mode in @("All", "Audience")) {
                    [BeacnMuteOverlay.BeacnAppScanner]::RequestFaderRefresh([string]$state.Name, $mode)
                    $rowTimer = [System.Diagnostics.Stopwatch]::StartNew()
                    [void][BeacnMuteOverlay.BeacnAppScanner]::ScanAsync().GetAwaiter().GetResult()
                    $rowTimer.Stop()
                    "TARGETED_ROW|name={0}|mode={1}|elapsedMs={2:N1}|scannerMs={3:N1}" -f `
                        [string]$state.Name, `
                        $mode, `
                        $rowTimer.Elapsed.TotalMilliseconds, `
                        [double][BeacnMuteOverlay.BeacnAppScanner]::LastScanMilliseconds
                }
            }
        }
    } catch {
        "ERROR|$($_.Exception.Message)"
        exit 1
    }
    exit 0
}

if ($CaptureMixCreate) {
    $diagnosticPath = Join-Path $script:muteCuePaths.LogsDirectory "mix-create-diagnostic.log"
    Remove-Item -LiteralPath $diagnosticPath -Force -ErrorAction SilentlyContinue
    $usbPcapCommand = [string]$script:usbPcapCommandPath
    $monitor = $null
    try {
        $route = [BeacnMuteOverlay.MixCreateUsbMonitor]::DiscoverRouteAsync($usbPcapCommand, 700).GetAwaiter().GetResult()
        if ($null -ne $route) {
            $monitor = New-Object BeacnMuteOverlay.MixCreateUsbMonitor
            $monitor.Start($usbPcapCommand, [string]$route.CaptureDevice, [int]$route.DeviceAddress, $false, $false)
        }
    } catch {}
    $until = [DateTime]::UtcNow.AddSeconds([Math]::Max(5, $CaptureSeconds))
    while ([DateTime]::UtcNow -lt $until) {
        $packet = $null
        while ($null -ne $monitor -and $monitor.TryDequeue([ref]$packet)) {
            $hex = [BitConverter]::ToString($packet.Data).Replace("-", " ")
            Add-Content -LiteralPath $diagnosticPath -Value ("{0:O}|{1}|{2:X2}|{3}" -f [DateTime]::UtcNow, $packet.DeviceAddress, $packet.Endpoint, $hex) -Encoding ASCII
        }
        Start-Sleep -Milliseconds 50
    }
    try { if ($null -ne $monitor) { $monitor.Dispose() } } catch {}
    exit
}

if ($CaptureBeacnPageMap) {
    $diagnosticPath = Join-Path $script:muteCuePaths.LogsDirectory "beacn-page-map-diagnostic.log"
    Remove-Item -LiteralPath $diagnosticPath -Force -ErrorAction SilentlyContinue
    $usbPcapCommand = [string]$script:usbPcapCommandPath
    $monitor = $null
    try {
        $route = [BeacnMuteOverlay.MixCreateUsbMonitor]::DiscoverRouteAsync($usbPcapCommand, 700).GetAwaiter().GetResult()
        if ($null -ne $route) {
            $monitor = New-Object BeacnMuteOverlay.MixCreateUsbMonitor
            $monitor.Start($usbPcapCommand, [string]$route.CaptureDevice, [int]$route.DeviceAddress, $false, $false)
        }
    } catch {}

    $lastButtonSignature = ""
    $lastStateSignature = ""
    $scanTask = $null
    $until = [DateTime]::UtcNow.AddSeconds([Math]::Max(10, $CaptureSeconds))
    while ([DateTime]::UtcNow -lt $until) {
        $packet = $null
        while ($null -ne $monitor -and $monitor.TryDequeue([ref]$packet)) {
            $data = $packet.Data
            if (
                $packet.Endpoint -ne 0x83 -or
                $data.Length -lt 10 -or
                $data[0] -ne 0x00 -or $data[1] -ne 0x00 -or
                $data[2] -ne 0x00 -or $data[3] -ne 0x06
            ) { continue }

            $buttonSignature = "{0:X2}:{1:X2}" -f [int]$data[8], [int]$data[9]
            if ($buttonSignature -eq $lastButtonSignature) { continue }
            $lastButtonSignature = $buttonSignature
            if ($buttonSignature -ne "00:00") {
                Add-Content -LiteralPath $diagnosticPath -Value (
                    "{0:O}|BUTTON|B8={1:X2}|B9={2:X2}" -f
                    [DateTime]::UtcNow,
                    [int]$data[8],
                    [int]$data[9]
                ) -Encoding UTF8
            }
        }

        if ($null -eq $scanTask) {
            try { $scanTask = [BeacnMuteOverlay.BeacnAppScanner]::ScanAsync() } catch {}
        } elseif ($scanTask.IsCompleted) {
            try {
                $states = @($scanTask.Result | Sort-Object Order)
                $stateSignature = @(
                    foreach ($state in $states) {
                        "{0}:{1}:{2}:{3}:{4}" -f
                            [int]$state.Order,
                            [string]$state.Name,
                            [int][bool]$state.IsLocked,
                            [int][bool]$state.PersonalMuted,
                            [int][bool]$state.AudienceMuted
                    }
                ) -join ";"
                if (-not [string]::IsNullOrWhiteSpace($stateSignature) -and $stateSignature -ne $lastStateSignature) {
                    $lastStateSignature = $stateSignature
                    Add-Content -LiteralPath $diagnosticPath -Value (
                        "{0:O}|STATE|{1}" -f [DateTime]::UtcNow, $stateSignature
                    ) -Encoding UTF8
                }
            } catch {}
            $scanTask = $null
        }
        Start-Sleep -Milliseconds 10
    }
    try { if ($null -ne $monitor) { $monitor.Dispose() } } catch {}
    exit
}

if ($CaptureDiscordAccessibility) {
    $diagnosticPath = Join-Path $script:muteCuePaths.LogsDirectory "discord-accessibility-diagnostic.log"
    Remove-Item -LiteralPath $diagnosticPath -Force -ErrorAction SilentlyContinue
    $until = [DateTime]::UtcNow.AddSeconds([Math]::Max(5, $CaptureSeconds))
    while ([DateTime]::UtcNow -lt $until) {
        Add-Content -LiteralPath $diagnosticPath -Value ("--- {0:O} ---" -f [DateTime]::UtcNow) -Encoding UTF8
        foreach ($row in @([BeacnMuteOverlay.DiscordMuteScanner]::DescribeAccessibleControls())) {
            Add-Content -LiteralPath $diagnosticPath -Value $row -Encoding UTF8
        }
        Start-Sleep -Milliseconds 400
    }
    exit
}

if ($CaptureDiscordState) {
    $diagnosticPath = Join-Path $script:muteCuePaths.LogsDirectory "discord-state-diagnostic.log"
    Remove-Item -LiteralPath $diagnosticPath -Force -ErrorAction SilentlyContinue
    $until = [DateTime]::UtcNow.AddSeconds([Math]::Max(5, $CaptureSeconds))
    while ([DateTime]::UtcNow -lt $until) {
        $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
        try {
            $result = [BeacnMuteOverlay.DiscordMuteScanner]::ScanAsync($true, $true).GetAwaiter().GetResult()
            $stopwatch.Stop()
            Add-Content -LiteralPath $diagnosticPath -Value (
                "{0:O};MS={1};CLIENT={2};MIC_KNOWN={3};MIC_MUTED={4};DEAFEN_KNOWN={5};DEAFENED={6}" -f
                [DateTime]::UtcNow,
                $stopwatch.ElapsedMilliseconds,
                $result.ClientFound,
                $result.MicStateKnown,
                $result.MicMuted,
                $result.DeafenStateKnown,
                $result.Deafened
            ) -Encoding UTF8
        } catch {
            $stopwatch.Stop()
            Add-Content -LiteralPath $diagnosticPath -Value ("{0:O};MS={1};ERROR={2}" -f [DateTime]::UtcNow, $stopwatch.ElapsedMilliseconds, $_.Exception.Message) -Encoding UTF8
        }
        Start-Sleep -Milliseconds 300
    }
    exit
}

if ($CaptureDiscordToggleEvents) {
    $diagnosticPath = Join-Path $script:muteCuePaths.LogsDirectory "discord-toggle-events.log"
    Remove-Item -LiteralPath $diagnosticPath -Force -ErrorAction SilentlyContinue
    foreach ($row in @([BeacnMuteOverlay.DiscordMuteScanner]::CaptureToggleEvents([Math]::Max(5, $CaptureSeconds) * 1000))) {
        Add-Content -LiteralPath $diagnosticPath -Value $row -Encoding UTF8
    }
    exit
}

if ($CaptureDiscordInvokeEvents) {
    $diagnosticPath = Join-Path $script:muteCuePaths.LogsDirectory "discord-invoke-events.log"
    Remove-Item -LiteralPath $diagnosticPath -Force -ErrorAction SilentlyContinue
    foreach ($row in @([BeacnMuteOverlay.DiscordMuteScanner]::CaptureInvokeEvents([Math]::Max(5, $CaptureSeconds) * 1000))) {
        Add-Content -LiteralPath $diagnosticPath -Value $row -Encoding UTF8
    }
    exit
}

function Get-BeacnMixerProfilePathLegacy {
    $beacnDataPath = Join-Path ([Environment]::GetFolderPath("MyDocuments")) "BEACN"
    $profilesPath = Join-Path $beacnDataPath "profiles\MixerProfiles"
    if (-not (Test-Path -LiteralPath $profilesPath)) { return $null }

    $profileName = $null
    $lastLoadedPath = Join-Path $env:APPDATA "BEACN\lastLoaded.profiles"
    if (Test-Path -LiteralPath $lastLoadedPath) {
        try {
            [xml]$lastLoaded = Get-Content -LiteralPath $lastLoadedPath -Raw
            $profileName = [string]$lastLoaded.lastLoadedProfiles.MixerProfile.lastLoadedProfile
        } catch {}
    }

    if (-not [string]::IsNullOrWhiteSpace($profileName)) {
        $activePath = Join-Path $profilesPath ($profileName + ".beacnMixer")
        if (Test-Path -LiteralPath $activePath) { return $activePath }
    }

    return Get-ChildItem -LiteralPath $profilesPath -Filter "*.beacnMixer" -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1 -ExpandProperty FullName
}

function Get-DiscordMutedSources {
    $sources = New-Object 'System.Collections.Generic.List[string]'

    try {
        $processes = @(Get-Process -Name "Discord", "DiscordPTB", "DiscordCanary" -ErrorAction SilentlyContinue)
        if ($processes.Count -eq 0) { return @() }

        $root = [System.Windows.Automation.AutomationElement]::RootElement
        $elements = New-Object 'System.Collections.Generic.List[System.Windows.Automation.AutomationElement]'
        foreach ($process in $processes) {
            $condition = New-Object System.Windows.Automation.PropertyCondition(
                [System.Windows.Automation.AutomationElement]::ProcessIdProperty,
                $process.Id
            )
            $windows = $root.FindAll([System.Windows.Automation.TreeScope]::Children, $condition)
            for ($i = 0; $i -lt $windows.Count; $i++) {
                Add-AutomationElements -Elements $elements -Element $windows.Item($i) -Depth 0 -MaxDepth 9
            }
        }
        if ($elements.Count -eq 0) { return @() }

        foreach ($element in $elements) {
            $current = $element.Current
            if ($current.IsOffscreen) { continue }

            $controlType = $current.ControlType.ProgrammaticName
            if ($controlType -ne "ControlType.Button" -and $controlType -ne "ControlType.CheckBox") { continue }

            $name = [string]$current.Name
            if ([string]::IsNullOrWhiteSpace($name)) { continue }

            $lowerName = $name.ToLowerInvariant()

            if (
                [bool]$settings.DiscordMicDetect -and
                (
                    $lowerName -match '\bunmute\b' -or
                    $lowerName -match '\bmuted\b' -or
                    $lowerName -match 'microphone off' -or
                    $lowerName -match 'mic off'
                ) -and
                $lowerName -notmatch '\bunmuted\b'
            ) {
                [void]$sources.Add("Discord: mic muted")
            }

            if ([bool]$settings.DiscordMicDetect -and $lowerName -match '^mute( microphone| mic)?$') {
                $toggleState = Get-ToggleStateName -Element $element
                if ($toggleState -eq "On") { [void]$sources.Add("Discord: mic muted") }
            }

            if (
                [bool]$settings.DiscordDeafenDetect -and
                (
                    $lowerName -match '\bundeafen\b' -or
                    $lowerName -match '\bdeafened\b' -or
                    $lowerName -match 'audio off' -or
                    $lowerName -match 'sound off'
                ) -and
                $lowerName -notmatch '\bundeafened\b'
            ) {
                [void]$sources.Add("Discord: deafened")
            }

            if ([bool]$settings.DiscordDeafenDetect -and $lowerName -match '^deafen$') {
                $toggleState = Get-ToggleStateName -Element $element
                if ($toggleState -eq "On") { [void]$sources.Add("Discord: deafened") }
            }
        }
    } catch {}

    return @($sources | Select-Object -Unique)
}

function Update-DiscordStableState {
    param(
        [string]$Name,
        [bool]$Known,
        [bool]$Muted
    )

    $state = $script:discordStableState[$Name]
    $now = [DateTime]::UtcNow
    if (-not $Known) {
        if ($state.Known -and ($now - $state.LastConfirmed).TotalSeconds -gt 4) {
            $state.Known = $false
            $state.Muted = $false
            $state.PendingMuted = $null
            $state.Confirmations = 0
        }
        return
    }

    if ($null -ne $state.PendingMuted -and [bool]$state.PendingMuted -eq $Muted) {
        $state.Confirmations++
    } else {
        $state.PendingMuted = $Muted
        $state.Confirmations = 1
    }

    if ($state.Confirmations -ge 2) {
        $state.Known = $true
        $state.Muted = $Muted
        $state.LastConfirmed = $now
    }
}

function Update-DiscordMutedSources {
    if (-not [bool]$settings.DiscordMicDetect -and -not [bool]$settings.DiscordDeafenDetect) {
        $script:discordMuteSources = @()
        return
    }
    if (-not $discordScannerAvailable) { return }

    $task = $script:discordScanTask
    if ($null -ne $task) {
        if (-not $task.IsCompleted) { return }
        try {
            $result = $task.Result
            if ([bool]$settings.DiscordMicDetect) {
                Update-DiscordStableState -Name "Mic" -Known ([bool]$result.MicStateKnown) -Muted ([bool]$result.MicMuted)
            } else {
                $script:discordStableState.Mic.Known = $false
            }
            if ([bool]$settings.DiscordDeafenDetect) {
                Update-DiscordStableState -Name "Deafen" -Known ([bool]$result.DeafenStateKnown) -Muted ([bool]$result.Deafened)
            } else {
                $script:discordStableState.Deafen.Known = $false
            }

            $sources = New-Object 'System.Collections.Generic.List[string]'
            if ([bool]$settings.DiscordMicDetect -and $script:discordStableState.Mic.Known -and $script:discordStableState.Mic.Muted) {
                [void]$sources.Add("Discord: mic muted")
            }
            if ([bool]$settings.DiscordDeafenDetect -and $script:discordStableState.Deafen.Known -and $script:discordStableState.Deafen.Muted) {
                [void]$sources.Add("Discord: deafened")
            }
            $script:discordMuteSources = @($sources)
        } catch {
            # Keep the last confirmed state through a transient Discord UI redraw.
        }
        $script:discordScanTask = $null
        return
    }

    $now = [DateTime]::UtcNow
    if (($now - $script:lastDiscordScanStart).TotalMilliseconds -lt 200) { return }

    $script:lastDiscordScanStart = $now
    try {
        $script:discordScanTask = [BeacnMuteOverlay.DiscordMuteScanner]::ScanAsync(
            [bool]$settings.DiscordMicDetect,
            [bool]$settings.DiscordDeafenDetect
        )
    } catch {
        $script:discordMuteSources = @()
    }
}

function Update-DiscordRpcConnectionStatus {
    $task = $script:discordRpcProbeTask
    if ($null -eq $task -or -not $task.IsCompleted) { return }

    try {
        $result = $task.Result
        $discordRpcStatus.Text = [string]$result.Status
        $script:discordRpcConnected = [bool]$result.Connected
        $script:discordRpcConnecting = $false
        $discordRpcStatus.Foreground = if ($result.Connected) { $uiForeground } else { $uiMuted }
        Update-DiscordSettingsVisibility
    } catch {
        $script:discordRpcConnected = $false
        $script:discordRpcConnecting = $false
        $discordRpcStatus.Text = "Discord could not complete the connection check."
        $discordRpcStatus.Foreground = $uiMuted
        Update-DiscordSettingsVisibility
    }
    $script:discordRpcProbeTask = $null
}

function Update-DiscordRpcState {
    if (-not $discordRpcAvailable) { return }

    try {
        $update = $null
        while ([BeacnMuteOverlay.DiscordRpcMonitor]::TryDequeue([ref]$update)) {
            if ($update.Kind -eq "status") {
                $discordRpcStatus.Text = [string]$update.Status
                $script:discordRpcConnected = ([string]$update.Status).StartsWith("Discord connected.", [System.StringComparison]::OrdinalIgnoreCase)
                $script:discordRpcConnecting = -not $script:discordRpcConnected -and (
                    ([string]$update.Status).IndexOf("Finding Discord", [System.StringComparison]::OrdinalIgnoreCase) -ge 0 -or
                    ([string]$update.Status).IndexOf("Restoring", [System.StringComparison]::OrdinalIgnoreCase) -ge 0 -or
                    ([string]$update.Status).IndexOf("Refreshing", [System.StringComparison]::OrdinalIgnoreCase) -ge 0 -or
                    ([string]$update.Status).IndexOf("Connecting", [System.StringComparison]::OrdinalIgnoreCase) -ge 0 -or
                    ([string]$update.Status).IndexOf("Signing in", [System.StringComparison]::OrdinalIgnoreCase) -ge 0
                )
                $discordRpcStatus.Foreground = if ($script:discordRpcConnected) { $uiForeground } else { $uiMuted }
                Update-DiscordSettingsVisibility
                continue
            }

            if ($update.Kind -eq "state") {
                $sources = New-Object 'System.Collections.Generic.List[string]'
                if ([bool]$update.Known) {
                    if ([bool]$settings.DiscordMicDetect -and [bool]$update.MicMuted) {
                        [void]$sources.Add("Discord: mic muted")
                    }
                    if ([bool]$settings.DiscordDeafenDetect -and [bool]$update.Deafened) {
                        [void]$sources.Add("Discord: deafened")
                    }
                }
                $script:discordMuteSources = @($sources)
            }

            if ($update.Kind -eq "credentials") {
                $script:discordAuthorization = [pscustomobject]@{
                    AccessToken = [string]$update.AccessToken
                    RefreshToken = [string]$update.RefreshToken
                    ExpiresAtUnixSeconds = [int64]$update.ExpiresAtUnixSeconds
                }
                try {
                    Save-DiscordAuthorization -AccessToken $script:discordAuthorization.AccessToken -RefreshToken $script:discordAuthorization.RefreshToken -ExpiresAtUnixSeconds $script:discordAuthorization.ExpiresAtUnixSeconds
                } catch {
                    Write-MuteCueDiagnosticThrottled -Key "discord-authorization-save" -Component "Discord" -Message "Discord authorization could not be saved securely." -Exception $_.Exception
                }
            }
        }
    } catch {
        # Preserve the last confirmed voice state during a transient queue or UI
        # failure. The connector explicitly emits an unknown state when it stops.
        Write-MuteCueDiagnosticThrottled -Key "discord-update" -Level Warning -Component "Discord" -Message "A Discord state update could not be processed." -Exception $_.Exception
    }
}

function Set-ClickThrough {
    param(
        [System.Windows.Window]$Window,
        [bool]$Enabled
    )

    $interop = New-Object System.Windows.Interop.WindowInteropHelper($Window)
    $handle = $interop.Handle
    if ($handle -eq [IntPtr]::Zero) { return }

    $GWL_EXSTYLE = -20
    $WS_EX_TRANSPARENT = 0x20
    $WS_EX_TOOLWINDOW = 0x80

    if ($null -eq ("MuteCue.NativeWindow" -as [type])) { return }
    $style = [MuteCue.NativeWindow]::GetWindowLong($handle, $GWL_EXSTYLE)
    if ($Enabled) {
        $style = $style -bor $WS_EX_TRANSPARENT -bor $WS_EX_TOOLWINDOW
    } else {
        $style = ($style -band (-bnot $WS_EX_TRANSPARENT)) -bor $WS_EX_TOOLWINDOW
    }

    [void][MuteCue.NativeWindow]::SetWindowLong($handle, $GWL_EXSTYLE, $style)
    # Refresh the non-client frame so Windows immediately honors the new hit-test style.
    [void][MuteCue.NativeWindow]::SetWindowPos($handle, [IntPtr]::Zero, 0, 0, 0, 0, 0x0027)
}

$nativeWindowSource = @"
using System;
using System.Runtime.InteropServices;
namespace MuteCue {
    public static class NativeWindow {
        [DllImport("user32.dll")]
        public static extern int GetWindowLong(IntPtr hWnd, int nIndex);
        [DllImport("user32.dll")]
        public static extern int SetWindowLong(IntPtr hWnd, int nIndex, int dwNewLong);
        [DllImport("user32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool SetWindowPos(IntPtr hWnd, IntPtr hWndInsertAfter, int X, int Y, int cx, int cy, uint uFlags);
    }
}
"@
try {
    Add-Type -TypeDefinition $nativeWindowSource
} catch {
    Write-MuteCueDiagnostic -Level Error -Component "Startup" -Message "Window helper compilation failed; click-through mode is unavailable." -Exception $_.Exception
}

$overlay = New-Object System.Windows.Window
$overlay.Title = "Mute Cue"
$overlay.WindowStyle = "None"
$overlay.ResizeMode = "NoResize"
$overlay.AllowsTransparency = $true
$overlay.Background = [System.Windows.Media.Brushes]::Transparent
$overlay.Topmost = $true
$overlay.ShowInTaskbar = $false
$overlay.Left = [double]$settings.X
$overlay.Top = [double]$settings.Y
$overlay.Width = [double]$settings.Size
$overlay.Height = [double]$settings.Size * 0.68
$overlay.Opacity = [double]$settings.Opacity

function Move-OverlayIntoView {
    $left = [double][System.Windows.SystemParameters]::VirtualScreenLeft
    $top = [double][System.Windows.SystemParameters]::VirtualScreenTop
    $right = $left + [double][System.Windows.SystemParameters]::VirtualScreenWidth
    $bottom = $top + [double][System.Windows.SystemParameters]::VirtualScreenHeight

    if (
        $overlay.Left -lt $left -or
        $overlay.Top -lt $top -or
        ($overlay.Left + $overlay.Width) -gt $right -or
        ($overlay.Top + $overlay.Height) -gt $bottom
    ) {
        $overlay.Left = $left + 80
        $overlay.Top = $top + 80
    }
}

function Center-Overlay {
    $left = [double][System.Windows.SystemParameters]::WorkArea.Left
    $top = [double][System.Windows.SystemParameters]::WorkArea.Top
    $width = [double][System.Windows.SystemParameters]::WorkArea.Width
    $height = [double][System.Windows.SystemParameters]::WorkArea.Height

    $overlay.Left = $left + (($width - $overlay.Width) / 2)
    $overlay.Top = $top + (($height - $overlay.Height) / 2)
}

$grid = New-Object System.Windows.Controls.Grid
$grid.Background = [System.Windows.Media.Brushes]::Transparent
$border = New-Object System.Windows.Controls.Border
$border.CornerRadius = 0
$border.BorderThickness = 0
$border.BorderBrush = [System.Windows.Media.Brushes]::Transparent
$border.Background = [System.Windows.Media.Brushes]::Transparent

$stack = New-Object System.Windows.Controls.StackPanel
$stack.HorizontalAlignment = "Center"
$stack.VerticalAlignment = "Center"
$stack.Margin = "18"

$beacnLogoPath = Join-Path $scriptDir "beacn-logo.png"
$beacnLogo = New-Object System.Windows.Controls.Image
$beacnLogo.Width = 90
$beacnLogo.Height = 96
$beacnLogo.Stretch = "Uniform"
$beacnLogo.HorizontalAlignment = "Center"
$beacnLogo.Margin = "0,0,0,4"
try {
    $logoSource = New-Object System.Windows.Media.Imaging.BitmapImage
    $logoSource.BeginInit()
    $logoSource.CacheOption = [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad
    $logoSource.UriSource = New-Object System.Uri($beacnLogoPath, [System.UriKind]::Absolute)
    $logoSource.EndInit()
    $logoSource.Freeze()
    $beacnLogo.Source = $logoSource
} catch {
    $beacnLogo.Visibility = "Collapsed"
}

$discordLogoPath = Join-Path $scriptDir "discord-logo.png"
$discordOverlayLogo = New-Object System.Windows.Controls.Image
$discordOverlayLogo.Width = 98
$discordOverlayLogo.Height = 86
$discordOverlayLogo.Stretch = "Uniform"
$discordOverlayLogo.HorizontalAlignment = "Center"
$discordOverlayLogo.Visibility = "Collapsed"
try {
    $overlayDiscordImage = New-Object System.Windows.Media.Imaging.BitmapImage
    $overlayDiscordImage.BeginInit()
    $overlayDiscordImage.CacheOption = [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad
    $overlayDiscordImage.UriSource = New-Object System.Uri($discordLogoPath, [System.UriKind]::Absolute)
    $overlayDiscordImage.EndInit()
    $overlayDiscordImage.Freeze()
    $discordOverlayLogo.Source = $overlayDiscordImage
} catch {}

$logoRow = New-Object System.Windows.Controls.StackPanel
$logoRow.Orientation = "Horizontal"
$logoRow.HorizontalAlignment = "Center"
$logoRow.VerticalAlignment = "Center"
$logoRow.Margin = "0,0,0,4"
[void]$logoRow.Children.Add($beacnLogo)
[void]$logoRow.Children.Add($discordOverlayLogo)

$muted = New-Object System.Windows.Controls.TextBlock
$muted.Text = "Muted"
$muted.FontFamily = "Segoe UI Semibold"
$muted.FontSize = 34
$muted.Foreground = [System.Windows.Media.Brushes]::White
$muted.HorizontalAlignment = "Center"
$muted.TextAlignment = "Center"

$sub = New-Object System.Windows.Controls.TextBlock
$sub.Text = "Testing overlay"
$sub.FontFamily = "Segoe UI Semibold"
$sub.FontSize = 15
$sub.Foreground = [System.Windows.Media.Brushes]::White
$sub.Opacity = 0.88
$sub.Margin = "0,6,0,0"
$sub.HorizontalAlignment = "Center"
$sub.TextAlignment = "Center"
$sub.TextWrapping = "Wrap"

$beacnMuteList = New-Object System.Windows.Controls.StackPanel
$beacnMuteList.HorizontalAlignment = "Stretch"
$beacnMuteList.VerticalAlignment = "Center"
$beacnMuteList.Visibility = "Collapsed"
$script:lastBeacnOverlaySignature = $null
$script:beacnMuteListContentHeight = 0
$script:overlayListScale = 1.0

[void]$stack.Children.Add($logoRow)
[void]$stack.Children.Add($muted)
[void]$stack.Children.Add($beacnMuteList)
[void]$stack.Children.Add($sub)
$border.Child = $stack
[void]$grid.Children.Add($border)
$overlay.Content = $grid

function Update-OverlayContentScale {
    $scale = [Math]::Max(0.55, [Math]::Min(2.2, [double]$settings.Size / 405))
    $script:overlayListScale = [Math]::Min(1.65, $scale)
    $padding = [Math]::Round(18 * $scale)
    $gap = [Math]::Round(4 * $scale)

    $stack.Margin = "$padding"
    $beacnLogo.Width = [Math]::Round(90 * $scale)
    $beacnLogo.Height = [Math]::Round(96 * $scale)
    $beacnLogo.Margin = "0,0,$gap,0"
    $discordOverlayLogo.Width = [Math]::Round(98 * $scale)
    $discordOverlayLogo.Height = [Math]::Round(86 * $scale)
    $discordOverlayLogo.Margin = "0,0,0,0"
    $logoRow.Margin = "0,0,0,$gap"
    $muted.FontSize = [Math]::Round(30 * $scale)
    $sub.FontSize = [Math]::Round(14 * $scale)
    $sub.Margin = "0,$([Math]::Round(6 * $scale)),0,0"
    $beacnMuteList.Width = [Math]::Max(180, [double]$settings.Size - (2 * $padding))
    $script:lastBeacnOverlaySignature = $null
}

function Update-OverlayDynamicHeight {
    $baseHeight = [double]$settings.Size * 0.68
    if ($beacnMuteList.Visibility -ne "Visible") {
        $overlay.Height = $baseHeight
        return
    }

    $scale = [double]$script:overlayListScale
    $padding = [Math]::Round(18 * [Math]::Max(0.55, [Math]::Min(2.2, [double]$settings.Size / 405)))
    $logoHeight = [Math]::Max([double]$beacnLogo.Height, [double]$discordOverlayLogo.Height)
    $desiredHeight = (2 * $padding) + $logoHeight + [Math]::Round(8 * $scale) + [double]$script:beacnMuteListContentHeight
    if ($muted.Visibility -eq "Visible") {
        $desiredHeight += [Math]::Round(42 * $scale)
    }

    $virtualTop = [double][System.Windows.SystemParameters]::VirtualScreenTop
    $virtualBottom = $virtualTop + [double][System.Windows.SystemParameters]::VirtualScreenHeight
    $overlay.Height = [Math]::Min([Math]::Max($baseHeight, $desiredHeight), [Math]::Max(180, $virtualBottom - $virtualTop - 24))
    if (($overlay.Top + $overlay.Height) -gt $virtualBottom) {
        $overlay.Top = [Math]::Max($virtualTop, $virtualBottom - $overlay.Height)
    }
}

function Update-BeacnOverlayRows {
    param([string[]]$Sources)

    $orderedNames = New-Object 'System.Collections.Generic.List[string]'
    $statesByName = @{}
    foreach ($source in @($Sources)) {
        $match = [regex]::Match([string]$source, '^BEACN (.+): muted to (all|audience)$')
        if (-not $match.Success) { continue }

        $name = [string]$match.Groups[1].Value
        $state = if ([string]$match.Groups[2].Value -eq "all") { "All" } else { "Audience" }
        if (-not $statesByName.ContainsKey($name)) {
            $statesByName[$name] = New-Object 'System.Collections.Generic.List[string]'
            [void]$orderedNames.Add($name)
        }
        if (-not $statesByName[$name].Contains($state)) {
            [void]$statesByName[$name].Add($state)
        }
    }

    $signatureParts = @(
        foreach ($name in $orderedNames) {
            "{0}={1}" -f $name, (@($statesByName[$name]) -join ',')
        }
    )
    $signature = "{0:F3}|{1}" -f [double]$script:overlayListScale, ($signatureParts -join ';')
    if ($script:lastBeacnOverlaySignature -eq $signature) {
        Update-OverlayDynamicHeight
        return
    }

    $script:lastBeacnOverlaySignature = $signature
    $beacnMuteList.Children.Clear()
    $script:beacnMuteListContentHeight = 0
    $scale = [double]$script:overlayListScale
    $stateBrush = New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.Colors]::White)
    $stateBrush.Opacity = 0.82

    foreach ($name in $orderedNames) {
        $states = @($statesByName[$name])
        $stateLineHeight = [Math]::Round(23 * $scale)
        $rowHeight = if ($states.Count -le 1) {
            [Math]::Round(42 * $scale)
        } else {
            [Math]::Max([Math]::Round(50 * $scale), $states.Count * $stateLineHeight)
        }
        $script:beacnMuteListContentHeight += $rowHeight

        if ($states.Count -le 1) {
            $inlineText = New-Object System.Windows.Controls.TextBlock
            $inlineText.HorizontalAlignment = "Center"
            $inlineText.VerticalAlignment = "Center"
            $inlineText.TextAlignment = "Center"
            $inlineText.MinHeight = $rowHeight
            $inlineText.Margin = "0,$([Math]::Round(2 * $scale)),0,0"

            $nameRun = New-Object System.Windows.Documents.Run
            $nameRun.Text = "${name}: "
            $nameRun.FontFamily = "Segoe UI Semibold"
            $nameRun.FontSize = [Math]::Round(28 * $scale)
            $nameRun.Foreground = [System.Windows.Media.Brushes]::White
            [void]$inlineText.Inlines.Add($nameRun)

            $stateRun = New-Object System.Windows.Documents.Run
            $stateRun.Text = if ($states.Count -eq 1) { [string]$states[0] } else { "Muted" }
            $stateRun.FontFamily = "Segoe UI Semibold"
            $stateRun.FontSize = [Math]::Round(17 * $scale)
            $stateRun.Foreground = $stateBrush
            [void]$inlineText.Inlines.Add($stateRun)
            [void]$beacnMuteList.Children.Add($inlineText)
            continue
        }

        $row = New-Object System.Windows.Controls.Grid
        $row.HorizontalAlignment = "Center"
        $row.VerticalAlignment = "Center"
        $row.MinHeight = $rowHeight
        $row.Margin = "0,$([Math]::Round(3 * $scale)),0,0"
        $nameColumn = New-Object System.Windows.Controls.ColumnDefinition
        $nameColumn.Width = "Auto"
        $row.ColumnDefinitions.Add($nameColumn)
        $stateColumn = New-Object System.Windows.Controls.ColumnDefinition
        $stateColumn.Width = "Auto"
        $row.ColumnDefinitions.Add($stateColumn)

        $nameText = New-Object System.Windows.Controls.TextBlock
        $nameText.Text = "${name}:"
        $nameText.FontFamily = "Segoe UI Semibold"
        $nameText.FontSize = [Math]::Round(28 * $scale)
        $nameText.Foreground = [System.Windows.Media.Brushes]::White
        $nameText.VerticalAlignment = "Center"
        $nameText.TextAlignment = "Right"
        [void]$row.Children.Add($nameText)

        $stateStack = New-Object System.Windows.Controls.StackPanel
        $stateStack.VerticalAlignment = "Center"
        $stateStack.Margin = "$([Math]::Round(18 * $scale)),0,0,0"
        [System.Windows.Controls.Grid]::SetColumn($stateStack, 1)
        foreach ($state in $states) {
            $stateText = New-Object System.Windows.Controls.TextBlock
            $stateText.Text = [string]$state
            $stateText.FontFamily = "Segoe UI Semibold"
            $stateText.FontSize = [Math]::Round(17 * $scale)
            $stateText.Foreground = $stateBrush
            $stateText.HorizontalAlignment = "Left"
            $stateText.TextAlignment = "Left"
            $stateText.MinHeight = $stateLineHeight
            [void]$stateStack.Children.Add($stateText)
        }
        [void]$row.Children.Add($stateStack)
        [void]$beacnMuteList.Children.Add($row)
    }

    Update-OverlayDynamicHeight
}

$script:overlayDragStartPointer = $null
$script:overlayDragStartPosition = $null

$overlay.Add_PreviewMouseLeftButtonDown({
    param($sender, $eventArgs)

    if ([bool]$settings.ClickThrough) { return }
    $script:overlayDragStartPointer = $overlay.PointToScreen($eventArgs.GetPosition($overlay))
    $script:overlayDragStartPosition = New-Object System.Windows.Point($overlay.Left, $overlay.Top)
    [void][System.Windows.Input.Mouse]::Capture($overlay)
    $eventArgs.Handled = $true
})

$overlay.Add_PreviewMouseMove({
    param($sender, $eventArgs)

    if ($null -eq $script:overlayDragStartPointer -or $eventArgs.LeftButton -ne [System.Windows.Input.MouseButtonState]::Pressed) { return }
    $pointer = $overlay.PointToScreen($eventArgs.GetPosition($overlay))
    $overlay.Left = $script:overlayDragStartPosition.X + ($pointer.X - $script:overlayDragStartPointer.X)
    $overlay.Top = $script:overlayDragStartPosition.Y + ($pointer.Y - $script:overlayDragStartPointer.Y)
})

$overlay.Add_PreviewMouseLeftButtonUp({
    param($sender, $eventArgs)

    if ($null -eq $script:overlayDragStartPointer) { return }
    $script:overlayDragStartPointer = $null
    $script:overlayDragStartPosition = $null
    [System.Windows.Input.Mouse]::Capture($null)
    $settings.X = [int]$overlay.Left
    $settings.Y = [int]$overlay.Top
    Save-OverlaySettings -Settings $settings
    $eventArgs.Handled = $true
})

$settingsWindow = New-Object System.Windows.Window
$settingsWindow.Title = "Mute Cue Settings"
$settingsWindow.Width = 500
$settingsWindow.Height = 700
$settingsWindow.ResizeMode = "NoResize"
$settingsWindow.WindowStartupLocation = "CenterScreen"
$settingsWindow.Topmost = $true
$settingsWindow.Background = New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.Color]::FromRgb(18, 19, 23))

$uiForeground = New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.Color]::FromRgb(242, 243, 245))
$uiMuted = New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.Color]::FromRgb(158, 163, 172))
$uiAccent = New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.Color]::FromRgb(255, 67, 82))
$uiDivider = New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.Color]::FromRgb(47, 49, 56))
$uiControl = New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.Color]::FromRgb(37, 39, 45))

function New-SectionHeader {
    param(
        [string]$Text,
        [System.Windows.Media.ImageSource]$Icon
    )

    $header = New-Object System.Windows.Controls.Grid
    $labelColumn = New-Object System.Windows.Controls.ColumnDefinition
    $labelColumn.Width = "Auto"
    $header.ColumnDefinitions.Add($labelColumn)
    $header.Height = 44
    $header.Margin = "0,8,0,8"

    if ($null -ne $Icon) {
        $iconColumn = New-Object System.Windows.Controls.ColumnDefinition
        $iconColumn.Width = "Auto"
        $header.ColumnDefinitions.Add($iconColumn)

        $image = New-Object System.Windows.Controls.Image
        $image.Source = $Icon
        $image.Width = 34
        $image.Height = 34
        $image.Stretch = "Uniform"
        $image.Margin = "12,0,0,0"
        $image.VerticalAlignment = "Center"
        [System.Windows.Controls.Grid]::SetColumn($image, 1)
        [void]$header.Children.Add($image)
    }

    $fillColumn = New-Object System.Windows.Controls.ColumnDefinition
    $fillColumn.Width = "*"
    $header.ColumnDefinitions.Add($fillColumn)

    $label = New-Object System.Windows.Controls.TextBlock
    $label.Text = $Text
    $label.Foreground = $uiForeground
    $label.FontFamily = "Segoe UI Semibold"
    $label.FontSize = 24
    $label.VerticalAlignment = "Center"
    [void]$header.Children.Add($label)
    return $header
}

function New-CollapsibleSection {
    param(
        [System.Windows.Controls.Panel]$Container,
        [string]$Text,
        [System.Windows.Media.ImageSource]$Icon,
        [bool]$Expanded = $true
    )

    $section = New-Object System.Windows.Controls.StackPanel
    $section.Margin = "0,16,0,0"

    $header = New-Object System.Windows.Controls.Grid
    $header.Height = 48
    $header.Margin = "0,6,0,8"
    $header.Cursor = [System.Windows.Input.Cursors]::Hand
    $header.Background = [System.Windows.Media.Brushes]::Transparent
    $labelColumn = New-Object System.Windows.Controls.ColumnDefinition
    $labelColumn.Width = "Auto"
    $header.ColumnDefinitions.Add($labelColumn)
    $iconColumn = New-Object System.Windows.Controls.ColumnDefinition
    $iconColumn.Width = "Auto"
    $header.ColumnDefinitions.Add($iconColumn)
    $arrowColumn = New-Object System.Windows.Controls.ColumnDefinition
    $arrowColumn.Width = "Auto"
    $header.ColumnDefinitions.Add($arrowColumn)
    $fillColumn = New-Object System.Windows.Controls.ColumnDefinition
    $fillColumn.Width = "*"
    $header.ColumnDefinitions.Add($fillColumn)

    $label = New-Object System.Windows.Controls.TextBlock
    $label.Text = $Text
    $label.Foreground = $uiForeground
    $label.FontFamily = "Segoe UI Semibold"
    $label.FontSize = 24
    $label.VerticalAlignment = "Center"
    [void]$header.Children.Add($label)

    if ($null -ne $Icon) {
        $image = New-Object System.Windows.Controls.Image
        $image.Source = $Icon
        $image.Width = 34
        $image.Height = 34
        $image.Stretch = "Uniform"
        $image.Margin = "12,0,0,0"
        $image.VerticalAlignment = "Center"
        [System.Windows.Controls.Grid]::SetColumn($image, 1)
        [void]$header.Children.Add($image)
    }

    $arrow = New-Object System.Windows.Controls.TextBlock
    $arrow.Text = if ($Expanded) { "v" } else { ">" }
    $arrow.Foreground = $uiMuted
    $arrow.FontFamily = "Segoe UI Semibold"
    $arrow.FontSize = 14
    $arrow.Margin = "14,4,0,0"
    $arrow.VerticalAlignment = "Center"
    [System.Windows.Controls.Grid]::SetColumn($arrow, 2)
    [void]$header.Children.Add($arrow)

    $body = New-Object System.Windows.Controls.StackPanel
    $body.Margin = "0,0,0,4"
    $body.Visibility = if ($Expanded) { "Visible" } else { "Collapsed" }

    $header.Tag = [pscustomobject]@{
        Body = $body
        Arrow = $arrow
    }
    $header.Add_MouseLeftButtonUp({
        param($sender, $eventArgs)

        $sectionState = $sender.Tag
        if ($sectionState.Body.Visibility -eq "Visible") {
            $sectionState.Body.Visibility = "Collapsed"
            $sectionState.Arrow.Text = ">"
        } else {
            $sectionState.Body.Visibility = "Visible"
            $sectionState.Arrow.Text = "v"
        }
        $eventArgs.Handled = $true
    })

    [void]$section.Children.Add($header)
    [void]$section.Children.Add($body)
    [void]$Container.Children.Add($section)

    return [pscustomobject]@{
        Expander = $section
        Body = $body
    }
}

function Add-SettingToggle {
    param(
        [System.Windows.Controls.Panel]$Container,
        [string]$Text,
        [bool]$Checked
    )

    $row = New-Object System.Windows.Controls.Grid
    $row.Height = 38
    $row.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition))
    $toggleColumn = New-Object System.Windows.Controls.ColumnDefinition
    $toggleColumn.Width = "Auto"
    $row.ColumnDefinitions.Add($toggleColumn)

    $label = New-Object System.Windows.Controls.TextBlock
    $label.Text = $Text
    $label.Foreground = $uiForeground
    $label.FontSize = 14
    $label.VerticalAlignment = "Center"
    [void]$row.Children.Add($label)

    $toggle = New-Object System.Windows.Controls.CheckBox
    $toggle.IsChecked = $Checked
    $toggle.Foreground = $uiAccent
    $toggle.VerticalAlignment = "Center"
    $toggle.HorizontalAlignment = "Right"
    $toggle.Margin = "16,0,2,0"
    [System.Windows.Controls.Grid]::SetColumn($toggle, 1)
    [void]$row.Children.Add($toggle)

    [void]$Container.Children.Add($row)
    return $toggle
}

function Add-SettingSlider {
    param(
        [System.Windows.Controls.Panel]$Container,
        [string]$Text,
        [double]$Minimum,
        [double]$Maximum,
        [double]$Value,
        [double]$SmallChange
    )

    $heading = New-Object System.Windows.Controls.Grid
    $heading.Margin = "0,2,0,0"
    $heading.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition))
    $valueColumn = New-Object System.Windows.Controls.ColumnDefinition
    $valueColumn.Width = "Auto"
    $heading.ColumnDefinitions.Add($valueColumn)

    $label = New-Object System.Windows.Controls.TextBlock
    $label.Text = $Text
    $label.Foreground = $uiForeground
    $label.FontSize = 14
    [void]$heading.Children.Add($label)

    $valueLabel = New-Object System.Windows.Controls.TextBlock
    $valueLabel.Foreground = $uiMuted
    $valueLabel.FontFamily = "Segoe UI Semibold"
    $valueLabel.FontSize = 12
    [System.Windows.Controls.Grid]::SetColumn($valueLabel, 1)
    [void]$heading.Children.Add($valueLabel)

    $slider = New-Object System.Windows.Controls.Slider
    $slider.Minimum = $Minimum
    $slider.Maximum = $Maximum
    $slider.Value = $Value
    $slider.SmallChange = $SmallChange
    $slider.LargeChange = ($SmallChange * 5)
    $slider.IsSnapToTickEnabled = $false
    $slider.Foreground = $uiAccent
    $slider.Margin = "0,4,0,4"

    [void]$Container.Children.Add($heading)
    [void]$Container.Children.Add($slider)
    return [pscustomobject]@{ Slider = $slider; ValueLabel = $valueLabel }
}

function New-SettingsPage {
    param([Parameter(Mandatory)][System.Windows.Controls.Grid]$Container)

    $pageScroll = New-Object System.Windows.Controls.ScrollViewer
    $pageScroll.VerticalScrollBarVisibility = "Auto"
    $pageScroll.HorizontalScrollBarVisibility = "Disabled"
    $pageScroll.Visibility = "Collapsed"
    $pagePanel = New-Object System.Windows.Controls.StackPanel
    $pagePanel.Margin = "22,14,22,14"
    $pageScroll.Content = $pagePanel
    [void]$Container.Children.Add($pageScroll)
    return [pscustomobject]@{ Scroll = $pageScroll; Panel = $pagePanel }
}

function New-SettingsTabButton {
    param(
        [Parameter(Mandatory)][System.Windows.Controls.Grid]$Container,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Text,
        [System.Windows.Media.ImageSource]$Icon,
        [int]$Column
    )

    $button = New-Object System.Windows.Controls.Button
    $button.Height = 40
    $button.Margin = "3,0"
    $button.Padding = "10,4"
    $button.Cursor = [System.Windows.Input.Cursors]::Hand
    $button.HorizontalContentAlignment = "Center"
    $button.VerticalContentAlignment = "Center"
    $button.Background = New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.Color]::FromRgb(27, 29, 34))
    $button.BorderBrush = $uiDivider
    $button.BorderThickness = "1"
    [System.Windows.Controls.Grid]::SetColumn($button, $Column)

    $content = New-Object System.Windows.Controls.StackPanel
    $content.Orientation = "Horizontal"
    $content.HorizontalAlignment = "Center"
    $content.VerticalAlignment = "Center"
    if ($null -ne $Icon) {
        $image = New-Object System.Windows.Controls.Image
        $image.Source = $Icon
        $image.Width = 20
        $image.Height = 20
        $image.Margin = "0,0,7,0"
        $image.Stretch = "Uniform"
        [void]$content.Children.Add($image)
    }
    $label = New-Object System.Windows.Controls.TextBlock
    $label.Text = $Text
    $label.Foreground = $uiMuted
    $label.FontFamily = "Segoe UI Semibold"
    $label.FontSize = 13
    $label.VerticalAlignment = "Center"
    [void]$content.Children.Add($label)
    $button.Content = $content
    $button.Tag = [pscustomobject]@{ Name = $Name; Label = $label }
    [System.Windows.Automation.AutomationProperties]::SetName($button, "$Text tab")
    $button.Add_Click({
        param($sender, $eventArgs)
        Select-MuteCueSettingsTab -Name ([string]$sender.Tag.Name)
        $eventArgs.Handled = $true
    })
    [void]$Container.Children.Add($button)
    return $button
}

function Select-MuteCueSettingsTab {
    param([Parameter(Mandatory)][ValidateSet("Discord", "BEACN", "Settings")][string]$Name)

    $tabChanged = -not [string]::Equals(
        [string]$script:selectedSettingsTab,
        $Name,
        [StringComparison]::OrdinalIgnoreCase
    )
    foreach ($tabName in @($script:settingsTabPages.Keys)) {
        $selected = [string]::Equals([string]$tabName, $Name, [StringComparison]::OrdinalIgnoreCase)
        $script:settingsTabPages[$tabName].Visibility = if ($selected) { "Visible" } else { "Collapsed" }
        $button = $script:settingsTabButtons[$tabName]
        $buttonState = $button.Tag
        if ($selected) {
            $button.Background = New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.Color]::FromRgb(57, 35, 41))
            $button.BorderBrush = $uiAccent
            $button.BorderThickness = "1,1,1,3"
            $buttonState.Label.Foreground = $uiForeground
        } else {
            $button.Background = New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.Color]::FromRgb(27, 29, 34))
            $button.BorderBrush = $uiDivider
            $button.BorderThickness = "1"
            $buttonState.Label.Foreground = $uiMuted
        }
    }
    $script:selectedSettingsTab = $Name
    if ($tabChanged -and $Name -eq 'BEACN') { [void](Request-BeacnDiscovery) }
}

$discordLogoPath = Join-Path $scriptDir "discord-logo.png"
$discordLogoSource = $null
try {
    $discordImage = New-Object System.Windows.Media.Imaging.BitmapImage
    $discordImage.BeginInit()
    $discordImage.CacheOption = [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad
    $discordImage.UriSource = New-Object System.Uri($discordLogoPath, [System.UriKind]::Absolute)
    $discordImage.EndInit()
    $discordImage.Freeze()
    $discordLogoSource = $discordImage
} catch {}

$settingsRoot = New-Object System.Windows.Controls.Grid
$headerRow = New-Object System.Windows.Controls.RowDefinition
$headerRow.Height = "Auto"
$settingsRoot.RowDefinitions.Add($headerRow)
$tabsRow = New-Object System.Windows.Controls.RowDefinition
$tabsRow.Height = "Auto"
$settingsRoot.RowDefinitions.Add($tabsRow)
$contentRow = New-Object System.Windows.Controls.RowDefinition
$contentRow.Height = "*"
$settingsRoot.RowDefinitions.Add($contentRow)
$footerRow = New-Object System.Windows.Controls.RowDefinition
$footerRow.Height = "Auto"
$settingsRoot.RowDefinitions.Add($footerRow)

$settingsHeader = New-Object System.Windows.Controls.Border
$settingsHeader.Background = New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.Color]::FromRgb(27, 29, 34))
$settingsHeader.BorderBrush = $uiDivider
$settingsHeader.BorderThickness = "0,0,0,1"
$settingsHeader.Padding = "22,12"
$headerText = New-Object System.Windows.Controls.StackPanel
$headerLogoPath = Join-Path $scriptDir "mute-cue-logo-transparent.png"
$headerLogo = New-Object System.Windows.Controls.Image
$headerLogo.Width = 150
$headerLogo.Height = 43
$headerLogo.Stretch = "Uniform"
$headerLogo.HorizontalAlignment = "Left"
$headerLogo.Margin = "0"
try {
    $headerLogoSource = New-Object System.Windows.Media.Imaging.BitmapImage
    $headerLogoSource.BeginInit()
    $headerLogoSource.CacheOption = [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad
    $headerLogoSource.UriSource = New-Object System.Uri($headerLogoPath, [System.UriKind]::Absolute)
    $headerLogoSource.EndInit()
    $headerLogoSource.Freeze()
    $headerLogo.Source = $headerLogoSource
} catch {
    $headerLogo.Visibility = "Collapsed"
}
[void]$headerText.Children.Add($headerLogo)
$settingsHeader.Child = $headerText
[System.Windows.Controls.Grid]::SetRow($settingsHeader, 0)
[void]$settingsRoot.Children.Add($settingsHeader)

$tabsBorder = New-Object System.Windows.Controls.Border
$tabsBorder.Background = New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.Color]::FromRgb(22, 24, 29))
$tabsBorder.BorderBrush = $uiDivider
$tabsBorder.BorderThickness = "0,0,0,1"
$tabsBorder.Padding = "16,7"
$tabsGrid = New-Object System.Windows.Controls.Grid
foreach ($index in 0..2) {
    $tabColumn = New-Object System.Windows.Controls.ColumnDefinition
    $tabColumn.Width = "*"
    $tabsGrid.ColumnDefinitions.Add($tabColumn)
}
$tabsBorder.Child = $tabsGrid
[System.Windows.Controls.Grid]::SetRow($tabsBorder, 1)
[void]$settingsRoot.Children.Add($tabsBorder)

$pageHost = New-Object System.Windows.Controls.Grid
[System.Windows.Controls.Grid]::SetRow($pageHost, 2)
[void]$settingsRoot.Children.Add($pageHost)
$discordPage = New-SettingsPage -Container $pageHost
$beacnPage = New-SettingsPage -Container $pageHost
$generalSettingsPage = New-SettingsPage -Container $pageHost
$script:settingsTabPages = @{
    Discord = $discordPage.Scroll
    BEACN = $beacnPage.Scroll
    Settings = $generalSettingsPage.Scroll
}
$script:settingsTabButtons = @{}
$script:settingsTabButtons.Discord = New-SettingsTabButton -Container $tabsGrid -Name "Discord" -Text "Discord" -Icon $discordLogoSource -Column 0
$script:settingsTabButtons.BEACN = New-SettingsTabButton -Container $tabsGrid -Name "BEACN" -Text "BEACN" -Icon $beacnLogo.Source -Column 1
$script:settingsTabButtons.Settings = New-SettingsTabButton -Container $tabsGrid -Name "Settings" -Text "Settings" -Column 2

$discordBody = $discordPage.Panel

$discordRpcLabel = New-Object System.Windows.Controls.TextBlock
$discordRpcLabel.Text = "Connect Discord"
$discordRpcLabel.Foreground = $uiForeground
$discordRpcLabel.FontSize = 14
$discordRpcLabel.Margin = "0,4,0,4"
[void]$discordBody.Children.Add($discordRpcLabel)

$discordSetupPanel = New-Object System.Windows.Controls.StackPanel
[void]$discordBody.Children.Add($discordSetupPanel)

$discordConsent = New-Object System.Windows.Controls.TextBlock
$discordConsent.Text = if ([bool]$script:discordPublicClient.Available) { [string]$script:discordPublicClient.Detail } else { "Discord monitoring is unavailable in this build." }
$discordConsent.Foreground = $uiMuted
$discordConsent.FontSize = 12
$discordConsent.Margin = "0,2,0,6"
$discordConsent.TextWrapping = "Wrap"
[void]$discordSetupPanel.Children.Add($discordConsent)

$discordRpcActions = New-Object System.Windows.Controls.Grid
$discordRpcActions.Margin = "0,8,0,0"
$discordRpcActions.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition))
$discordRpcButtonColumn = New-Object System.Windows.Controls.ColumnDefinition
$discordRpcButtonColumn.Width = "Auto"
$discordRpcActions.ColumnDefinitions.Add($discordRpcButtonColumn)
$discordRpcStatus = New-Object System.Windows.Controls.TextBlock
$discordRpcStatus.Text = "Connect to monitor Discord mute and deafen state."
$discordRpcStatus.Foreground = $uiMuted
$discordRpcStatus.FontSize = 12
$discordRpcStatus.TextWrapping = "Wrap"
$discordRpcStatus.VerticalAlignment = "Center"
[void]$discordRpcActions.Children.Add($discordRpcStatus)
$discordRpcConnect = New-Object System.Windows.Controls.Button
$discordRpcConnect.Content = "Connect Discord"
$discordRpcConnect.Width = 124
$discordRpcConnect.Height = 32
$discordRpcConnect.Margin = "12,0,0,0"
$discordRpcConnect.Background = $uiControl
$discordRpcConnect.BorderBrush = $uiDivider
$discordRpcConnect.Foreground = $uiForeground
$discordRpcConnect.IsEnabled = $discordRpcAvailable
$discordRpcConnect.ToolTip = "Authorize the local Discord voice-state monitor"
$discordRpcButtons = New-Object System.Windows.Controls.StackPanel
$discordRpcButtons.Orientation = "Horizontal"
[void]$discordRpcButtons.Children.Add($discordRpcConnect)
$discordRpcDisconnect = New-Object System.Windows.Controls.Button
$discordRpcDisconnect.Content = "Disconnect"
$discordRpcDisconnect.Width = 92
$discordRpcDisconnect.Height = 32
$discordRpcDisconnect.Margin = "8,0,0,0"
$discordRpcDisconnect.Background = $uiControl
$discordRpcDisconnect.BorderBrush = $uiDivider
$discordRpcDisconnect.Foreground = $uiForeground
$discordRpcDisconnect.IsEnabled = $discordRpcAvailable
$discordRpcDisconnect.ToolTip = "Stop Discord monitoring"
[void]$discordRpcButtons.Children.Add($discordRpcDisconnect)
$discordForget = New-Object System.Windows.Controls.Button
$discordForget.Content = "Forget authorization"
$discordForget.Width = 132
$discordForget.Height = 32
$discordForget.Margin = "8,0,0,0"
$discordForget.Background = $uiControl
$discordForget.BorderBrush = $uiDivider
$discordForget.Foreground = $uiForeground
$discordForget.ToolTip = "Delete the locally saved Discord authorization"
[void]$discordRpcButtons.Children.Add($discordForget)
[System.Windows.Controls.Grid]::SetColumn($discordRpcButtons, 1)
[void]$discordRpcActions.Children.Add($discordRpcButtons)

$discordConnectedPanel = New-Object System.Windows.Controls.StackPanel
$discordConnectedPanel.Margin = "0,10,0,0"
[void]$discordBody.Children.Add($discordConnectedPanel)
$discordMicDetect = Add-SettingToggle -Container $discordConnectedPanel -Text "Microphone muted" -Checked ([bool]$settings.DiscordMicDetect)
$discordDeafenDetect = Add-SettingToggle -Container $discordConnectedPanel -Text "Deafened" -Checked ([bool]$settings.DiscordDeafenDetect)
[void]$discordBody.Children.Add($discordRpcActions)

$beacnBody = $beacnPage.Panel
$beacnDirectDetect = Add-SettingToggle -Container $beacnBody -Text "Monitor BEACN hardware" -Checked ([bool]$settings.BeacnDirectDetect)
$beacnDirectDetect.IsEnabled = ($usbCaptureAvailable -or $beacnAppScannerAvailable)
$beacnDirectDetect.ToolTip = "Uses BEACN's displayed state as truth; USBPcap adds immediate hardware-button wakeups when installed."

$beacnStatusCard = New-Object System.Windows.Controls.Border
$beacnStatusCard.CornerRadius = "7"
$beacnStatusCard.BorderThickness = "1"
$beacnStatusCard.Padding = "11,8"
$beacnStatusCard.Margin = "4,4,4,4"
$beacnStatusCard.Background = New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.Color]::FromRgb(57, 29, 33))
$beacnStatusCard.BorderBrush = New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.Color]::FromRgb(112, 52, 58))
$beacnStatusContent = New-Object System.Windows.Controls.StackPanel
$beacnCompatibilityStatus = New-Object System.Windows.Controls.TextBlock
$beacnCompatibilityStatus.Text = "Discovering"
$beacnCompatibilityStatus.Foreground = New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.Color]::FromRgb(232, 134, 140))
$beacnCompatibilityStatus.FontSize = 13
$beacnCompatibilityStatus.FontWeight = "SemiBold"
$beacnCompatibilityStatus.TextWrapping = "Wrap"
[void]$beacnStatusContent.Children.Add($beacnCompatibilityStatus)
$beacnReadinessStatus = New-Object System.Windows.Controls.TextBlock
$beacnReadinessStatus.Text = "Looking for BEACN software and validating its faders."
$beacnReadinessStatus.Foreground = $uiMuted
$beacnReadinessStatus.FontSize = 11
$beacnReadinessStatus.Margin = "0,3,0,0"
$beacnReadinessStatus.TextWrapping = "Wrap"
[void]$beacnStatusContent.Children.Add($beacnReadinessStatus)
$beacnStatusCard.Child = $beacnStatusContent
[void]$beacnBody.Children.Add($beacnStatusCard)
$script:lastBeacnCompatibilityStatusSignature = ""
$script:beacnStatusStartedAt = [DateTime]::UtcNow
$script:beacnEverReady = $false
$script:beacnStatusPresentationState = New-MuteCueBeacnStatusPresentationState

$copyBeacnDiagnostics = New-Object System.Windows.Controls.Button
$copyBeacnDiagnostics.Content = "Copy BEACN diagnostics"
$copyBeacnDiagnostics.Height = 30
$copyBeacnDiagnostics.Padding = "10,0"
$copyBeacnDiagnostics.Margin = "4,4,0,2"
$copyBeacnDiagnostics.HorizontalAlignment = "Left"
$copyBeacnDiagnostics.Background = $uiControl
$copyBeacnDiagnostics.BorderBrush = $uiDivider
$copyBeacnDiagnostics.Foreground = $uiForeground
$copyBeacnDiagnostics.ToolTip = "Copies a privacy-safe health report for troubleshooting."
[void]$beacnBody.Children.Add($copyBeacnDiagnostics)

$beacnAdvancedPanel = New-Object System.Windows.Controls.StackPanel
$beacnAdvancedPanel.Margin = "0,8,0,0"
[void]$beacnBody.Children.Add($beacnAdvancedPanel)
$beacnHotkeyHelp = New-Object System.Windows.Controls.TextBlock
$beacnHotkeyHelp.Text = "Mute Cue follows BEACN's Knob Mute assignments automatically and rereads the mapped fader; no separate Mute Cue hotkey is required."
$beacnHotkeyHelp.Foreground = $uiMuted
$beacnHotkeyHelp.FontSize = 12
$beacnHotkeyHelp.TextWrapping = "Wrap"
$beacnHotkeyHelp.Margin = "4,2,4,8"
[void]$beacnAdvancedPanel.Children.Add($beacnHotkeyHelp)

$faderSection = New-Object System.Windows.Controls.StackPanel
$faderSection.Margin = "18,2,0,0"
[void]$beacnAdvancedPanel.Children.Add($faderSection)
$faderHeading = New-Object System.Windows.Controls.TextBlock
$faderHeading.Text = "Fader Sources"
$faderHeading.Foreground = $uiForeground
$faderHeading.FontFamily = "Segoe UI Semibold"
$faderHeading.FontSize = 18
$faderHeading.Margin = "0,2,0,8"
[void]$faderSection.Children.Add($faderHeading)
$faderBody = New-Object System.Windows.Controls.StackPanel
$faderBody.Margin = "0,0,0,4"
[void]$faderSection.Children.Add($faderBody)
$faderHelp = New-Object System.Windows.Controls.TextBlock
$faderHelp.Text = "Choose which mute states should show the overlay for each mixer source. Unavailable sources are shown in the same order as BEACN and remain disabled."
$faderHelp.Foreground = $uiMuted
$faderHelp.FontSize = 12
$faderHelp.TextWrapping = "Wrap"
$faderHelp.Margin = "0,0,0,8"
[void]$faderBody.Children.Add($faderHelp)

$faderHeader = New-Object System.Windows.Controls.Grid
$faderHeader.Margin = "0,0,0,2"
$faderHeader.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition))
foreach ($width in @("92", "112")) {
    $column = New-Object System.Windows.Controls.ColumnDefinition
    $column.Width = $width
    $faderHeader.ColumnDefinitions.Add($column)
}
$sourceHeader = New-Object System.Windows.Controls.TextBlock
$sourceHeader.Text = "Source"
$sourceHeader.Foreground = $uiMuted
$sourceHeader.FontSize = 12
[void]$faderHeader.Children.Add($sourceHeader)
foreach ($columnIndex in 1..2) {
    $columnHeader = New-Object System.Windows.Controls.TextBlock
    $columnHeader.Text = if ($columnIndex -eq 1) { "Mute to All" } else { "Mute to Audience" }
    $columnHeader.Foreground = $uiMuted
    $columnHeader.FontSize = 12
    $columnHeader.HorizontalAlignment = "Center"
    [System.Windows.Controls.Grid]::SetColumn($columnHeader, $columnIndex)
    [void]$faderHeader.Children.Add($columnHeader)
}
[void]$faderBody.Children.Add($faderHeader)

$script:beacnFaderRows = @{}
$script:beacnFaderAudienceToggles = @{}
$script:beacnFaderAllToggles = @{}
$script:beacnFaderRowOrder = $null
$initialAudienceFaderNames = @(Get-ConfiguredMixCreateFaderNames -NamesProperty "BeacnAudienceFaderNames" -LegacyIdsProperty "BeacnAudienceFaderIds")
$initialAllFaderNames = @(Get-ConfiguredMixCreateFaderNames -NamesProperty "BeacnAllFaderNames" -LegacyIdsProperty "BeacnAllFaderIds")
foreach ($fader in @(Get-MixCreateFaderDefinitions)) {
    $row = New-Object System.Windows.Controls.Grid
    $row.Height = 32
    $row.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition))
    foreach ($width in @("92", "112")) {
        $column = New-Object System.Windows.Controls.ColumnDefinition
        $column.Width = $width
        $row.ColumnDefinitions.Add($column)
    }

    $label = New-Object System.Windows.Controls.TextBlock
    $label.Text = [string]$fader.Name
    $label.Foreground = if ($fader.IsAvailable) { $uiForeground } else { $uiMuted }
    $label.FontSize = 14
    $label.VerticalAlignment = "Center"
    [void]$row.Children.Add($label)

    $allToggle = New-Object System.Windows.Controls.CheckBox
    $allToggle.IsChecked = ($initialAllFaderNames -contains [string]$fader.Name)
    $allToggle.IsEnabled = [bool]$fader.IsAvailable
    $allToggle.HorizontalAlignment = "Center"
    $allToggle.VerticalAlignment = "Center"
    $allToggle.ToolTip = "Show the overlay when this source is muted to all mixes."
    [System.Windows.Controls.Grid]::SetColumn($allToggle, 1)
    [void]$row.Children.Add($allToggle)

    $audienceToggle = New-Object System.Windows.Controls.CheckBox
    $audienceToggle.IsChecked = ($initialAudienceFaderNames -contains [string]$fader.Name)
    $audienceToggle.IsEnabled = [bool]$fader.CanMonitorAudience
    $audienceToggle.HorizontalAlignment = "Center"
    $audienceToggle.VerticalAlignment = "Center"
    $audienceToggle.ToolTip = "Show the overlay when this source is muted to your audience."
    [System.Windows.Controls.Grid]::SetColumn($audienceToggle, 2)
    [void]$row.Children.Add($audienceToggle)

    $script:beacnFaderRows[[string]$fader.Name] = [pscustomobject]@{
        Container = $row
        Label = $label
        AllToggle = $allToggle
        AudienceToggle = $audienceToggle
    }
    $script:beacnFaderAllToggles[[string]$fader.Name] = $allToggle
    $script:beacnFaderAudienceToggles[[string]$fader.Name] = $audienceToggle
    [void]$faderBody.Children.Add($row)
}

$overlayBody = $generalSettingsPage.Panel
$overlayHeading = New-Object System.Windows.Controls.TextBlock
$overlayHeading.Text = "Overlay"
$overlayHeading.Foreground = $uiForeground
$overlayHeading.FontFamily = "Segoe UI Semibold"
$overlayHeading.FontSize = 18
$overlayHeading.Margin = "0,2,0,8"
[void]$overlayBody.Children.Add($overlayHeading)
$forceShow = Add-SettingToggle -Container $overlayBody -Text "Preview overlay" -Checked ([bool]$settings.ForceShow)
$clickThrough = Add-SettingToggle -Container $overlayBody -Text "Click through overlay" -Checked ([bool]$settings.ClickThrough)
$closeToSystemTray = Add-SettingToggle -Container $overlayBody -Text "Close to system tray" -Checked ([bool]$settings.CloseToSystemTray)
$sizeSetting = Add-SettingSlider -Container $overlayBody -Text "Size" -Minimum 220 -Maximum 900 -Value ([double]$settings.Size) -SmallChange 10
$sizeSlider = $sizeSetting.Slider
$sizeValue = $sizeSetting.ValueLabel
$opacitySetting = Add-SettingSlider -Container $overlayBody -Text "Opacity" -Minimum 0.25 -Maximum 1 -Value ([double]$settings.Opacity) -SmallChange 0.01
$opacitySlider = $opacitySetting.Slider
$opacityValue = $opacitySetting.ValueLabel

$startupDivider = New-Object System.Windows.Controls.Border
$startupDivider.BorderBrush = $uiDivider
$startupDivider.BorderThickness = "0,1,0,0"
$startupDivider.Margin = "0,14,0,12"
[void]$overlayBody.Children.Add($startupDivider)
$startupHeading = New-Object System.Windows.Controls.TextBlock
$startupHeading.Text = "Startup"
$startupHeading.Foreground = $uiForeground
$startupHeading.FontFamily = "Segoe UI Semibold"
$startupHeading.FontSize = 18
$startupHeading.Margin = "0,0,0,6"
[void]$overlayBody.Children.Add($startupHeading)
$script:startupRegistration = $null
try {
    $script:startupRegistration = Get-MuteCueStartupRegistration -LauncherPath $script:startupLauncherPath
} catch {}
$initialStartupEnabled = $null -ne $script:startupRegistration -and [bool]$script:startupRegistration.IsEnabled
$runOnStartup = Add-SettingToggle -Container $overlayBody -Text "Run on startup" -Checked $initialStartupEnabled
$startInSystemTray = Add-SettingToggle -Container $overlayBody -Text "Start in system tray" -Checked ([bool]$settings.StartInSystemTray -and $initialStartupEnabled)
$startInSystemTray.IsEnabled = $initialStartupEnabled
$startupStatus = New-Object System.Windows.Controls.TextBlock
$startupStatus.Text = if ($initialStartupEnabled) {
    "Mute Cue will start after you sign in to Windows."
} else {
    "Mute Cue will only open when you launch it."
}
$startupStatus.Foreground = $uiMuted
$startupStatus.FontSize = 11
$startupStatus.TextWrapping = "Wrap"
$startupStatus.Margin = "0,2,0,4"
[void]$overlayBody.Children.Add($startupStatus)
$script:updatingStartupControls = $false

$footer = New-Object System.Windows.Controls.Border
$footer.Background = New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.Color]::FromRgb(27, 29, 34))
$footer.BorderBrush = $uiDivider
$footer.BorderThickness = "0,1,0,0"
$footer.Padding = "22,12"
$buttonRow = New-Object System.Windows.Controls.Grid
$buttonRow.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition))
$buttonColumn = New-Object System.Windows.Controls.ColumnDefinition
$buttonColumn.Width = "Auto"
$buttonRow.ColumnDefinitions.Add($buttonColumn)

$center = New-Object System.Windows.Controls.Button
$center.Content = "Center Overlay"
$center.Height = 34
$center.Padding = "12,0"
$center.Background = $uiControl
$center.BorderBrush = $uiDivider
$center.Foreground = $uiForeground
$center.HorizontalAlignment = "Left"
[void]$buttonRow.Children.Add($center)

$close = New-Object System.Windows.Controls.Button
$close.Content = "Close"
$close.Width = 86
$close.Height = 34
$close.Margin = "8,0,0,0"
$close.Background = $uiAccent
$close.BorderBrush = $uiAccent
$close.Foreground = [System.Windows.Media.Brushes]::White
[System.Windows.Controls.Grid]::SetColumn($close, 1)
[void]$buttonRow.Children.Add($close)
$footer.Child = $buttonRow
[System.Windows.Controls.Grid]::SetRow($footer, 3)
[void]$settingsRoot.Children.Add($footer)

$settingsWindow.Content = $settingsRoot
Select-MuteCueSettingsTab -Name "Discord"

$script:allowApplicationExit = $false
$script:trayIcon = $null
$script:trayMenu = $null
$script:settingsHiddenToTray = $false

function Show-SettingsFromTray {
    $script:settingsHiddenToTray = $false
    if (-not $settingsWindow.IsVisible) {
        $settingsWindow.Show()
    }
    if ($settingsWindow.WindowState -eq [System.Windows.WindowState]::Minimized) {
        $settingsWindow.WindowState = [System.Windows.WindowState]::Normal
    }
    $settingsWindow.Activate()
    Update-TrayIconVisibility
}

function Update-TrayIconVisibility {
    if ($null -eq $script:trayIcon) { return }
    $script:trayIcon.Visible = (
        [bool]$settings.CloseToSystemTray -or
        [bool]$script:settingsHiddenToTray
    )
}

try {
    $trayLogoPath = Join-Path $scriptDir "mute-cue-tray.png"
    if (Test-Path -LiteralPath $trayLogoPath) {
        $traySource = [System.Drawing.Bitmap]::FromFile($trayLogoPath)
        try {
            $trayBitmap = [System.Drawing.Bitmap]::new(64, 64, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
            $trayGraphics = [System.Drawing.Graphics]::FromImage($trayBitmap)
            try {
                $trayGraphics.Clear([System.Drawing.Color]::Transparent)
                $trayGraphics.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
                $trayGraphics.DrawImage($traySource, [System.Drawing.Rectangle]::new(0, 0, 64, 64))
            } finally {
                $trayGraphics.Dispose()
            }
            $trayImageHandle = $trayBitmap.GetHicon()
            $trayIconImage = [System.Drawing.Icon]::FromHandle($trayImageHandle)
        } finally {
            if ($null -ne $trayBitmap) { $trayBitmap.Dispose() }
            $traySource.Dispose()
        }

        $script:trayMenu = New-Object System.Windows.Forms.ContextMenuStrip
        $openSettingsItem = $script:trayMenu.Items.Add("Open Settings")
        [void]$script:trayMenu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
        $exitItem = $script:trayMenu.Items.Add("Exit Mute Cue")

        $script:trayIcon = New-Object System.Windows.Forms.NotifyIcon
        $script:trayIcon.Icon = $trayIconImage
        $script:trayIcon.Text = "Mute Cue"
        $script:trayIcon.ContextMenuStrip = $script:trayMenu
        $script:trayIcon.Visible = (
            [bool]$settings.CloseToSystemTray -or
            [bool]$script:settingsHiddenToTray
        )

        $openSettingsItem.Add_Click({ Show-SettingsFromTray })
        $script:trayIcon.Add_MouseClick({
            param($sender, $eventArgs)

            if ($eventArgs.Button -eq [System.Windows.Forms.MouseButtons]::Left) {
                Show-SettingsFromTray
            }
        })
        $exitItem.Add_Click({
            $script:allowApplicationExit = $true
            try { $settingsWindow.Close() } finally {
                [System.Windows.Threading.Dispatcher]::CurrentDispatcher.BeginInvokeShutdown(
                    [System.Windows.Threading.DispatcherPriority]::Background
                )
            }
        })
    }
} catch {
    if ($null -ne $script:trayIcon) {
        $script:trayIcon.Dispose()
        $script:trayIcon = $null
    }
    if ($null -ne $script:trayMenu) {
        $script:trayMenu.Dispose()
        $script:trayMenu = $null
    }
}

function Refresh-MuteCueStartupControls {
    param([switch]$UpgradeOwnedShortcut)

    if ($script:updatingStartupControls) { return }
    $script:updatingStartupControls = $true
    try {
        $registration = Get-MuteCueStartupRegistration -LauncherPath $script:startupLauncherPath
        if ($UpgradeOwnedShortcut -and [bool]$registration.IsOwned -and [bool]$registration.NeedsUpdate) {
            $registration = Enable-MuteCueStartupRegistration -LauncherPath $script:startupLauncherPath
        }
        $script:startupRegistration = $registration
        $runOnStartup.IsChecked = [bool]$registration.IsEnabled
        $runOnStartup.IsEnabled = [bool]$registration.LauncherExists -and -not [bool]$registration.IsConflict
        $startInSystemTray.IsEnabled = [bool]$registration.IsEnabled
        if (-not [bool]$registration.IsEnabled) {
            $startInSystemTray.IsChecked = $false
            $settings.StartInSystemTray = $false
        }
        $startupStatus.Text = if ([bool]$registration.IsConflict) {
            [string]$registration.Detail
        } elseif (-not [bool]$registration.LauncherExists) {
            "The Mute Cue launcher is unavailable, so startup cannot be changed."
        } elseif ([bool]$registration.IsEnabled) {
            if ([bool]$settings.StartInSystemTray) {
                "Mute Cue will start quietly in the system tray after you sign in."
            } else {
                "Mute Cue will open after you sign in to Windows."
            }
        } else {
            "Mute Cue will only open when you launch it."
        }
        $runOnStartup.ToolTip = [string]$registration.Detail
        $startInSystemTray.ToolTip = "Only affects launches that happen automatically after Windows sign-in."
    } catch {
        $runOnStartup.IsEnabled = $false
        $startInSystemTray.IsEnabled = $false
        $startupStatus.Text = "Windows startup settings could not be read safely."
        Write-MuteCueDiagnosticThrottled `
            -Key "startup-settings-read" `
            -Level Warning `
            -Component "Startup" `
            -Message "Windows startup settings could not be read safely." `
            -Exception $_.Exception
    } finally {
        $script:updatingStartupControls = $false
    }
}

function Set-MuteCueRunOnStartupFromControl {
    if ($script:updatingStartupControls) { return }
    $desired = [bool]$runOnStartup.IsChecked
    $writeErrorMessage = ""
    $script:updatingStartupControls = $true
    try {
        $script:startupRegistration = Set-MuteCueStartupRegistration `
            -Enabled $desired `
            -LauncherPath $script:startupLauncherPath
        if (-not $desired) {
            $startInSystemTray.IsChecked = $false
            $settings.StartInSystemTray = $false
        }
    } catch {
        $writeErrorMessage = "The Windows startup setting could not be changed: $($_.Exception.Message)"
        Write-MuteCueDiagnosticThrottled `
            -Key "startup-settings-write" `
            -Level Warning `
            -Component "Startup" `
            -Message "The Windows startup setting could not be changed." `
            -Exception $_.Exception
    } finally {
        $script:updatingStartupControls = $false
    }
    Refresh-MuteCueStartupControls
    if (-not [string]::IsNullOrWhiteSpace($writeErrorMessage)) {
        $startupStatus.Text = $writeErrorMessage
    }
    Save-OverlaySettings -Settings $settings
}

function Set-MuteCueStartInTrayFromControl {
    if ($script:updatingStartupControls) { return }
    $settings.StartInSystemTray = (
        [bool]$runOnStartup.IsChecked -and
        [bool]$startInSystemTray.IsChecked
    )
    Refresh-MuteCueStartupControls
    Save-OverlaySettings -Settings $settings
}

function Update-DiscordSettingsVisibility {
    $connected = [bool]$script:discordRpcConnected
    $connecting = [bool]$script:discordRpcConnecting -and -not $connected

    $discordRpcLabel.Text = if ($connected) { "Connected to Discord" } elseif ($connecting) { "Connecting to Discord" } else { "Connect Discord" }
    $discordSetupPanel.Visibility = if ($connected -or $connecting) { "Collapsed" } else { "Visible" }
    $discordConnectedPanel.Visibility = if ($connected) { "Visible" } else { "Collapsed" }
    $discordRpcConnect.Visibility = if ($connected -or $connecting) { "Collapsed" } else { "Visible" }
    $discordRpcDisconnect.Visibility = if ($connected -or $connecting) { "Visible" } else { "Collapsed" }
    if ($connected) {
        $discordRpcStatus.Text = "Connected to Discord."
    } elseif ($connecting) {
        $discordRpcStatus.Text = "Connecting to Discord..."
    } elseif ([string]::IsNullOrWhiteSpace([string]$discordRpcStatus.Text)) {
        $discordRpcStatus.Text = "Connect to monitor Discord mute and deafen state."
    }
}

function Add-BeacnDynamicFaderRow {
    param([Parameter(Mandatory)][object]$Fader)

    $name = ([string]$Fader.Name).Trim()
    if ([string]::IsNullOrWhiteSpace($name) -or $script:beacnFaderRows.ContainsKey($name)) { return }
    $selectedAll = @(Get-ConfiguredMixCreateFaderNames -NamesProperty "BeacnAllFaderNames" -LegacyIdsProperty "BeacnAllFaderIds")
    $selectedAudience = @(Get-ConfiguredMixCreateFaderNames -NamesProperty "BeacnAudienceFaderNames" -LegacyIdsProperty "BeacnAudienceFaderIds")

    $row = New-Object System.Windows.Controls.Grid
    $row.Height = 32
    $row.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition))
    foreach ($width in @("92", "112")) {
        $column = New-Object System.Windows.Controls.ColumnDefinition
        $column.Width = $width
        $row.ColumnDefinitions.Add($column)
    }
    $label = New-Object System.Windows.Controls.TextBlock
    $label.Text = $name
    $label.Foreground = if ([bool]$Fader.IsAvailable) { $uiForeground } else { $uiMuted }
    $label.FontSize = 14
    $label.VerticalAlignment = "Center"
    [void]$row.Children.Add($label)

    $allToggle = New-Object System.Windows.Controls.CheckBox
    $allToggle.IsChecked = ($selectedAll -contains $name)
    $allToggle.IsEnabled = [bool]$Fader.IsAvailable
    $allToggle.HorizontalAlignment = "Center"
    $allToggle.VerticalAlignment = "Center"
    $allToggle.ToolTip = "Show the overlay when this source is muted to all mixes."
    [System.Windows.Controls.Grid]::SetColumn($allToggle, 1)
    [void]$row.Children.Add($allToggle)

    $audienceToggle = New-Object System.Windows.Controls.CheckBox
    $audienceToggle.IsChecked = ($selectedAudience -contains $name)
    $audienceToggle.IsEnabled = [bool]$Fader.CanMonitorAudience
    $audienceToggle.HorizontalAlignment = "Center"
    $audienceToggle.VerticalAlignment = "Center"
    $audienceToggle.ToolTip = "Show the overlay when this source is muted to your audience."
    [System.Windows.Controls.Grid]::SetColumn($audienceToggle, 2)
    [void]$row.Children.Add($audienceToggle)

    $script:beacnFaderRows[$name] = [pscustomobject]@{
        Container = $row
        Label = $label
        AllToggle = $allToggle
        AudienceToggle = $audienceToggle
    }
    $script:beacnFaderAllToggles[$name] = $allToggle
    $script:beacnFaderAudienceToggles[$name] = $audienceToggle
    $allToggle.Add_Checked({ Apply-SettingsToOverlay })
    $allToggle.Add_Unchecked({ Apply-SettingsToOverlay })
    $audienceToggle.Add_Checked({ Apply-SettingsToOverlay })
    $audienceToggle.Add_Unchecked({ Apply-SettingsToOverlay })
    [void]$faderBody.Children.Add($row)
}

function Update-BeacnFaderRows {
    if ($null -eq $script:beacnFaderRows) { return }
    $previousApplyingState = [bool]$script:applyingBeacnFaderRows
    $script:applyingBeacnFaderRows = $true
    try {
    $selectedAll = @(Get-ConfiguredMixCreateFaderNames -NamesProperty "BeacnAllFaderNames" -LegacyIdsProperty "BeacnAllFaderIds")
    $selectedAudience = @(Get-ConfiguredMixCreateFaderNames -NamesProperty "BeacnAudienceFaderNames" -LegacyIdsProperty "BeacnAudienceFaderIds")

    $definitions = @(Get-MixCreateFaderDefinitions)
    foreach ($definition in $definitions) { Add-BeacnDynamicFaderRow -Fader $definition }
    $orderedNames = @(
        $definitions |
            ForEach-Object { [string]$_.Name } |
            Where-Object { $script:beacnFaderRows.ContainsKey($_) }
    )
    $rowOrder = $orderedNames -join '|'
    if ($script:beacnFaderRowOrder -ne $rowOrder) {
        foreach ($row in @($script:beacnFaderRows.Values)) {
            [void]$faderBody.Children.Remove($row.Container)
        }
        foreach ($name in $orderedNames) {
            [void]$faderBody.Children.Add($script:beacnFaderRows[$name].Container)
        }
        $script:beacnFaderRowOrder = $rowOrder
    }

    foreach ($name in @($script:beacnFaderRows.Keys)) {
        $row = $script:beacnFaderRows[$name]
        if (-not $script:mixCreateFaderDefinitionsByName.ContainsKey($name)) {
            $row.Label.Foreground = $uiMuted
            $row.AllToggle.IsEnabled = $false
            $row.AudienceToggle.IsEnabled = $false
            continue
        }

        $fader = $script:mixCreateFaderDefinitionsByName[$name]
        $row.Label.Text = [string]$fader.Name
        $row.Label.Foreground = $uiForeground
        $row.AllToggle.IsEnabled = $true
        $row.AudienceToggle.IsEnabled = [bool]$fader.CanMonitorAudience
        $row.AllToggle.IsChecked = ($selectedAll -contains $name)
        $row.AudienceToggle.IsChecked = ($selectedAudience -contains $name)
    }
    } finally {
        $script:applyingBeacnFaderRows = $previousApplyingState
    }
}

function Update-BeacnCompatibilityStatus {
    if ($null -eq $beacnCompatibilityStatus) { return }

    $now = [DateTime]::UtcNow
    $telemetry = Get-BeacnScannerTelemetry
    $scannerStatus = if ($null -ne $telemetry) { [string]$telemetry.ScannerStatus } else { "Unavailable" }
    $adapterStatus = [string]$script:beacnAdapterState.CompatibilityStatus
    $faderCount = @($script:beacnAppFaderStates).Count
    $version = if ($null -ne $telemetry) { [string]$telemetry.BeacnVersion } else { "" }
    $script:muteCueBeacnReadiness = Get-MuteCueBeacnReadiness `
        -StaticReadiness $script:muteCueStaticReadiness `
        -Telemetry $telemetry `
        -FaderCount $faderCount `
        -HasAuthority ([bool]$script:beacnAppHasAuthority) `
        -HasActionAuthority ([bool]$script:beacnAppHasActionAuthority) `
        -UsbAvailable ([bool]$usbCaptureAvailable) `
        -UsbActive ($null -ne $script:mixCreateMonitor)

    $geometryInProgress = $false
    $geometryRemaining = 0
    $scanInProgress = $false
    $scanInProgressMilliseconds = 0.0
    if ($null -ne $telemetry) {
        $geometryProperty = $telemetry.PSObject.Properties["GeometryRefreshInProgress"]
        $remainingProperty = $telemetry.PSObject.Properties["GeometryRefreshRemaining"]
        $scanProperty = $telemetry.PSObject.Properties["ScanInProgress"]
        $scanDurationProperty = $telemetry.PSObject.Properties["ScanInProgressMilliseconds"]
        if ($null -ne $geometryProperty) { $geometryInProgress = [bool]$geometryProperty.Value }
        if ($null -ne $remainingProperty) { $geometryRemaining = [int]$remainingProperty.Value }
        if ($null -ne $scanProperty) { $scanInProgress = [bool]$scanProperty.Value }
        if ($null -ne $scanDurationProperty) { $scanInProgressMilliseconds = [double]$scanDurationProperty.Value }
    }
    $scanSlow = $scanInProgress -and $scanInProgressMilliseconds -ge 500
    $workerRunning = $false
    if ($null -ne $script:beacnAccessibilityClient) {
        try { $workerRunning = Test-BeacnAccessibilityClientRunning -Client $script:beacnAccessibilityClient } catch {}
    }
    $health = Get-BeacnCoordinatorHealth `
        -Coordinator $script:beacnStateCoordinator `
        -WorkerRunning $workerRunning `
        -Now $now
    $workerHealthReady = (
        -not $script:useBeacnAccessibilityWorker -or
        ($workerRunning -and $health.Status -eq "Healthy")
    )
    $workerNeedsRecovery = (
        $script:useBeacnAccessibilityWorker -and
        (-not $workerRunning -or $health.Status -ne "Healthy")
    )
    $providerTroubleDetected = (
        $workerNeedsRecovery -or
        $scannerStatus -in @("Unavailable", "Degraded") -or
        $adapterStatus -in @("Unavailable", "Degraded")
    )
    $providerTrouble = Update-MuteCueBeacnProviderTrouble `
        -State $script:beacnStatusPresentationState `
        -TroubleDetected $providerTroubleDetected `
        -Now $now
    $fullyReady = (
        [bool]$script:beacnAppHasAuthority -and
        [bool]$script:beacnAppHasActionAuthority -and
        $adapterStatus -eq "Ready" -and
        $scannerStatus -eq "Ready" -and
        [bool]$script:muteCueBeacnReadiness.CanMonitor -and
        $workerHealthReady -and
        -not $geometryInProgress -and
        -not $scanSlow
    )
    if ($fullyReady) { $script:beacnEverReady = $true }

    $readyPrimary = if ($null -ne $script:mixCreateMonitor) {
        "Ready - Fast hardware response active"
    } else {
        "Ready - Desktop monitoring active"
    }
    $readyDetailParts = New-Object 'System.Collections.Generic.List[string]'
    [void]$readyDetailParts.Add(("{0} faders synchronized" -f $faderCount))
    if (-not [string]::IsNullOrWhiteSpace($version)) { [void]$readyDetailParts.Add(("BEACN {0}" -f $version)) }
    if ([bool]$script:muteCueBeacnReadiness.ProfileVerified) { [void]$readyDetailParts.Add("verified compatibility") }
    $readyDetail = @($readyDetailParts.ToArray()) -join " - "

    $hardUnavailable = (
        $scannerStatus -eq "Incompatible" -or
        [string]$script:muteCueBeacnReadiness.Status -in @("EnvironmentIssue", "ComponentIssue") -or
        [bool]$providerTrouble.IsUnavailable
    )
    $recoveryRequested = (
        [bool]$script:beacnEverReady -and
        (
            $scanSlow -or
            $providerTroubleDetected -or
            $adapterStatus -in @("Synchronizing", "Discovering") -or
            $scannerStatus -eq "Reconnecting"
        )
    )

    $rawPhase = "Discovering"
    $rawPrimary = "Discovering"
    $rawDetail = "Looking for BEACN software and validating its faders."
    if ($fullyReady) {
        $rawPhase = "Ready"
        $rawPrimary = $readyPrimary
        $rawDetail = $readyDetail
    } elseif ($hardUnavailable) {
        $rawPhase = "Unavailable"
        $rawPrimary = "Discovering - BEACN monitoring unavailable"
        $rawDetail = if (@($script:muteCueBeacnReadiness.Issues).Count -gt 0) {
            @($script:muteCueBeacnReadiness.Issues) -join "; "
        } else {
            "Open the BEACN software and verify that both applications use the same Windows permission level."
        }
    } elseif ($geometryInProgress) {
        $rawPhase = "Resyncing"
        $rawPrimary = "Resyncing - Refreshing BEACN locations"
        $rawDetail = if ($geometryRemaining -gt 0) {
            "Updating $geometryRemaining remaining fader locations. Confirmed mute states stay protected."
        } else {
            "Finishing the monitor-location update. Confirmed mute states stay protected."
        }
    } elseif ($recoveryRequested) {
        $rawPhase = "Resyncing"
        $rawPrimary = if ($workerNeedsRecovery -or $scannerStatus -eq "Reconnecting") {
            "Resyncing - Connecting to BEACN software"
        } else {
            "Resyncing - Verifying the latest BEACN state"
        }
        $rawDetail = if ($scanSlow) {
            "BEACN is finishing an internal response. The last confirmed fader states remain active."
        } else {
            "Revalidating faders after a BEACN change. The last confirmed state is preserved."
        }
    }

    $presentation = Update-MuteCueBeacnStatusPresentation `
        -State $script:beacnStatusPresentationState `
        -RawPhase $rawPhase `
        -RawPrimary $rawPrimary `
        -RawDetail $rawDetail `
        -EverReady ([bool]$script:beacnEverReady) `
        -Now $now
    $phase = [string]$presentation.VisiblePhase
    $primary = [string]$presentation.VisiblePrimary
    $detail = [string]$presentation.VisibleDetail

    $signature = "$phase|$primary|$detail|$geometryRemaining"
    if ($signature -eq $script:lastBeacnCompatibilityStatusSignature) { return }
    $script:lastBeacnCompatibilityStatusSignature = $signature
    $beacnCompatibilityStatus.Text = $primary
    $beacnCompatibilityStatus.ToolTip = $detail
    $beacnReadinessStatus.Text = $detail
    $beacnReadinessStatus.ToolTip = $detail
    if ($phase -eq "Ready") {
        $beacnCompatibilityStatus.Foreground = New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.Color]::FromRgb(120, 214, 163))
        $beacnStatusCard.BorderBrush = New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.Color]::FromRgb(48, 105, 78))
        $beacnStatusCard.Background = New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.Color]::FromRgb(24, 53, 42))
    } elseif ($phase -in @("Discovering", "Unavailable")) {
        $beacnCompatibilityStatus.Foreground = New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.Color]::FromRgb(232, 134, 140))
        $beacnStatusCard.BorderBrush = New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.Color]::FromRgb(112, 52, 58))
        $beacnStatusCard.Background = New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.Color]::FromRgb(57, 29, 33))
    } else {
        $beacnCompatibilityStatus.Foreground = New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.Color]::FromRgb(239, 193, 90))
        $beacnStatusCard.BorderBrush = New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.Color]::FromRgb(113, 87, 35))
        $beacnStatusCard.Background = New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.Color]::FromRgb(48, 39, 23))
    }
    $beacnReadinessStatus.Foreground = $uiMuted
}

function Get-SelectedBeacnFaderNames {
    param([ValidateSet("All", "Audience")][string]$Mode)

    $names = New-Object 'System.Collections.Generic.List[string]'
    $toggles = if ($Mode -eq "All") { $script:beacnFaderAllToggles } else { $script:beacnFaderAudienceToggles }
    if ($null -eq $toggles) { return @() }

    foreach ($name in @($toggles.Keys)) {
        if ([bool]$toggles[$name].IsChecked) {
            [void]$names.Add([string]$name)
        }
    }

    return @($names.ToArray())
}

function Get-SelectedBeacnFaderKeys {
    param([ValidateSet("All", "Audience")][string]$Mode)

    $selectedNames = @(Get-SelectedBeacnFaderNames -Mode $Mode)
    $selectedKeys = New-Object 'System.Collections.Generic.List[string]'
    foreach ($fader in @(Get-MixCreateFaderDefinitions)) {
        if ($selectedNames -contains [string]$fader.Name -and -not [string]::IsNullOrWhiteSpace([string]$fader.StableKey)) {
            [void]$selectedKeys.Add(([string]$fader.StableKey).ToLowerInvariant())
        }
    }
    return @($selectedKeys.ToArray() | Select-Object -Unique)
}

function Update-BeacnSettingsVisibility {
    $beacnAdvancedPanel.Visibility = if ([bool]$beacnDirectDetect.IsChecked) { "Visible" } else { "Collapsed" }
}

function Apply-SettingsToOverlay {
    if ([bool]$script:applyingBeacnFaderRows) { return }
    $settings.BeacnDirectDetect = [bool]$beacnDirectDetect.IsChecked
    $settings.BeacnAudienceFaderNames = @(Get-SelectedBeacnFaderNames -Mode "Audience") -join ','
    $settings.BeacnAllFaderNames = @(Get-SelectedBeacnFaderNames -Mode "All") -join ','
    $settings.BeacnAudienceFaderKeys = @(Get-SelectedBeacnFaderKeys -Mode "Audience") -join ','
    $settings.BeacnAllFaderKeys = @(Get-SelectedBeacnFaderKeys -Mode "All") -join ','
    $settings.BeacnFaderSelectionFormat = 3
    $settings.DiscordMicDetect = [bool]$discordMicDetect.IsChecked
    $settings.DiscordDeafenDetect = [bool]$discordDeafenDetect.IsChecked
    $settings.ForceShow = [bool]$forceShow.IsChecked
    $settings.ClickThrough = [bool]$clickThrough.IsChecked
    $settings.CloseToSystemTray = [bool]$closeToSystemTray.IsChecked
    $settings.StartInSystemTray = (
        [bool]$runOnStartup.IsChecked -and
        [bool]$startInSystemTray.IsChecked
    )
    $settings.Size = [int]$sizeSlider.Value
    $settings.Opacity = [double]$opacitySlider.Value
    $sizeValue.Text = "{0} px" -f $settings.Size
    $opacityValue.Text = "{0}%" -f [Math]::Round($settings.Opacity * 100)
    Update-BeacnSettingsVisibility
    Update-DiscordSettingsVisibility

    $overlay.Width = [double]$settings.Size
    $overlay.Height = [double]$settings.Size * 0.68
    $overlay.Opacity = [double]$settings.Opacity
    Update-OverlayContentScale
    Move-OverlayIntoView
    Set-ClickThrough -Window $overlay -Enabled ([bool]$settings.ClickThrough)
    Save-OverlaySettings -Settings $settings
    Update-TrayIconVisibility

    if ([bool]$settings.ForceShow) {
        if (-not $overlay.IsVisible) { $overlay.Show() }
        $overlay.Activate()
    }
}

$sizeSlider.Add_ValueChanged({ Apply-SettingsToOverlay })
$opacitySlider.Add_ValueChanged({ Apply-SettingsToOverlay })
$clickThrough.Add_Checked({ Apply-SettingsToOverlay })
$clickThrough.Add_Unchecked({ Apply-SettingsToOverlay })
$forceShow.Add_Checked({ Apply-SettingsToOverlay })
$forceShow.Add_Unchecked({ Apply-SettingsToOverlay })
$closeToSystemTray.Add_Checked({ Apply-SettingsToOverlay })
$closeToSystemTray.Add_Unchecked({ Apply-SettingsToOverlay })
$runOnStartup.Add_Checked({ Set-MuteCueRunOnStartupFromControl })
$runOnStartup.Add_Unchecked({ Set-MuteCueRunOnStartupFromControl })
$startInSystemTray.Add_Checked({ Set-MuteCueStartInTrayFromControl })
$startInSystemTray.Add_Unchecked({ Set-MuteCueStartInTrayFromControl })
$beacnDirectDetect.Add_Checked({ Apply-SettingsToOverlay })
$beacnDirectDetect.Add_Unchecked({ Apply-SettingsToOverlay })
$copyBeacnDiagnostics.Add_Click({
    try {
        $diagnosticUsbStatus = if ($null -ne $script:mixCreateMonitor) {
            "fast hardware response active"
        } elseif ($usbCaptureAvailable) {
            "available, not connected"
        } else {
            "desktop monitoring only"
        }
        $report = Get-BeacnHealthReport `
            -Coordinator $script:beacnStateCoordinator `
            -Client $script:beacnAccessibilityClient `
            -Telemetry (Get-BeacnScannerTelemetry) `
            -States $script:beacnAppFaderStates `
            -HasAuthority ([bool]$script:beacnAppHasAuthority) `
            -HasActionAuthority ([bool]$script:beacnAppHasActionAuthority) `
            -Readiness $script:muteCueBeacnReadiness `
            -UsbStatus $diagnosticUsbStatus `
            -UsbDroppedPackets ([long]$script:lastMixCreateDroppedPacketCount)
        [Windows.Clipboard]::SetText($report)
        $copyBeacnDiagnostics.Content = "BEACN diagnostics copied"
    } catch {
        $copyBeacnDiagnostics.Content = "Could not copy diagnostics"
        Write-MuteCueDiagnosticThrottled -Key "beacn-copy-diagnostics" -Level Warning -Component "BEACN" -Message "The BEACN health report could not be copied." -Exception $_.Exception
    }
})
foreach ($faderToggle in @($script:beacnFaderAllToggles.Values) + @($script:beacnFaderAudienceToggles.Values)) {
    $faderToggle.Add_Checked({ Apply-SettingsToOverlay })
    $faderToggle.Add_Unchecked({ Apply-SettingsToOverlay })
}
$discordMicDetect.Add_Checked({ Apply-SettingsToOverlay })
$discordMicDetect.Add_Unchecked({ Apply-SettingsToOverlay })
$discordDeafenDetect.Add_Checked({ Apply-SettingsToOverlay })
$discordDeafenDetect.Add_Unchecked({ Apply-SettingsToOverlay })
$discordRpcConnect.Add_Click({
    Apply-SettingsToOverlay
    $script:discordRpcConnected = $false
    $script:discordRpcConnecting = $true
    if (-not $discordRpcAvailable) {
        $script:discordRpcConnecting = $false
        $discordRpcStatus.Text = "The local Discord connector is unavailable."
        Update-DiscordSettingsVisibility
        return
    }
    if (-not [bool]$script:discordPublicClient.Available) {
        $script:discordRpcConnecting = $false
        $discordRpcStatus.Text = [string]$script:discordPublicClient.Detail
        $discordRpcStatus.Foreground = $uiMuted
        Update-DiscordSettingsVisibility
        return
    }
    $discordRpcStatus.Text = "Connecting to Discord..."
    $discordRpcStatus.Foreground = $uiMuted
    $discordRpcStatus.Text = [BeacnMuteOverlay.DiscordRpcMonitor]::Start(
        [string]$script:discordPublicClient.ApplicationId,
        [string]$script:discordPublicClient.RedirectUri,
        [string]$script:discordAuthorization.AccessToken,
        [string]$script:discordAuthorization.RefreshToken,
        [int64]$script:discordAuthorization.ExpiresAtUnixSeconds
    )
    if (-not ([string]$discordRpcStatus.Text).StartsWith("Connecting", [System.StringComparison]::OrdinalIgnoreCase)) {
        $script:discordRpcConnecting = $false
    }
    Update-DiscordSettingsVisibility
})
$discordRpcDisconnect.Add_Click({
    if ($discordRpcAvailable) {
        [BeacnMuteOverlay.DiscordRpcMonitor]::Stop()
    }
    $script:discordRpcConnected = $false
    $script:discordRpcConnecting = $false
    $script:discordMuteSources = @()
    $discordRpcStatus.Text = "Discord monitoring disconnected."
    $discordRpcStatus.Foreground = $uiMuted
    Update-DiscordSettingsVisibility
})
$discordForget.Add_Click({
    if ($discordRpcAvailable) { [BeacnMuteOverlay.DiscordRpcMonitor]::Stop() }
    try {
        if (Test-Path -LiteralPath $discordAuthorizationPath) { Remove-Item -LiteralPath $discordAuthorizationPath -Force }
        $script:discordAuthorization = Get-SavedDiscordAuthorization
        $script:discordRpcConnected = $false
        $script:discordRpcConnecting = $false
        $script:discordMuteSources = @()
        $discordRpcStatus.Text = "Discord authorization was removed from this Windows account."
        $discordRpcStatus.Foreground = $uiMuted
    } catch {
        $discordRpcStatus.Text = "Discord authorization could not be removed."
        $discordRpcStatus.Foreground = $uiMuted
        Write-MuteCueDiagnostic -Level Warning -Component "Discord" -Message "The saved Discord authorization could not be removed." -Exception $_.Exception
    }
    Update-DiscordSettingsVisibility
})
$center.Add_Click({
    Apply-SettingsToOverlay
    Center-Overlay
    $forceShow.IsChecked = $true
    $settings.ForceShow = $true
    if (-not $overlay.IsVisible) { $overlay.Show() }
    $overlay.Activate()
})

$close.Add_Click({
    Apply-SettingsToOverlay
    $settings.X = [int]$overlay.Left
    $settings.Y = [int]$overlay.Top
    Save-OverlaySettings -Settings $settings
    $settingsWindow.Close()
})

$settingsWindow.Add_Closing({
    param($sender, $eventArgs)

    Apply-SettingsToOverlay
    $settings.X = [int]$overlay.Left
    $settings.Y = [int]$overlay.Top
    Save-OverlaySettings -Settings $settings

    if (
        [bool]$settings.CloseToSystemTray -and
        $null -ne $script:trayIcon -and
        -not $script:allowApplicationExit
    ) {
        $eventArgs.Cancel = $true
        $script:settingsHiddenToTray = $true
        Update-TrayIconVisibility
        $settingsWindow.Hide()
    }
})

$settingsWindow.Add_Activated({
    $script:settingsHiddenToTray = $false
    Refresh-MuteCueStartupControls -UpgradeOwnedShortcut
    Update-TrayIconVisibility
})

$settingsWindow.Add_Closed({
    if ($null -ne $script:trayIcon) {
        $script:trayIcon.Visible = $false
        $script:trayIcon.Dispose()
        $script:trayIcon = $null
    }
    if ($null -ne $script:trayMenu) {
        $script:trayMenu.Dispose()
        $script:trayMenu = $null
    }
    [System.Windows.Threading.Dispatcher]::CurrentDispatcher.BeginInvokeShutdown([System.Windows.Threading.DispatcherPriority]::Background)
})

$timer = New-Object System.Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromMilliseconds(50)
$timer.Add_Tick({
    $tickStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    try {
    Update-ExternalFaderSelectionSettings
    $muteSources = New-Object 'System.Collections.Generic.List[string]'
    if ([bool]$settings.ForceShow) {
        [void]$muteSources.Add("Testing overlay")
    }

    Update-MixCreateAudienceState
    Update-BeacnCompatibilityStatus
    if ($LogBeacnState -and ([DateTime]::UtcNow - $script:lastBeacnHeartbeatLog).TotalSeconds -ge 1) {
        $script:lastBeacnHeartbeatLog = [DateTime]::UtcNow
        $heartbeatTelemetry = Get-BeacnScannerTelemetry
        if ($null -ne $heartbeatTelemetry) {
            Write-BeacnStateLog -Message ("HEARTBEAT {0}; lastScanMs={1:N1}; event={2}" -f $heartbeatTelemetry.DiagnosticSummary, [double]$heartbeatTelemetry.LastScanMilliseconds, $heartbeatTelemetry.LastActionEventSummary)
        } else {
            Write-BeacnStateLog -Message "HEARTBEAT accessibility helper unavailable"
        }
    }
    foreach ($source in @(Get-MixCreateMutedSources)) {
        [void]$muteSources.Add([string]$source)
    }

    Update-DiscordRpcState
    foreach ($source in @($script:discordMuteSources)) {
        [void]$muteSources.Add([string]$source)
    }

    $activeSources = @($muteSources | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)
    if ($LogBeacnState) {
        $sourceLogSignature = $activeSources -join "|"
        if ($sourceLogSignature -ne $script:lastBeacnSourceLogSignature) {
            $script:lastBeacnSourceLogSignature = $sourceLogSignature
            Write-BeacnStateLog -Message ("SOURCES {0}" -f $sourceLogSignature)
        }
    }
    if ($activeSources.Count -gt 0) {
        $hasBeacnMute = @($activeSources | Where-Object { $_.StartsWith("BEACN", [System.StringComparison]::OrdinalIgnoreCase) }).Count -gt 0
        $hasDiscordMute = @($activeSources | Where-Object { $_.StartsWith("Discord", [System.StringComparison]::OrdinalIgnoreCase) }).Count -gt 0
        if ($hasBeacnMute -or $hasDiscordMute) {
            $logoRow.Visibility = "Visible"
            $beacnLogo.Visibility = if ($hasBeacnMute) { "Visible" } else { "Collapsed" }
            $discordOverlayLogo.Visibility = if ($hasDiscordMute) { "Visible" } else { "Collapsed" }
            $beacnMuteList.Visibility = if ($hasBeacnMute) { "Visible" } else { "Collapsed" }
            if ($hasBeacnMute) {
                Update-BeacnOverlayRows -Sources $activeSources
            }
            if ($hasBeacnMute -and $hasDiscordMute) {
                $muted.Text = "Discord: Muted"
                $muted.Visibility = "Visible"
            } elseif ($hasDiscordMute) {
                $discordDeafened = @($activeSources | Where-Object { $_ -eq "Discord: deafened" }).Count -gt 0
                $muted.Text = if ($discordDeafened) { "Deafened" } else { "Muted" }
                $muted.Visibility = "Visible"
            } else {
                $muted.Visibility = "Collapsed"
            }
            $sub.Visibility = "Collapsed"
            Update-OverlayDynamicHeight
        } else {
            $logoRow.Visibility = "Collapsed"
            $beacnMuteList.Visibility = "Collapsed"
            $muted.Visibility = "Visible"
            $muted.Text = "Muted"
            $sub.Text = ($activeSources -join [Environment]::NewLine)
            $sub.Visibility = "Visible"
            Update-OverlayDynamicHeight
        }
        if (-not $overlay.IsVisible) { $overlay.Show() }
    } else {
        $beacnMuteList.Visibility = "Collapsed"
        $muted.Visibility = "Visible"
        Update-OverlayDynamicHeight
        if ($overlay.IsVisible) { $overlay.Hide() }
    }
    } catch {
        Write-MuteCueDiagnosticThrottled `
            -Key "runtime-tick" `
            -Component "Runtime" `
            -Message "A monitoring update failed; the next update will retry." `
            -Exception $_.Exception
        Write-BeacnStateLog -Message ("ERROR runtime tick: {0}" -f $_.Exception.Message)
    } finally {
        $tickStopwatch.Stop()
        if ($tickStopwatch.ElapsedMilliseconds -ge 250) {
            Write-MuteCueDiagnosticThrottled `
                -Key "runtime-slow-tick" `
                -Level Warning `
                -Component "Performance" `
                -Message ("A UI monitoring update took {0} ms." -f $tickStopwatch.ElapsedMilliseconds) `
                -MinimumIntervalSeconds 30
        }
    }
})

# The full monitoring pass stays at 20 Hz, while the tiny keyboard and USB input
# queues get a dedicated 15 ms pump (about 67 Hz). This improves control latency
# without tripling accessibility, Discord, settings, and presentation work.
$hotkeyInputTimer = New-Object System.Windows.Threading.DispatcherTimer
$hotkeyInputTimer.Interval = [TimeSpan]::FromMilliseconds(15)
$hotkeyInputTimer.Add_Tick({
    try {
        Invoke-BeacnHotkeyGestureQueue
        Invoke-MixCreateUsbPacketQueue
    } catch {
        Write-MuteCueDiagnosticThrottled `
            -Key 'beacn-fast-input-pump' `
            -Level Warning `
            -Component 'BEACN' `
            -Message 'A fast input update failed; the next update will retry.' `
            -Exception $_.Exception `
            -MinimumIntervalSeconds 30
    }
})

$overlay.Add_SourceInitialized({
    Set-ClickThrough -Window $overlay -Enabled ([bool]$settings.ClickThrough)
})

$settingsWindow.Add_SourceInitialized({
    if ([bool]$settings.ForceShow) {
        $overlay.Show()
    }
})

Apply-SettingsToOverlay
Refresh-MuteCueStartupControls -UpgradeOwnedShortcut

if (
    $discordRpcAvailable -and
    [bool]$script:discordPublicClient.Available -and
    -not [string]::IsNullOrWhiteSpace([string]$script:discordAuthorization.AccessToken)
) {
    $script:discordRpcConnected = $false
    $script:discordRpcConnecting = $true
    $discordRpcStatus.Text = [BeacnMuteOverlay.DiscordRpcMonitor]::Start(
        [string]$script:discordPublicClient.ApplicationId,
        [string]$script:discordPublicClient.RedirectUri,
        [string]$script:discordAuthorization.AccessToken,
        [string]$script:discordAuthorization.RefreshToken,
        [int64]$script:discordAuthorization.ExpiresAtUnixSeconds
    )
    if (-not ([string]$discordRpcStatus.Text).StartsWith("Connecting", [System.StringComparison]::OrdinalIgnoreCase)) {
        $script:discordRpcConnecting = $false
    }
    Update-DiscordSettingsVisibility
}

$script:runtimeStopped = $false
function Stop-MuteCueRuntime {
    if ($script:runtimeStopped) { return }
    $script:runtimeStopped = $true

    try { $timer.Stop() } catch {}
    try { $hotkeyInputTimer.Stop() } catch {}
    try {
        $settings.X = [int]$overlay.Left
        $settings.Y = [int]$overlay.Top
        Save-OverlaySettings -Settings $settings -Immediate
    } catch {}
    if ($discordRpcAvailable) {
        try { [BeacnMuteOverlay.DiscordRpcMonitor]::Stop() } catch {}
    }
    if ($null -ne $script:beacnAccessibilityClient) {
        try { Stop-BeacnAccessibilityClient -Client $script:beacnAccessibilityClient } catch {}
    }
    if ($beacnAppScannerAvailable) {
        try { [BeacnMuteOverlay.BeacnAppScanner]::Shutdown() } catch {}
    }
    if ($mouseHookAvailable) {
        try { [BeacnMuteOverlay.KeyboardInput]::StopMouseListener() } catch {}
    }
    if ($script:keyboardHookAvailable) {
        try { [BeacnMuteOverlay.KeyboardInput]::StopKeyboardListener() } catch {}
        $script:keyboardHookAvailable = $false
    }
    if ($null -ne $script:mixCreateMonitor) {
        try { $script:mixCreateMonitor.Dispose() } catch {}
        $script:mixCreateMonitor = $null
    }
    if ($null -ne $script:trayIcon) {
        try { $script:trayIcon.Visible = $false } catch {}
        try { $script:trayIcon.Dispose() } catch {}
        $script:trayIcon = $null
    }
    if ($null -ne $script:trayMenu) {
        try { $script:trayMenu.Dispose() } catch {}
        $script:trayMenu = $null
    }
    try { $overlay.Close() } catch {}
    if ($null -ne $script:overlayInstanceMutex) {
        try { $script:overlayInstanceMutex.ReleaseMutex() } catch {}
        try { $script:overlayInstanceMutex.Dispose() } catch {}
        $script:overlayInstanceMutex = $null
    }
    if ($null -ne $script:overlayInstanceLock) {
        try { $script:overlayInstanceLock.Dispose() } catch {}
        $script:overlayInstanceLock = $null
    }
}

try {
    try {
        $mouseHookAvailable = [BeacnMuteOverlay.KeyboardInput]::StartMouseListener()
    } catch {
        $mouseHookAvailable = $false
        Write-MuteCueDiagnostic -Level Warning -Component "Input" -Message "Mouse listener could not start." -Exception $_.Exception
    }
    Update-BeacnHotkeyConfiguration -Force

    $hotkeyInputTimer.Start()
    $timer.Start()
    $startHiddenInTray = (
        [bool]$StartedAtLogin -and
        [bool]$settings.StartInSystemTray -and
        $null -ne $script:trayIcon
    )
    if ($startHiddenInTray) {
        $script:settingsHiddenToTray = $true
        Update-TrayIconVisibility
        Write-MuteCueDiagnostic -Level Info -Component "Startup" -Message "The settings window started in the system tray after Windows sign-in."
    } else {
        $script:settingsHiddenToTray = $false
        $settingsWindow.Show()
        Write-MuteCueDiagnostic `
            -Level Info `
            -Component "Startup" `
            -Message ("The settings window was shown (visible={0}, signInLaunch={1})." -f [int]$settingsWindow.IsVisible, [int][bool]$StartedAtLogin)
    }
    [System.Windows.Threading.Dispatcher]::Run()
} catch {
    Write-MuteCueDiagnostic -Level Error -Component "Runtime" -Message "Mute Cue stopped unexpectedly." -Exception $_.Exception
    throw
} finally {
    Stop-MuteCueRuntime
}
