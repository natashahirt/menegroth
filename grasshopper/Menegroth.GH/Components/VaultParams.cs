using System;
using System.Collections.Generic;
using Grasshopper.Kernel;
using Menegroth.GH.Helpers;
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
                   "Menegroth", "Params")
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
                var coords = GeometryExtraction.GetBoundaryPolylineCoords(geom);
                if (coords == null || coords.Count < 3) continue;
                data.Faces.Add(coords);
            }

            DA.SetData(0, new VaultParamsDataGoo(data));
        }
    }
}
