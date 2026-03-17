using System.Collections.Generic;

namespace Menegroth.GH.Types
{
    /// <summary>
    /// Face-scoped slab override data used by both Geometry Input and Design Params.
    /// </summary>
    public class SlabParamsData
    {
        // Geometry face grouping category (used by Geometry Input).
        public string Category { get; set; } = "floor";

        // Scoped slab override fields (used by Design Params -> scoped_overrides).
        public string FloorType { get; set; } = "vault";
        public string AnalysisMethod { get; set; } = "DDM";
        public string DeflectionLimit { get; set; } = "L_360";
        public string PunchingStrategy { get; set; } = "grow_columns";
        public string Concrete { get; set; } = "NWC_4000";
        public double? VaultLambda { get; set; } = null;
        public double? TargetEdgeM { get; set; } = null;

        /// <summary>
        /// Optional face selector polygons in model coordinates.
        /// Each polygon is an ordered list of [x,y,z] vertices.
        /// </summary>
        public List<List<double[]>> Faces { get; set; } = new List<List<double[]>>();

        public bool HasScopedFaces => Faces != null && Faces.Count > 0;

        /// <summary>
        /// Apply as a global (non-scoped) slab override.
        /// </summary>
        public void ApplyTo(DesignParamsData target)
        {
            if (target == null) return;
            target.FloorType = FloorType;
            target.AnalysisMethod = AnalysisMethod;
            target.DeflectionLimit = DeflectionLimit;
            target.PunchingStrategy = PunchingStrategy;
            target.Concrete = Concrete;
            if (VaultLambda.HasValue)
                target.VaultLambda = VaultLambda.Value;
        }

        public SlabParamsData Clone()
        {
            var copy = new SlabParamsData
            {
                Category = Category,
                FloorType = FloorType,
                AnalysisMethod = AnalysisMethod,
                DeflectionLimit = DeflectionLimit,
                PunchingStrategy = PunchingStrategy,
                Concrete = Concrete,
                VaultLambda = VaultLambda,
                TargetEdgeM = TargetEdgeM
            };
            foreach (var poly in Faces)
            {
                if (poly == null || poly.Count == 0) continue;
                var polyCopy = new List<double[]>();
                foreach (var p in poly)
                {
                    if (p == null || p.Length < 3) continue;
                    polyCopy.Add(new[] { p[0], p[1], p[2] });
                }
                if (polyCopy.Count > 0)
                    copy.Faces.Add(polyCopy);
            }
            return copy;
        }
    }
}
