#pragma warning disable
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
using Point = System.Windows.Point;

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
        public long ActionRevision { get; set; }
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
            public long ActionRevision;
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
            public long ActionRevision;
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
            public bool OutputCandidateCorrelated;
            public int Mask;
            public int Position;
            public long RequestId;
            public long MappingGeneration;
            public bool MappingConfident;
            public int Attempt;
            public int FallbackIndex;
            public bool FinalVerification;
            public DateTime RequestedAtUtc;
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
        private static readonly ConcurrentDictionary<string, long> recentPersonalOutputEdges =
            new ConcurrentDictionary<string, long>(StringComparer.OrdinalIgnoreCase);
        private static readonly ConcurrentDictionary<string, long> recentAudienceOutputEdges =
            new ConcurrentDictionary<string, long>(StringComparer.OrdinalIgnoreCase);
        private const int MaximumRecordedOutputEdgeNames = 128;
        private const int OutputEdgePreRequestToleranceMilliseconds = 250;
        private const int OutputEdgeCorrelationMilliseconds = 2500;
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
        private static long stateRevision;
        private static long lastStateObservationUtcTicks;
        private static AutomationElement subscribedWindow;
        private static IntPtr subscribedWindowHandle = IntPtr.Zero;
        private static readonly object geometryGate = new object();
        private static Rect lastWindowBounds = Rect.Empty;
        private const int WindowGeometrySettleMilliseconds = 3000;
        private static readonly StructureChangedEventHandler rootStructureChangedHandler = HandleRootStructureChanged;
        private static readonly System.Windows.Automation.Condition ButtonElementCondition = new PropertyCondition(
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
        public static long StateRevision { get { return Interlocked.Read(ref stateRevision); } }
        public static DateTime StateCapturedAtUtc {
            get {
                long ticks = Interlocked.Read(ref lastStateObservationUtcTicks);
                return ticks <= 0 ? DateTime.MinValue : new DateTime(ticks, DateTimeKind.Utc);
            }
        }
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
                    (discoveryTask != null && !discoveryTask.IsCompleted) ||
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
            recentPersonalOutputEdges.Clear();
            recentAudienceOutputEdges.Clear();
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
                ? 21
                : String.Equals(mode, "Audience", StringComparison.OrdinalIgnoreCase) ? 26 : 31;
            // A row/output event is BEACN's exact source identity. Always let it
            // interrupt positional page recovery and force an independent follow-up
            // read. The coalescing urgent dictionary keeps redraw bursts bounded,
            // and no physical-position guess is ever shown.
            QueueUrgentFaderRefresh(name, mask);
        }

        public static void RequestUrgentFaderRefresh(string name, string mode) {
            if (String.IsNullOrWhiteSpace(name)) return;
            int mask = String.Equals(mode, "All", StringComparison.OrdinalIgnoreCase)
                ? 5
                : String.Equals(mode, "Audience", StringComparison.OrdinalIgnoreCase) ? 10 : 15;
            QueueUrgentFaderRefresh(name, mask);
        }

        public static void RequestHardwareRefresh(string preferredName, string mode, int position, long requestId, long mappingGeneration, bool mappingConfident) {
            RequestHardwareRefresh(
                preferredName,
                mode,
                position,
                requestId,
                mappingGeneration,
                mappingConfident,
                DateTime.UtcNow.Ticks
            );
        }

        public static void RequestHardwareRefresh(string preferredName, string mode, int position, long requestId, long mappingGeneration, bool mappingConfident, long inputAtUtcTicks) {
            int mask = String.Equals(mode, "All", StringComparison.OrdinalIgnoreCase)
                ? 5
                : String.Equals(mode, "Audience", StringComparison.OrdinalIgnoreCase) ? 10 : 0;
            if (mask == 0) return;
            DateTime now = DateTime.UtcNow;
            DateTime inputAtUtc = now;
            try {
                if (inputAtUtcTicks > DateTime.MinValue.Ticks && inputAtUtcTicks < DateTime.MaxValue.Ticks) {
                    DateTime candidate = new DateTime(inputAtUtcTicks, DateTimeKind.Utc);
                    if (Math.Abs((now - candidate).TotalSeconds) <= 5) inputAtUtc = candidate;
                }
            } catch { }
            EnqueueHardwareRefresh(new HardwareRefreshRequest {
                PreferredName = preferredName ?? String.Empty,
                OutputCandidateName = String.Empty,
                OutputCandidateCorrelated = false,
                Mask = mask,
                Position = position,
                RequestId = requestId,
                MappingGeneration = mappingGeneration,
                MappingConfident = mappingConfident,
                Attempt = 0,
                FallbackIndex = -1,
                FinalVerification = false,
                RequestedAtUtc = inputAtUtc,
                // Let BEACN finish applying the USB action before reading its row.
                NotBeforeUtc = now.AddMilliseconds(30)
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
                ? 21
                : String.Equals(mode, "Audience", StringComparison.OrdinalIgnoreCase) ? 26 : 31;
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
                    ActionRevision = fader.ActionRevision,
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
                fader.ActionRevision = checkpoint.ActionRevision;
                fader.PersonalMuted = checkpoint.PersonalMuted;
                fader.AudienceMuted = checkpoint.AudienceMuted;
                fader.IsLocked = checkpoint.IsLocked;
            }
            // Do not clear refreshes queued concurrently while geometry was moving.
            // The caller restores this checkpoint, then the named request retries
            // against the new screen coordinates on the next scan.
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
                    // Exact-name work (hotkeys and resolved desktop clicks) must be
                    // able to interrupt a page-recovery walk. This keeps one stale
                    // hardware mapping from monopolizing several expensive scans.
                    bool urgentRefresh = false;
                    Dictionary<string, int> requested =
                        DrainActionRefreshes(pendingUrgentActionRefreshes, MaximumFaderRefreshesPerScan);
                    urgentRefresh = requested.Count > 0;

                    HardwareRefreshRequest hardwareRequest = null;
                    bool hardwareRefreshDequeued = false;
                    if (!urgentRefresh) {
                        hardwareRefreshDequeued = TryDequeueHardwareRefresh(out hardwareRequest);
                    }
                    if (!urgentRefresh && hardwareRefreshDequeued) {
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

                    if (!urgentRefresh && !hardwareRefreshDequeued) {
                        requested = DrainActionRefreshes(pendingActionRefreshes, MaximumFaderRefreshesPerScan);
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
                                System.Windows.Automation.Condition.TrueCondition
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
            foreach (TrackedFader fader in complete) {
                fader.ActionRevision = MarkStateObservation();
                // Discovery is the first real observation. Queue one independent
                // named verification per fader so startup authority never depends
                // on a cache-only idle scan.
                QueueFaderRefresh(fader.Name, 15);
            }
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
                        RecordOutputEdge(fader.Name, true);
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
                        RecordOutputEdge(fader.Name, false);
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

        private static void RecordOutputEdge(string name, bool personal) {
            if (String.IsNullOrWhiteSpace(name)) return;
            ConcurrentDictionary<string, long> target = personal
                ? recentPersonalOutputEdges
                : recentAudienceOutputEdges;
            if (target.Count >= MaximumRecordedOutputEdgeNames && !target.ContainsKey(name)) {
                // The live mixer has far fewer rows. Clearing an impossible identity
                // burst fails correlation closed and keeps this callback bounded.
                target.Clear();
            }
            target[name] = DateTime.UtcNow.Ticks;
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
            // Geometry is part of the published envelope, but it must not advance
            // any fader's action-confirmation revision.
            MarkStateObservation();
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
                        bool requiresFollowup = (mask & 16) != 0;
                        int followupMask = mask & ~16;
                        if (changed || requiresFollowup) {
                            // Require a second real UIA read, not merely a repeated cached snapshot.
                            // HasPendingChanges keeps the worker on its 15 ms confirmation cadence.
                            if (urgent) QueueUrgentFaderRefresh(fader.Name, followupMask);
                            else QueueFaderRefresh(fader.Name, followupMask);
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
                    fader.AllActionSeen = false;
                    fader.AllVerifiedUtc = DateTime.UtcNow;
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
                    fader.AudienceActionSeen = false;
                    fader.AudienceVerifiedUtc = DateTime.UtcNow;
                    succeeded = false;
                }
            }

            // A failed targeted read is also a real observation: it makes the row
            // explicitly unknown and must be published. The per-fader revision
            // prevents cache-only or unrelated reads from confirming this row.
            if ((mask & 3) != 0) fader.ActionRevision = MarkStateObservation();
            return succeeded;
        }

        private static long MarkStateObservation() {
            Interlocked.Exchange(ref lastStateObservationUtcTicks, DateTime.UtcNow.Ticks);
            return Interlocked.Increment(ref stateRevision);
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

        private static bool IsCorrelatedUniqueOutputEdge(string name, int mask, DateTime requestedAtUtc) {
            if (String.IsNullOrWhiteSpace(name) || requestedAtUtc == DateTime.MinValue) return false;
            List<TrackedFader> snapshot = trackedFaders;
            bool[] personalRecent = new bool[snapshot.Count];
            bool[] audienceRecent = new bool[snapshot.Count];
            DateTime now = DateTime.UtcNow;
            long earliestTicks = requestedAtUtc.AddMilliseconds(-OutputEdgePreRequestToleranceMilliseconds).Ticks;
            long latestTicks = requestedAtUtc.AddMilliseconds(OutputEdgeCorrelationMilliseconds).Ticks;
            for (int index = 0; index < snapshot.Count; index++) {
                string faderName = snapshot[index].Name;
                long ticks;
                if (recentPersonalOutputEdges.TryGetValue(faderName, out ticks)) {
                    personalRecent[index] = ticks >= earliestTicks && ticks <= latestTicks && ticks <= now.Ticks;
                }
                if (recentAudienceOutputEdges.TryGetValue(faderName, out ticks)) {
                    audienceRecent[index] = ticks >= earliestTicks && ticks <= latestTicks && ticks <= now.Ticks;
                }
            }
            int selected = SelectUniqueOutputChange(personalRecent, audienceRecent, mask);
            return selected >= 0 && selected < snapshot.Count && String.Equals(
                snapshot[selected].Name,
                name,
                StringComparison.OrdinalIgnoreCase
            );
        }

        private static bool ShouldCompletePreferredHardwareRead(
            bool preferredRead,
            bool preferredChanged,
            bool mappingConfident,
            bool outputCandidateCorrelated
        ) {
            return preferredRead && (
                preferredChanged || (!mappingConfident && outputCandidateCorrelated)
            );
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
            // Only use output-toggle edge inference when the page mapping is already
            // uncertain; an unrelated earlier client edge must not override a known row.
            if (
                !request.MappingConfident &&
                request.FallbackIndex < 0 &&
                String.IsNullOrWhiteSpace(request.OutputCandidateName)
            ) {
                TrackedFader outputCandidate = FindUniqueOutputChange(request.Mask);
                if (outputCandidate != null) {
                    request.OutputCandidateName = outputCandidate.Name;
                    request.OutputCandidateCorrelated = IsCorrelatedUniqueOutputEdge(
                        outputCandidate.Name,
                        request.Mask,
                        request.RequestedAtUtc
                    );
                }
            }
            if (
                !request.MappingConfident &&
                request.FallbackIndex < 0 &&
                !request.OutputCandidateCorrelated &&
                !String.IsNullOrWhiteSpace(request.OutputCandidateName)
            ) {
                // The toggle value can become visible just before its property event
                // callback. Retain the provisional exact candidate and correlate it
                // on a later staged retry instead of losing the edge to that race.
                request.OutputCandidateCorrelated = IsCorrelatedUniqueOutputEdge(
                    request.OutputCandidateName,
                    request.Mask,
                    request.RequestedAtUtc
                );
            }
            TrackedFader preferred = request.MappingConfident
                ? FindTrackedFader(request.PreferredName)
                : FindTrackedFader(request.OutputCandidateName);
            if (preferred == null) preferred = FindTrackedFader(request.PreferredName);

            if (preferred != null) {
                bool preferredChanged;
                bool preferredRead = TryRefreshFaderAction(preferred, request.Mask, out preferredChanged);
                bool correlatedCandidate = request.OutputCandidateCorrelated && String.Equals(
                    preferred.Name,
                    request.OutputCandidateName,
                    StringComparison.OrdinalIgnoreCase
                );
                if (ShouldCompletePreferredHardwareRead(
                    preferredRead,
                    preferredChanged,
                    request.MappingConfident,
                    correlatedCandidate
                )) {
                    timer.Stop();
                    lastActionRefresh = DateTime.UtcNow;
                    lastHardwareRefreshSummary = String.Format(
                        "preferred {0} attempt={1} correlated={2} elapsed={3:0}ms",
                        preferred.Name,
                        request.Attempt + 1,
                        correlatedCandidate ? 1 : 0,
                        timer.Elapsed.TotalMilliseconds
                    );
                    return new HardwareRefreshCompletion { Request = request, ChangedName = preferred.Name };
                }

                // JUCE can redraw after several early reads. A known hardware page
                // must stay on its exact mapped row instead of walking every other
                // fader. Unknown pages use the same staged reads first, allowing a
                // late output edge to identify the page before broad recovery.
                int[] preferredRetryDelays = new int[] { 45, 80, 140, 240 };
                if (request.FallbackIndex < 0 && request.Attempt < preferredRetryDelays.Length) {
                    int retryDelay = preferredRetryDelays[request.Attempt];
                    request.Attempt++;
                    request.NotBeforeUtc = DateTime.UtcNow.AddMilliseconds(retryDelay);
                    EnqueueHardwareRefresh(request);
                    Interlocked.Exchange(ref actionRefreshRequested, 1);
                    timer.Stop();
                    lastActionRefresh = DateTime.UtcNow;
                    lastHardwareRefreshSummary = String.Format(
                        "preferred waiting {0} attempt={1} delay={2}ms elapsed={3:0}ms",
                        preferred.Name,
                        request.Attempt + 1,
                        retryDelay,
                        timer.Elapsed.TotalMilliseconds
                    );
                    return null;
                }
            }

            if (request.MappingConfident) {
                timer.Stop();
                lastActionRefresh = DateTime.UtcNow;
                lastHardwareRefreshSummary = String.Format(
                    "confident no change preferred={0} attempts={1} elapsed={2:0}ms",
                    request.PreferredName,
                    request.Attempt + 1,
                    timer.Elapsed.TotalMilliseconds
                );
                return new HardwareRefreshCompletion {
                    Request = request,
                    ChangedName = String.Empty
                };
            }

            if (request.FinalVerification) {
                HardwareRefreshCompletion finalCompletion = new HardwareRefreshCompletion {
                    Request = request,
                    ChangedName = String.Empty
                };
                timer.Stop();
                lastActionRefresh = DateTime.UtcNow;
                lastHardwareRefreshSummary = String.Format(
                    "final no change preferred={0} attempt={1} elapsed={2:0}ms",
                    request.PreferredName,
                    request.Attempt + 1,
                    timer.Elapsed.TotalMilliseconds
                );
                return finalCompletion;
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

            // JUCE can apply the hardware action after the fallback walk has already
            // passed the intended row. Give the preferred row one bounded final read
            // before retracting the request as a no-change result.
            request.FinalVerification = true;
            request.FallbackIndex = -1;
            request.NotBeforeUtc = DateTime.UtcNow.AddMilliseconds(60);
            EnqueueHardwareRefresh(request);
            Interlocked.Exchange(ref actionRefreshRequested, 1);
            timer.Stop();
            lastActionRefresh = DateTime.UtcNow;
            lastHardwareRefreshSummary = String.Format(
                "final verification waiting preferred={0} elapsed={1:0}ms",
                request.PreferredName,
                timer.Elapsed.TotalMilliseconds
            );
            return null;

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
                            ActionRevision = fader.ActionRevision,
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
                System.Windows.Automation.Condition buttonCondition = new AndCondition(
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
                                System.Windows.Automation.Condition controlCondition = new OrCondition(
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
