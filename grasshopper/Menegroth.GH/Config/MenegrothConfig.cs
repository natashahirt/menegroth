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
