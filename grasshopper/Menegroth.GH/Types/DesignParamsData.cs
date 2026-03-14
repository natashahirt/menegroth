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
        public double RoofLL { get; set; } = 20;
        public double GradeLL { get; set; } = 100;
        public double FloorSDL { get; set; } = 15;
        public double RoofSDL { get; set; } = 15;
        public double WallSDL { get; set; } = 10;

        // Floor system
        public string FloorType { get; set; } = "flat_plate";
        public string AnalysisMethod { get; set; } = "DDM";
        public string DeflectionLimit { get; set; } = "L_360";
        public string PunchingStrategy { get; set; } = "grow_columns";
        public double? VaultLambda { get; set; } = null;

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
        public string BeamType { get; set; } = "steel_w";
        /// <summary>RC beam catalog when BeamType is rc_rect or rc_tbeam: standard, small, large, xlarge, all, custom. Default: large.</summary>
        public string BeamCatalog { get; set; } = "large";
        /// <summary>RC beams only: discrete (MIP) or nlp (continuous).</summary>
        public string BeamSizingStrategy { get; set; } = "discrete";
        /// <summary>Bounds for custom catalog (required when BeamCatalog is custom).</summary>
        public BeamCatalogBoundsData BeamCatalogBounds { get; set; } = null;

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
        public List<VaultParamsData> ScopedVaultOverrides { get; set; } = new List<VaultParamsData>();

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
                ["beam_type"] = BeamType,
                ["beam_catalog"] = BeamCatalog,
                ["beam_sizing_strategy"] = BeamSizingStrategy ?? "discrete",
                ["beam_catalog_bounds"] = BeamCatalogBounds != null
                    ? (JToken)new JObject
                    {
                        ["min_width_in"] = BeamCatalogBounds.MinWidthIn,
                        ["max_width_in"] = BeamCatalogBounds.MaxWidthIn,
                        ["min_depth_in"] = BeamCatalogBounds.MinDepthIn,
                        ["max_depth_in"] = BeamCatalogBounds.MaxDepthIn,
                        ["resolution_in"] = BeamCatalogBounds.ResolutionIn
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

            if (ScopedVaultOverrides != null && ScopedVaultOverrides.Count > 0)
            {
                var scoped = new JArray();
                foreach (var ov in ScopedVaultOverrides)
                {
                    if (ov == null || !ov.HasScopedFaces) continue;
                    var floorOpts = new JObject();
                    if (ov.Lambda.HasValue)
                        floorOpts["vault_lambda"] = ov.Lambda.Value;

                    scoped.Add(new JObject
                    {
                        ["floor_type"] = "vault",
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
        /// Compute a hash for change detection.
        /// </summary>
        public string ComputeHash()
        {
            var json = ToJson().ToString(Newtonsoft.Json.Formatting.None);
            using (var sha = System.Security.Cryptography.SHA256.Create())
            {
                var bytes = System.Text.Encoding.UTF8.GetBytes(json);
                var hash = sha.ComputeHash(bytes);
                return BitConverter.ToString(hash).Replace("-", "").ToLowerInvariant();
            }
        }
    }
}
