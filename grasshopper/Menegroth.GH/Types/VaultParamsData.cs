namespace Menegroth.GH.Types
{
    /// <summary>
    /// Override parameters for vault floor design.
    /// </summary>
    public class VaultParamsData
    {
        /// <summary>
        /// Optional vault span/rise ratio (dimensionless). Must be > 0 when set.
        /// </summary>
        public double? Lambda { get; set; } = null;

        /// <summary>
        /// Optional face selector polygons in model coordinates.
        /// Each polygon is an ordered list of [x,y,z] vertices.
        /// </summary>
        public System.Collections.Generic.List<System.Collections.Generic.List<double[]>> Faces { get; set; }
            = new System.Collections.Generic.List<System.Collections.Generic.List<double[]>>();

        /// <summary>
        /// True when this override targets a specific set of faces.
        /// </summary>
        public bool HasScopedFaces => Faces != null && Faces.Count > 0;

        /// <summary>
        /// Apply this override to an existing DesignParamsData instance.
        /// </summary>
        public void ApplyTo(DesignParamsData target)
        {
            if (target == null) return;
            target.FloorType = "vault";
            if (Lambda.HasValue)
                target.VaultLambda = Lambda.Value;
        }

        /// <summary>
        /// Deep-copy helper so scoped overrides are immutable after capture.
        /// </summary>
        public VaultParamsData Clone()
        {
            var copy = new VaultParamsData { Lambda = Lambda };
            foreach (var poly in Faces)
            {
                if (poly == null || poly.Count == 0) continue;
                var polyCopy = new System.Collections.Generic.List<double[]>();
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
