using System;
using System.Collections.Generic;
using Grasshopper.Kernel;
using Menegroth.GH.Types;
using Rhino.Geometry;

namespace Menegroth.GH.Components
{
    /// <summary>
    /// Builds vault-specific design parameter overrides.
    /// </summary>
    public class VaultParams : GH_Component
    {
        public VaultParams()
            : base("Vault Params",
                   "VaultParams",
                   "Configure vault-specific design parameter overrides",
                   "Menegroth", "Design Params")
        { }

        public override Guid ComponentGuid =>
            new Guid("4AB2FA25-2931-40FF-94AD-B85F617E189B");

        protected override void RegisterInputParams(GH_InputParamManager pManager)
        {
            pManager.AddNumberParameter("Lambda", "Lambda",
                "Vault span/rise ratio (dimensionless). Optional; if omitted, backend default is used.",
                GH_ParamAccess.item);
            pManager[0].Optional = true;

            pManager.AddGeometryParameter("Faces", "Faces",
                "Optional face geometry scope (planar surfaces or closed curves). When provided, override applies only to matched faces.",
                GH_ParamAccess.list);
            pManager[1].Optional = true;
        }

        protected override void RegisterOutputParams(GH_OutputParamManager pManager)
        {
            pManager.AddGenericParameter("Param", "Param",
                "Vault parameter override object for Design Params input 'Params'",
                GH_ParamAccess.item);
        }

        protected override void SolveInstance(IGH_DataAccess DA)
        {
            double lambda = 0.0;
            bool hasLambda = DA.GetData(0, ref lambda);
            if (hasLambda && lambda <= 0.0)
            {
                AddRuntimeMessage(GH_RuntimeMessageLevel.Error,
                    "Lambda must be greater than 0.");
                return;
            }

            var faceInputs = new List<GeometryBase>();
            DA.GetDataList(1, faceInputs);

            var data = new VaultParamsData
            {
                Lambda = hasLambda ? lambda : (double?)null
            };

            foreach (var geom in faceInputs)
            {
                if (geom == null) continue;
                var coords = GetBoundaryPolylineCoords(geom);
                if (coords == null || coords.Count < 3) continue;
                data.Faces.Add(coords);
            }

            DA.SetData(0, new GH_VaultParamsData(data));
        }

        /// <summary>
        /// Get boundary as a closed polyline in [x,y,z] coords. Supports closed curves
        /// (polyline or NURBS) and planar surfaces / single-face Breps.
        /// </summary>
        private static List<double[]> GetBoundaryPolylineCoords(GeometryBase geom)
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

        private static List<double[]> CurveToPolylineCoords(Curve crv)
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

        private static List<double[]> BrepFaceToPolylineCoords(BrepFace face)
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
