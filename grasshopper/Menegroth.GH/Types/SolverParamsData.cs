namespace Menegroth.GH.Types
{
    /// <summary>
    /// Beam solver parameters for MIP catalog selection.
    /// When Catalog is "custom", bounds are used to generate the catalog from
    /// min/max width, min/max depth, and resolution (all in inches).
    /// </summary>
    public class SolverParamsData
    {
        /// <summary>
        /// Catalog preset: small, medium, large, xlarge, all, or custom.
        /// When custom, MinWidthIn, MaxWidthIn, MinDepthIn, MaxDepthIn, ResolutionIn are used.
        /// </summary>
        public string Catalog { get; set; } = "large";

        /// <summary>
        /// Minimum beam width in inches. Used when Catalog is "custom".
        /// </summary>
        public double? MinWidthIn { get; set; } = null;

        /// <summary>
        /// Maximum beam width in inches. Used when Catalog is "custom".
        /// </summary>
        public double? MaxWidthIn { get; set; } = null;

        /// <summary>
        /// Minimum beam depth in inches. Used when Catalog is "custom".
        /// </summary>
        public double? MinDepthIn { get; set; } = null;

        /// <summary>
        /// Maximum beam depth in inches. Used when Catalog is "custom".
        /// </summary>
        public double? MaxDepthIn { get; set; } = null;

        /// <summary>
        /// Resolution (step size) in inches for width and depth. Used when Catalog is "custom".
        /// </summary>
        public double? ResolutionIn { get; set; } = null;

        /// <summary>
        /// Apply this override to an existing DesignParamsData instance.
        /// </summary>
        public void ApplyTo(DesignParamsData target)
        {
            if (target == null) return;
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
