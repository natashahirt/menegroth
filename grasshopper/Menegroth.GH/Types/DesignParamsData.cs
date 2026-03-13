using System;
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

        // Materials
        public string Concrete { get; set; } = "NWC_4000";
        public string Rebar { get; set; } = "Rebar_60";
        public string Steel { get; set; } = "A992";

        // Member types
        public string ColumnType { get; set; } = "rc_rect";
        public string BeamType { get; set; } = "steel_w";

        // Design targets
        public double FireRating { get; set; } = 0;
        public string OptimizeFor { get; set; } = "weight";
        public bool SizeFoundations { get; set; } = false;
        public string FoundationSoil { get; set; } = "medium_sand";
        public string UnitSystem { get; set; } = "imperial";

        /// <summary>
        /// Serialise to a JObject matching the API params schema.
        /// </summary>
        public JObject ToJson()
        {
            return new JObject
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
                ["beam_type"] = BeamType,
                ["fire_rating"] = FireRating,
                ["optimize_for"] = OptimizeFor,
                ["size_foundations"] = SizeFoundations,
                ["foundation_soil"] = FoundationSoil
            };
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
