using System.Collections.Generic;
using System.Linq;
using Menegroth.GH.Types;

namespace Menegroth.GH.Helpers
{
    /// <summary>
    /// Client-side validation for geometry and design parameters.
    /// Mirrors StructuralSynthesizer/src/api/validation.jl so that obvious
    /// errors are caught instantly without a network round-trip.
    /// </summary>
    public static class DesignRunValidator
    {
        private static readonly HashSet<string> ValidFloorTypes =
            new HashSet<string> { "flat_plate", "flat_slab", "one_way", "vault" };
        private static readonly HashSet<string> ValidColumnTypes =
            new HashSet<string> { "rc_rect", "rc_circular", "steel_w", "steel_hss", "steel_pipe" };
        private static readonly HashSet<string> ValidSteelColumnCatalogs =
            new HashSet<string> { "compact_only", "preferred", "all" };
        private static readonly HashSet<string> ValidRCRectColumnCatalogs =
            new HashSet<string> { "standard", "square", "rectangular", "low_capacity", "high_capacity", "all" };
        private static readonly HashSet<string> ValidRCCircularColumnCatalogs =
            new HashSet<string> { "standard", "low_capacity", "high_capacity", "all" };
        private static readonly HashSet<string> ValidBeamTypes =
            new HashSet<string> { "steel_w", "steel_hss", "rc_rect", "rc_tbeam" };
        private static readonly HashSet<string> ValidBeamCatalogs =
            new HashSet<string> { "standard", "small", "large", "xlarge", "all", "custom" };
        private static readonly HashSet<string> ValidConcretes =
            new HashSet<string> { "NWC_3000", "NWC_4000", "NWC_5000", "NWC_6000" };
        private static readonly HashSet<string> ValidRebars =
            new HashSet<string> { "Rebar_40", "Rebar_60", "Rebar_75", "Rebar_80" };
        private static readonly HashSet<string> ValidSteels =
            new HashSet<string> { "A992" };
        private static readonly HashSet<string> ValidSoils =
            new HashSet<string> { "loose_sand", "medium_sand", "dense_sand", "soft_clay", "stiff_clay", "hard_clay" };
        private static readonly HashSet<double> ValidFireRatings =
            new HashSet<double> { 0, 1, 1.5, 2, 3, 4 };
        private static readonly HashSet<string> ValidOptimize =
            new HashSet<string> { "weight", "carbon", "cost" };
        private static readonly HashSet<string> ValidUnitSystems =
            new HashSet<string> { "imperial", "metric" };

