using System;
using System.Collections.Generic;
using Newtonsoft.Json.Linq;

namespace Menegroth.GH.Types
{
    /// <summary>
    /// Container for design parameters matching the Julia API schema.
    /// </summary>
    public class DesignParamsData
    {
        // Loads (psf)
        public double FloorLL { get; set; } = 80;
        public double RoofLL { get; set; } = 80;
        public double GradeLL { get; set; } = 80;
        public double FloorSDL { get; set; } = 15;
        public double RoofSDL { get; set; } = 15;
        public double WallSDL { get; set; } = 10;

        // Floor system
        public string FloorType { get; set; } = "flat_plate";
        public string AnalysisMethod { get; set; } = "DDM";
        public string DeflectionLimit { get; set; } = "L_360";
        public string PunchingStrategy { get; set; } = "grow_columns";
        public double? VaultLambda { get; set; } = null;
        public int? MaxIterations { get; set; } = null;
        public double? FeaTargetEdgeM { get; set; } = null;

        // Materials
        public string Concrete { get; set; } = "NWC_4000";
        public string Rebar { get; set; } = "Rebar_60";
        public string Steel { get; set; } = "A992";

        // Member types
        public string ColumnType { get; set; } = "rc_rect";
        /// <summary>Column catalog: for steel_w/steel_hss use compact_only, preferred, all; for rc_rect use standard, square, rectangular, low_capacity, high_capacity, all; for rc_circular use standard, low_capacity, high_capacity, all. Default: preferred.</summary>
        public string ColumnCatalog { get; set; } = "preferred";
        /// <summary>RC columns only: discrete (MIP) or nlp (continuous).</summary>
        public string ColumnSizingStrategy { get; set; } = "discrete";
        /// <summary>MIP solver time limit (seconds) when discrete sizing. Default: 30.</summary>
        public double? MipTimeLimitSec { get; set; } = null;
        public string BeamType { get; set; } = "steel_w";
        /// <summary>RC beam catalog when BeamType is rc_rect or rc_tbeam: standard, small, large, xlarge, all, custom. Default: large.</summary>
        public string BeamCatalog { get; set; } = "large";
        /// <summary>RC beams only: discrete (MIP) or nlp (continuous).</summary>
        public string BeamSizingStrategy { get; set; } = "discrete";
        // NLP bounds for various element types
        public SteelWBoundsData SteelWBounds { get; set; } = null;
        public SteelHSSBoundsData SteelHSSBounds { get; set; } = null;
        public RCRectBoundsData RCRectBounds { get; set; } = null;
        public RCCircularBoundsData RCCircularBounds { get; set; } = null;

        /// <summary>PixelFrame fc preset when ColumnType or BeamType is pixelframe: standard, low, high, extended, custom.</summary>
        public string PixelFrameFcPreset { get; set; } = "standard";
        /// <summary>PixelFrame fc min (ksi). Required when PixelFrameFcPreset is custom.</summary>
        public double? PixelFrameFcMinKsi { get; set; } = null;
        /// <summary>PixelFrame fc max (ksi). Required when PixelFrameFcPreset is custom.</summary>
        public double? PixelFrameFcMaxKsi { get; set; } = null;
        /// <summary>PixelFrame fc resolution (ksi). Required when PixelFrameFcPreset is custom.</summary>
        public double? PixelFrameFcResolutionKsi { get; set; } = null;

        // Design targets
        public double FireRating { get; set; } = 0;
        public string OptimizeFor { get; set; } = "weight";
        public bool SizeFoundations { get; set; } = true;
        public string FoundationSoil { get; set; } = "medium_sand";
        public string FoundationConcrete { get; set; } = "NWC_3000";
        public string FoundationStrategy { get; set; } = "auto";
        public double MatCoverageThreshold { get; set; } = 0.5;
        public string UnitSystem { get; set; } = "imperial";
        public List<SlabParamsData> ScopedSlabOverrides { get; set; } = new List<SlabParamsData>();

