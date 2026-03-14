namespace Menegroth.GH.Types
{
    /// <summary>
    /// Override parameters for foundation design.
    /// All optional; only set fields override the Design Params defaults.
    /// </summary>
    public class FoundationParamsData
    {
        /// <summary>
        /// Soil preset: loose_sand, medium_sand, dense_sand, soft_clay, stiff_clay, hard_clay.
        /// </summary>
        public string? Soil { get; set; } = null;

        /// <summary>
        /// Foundation concrete grade (e.g. NWC_3000, NWC_4000).
        /// </summary>
        public string? Concrete { get; set; } = null;

        /// <summary>
        /// Strategy: auto, all_spread, all_strip, mat.
        /// </summary>
        public string? Strategy { get; set; } = null;

        /// <summary>
        /// Switch to mat when coverage ratio exceeds this (0–1). Default 0.5.
        /// </summary>
        public double? MatCoverageThreshold { get; set; } = null;

        /// <summary>
        /// Apply this override to an existing DesignParamsData instance.
        /// </summary>
        public void ApplyTo(DesignParamsData target)
        {
            if (target == null) return;

            if (!string.IsNullOrEmpty(Soil))
                target.FoundationSoil = Soil;

            if (!string.IsNullOrEmpty(Concrete))
                target.FoundationConcrete = Concrete;

            if (!string.IsNullOrEmpty(Strategy))
                target.FoundationStrategy = Strategy;

            if (MatCoverageThreshold.HasValue)
                target.MatCoverageThreshold = MatCoverageThreshold.Value;
        }
    }
}