        /// <summary>
        /// Validate geometry and design parameters. Returns a list of error messages;
        /// empty list means valid.
        /// </summary>
        public static List<string> Validate(BuildingGeometry geo, DesignParamsData prms)
        {
            var errors = new List<string>();

            // Vertices
            int nVerts = geo.Vertices.Count;
            if (nVerts < 4)
                errors.Add($"Need at least 4 vertices (got {nVerts}).");
            for (int i = 0; i < nVerts; i++)
                if (geo.Vertices[i].Length != 3)
                    errors.Add($"Vertex {i + 1} has {geo.Vertices[i].Length} coordinates (expected 3).");

            // Geometry: at least 2 distinct story elevations (from Z coordinates)
            if (nVerts >= 4)
            {
                var zValues = geo.Vertices.Select(v => v.Length >= 3 ? v[2] : 0.0).Distinct().ToList();
                if (zValues.Count < 2)
                    errors.Add("Need at least 2 distinct Z coordinates to infer stories (got " + zValues.Count + "). " +
                        "Ensure vertices span multiple floor levels.");
            }

            // Faces: each polyline must have at least 3 vertices
            if (geo.Faces != null)
            {
                foreach (var kv in geo.Faces)
                {
                    for (int j = 0; j < kv.Value.Count; j++)
                    {
                        if (kv.Value[j].Count < 3)
                            errors.Add($"Face \"{kv.Key}\"[{j + 1}] has {kv.Value[j].Count} vertices (need ≥ 3).");
                        else
                        {
                            for (int k = 0; k < kv.Value[j].Count; k++)
                            {
                                if (kv.Value[j][k].Length != 3)
                                    errors.Add($"Face \"{kv.Key}\"[{j + 1}] vertex {k + 1} has {kv.Value[j][k].Length} coords (expected 3).");
                            }
                        }
                    }
                }
            }

            // Scoped overrides: if HasScopedFaces, must have at least one face with ≥3 vertices
            if (prms.ScopedVaultOverrides != null)
            {
                for (int i = 0; i < prms.ScopedVaultOverrides.Count; i++)
                {
                    var ov = prms.ScopedVaultOverrides[i];
                    if (ov != null && ov.HasScopedFaces && (ov.Faces == null || ov.Faces.Count == 0))
                        errors.Add($"Scoped override {i + 1} must include at least one face polygon.");
                    else if (ov != null && ov.Faces != null)
                    {
                        for (int j = 0; j < ov.Faces.Count; j++)
                        {
                            if (ov.Faces[j].Count < 3)
                                errors.Add($"Scoped override {i + 1} face {j + 1} has {ov.Faces[j].Count} vertices (need ≥ 3).");
                        }
                    }
                }
            }

            // Edges
            var allEdges = geo.BeamEdges.Concat(geo.ColumnEdges).Concat(geo.StrutEdges).ToList();
            if (allEdges.Count == 0)
                errors.Add("No edges provided (need at least beams, columns, or braces).");
            for (int i = 0; i < allEdges.Count; i++)
            {
                var e = allEdges[i];
                if (e.Length != 2) { errors.Add($"Edge {i + 1} has {e.Length} indices (expected 2)."); continue; }
                if (e[0] < 1 || e[0] > nVerts) errors.Add($"Edge {i + 1}: vertex index {e[0]} out of range [1, {nVerts}].");
                if (e[1] < 1 || e[1] > nVerts) errors.Add($"Edge {i + 1}: vertex index {e[1]} out of range [1, {nVerts}].");
                if (e[0] == e[1]) errors.Add($"Edge {i + 1}: degenerate edge (both indices = {e[0]}).");
            }

            // Supports
            if (geo.Supports.Count == 0)
                errors.Add("No support vertices specified.");
            for (int i = 0; i < geo.Supports.Count; i++)
            {
                int si = geo.Supports[i];
                if (si < 1 || si > nVerts) errors.Add($"Support {i + 1}: vertex index {si} out of range [1, {nVerts}].");
            }

            // Parameters
            if (!ValidFloorTypes.Contains(prms.FloorType))
                errors.Add($"Invalid floor type \"{prms.FloorType}\". Options: {string.Join(", ", ValidFloorTypes)}");
            if (!ValidColumnTypes.Contains(prms.ColumnType))
                errors.Add($"Invalid column type \"{prms.ColumnType}\". Options: {string.Join(", ", ValidColumnTypes)}");
            if (prms.ColumnType == "steel_w" || prms.ColumnType == "steel_hss")
            {
                var steelCat = prms.ColumnCatalog ?? "preferred";
                if (!ValidSteelColumnCatalogs.Contains(steelCat))
                    errors.Add($"Invalid column_catalog for steel \"{prms.ColumnCatalog}\". Options: {string.Join(", ", ValidSteelColumnCatalogs)}");
            }
            else if (prms.ColumnType == "rc_rect")
            {
                var rcCat = prms.ColumnCatalog ?? "standard";
                if (!ValidRCRectColumnCatalogs.Contains(rcCat))
                    errors.Add($"Invalid column_catalog for RC rectangular \"{prms.ColumnCatalog}\". Options: {string.Join(", ", ValidRCRectColumnCatalogs)}");
            }
            else if (prms.ColumnType == "rc_circular")
            {
                var rcCat = prms.ColumnCatalog ?? "standard";
                if (!ValidRCCircularColumnCatalogs.Contains(rcCat))
                    errors.Add($"Invalid column_catalog for RC circular \"{prms.ColumnCatalog}\". Options: {string.Join(", ", ValidRCCircularColumnCatalogs)}");
            }
            if (!ValidBeamTypes.Contains(prms.BeamType))
                errors.Add($"Invalid beam type \"{prms.BeamType}\". Options: {string.Join(", ", ValidBeamTypes)}");
            if (!ValidConcretes.Contains(prms.Concrete))
                errors.Add($"Unknown concrete \"{prms.Concrete}\". Options: {string.Join(", ", ValidConcretes)}");
            if (!ValidRebars.Contains(prms.Rebar))
                errors.Add($"Unknown rebar \"{prms.Rebar}\". Options: {string.Join(", ", ValidRebars)}");
            if (!ValidSteels.Contains(prms.Steel))
                errors.Add($"Unknown steel \"{prms.Steel}\". Options: {string.Join(", ", ValidSteels)}");
            if (!ValidFireRatings.Contains(prms.FireRating))
                errors.Add($"Invalid fire rating {prms.FireRating}. Options: 0, 1, 1.5, 2, 3, 4");
            if (!ValidOptimize.Contains(prms.OptimizeFor))
                errors.Add($"Invalid optimize_for \"{prms.OptimizeFor}\". Options: weight, carbon, cost");
            if (!ValidUnitSystems.Contains(prms.UnitSystem?.ToLowerInvariant() ?? ""))
                errors.Add($"Invalid unit system \"{prms.UnitSystem}\". Options: imperial, metric");
            if (prms.VaultLambda.HasValue && prms.VaultLambda.Value <= 0)
                errors.Add($"Invalid vault_lambda {prms.VaultLambda.Value}. Must be > 0.");

            // Foundation soil (only if foundations requested)
            if (prms.SizeFoundations && !ValidSoils.Contains(prms.FoundationSoil))
                errors.Add($"Unknown foundation soil \"{prms.FoundationSoil}\". Options: {string.Join(", ", ValidSoils)}");

            return errors;
        }
    }
}