        /// <summary>
        /// Serialise to a JObject matching the API params schema.
        /// </summary>
        public JObject ToJson()
        {
            var obj = new JObject
            {
                ["unit_system"] = UnitSystem,
                ["loads"] = new JObject
                {
                    ["floor_LL_psf"] = FloorLL,
                    ["roof_LL_psf"] = RoofLL,
                    ["grade_LL_psf"] = GradeLL,
                    ["floor_SDL_psf"] = FloorSDL,
                    ["roof_SDL_psf"] = RoofSDL,
                    ["wall_SDL_psf"] = WallSDL
                },
                ["floor_type"] = FloorType,
                ["floor_options"] = new JObject
                {
                    ["method"] = AnalysisMethod,
                    ["deflection_limit"] = DeflectionLimit,
                    ["punching_strategy"] = PunchingStrategy
                },
                ["materials"] = new JObject
                {
                    ["concrete"] = Concrete,
                    ["rebar"] = Rebar,
                    ["steel"] = Steel
                },
                ["column_type"] = ColumnType,
                ["column_catalog"] = ColumnCatalog,
                ["column_sizing_strategy"] = ColumnSizingStrategy ?? "discrete",
                ["mip_time_limit_sec"] = MipTimeLimitSec,
                ["beam_type"] = BeamType,
                ["beam_catalog"] = BeamCatalog,
                ["beam_sizing_strategy"] = BeamSizingStrategy ?? "discrete",
                ["steel_w_bounds"] = SteelWBounds != null
                    ? (JToken)new JObject
                    {
                        ["min_depth_in"] = SteelWBounds.MinDepthIn,
                        ["max_depth_in"] = SteelWBounds.MaxDepthIn,
                        ["min_flange_width_in"] = SteelWBounds.MinFlangeWidthIn,
                        ["max_flange_width_in"] = SteelWBounds.MaxFlangeWidthIn,
                        ["min_flange_thickness_in"] = SteelWBounds.MinFlangeThicknessIn,
                        ["max_flange_thickness_in"] = SteelWBounds.MaxFlangeThicknessIn,
                        ["min_web_thickness_in"] = SteelWBounds.MinWebThicknessIn,
                        ["max_web_thickness_in"] = SteelWBounds.MaxWebThicknessIn
                    }
                    : null,
                ["steel_hss_bounds"] = SteelHSSBounds != null
                    ? (JToken)new JObject
                    {
                        ["min_outer_in"] = SteelHSSBounds.MinOuterIn,
                        ["max_outer_in"] = SteelHSSBounds.MaxOuterIn,
                        ["min_thickness_in"] = SteelHSSBounds.MinThicknessIn,
                        ["max_thickness_in"] = SteelHSSBounds.MaxThicknessIn
                    }
                    : null,
                ["rc_rect_bounds"] = RCRectBounds != null
                    ? (JToken)new JObject
                    {
                        ["min_width_in"] = RCRectBounds.MinWidthIn,
                        ["max_width_in"] = RCRectBounds.MaxWidthIn,
                        ["min_depth_in"] = RCRectBounds.MinDepthIn,
                        ["max_depth_in"] = RCRectBounds.MaxDepthIn
                    }
                    : null,
                ["rc_circular_bounds"] = RCCircularBounds != null
                    ? (JToken)new JObject
                    {
                        ["min_diameter_in"] = RCCircularBounds.MinDiameterIn,
                        ["max_diameter_in"] = RCCircularBounds.MaxDiameterIn
                    }
                    : null,
                ["pixelframe_options"] = (ColumnType == "pixelframe" || BeamType == "pixelframe")
                    ? (JToken)new JObject
                    {
                        ["fc_preset"] = PixelFrameFcPreset ?? "standard",
                        ["fc_min_ksi"] = PixelFrameFcMinKsi,
                        ["fc_max_ksi"] = PixelFrameFcMaxKsi,
                        ["fc_resolution_ksi"] = PixelFrameFcResolutionKsi
                    }
                    : null,
                ["fire_rating"] = FireRating,
                ["optimize_for"] = OptimizeFor,
                ["size_foundations"] = SizeFoundations,
                ["foundation_soil"] = FoundationSoil,
                ["foundation_concrete"] = FoundationConcrete,
                ["foundation_options"] = new JObject
                {
                    ["strategy"] = FoundationStrategy,
                    ["mat_coverage_threshold"] = MatCoverageThreshold
                }
            };

            if (VaultLambda.HasValue)
                ((JObject)obj["floor_options"])["vault_lambda"] = VaultLambda.Value;
            if (FeaTargetEdgeM.HasValue)
                ((JObject)obj["floor_options"])["target_edge_m"] = FeaTargetEdgeM.Value;
            if (MaxIterations.HasValue)
                obj["max_iterations"] = MaxIterations.Value;

            if (ScopedSlabOverrides != null && ScopedSlabOverrides.Count > 0)
            {
                var scoped = new JArray();
                foreach (var ov in ScopedSlabOverrides)
                {
                    if (ov == null || !ov.HasScopedFaces) continue;
                    var floorOpts = new JObject();
                    floorOpts["method"] = ov.AnalysisMethod ?? "DDM";
                    floorOpts["deflection_limit"] = ov.DeflectionLimit ?? "L_360";
                    floorOpts["punching_strategy"] = ov.PunchingStrategy ?? "grow_columns";
                    floorOpts["concrete"] = ov.Concrete ?? "NWC_4000";
                    if (ov.VaultLambda.HasValue)
                        floorOpts["vault_lambda"] = ov.VaultLambda.Value;
                    if (ov.TargetEdgeM.HasValue)
                        floorOpts["target_edge_m"] = ov.TargetEdgeM.Value;

                    scoped.Add(new JObject
                    {
                        ["floor_type"] = ov.FloorType ?? "vault",
                        ["floor_options"] = floorOpts,
                        ["faces"] = JToken.FromObject(ov.Faces)
                    });
                }

                if (scoped.Count > 0)
                    obj["scoped_overrides"] = scoped;
            }

            return obj;
        }

