using System;
using System.Threading;
using Menegroth.GH.Types;
using Newtonsoft.Json.Linq;

namespace Menegroth.GH.Config
{
    /// <summary>
    /// Centralized configuration constants for the Menegroth Grasshopper plugin.
    /// </summary>
    public static class MenegrothConfig
    {
        // ─── API / HTTP ───────────────────────────────────────────────────
        public const string DefaultServerUrl = "http://localhost:8080";
        public const int PollTimeoutSeconds = 3600;
        public const int HealthCheckTimeoutSeconds = 3;
        public static readonly TimeSpan HttpClientTimeout = TimeSpan.FromHours(1);

        /// <summary>
        /// Last server URL used by <see cref="Components.DesignRun"/>. Updated after every
        /// successful design request so downstream components (e.g. Visualization) can call
        /// the same server without requiring a separate URL input.
        /// </summary>
        public static string LastServerUrl { get; set; } = DefaultServerUrl;

        /// <summary>
        /// API key for server authentication. Set via DesignRun right-click menu.
        /// When non-empty, all requests include Authorization: Bearer &lt;key&gt;.
        /// </summary>
        public static string? LastApiKey { get; set; }

        // ─── UI / Solution scheduling ──────────────────────────────────────
        public const int ScheduleSolutionIntervalMs = 100;

        /// <summary>
        /// Assistant Apply queues a JSON params patch here; <see cref="Components.DesignRun"/> consumes it
        /// and merges into wired params. This avoids wiring Unified Assistant → Design Run Params (recursive data stream).
        /// </summary>
        private static readonly object AssistantParamsPatchLock = new object();
        private static JObject? _queuedAssistantParamsPatch;

        /// <summary>Queue a patch for the next <see cref="Components.DesignRun"/> solve (merged after reading Design Params wire).</summary>
        public static void QueueAssistantParamsPatch(JObject? patch)
        {
            if (patch == null || patch.Count == 0)
                return;
            lock (AssistantParamsPatchLock)
            {
                _queuedAssistantParamsPatch = (JObject)patch.DeepClone();
            }
        }

        /// <summary>Take queued patch for merge, or null if none.</summary>
        public static JObject? TryConsumeAssistantParamsPatch()
        {
            lock (AssistantParamsPatchLock)
            {
                var p = _queuedAssistantParamsPatch;
                _queuedAssistantParamsPatch = null;
                return p;
            }
        }

        private static int _designRunRequestedAfterAssistantPatch;

        /// <summary>
        /// Unified Assistant "Apply &amp; Run" sets this; the next <see cref="Components.DesignRun"/> solve treats Run as true once.
        /// </summary>
        public static void RequestDesignRunAfterAssistantPatch() =>
            Interlocked.Exchange(ref _designRunRequestedAfterAssistantPatch, 1);

        /// <summary>Returns true once after a request, then clears the flag.</summary>
        public static bool TryConsumeDesignRunRequest() =>
            Interlocked.Exchange(ref _designRunRequestedAfterAssistantPatch, 0) == 1;

        // ─── Geometry ─────────────────────────────────────────────────────
        public const double GeometryTolerance = 1e-6;

        /// <summary>
        /// Latest <see cref="BuildingGeometry"/> produced by GeometryInput.
        /// Chat clients read this to include <c>building_geometry</c> in
        /// <c>POST /chat</c> and <c>POST /chat/action</c> requests so the
        /// assistant can access geometry without a prior design run.
        /// </summary>
        private static readonly object BuildingGeometryLock = new object();
        private static BuildingGeometry? _lastBuildingGeometry;
        private static string? _lastBuildingGeometryHash;
        private static string? _lastGeometrySummary;

        /// <summary>
        /// Called by GeometryInput when it produces a new BuildingGeometry.
        /// </summary>
        public static void UpdateBuildingGeometry(BuildingGeometry? geo, string? summary)
        {
            lock (BuildingGeometryLock)
            {
                _lastBuildingGeometry = geo;
                _lastBuildingGeometryHash = geo?.ComputeHash();
                _lastGeometrySummary = summary;
            }
        }

        /// <summary>
        /// Returns the latest geometry JSON, hash, and summary for chat requests.
        /// All outputs are null when no geometry has been produced yet.
        /// </summary>
        public static (JObject? geoJson, string? geoHash, string? summary) GetBuildingGeometryForChat()
        {
            lock (BuildingGeometryLock)
            {
                return (
                    _lastBuildingGeometry?.ToJson(),
                    _lastBuildingGeometryHash,
                    _lastGeometrySummary
                );
            }
        }

        // ─── Visualization ───────────────────────────────────────────────
        public const int SlabVertexWarningThreshold = 200_000;
        public const int DeflectionSegmentsMin = 3;
        public const int DeflectionSegmentsMax = 6;
    }
}
