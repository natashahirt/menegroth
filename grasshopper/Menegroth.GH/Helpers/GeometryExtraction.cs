using System.Collections.Generic;
using Rhino.Geometry;

namespace Menegroth.GH.Helpers
{
    /// <summary>
    /// Shared geometry extraction helpers for converting Rhino geometry to
    /// boundary polylines in [x,y,z] coordinate arrays.
    /// Used by GeometryInput and SlabParams.
    /// </summary>
    public static class GeometryExtraction
    {
        /// <summary>
        /// Get boundary as a closed polyline in [x,y,z] coords. Supports closed curves
        /// (polyline or NURBS) and planar surfaces / single-face Breps.
        /// </summary>
        public static List<double[]> GetBoundaryPolylineCoords(GeometryBase geom)
        {
            if (geom is Curve crv)
                return CurveToPolylineCoords(crv);
            if (geom is Brep brep && brep.Faces.Count == 1)
                return BrepFaceToPolylineCoords(brep.Faces[0]);
            if (geom is Surface srf)
            {
                var brepFromSrf = Brep.CreateFromSurface(srf);
                if (brepFromSrf?.Faces.Count == 1)
                    return BrepFaceToPolylineCoords(brepFromSrf.Faces[0]);
            }
            return null;
        }

        /// <summary>
        /// Extract boundary coordinates from a closed curve.
        /// </summary>
        public static List<double[]> CurveToPolylineCoords(Curve crv)
        {
            if (crv == null || !crv.IsClosed) return null;
            if (crv.TryGetPolyline(out Polyline pl))
            {
                var coords = new List<double[]>();
                for (int i = 0; i < pl.Count - 1; i++)
                    coords.Add(new[] { pl[i].X, pl[i].Y, pl[i].Z });
                return coords;
            }
            const double tol = 1e-6;
            const double angleTol = 0.1;
            var plCurve = crv.ToPolyline(tol, angleTol, 0.001, 1000.0);
            if (plCurve == null || !plCurve.TryGetPolyline(out Polyline plApprox) || plApprox.Count < 4)
                return null;
            var list = new List<double[]>();
            for (int i = 0; i < plApprox.Count - 1; i++)
                list.Add(new[] { plApprox[i].X, plApprox[i].Y, plApprox[i].Z });
            return list;
        }

        /// <summary>
        /// Extract outer loop boundary from a Brep face.
        /// </summary>
        public static List<double[]> BrepFaceToPolylineCoords(BrepFace face)
        {
            var loop = face.OuterLoop;
            if (loop == null) return null;
            var coords = new List<double[]>();
            foreach (var trim in loop.Trims)
            {
                var edge = trim.Edge;
                if (edge?.EdgeCurve == null) return null;
                var edgeCrv = edge.EdgeCurve;
                if (edgeCrv.TryGetPolyline(out Polyline pl))
                {
                    int n = pl.Count - 1;
                    for (int i = 0; i < n; i++)
                        coords.Add(new[] { pl[i].X, pl[i].Y, pl[i].Z });
                }
                else
                {
                    const double tol = 1e-6;
                    const double angleTol = 0.1;
                    var plCurve = edgeCrv.ToPolyline(tol, angleTol, 0.001, 1000.0);
                    if (plCurve == null || !plCurve.TryGetPolyline(out Polyline plApprox)) return null;
                    for (int i = 0; i < plApprox.Count - 1; i++)
                        coords.Add(new[] { plApprox[i].X, plApprox[i].Y, plApprox[i].Z });
                }
            }
            return coords.Count >= 3 ? coords : null;
        }
    }
}
