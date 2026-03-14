namespace Menegroth.GH.Types
{
    /// <summary>
    /// Solver parameters for MIP/NLP catalog selection by section.
    /// Section determines which catalog is configured (beam or column).
    /// </summary>
    public class SolverParamsData
    {
        /// <summary>
        /// Solver type: mip (discrete catalog) or nlp (continuous).
        /// </summary>
        public string SolverType { get; set; } = "nlp";

        /// <summary>
        /// Section this config applies to: beam or column.
        /// </summary>
        public string Section { get; set; } = "column";

        /// <summary>
        /// Beam type when Section=beam: rc_rect or rc_tbeam (only these use catalog).
        /// </summary>
        public string? BeamType { get; set; } = "rc_rect";

        /// <summary>
        /// Beam catalog preset when Section=beam: standard, small, large, xlarge, all, custom.
        /// </summary>
        public string Catalog { get; set; } = "large";

        /// <summary>
        /// Column type when Section=column (for catalog choice scoping).
        /// </summary>
        public string? ColumnType { get; set; } = "rc_rect";

        /// <summary>
        /// Column catalog when Section=column.
        /// Steel: compact_only, preferred, all. RC rect: standard, square, rectangular, low_capacity, high_capacity, all. RC circular: standard, low_capacity, high_capacity, all.
        /// </summary>
        public string? ColumnCatalog { get; set; } = null;

        /// <summary>
        /// Minimum beam width in inches. Used when Section=beam and Catalog=custom.
        /// </summary>
        public double? MinWidthIn { get; set; } = null;

        /// <summary>
        /// Maximum beam width in inches. Used when Section=beam and Catalog=custom.
        /// </summary>
        public double? MaxWidthIn { get; set; } = null;

        /// <summary>
        /// Minimum beam depth in inches. Used when Section=beam and Catalog=custom.
        /// </summary>
        public double? MinDepthIn { get; set; } = null;

        /// <summary>
        /// Maximum beam depth in inches. Used when Section=beam and Catalog=custom.
        /// </summary>
        public double? MaxDepthIn { get; set; } = null;

        /// <summary>
        /// Resolution (step size) in inches. Used when Section=beam and Catalog=custom.
        /// </summary>
        public double? ResolutionIn { get; set; } = null;

        /// <summary>
        /// PixelFrame concrete strength preset: standard, low, high, extended, custom.
        /// Used when Section=column and ColumnType=pixelframe, or Section=beam and BeamType=pixelframe.
        /// </summary>
        public string? PixelFrameFcPreset { get; set; } = "standard";

        /// <summary>
        /// PixelFrame fc min (ksi). Required when PixelFrameFcPreset is custom.
        /// </summary>
        public double? PixelFrameFcMinKsi { get; set; } = null;

        /// <summary>
        /// PixelFrame fc max (ksi). Required when PixelFrameFcPreset is custom.
        /// </summary>
        public double? PixelFrameFcMaxKsi { get; set; } = null;

        /// <summary>
        /// PixelFrame fc resolution (ksi). Required when PixelFrameFcPreset is custom.
        /// </summary>
        public double? PixelFrameFcResolutionKsi { get; set; } = null;

        /// <summary>
        /// Apply this override to an existing DesignParamsData instance.
        /// </summary>
        public void ApplyTo(DesignParamsData target)
        {
            if (target == null) return;

            if (SolverType == "nlp")
            {
                if (Section == "beam")
                    target.BeamSizingStrategy = "nlp";
                else if (Section == "column")
                    target.ColumnSizingStrategy = "nlp";
                return;
            }

            if (Section == "beam")
            {
                target.BeamType = BeamType ?? "rc_rect";
                if (BeamType == "pixelframe")
                {
                    target.PixelFrameFcPreset = PixelFrameFcPreset ?? "standard";
                    target.PixelFrameFcMinKsi = PixelFrameFcMinKsi;
                    target.PixelFrameFcMaxKsi = PixelFrameFcMaxKsi;
                    target.PixelFrameFcResolutionKsi = PixelFrameFcResolutionKsi;
                    return;
                }
                target.BeamCatalog = Catalog;
                if (Catalog == "custom" && MinWidthIn.HasValue && MaxWidthIn.HasValue &&
                    MinDepthIn.HasValue && MaxDepthIn.HasValue && ResolutionIn.HasValue)
                {
                    target.BeamCatalogBounds = new BeamCatalogBoundsData
                    {
                        MinWidthIn = MinWidthIn.Value,
                        MaxWidthIn = MaxWidthIn.Value,
                        MinDepthIn = MinDepthIn.Value,
                        MaxDepthIn = MaxDepthIn.Value,
                        ResolutionIn = ResolutionIn.Value
                    };
                }
                else
                {
                    target.BeamCatalogBounds = null;
                }
            }
            else if (Section == "column")
            {
                target.ColumnType = ColumnType ?? "rc_rect";
                if (ColumnType == "pixelframe")
                {
                    target.PixelFrameFcPreset = PixelFrameFcPreset ?? "standard";
                    target.PixelFrameFcMinKsi = PixelFrameFcMinKsi;
                    target.PixelFrameFcMaxKsi = PixelFrameFcMaxKsi;
                    target.PixelFrameFcResolutionKsi = PixelFrameFcResolutionKsi;
                }
                else if (!string.IsNullOrEmpty(ColumnCatalog))
                {
                    target.ColumnCatalog = ColumnCatalog;
                }
            }
        }
    }

    /// <summary>
    /// Bounds for custom beam catalog (min/max width, min/max depth, resolution in inches).
    /// </summary>
    public class BeamCatalogBoundsData
    {
        public double MinWidthIn { get; set; } = 12;
        public double MaxWidthIn { get; set; } = 36;
        public double MinDepthIn { get; set; } = 18;
        public double MaxDepthIn { get; set; } = 48;
        public double ResolutionIn { get; set; } = 2;
    }
}
