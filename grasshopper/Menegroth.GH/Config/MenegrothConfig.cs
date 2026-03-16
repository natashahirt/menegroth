using System;

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

        // ─── Geometry ─────────────────────────────────────────────────────
        public const double GeometryTolerance = 1e-6;

        // ─── Visualization ───────────────────────────────────────────────
        public const int SlabVertexWarningThreshold = 200_000;
        public const int DeflectionSegmentsMin = 3;
        public const int DeflectionSegmentsMax = 6;
    }
}
