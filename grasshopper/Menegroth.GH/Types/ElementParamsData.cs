namespace Menegroth.GH.Types
{
    /// <summary>
    /// Element-specific sizing parameters for beams and columns.
    /// Stores NLP bounds as interval tuples (min, max).
    /// </summary>
    public class ElementParamsData
    {
        /// <summary>Solver type: mip or nlp.</summary>
        public string SolverType { get; set; } = "nlp";

        /// <summary>Section type: beam or column.</summary>
        public string Section { get; set; } = "beam";

        /// <summary>Element type: steel_w, steel_hss, rc_rect, rc_tbeam, rc_circular, pixelframe.</summary>
        public string ElementType { get; set; } = "steel_w";

        // Steel W bounds (inches)
        public (double Min, double Max)? DepthIn { get; set; }
        public (double Min, double Max)? FlangeWidthIn { get; set; }
        public (double Min, double Max)? FlangeThicknessIn { get; set; }
        public (double Min, double Max)? WebThicknessIn { get; set; }

        // Steel HSS bounds (inches)
        public (double Min, double Max)? OuterDimensionIn { get; set; }
        public (double Min, double Max)? WallThicknessIn { get; set; }

        // RC bounds (inches)
        public (double Min, double Max)? WidthIn { get; set; }
        public (double Min, double Max)? DiameterIn { get; set; }

        // PixelFrame bounds (ksi)
        public (double Min, double Max)? FcKsi { get; set; }

        /// <summary>
        /// Apply these element parameters to a DesignParamsData instance.
        /// </summary>
        public void ApplyTo(DesignParamsData target)
        {
            if (target == null) return;

            // Set section type and sizing strategy
            if (Section == "beam")
            {
                target.BeamType = ElementType;
                target.BeamSizingStrategy = SolverType;
            }
            else
            {
                target.ColumnType = ElementType;
                target.ColumnSizingStrategy = SolverType;
            }

            // Apply bounds based on element type
            switch (ElementType)
            {
                case "steel_w":
                    if (DepthIn.HasValue || FlangeWidthIn.HasValue)
                    {
                        target.SteelWBounds = new SteelWBoundsData
                        {
                            MinDepthIn = DepthIn?.Min ?? 8,
                            MaxDepthIn = DepthIn?.Max ?? 36,
                            MinFlangeWidthIn = FlangeWidthIn?.Min ?? 4,
                            MaxFlangeWidthIn = FlangeWidthIn?.Max ?? 18,
                            MinFlangeThicknessIn = FlangeThicknessIn?.Min ?? 0.25,
                            MaxFlangeThicknessIn = FlangeThicknessIn?.Max ?? 2.0,
                            MinWebThicknessIn = WebThicknessIn?.Min ?? 0.25,
                            MaxWebThicknessIn = WebThicknessIn?.Max ?? 1.0
                        };
                    }
                    break;

                case "steel_hss":
                    if (OuterDimensionIn.HasValue || WallThicknessIn.HasValue)
                    {
                        target.SteelHSSBounds = new SteelHSSBoundsData
                        {
                            MinOuterIn = OuterDimensionIn?.Min ?? 4,
                            MaxOuterIn = OuterDimensionIn?.Max ?? 20,
                            MinThicknessIn = WallThicknessIn?.Min ?? 0.125,
                            MaxThicknessIn = WallThicknessIn?.Max ?? 0.625
                        };
                    }
                    break;

                case "rc_rect":
                case "rc_tbeam":
                    if (WidthIn.HasValue || DepthIn.HasValue)
                    {
                        target.RCRectBounds = new RCRectBoundsData
                        {
                            MinWidthIn = WidthIn?.Min ?? 12,
                            MaxWidthIn = WidthIn?.Max ?? 24,
                            MinDepthIn = DepthIn?.Min ?? 12,
                            MaxDepthIn = DepthIn?.Max ?? 48
                        };
                    }
                    break;

                case "rc_circular":
                    if (DiameterIn.HasValue)
                    {
                        target.RCCircularBounds = new RCCircularBoundsData
                        {
                            MinDiameterIn = DiameterIn?.Min ?? 12,
                            MaxDiameterIn = DiameterIn?.Max ?? 48
                        };
                    }
                    break;

                case "pixelframe":
                    if (FcKsi.HasValue)
                    {
                        target.PixelFrameFcMinKsi = FcKsi?.Min;
                        target.PixelFrameFcMaxKsi = FcKsi?.Max;
                        target.PixelFrameFcResolutionKsi = (FcKsi.Value.Max - FcKsi.Value.Min) / 10.0;
                    }
                    break;
            }
        }
    }

    /// <summary>Bounds for Steel W NLP sizing (inches).</summary>
    public class SteelWBoundsData
    {
        public double MinDepthIn { get; set; } = 8;
        public double MaxDepthIn { get; set; } = 36;
        public double MinFlangeWidthIn { get; set; } = 4;
        public double MaxFlangeWidthIn { get; set; } = 18;
        public double MinFlangeThicknessIn { get; set; } = 0.25;
        public double MaxFlangeThicknessIn { get; set; } = 2.0;
        public double MinWebThicknessIn { get; set; } = 0.25;
        public double MaxWebThicknessIn { get; set; } = 1.0;
    }

    /// <summary>Bounds for Steel HSS NLP sizing (inches).</summary>
    public class SteelHSSBoundsData
    {
        public double MinOuterIn { get; set; } = 4;
        public double MaxOuterIn { get; set; } = 20;
        public double MinThicknessIn { get; set; } = 0.125;
        public double MaxThicknessIn { get; set; } = 0.625;
    }

    /// <summary>Bounds for RC rectangular NLP sizing (inches).</summary>
    public class RCRectBoundsData
    {
        public double MinWidthIn { get; set; } = 12;
        public double MaxWidthIn { get; set; } = 24;
        public double MinDepthIn { get; set; } = 12;
        public double MaxDepthIn { get; set; } = 48;
    }

    /// <summary>Bounds for RC circular NLP sizing (inches).</summary>
    public class RCCircularBoundsData
    {
        public double MinDiameterIn { get; set; } = 12;
        public double MaxDiameterIn { get; set; } = 48;
    }
}