        /// <summary>
        /// Apply a partial JSON patch to this instance. Only fields present in the
        /// patch are updated; all others retain their current values. Supports nested
        /// objects (loads, floor_options, materials, foundation_options).
        /// </summary>
        public void MergeFromJson(JObject patch)
        {
            if (patch == null) return;

            if (patch.TryGetValue("unit_system", out var us)) UnitSystem = us.ToString();
            if (patch.TryGetValue("floor_type", out var ft)) FloorType = ft.ToString();
            if (patch.TryGetValue("column_type", out var ct)) ColumnType = ct.ToString();
            if (patch.TryGetValue("column_catalog", out var cc)) ColumnCatalog = cc.ToString();
            if (patch.TryGetValue("column_sizing_strategy", out var css)) ColumnSizingStrategy = css.ToString();
            if (patch.TryGetValue("mip_time_limit_sec", out var mip)) MipTimeLimitSec = mip.Type == JTokenType.Null ? null : (double?)mip;
            if (patch.TryGetValue("beam_type", out var bt)) BeamType = bt.ToString();
            if (patch.TryGetValue("beam_catalog", out var bc)) BeamCatalog = bc.ToString();
            if (patch.TryGetValue("beam_sizing_strategy", out var bss)) BeamSizingStrategy = bss.ToString();
            if (patch.TryGetValue("fire_rating", out var fr)) FireRating = (double)fr;
            if (patch.TryGetValue("optimize_for", out var of)) OptimizeFor = of.ToString();
            if (patch.TryGetValue("max_iterations", out var mi)) MaxIterations = mi.Type == JTokenType.Null ? null : (int?)mi;
            if (patch.TryGetValue("size_foundations", out var sf)) SizeFoundations = (bool)sf;
            if (patch.TryGetValue("foundation_soil", out var fs)) FoundationSoil = fs.ToString();
            if (patch.TryGetValue("foundation_concrete", out var fc)) FoundationConcrete = fc.ToString();

            if (patch.TryGetValue("loads", out var loadsToken) && loadsToken is JObject loads)
            {
                if (loads.TryGetValue("floor_LL_psf", out var fll)) FloorLL = (double)fll;
                if (loads.TryGetValue("roof_LL_psf", out var rll)) RoofLL = (double)rll;
                if (loads.TryGetValue("grade_LL_psf", out var gll)) GradeLL = (double)gll;
                if (loads.TryGetValue("floor_SDL_psf", out var fsdl)) FloorSDL = (double)fsdl;
                if (loads.TryGetValue("roof_SDL_psf", out var rsdl)) RoofSDL = (double)rsdl;
                if (loads.TryGetValue("wall_SDL_psf", out var wsdl)) WallSDL = (double)wsdl;
            }

            if (patch.TryGetValue("floor_options", out var foToken) && foToken is JObject fo)
            {
                if (fo.TryGetValue("method", out var m)) AnalysisMethod = m.ToString();
                if (fo.TryGetValue("deflection_limit", out var dl)) DeflectionLimit = dl.ToString();
                if (fo.TryGetValue("punching_strategy", out var ps)) PunchingStrategy = ps.ToString();
                if (fo.TryGetValue("vault_lambda", out var vl)) VaultLambda = vl.Type == JTokenType.Null ? null : (double?)vl;
                if (fo.TryGetValue("target_edge_m", out var te)) FeaTargetEdgeM = te.Type == JTokenType.Null ? null : (double?)te;
            }

            if (patch.TryGetValue("materials", out var matToken) && matToken is JObject mat)
            {
                if (mat.TryGetValue("concrete", out var c)) Concrete = c.ToString();
                if (mat.TryGetValue("rebar", out var r)) Rebar = r.ToString();
                if (mat.TryGetValue("steel", out var s)) Steel = s.ToString();
            }

            if (patch.TryGetValue("foundation_options", out var fdnToken) && fdnToken is JObject fdn)
            {
                if (fdn.TryGetValue("strategy", out var strat)) FoundationStrategy = strat.ToString();
                if (fdn.TryGetValue("mat_coverage_threshold", out var mct)) MatCoverageThreshold = (double)mct;
            }

            if (patch.TryGetValue("pixelframe_options", out var pfToken) && pfToken is JObject pf)
            {
                if (pf.TryGetValue("fc_preset", out var fcp)) PixelFrameFcPreset = fcp.ToString();
                if (pf.TryGetValue("fc_min_ksi", out var pfmin)) PixelFrameFcMinKsi = pfmin.Type == JTokenType.Null ? null : (double?)pfmin;
                if (pf.TryGetValue("fc_max_ksi", out var pfmax)) PixelFrameFcMaxKsi = pfmax.Type == JTokenType.Null ? null : (double?)pfmax;
                if (pf.TryGetValue("fc_resolution_ksi", out var pfres)) PixelFrameFcResolutionKsi = pfres.Type == JTokenType.Null ? null : (double?)pfres;
            }
        }

        /// <summary>
        /// Compute a SHA-256 hash for change detection.
        /// Streams JSON directly to the hasher to avoid intermediate string allocation.
        /// </summary>
        public string ComputeHash()
        {
            using (var ms = new System.IO.MemoryStream())
            {
                using (var sw = new System.IO.StreamWriter(ms, System.Text.Encoding.UTF8, 4096, leaveOpen: true))
                using (var jw = new Newtonsoft.Json.JsonTextWriter(sw) { Formatting = Newtonsoft.Json.Formatting.None })
                {
                    ToJson().WriteTo(jw);
                }

                ms.Position = 0;
                using (var sha = System.Security.Cryptography.SHA256.Create())
                {
                    var hash = sha.ComputeHash(ms);
                    return BitConverter.ToString(hash).Replace("-", "").ToLowerInvariant();
                }
            }
        }
    }
}
