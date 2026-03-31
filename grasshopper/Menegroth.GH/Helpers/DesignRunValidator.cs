using System.Collections.Generic;
using System.Linq;
using Menegroth.GH.Components;
using Menegroth.GH.Types;
using V = Menegroth.GH.Components.DesignParams.ValidValues;

namespace Menegroth.GH.Helpers
{
    /// <summary>
    /// Client-side validation for geometry and design parameters.
    /// Mirrors StructuralSynthesizer/src/api/validation.jl so that obvious
    /// errors are caught instantly without a network round-trip.
    ///
    /// String-based valid-value sets are derived from the Choice arrays in
    /// <see cref="DesignParams.ValidValues"/> so adding a new option in one
    /// place automatically makes it valid here.
    /// </summary>
    public static class DesignRunValidator
    {
        private static readonly HashSet<double> ValidFireRatings =
            new HashSet<double> { 0, 1, 1.5, 2, 3, 4 };

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
            if (prms.ScopedSlabOverrides != null)
            {
                for (int i = 0; i < prms.ScopedSlabOverrides.Count; i++)
                {
                    var ov = prms.ScopedSlabOverrides[i];
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
                    if (ov != null)
                    {
                        if (!V.FloorTypes.Contains((ov.FloorType ?? "").ToLowerInvariant()))
                            errors.Add($"Scoped override {i + 1}: invalid floor type \"{ov.FloorType}\".");
                        if (!V.Methods.Contains((ov.AnalysisMethod ?? "").ToUpperInvariant()))
                            errors.Add($"Scoped override {i + 1}: invalid analysis method \"{ov.AnalysisMethod}\".");
                        if (!V.DeflectionLimits.Contains((ov.DeflectionLimit ?? "").ToUpperInvariant()))
                            errors.Add($"Scoped override {i + 1}: invalid deflection limit \"{ov.DeflectionLimit}\".");
                        if (!V.PunchStrategies.Contains((ov.PunchingStrategy ?? "").ToLowerInvariant()))
                            errors.Add($"Scoped override {i + 1}: invalid punching strategy \"{ov.PunchingStrategy}\".");
                        if (!V.Concretes.Contains(ov.Concrete ?? ""))
                            errors.Add($"Scoped override {i + 1}: invalid concrete \"{ov.Concrete}\".");
                        if (ov.VaultLambda.HasValue && ov.VaultLambda.Value <= 0)
                            errors.Add($"Scoped override {i + 1}: vault lambda must be > 0.");
                        if (ov.TargetEdgeM.HasValue && ov.TargetEdgeM.Value <= 0)
                            errors.Add($"Scoped override {i + 1}: FEA target edge must be > 0.");
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

            // Parameters -- valid-value sets come from DesignParams.ValidValues (single source of truth)
            if (!V.FloorTypes.Contains(prms.FloorType))
                errors.Add($"Invalid floor type \"{prms.FloorType}\". Options: {string.Join(", ", V.FloorTypes)}");
            if (!V.ColumnTypes.Contains(prms.ColumnType))
                errors.Add($"Invalid column type \"{prms.ColumnType}\". Options: {string.Join(", ", V.ColumnTypes)}");

            // Floor + column compatibility (mirrors DesignParams.ValidateDesignParams and API validation.jl)
            // Flat plate/slab accept RC (rectangular, circular) only; steel and PixelFrame not supported (punching shear assumes RC).
            var beamlessFloors = new[] { "flat_plate", "flat_slab" };
            var unsupportedBeamlessColumns = new[] { "steel_w", "steel_hss", "steel_pipe", "pixelframe" };
            var floor = (prms.FloorType ?? "").ToLowerInvariant();
            var colType = (prms.ColumnType ?? "").ToLowerInvariant();
            if (beamlessFloors.Contains(floor) && unsupportedBeamlessColumns.Contains(colType))
            {
                errors.Add($"floor_type \"{floor}\" requires reinforced concrete columns. " +
                    $"column_type \"{colType}\" is not supported for beamless slab systems.");
            }

            switch (prms.ColumnType)
            {
                case "steel_w":
                case "steel_hss":
                {
                    var steelCat = prms.ColumnCatalog ?? "preferred";
                    if (!V.SteelColumnCatalogs.Contains(steelCat))
                        errors.Add($"Invalid column_catalog for steel \"{prms.ColumnCatalog}\". Options: {string.Join(", ", V.SteelColumnCatalogs)}");
                    break;
                }
                case "rc_rect":
                {
                    var rcCat = prms.ColumnCatalog ?? "standard";
                    if (!V.RCRectColumnCatalogs.Contains(rcCat))
                        errors.Add($"Invalid column_catalog for RC rectangular \"{prms.ColumnCatalog}\". Options: {string.Join(", ", V.RCRectColumnCatalogs)}");
                    break;
                }
                case "rc_circular":
                {
                    var rcCat = prms.ColumnCatalog ?? "standard";
                    if (!V.RCCircularColumnCatalogs.Contains(rcCat))
                        errors.Add($"Invalid column_catalog for RC circular \"{prms.ColumnCatalog}\". Options: {string.Join(", ", V.RCCircularColumnCatalogs)}");
                    break;
                }
                // steel_pipe, pixelframe: no catalog validation needed
            }
            if (!V.BeamTypes.Contains(prms.BeamType))
                errors.Add($"Invalid beam type \"{prms.BeamType}\". Options: {string.Join(", ", V.BeamTypes)}");
            if (!V.Concretes.Contains(prms.Concrete))
                errors.Add($"Unknown concrete \"{prms.Concrete}\". Options: {string.Join(", ", V.Concretes)}");
            if (!V.Rebars.Contains(prms.Rebar))
                errors.Add($"Unknown rebar \"{prms.Rebar}\". Options: {string.Join(", ", V.Rebars)}");
            if (!V.Steels.Contains(prms.Steel))
                errors.Add($"Unknown steel \"{prms.Steel}\". Options: {string.Join(", ", V.Steels)}");
            if (!ValidFireRatings.Contains(prms.FireRating))
                errors.Add($"Invalid fire rating {prms.FireRating}. Options: 0, 1, 1.5, 2, 3, 4");
            if (!V.Objectives.Contains(prms.OptimizeFor))
                errors.Add($"Invalid optimize_for \"{prms.OptimizeFor}\". Options: weight, carbon, cost");

            var ucs = (prms.UniformColumnSizing ?? "off").ToLowerInvariant();
            if (!V.UniformColumnSizingModes.Contains(ucs))
                errors.Add($"Invalid uniform_column_sizing \"{prms.UniformColumnSizing}\". Options: off, per_story, building");
            if (ucs != "off" && colType == "pixelframe")
                errors.Add($"uniform_column_sizing \"{prms.UniformColumnSizing}\" is not supported with pixelframe columns.");

            if (!V.UnitSystems.Contains(prms.UnitSystem?.ToLowerInvariant() ?? ""))
                errors.Add($"Invalid unit system \"{prms.UnitSystem}\". Options: imperial, metric");
            if (prms.VaultLambda.HasValue && prms.VaultLambda.Value <= 0)
                errors.Add($"Invalid vault_lambda {prms.VaultLambda.Value}. Must be > 0.");

            // Foundation soil (only if foundations requested)
            if (prms.SizeFoundations && !V.SoilTypes.Contains(prms.FoundationSoil))
                errors.Add($"Unknown foundation soil \"{prms.FoundationSoil}\". Options: {string.Join(", ", V.SoilTypes)}");

            return errors;
        }
    }
}
