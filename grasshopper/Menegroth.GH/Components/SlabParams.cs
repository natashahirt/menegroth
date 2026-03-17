using System;
using System.Collections.Generic;
using System.Linq;
using System.Windows.Forms;
using Grasshopper.Kernel;
using Menegroth.GH.Helpers;
using Menegroth.GH.Types;
using Rhino.Geometry;

namespace Menegroth.GH.Components
{
    /// <summary>
    /// Builds face-scoped slab overrides for Design Params.
    /// Replaces Vault Params by supporting floor type + floor options + face geometry.
    /// </summary>
    public class SlabParams : GH_Component
    {
        private string _category = "floor";
        private string _floorType = "vault";
        private string _analysisMethod = "DDM";
        private string _deflectionLimit = "L_360";
        private string _punchingStrategy = "grow_columns";
        private string _concrete = "NWC_4000";

        private static readonly (string Label, string Value)[] CategoryChoices =
        {
            ("Floor", "floor"),
            ("Roof", "roof"),
            ("Grade", "grade"),
        };

        private static readonly (string Label, string Value)[] FloorTypes =
        {
            ("Flat Plate", "flat_plate"),
            ("Flat Slab", "flat_slab"),
            ("One-Way", "one_way"),
            ("Vault", "vault"),
        };

        private static readonly (string Label, string Value)[] Methods =
        {
            ("DDM", "DDM"),
            ("DDM (Simplified)", "DDM_SIMPLIFIED"),
            ("EFM", "EFM"),
            ("EFM (Hardy Cross)", "EFM_HARDY_CROSS"),
            ("FEA", "FEA"),
        };

        private static readonly (string Label, string Value)[] DeflLimits =
        {
            ("L / 240", "L_240"),
            ("L / 360", "L_360"),
            ("L / 480", "L_480"),
        };

        private static readonly (string Label, string Value)[] PunchStrategies =
        {
            ("Grow Columns Only", "grow_columns"),
            ("Grow First -> Reinforce Last", "reinforce_last"),
            ("Reinforce First -> Grow Last", "reinforce_first"),
        };

        private static readonly (string Label, string Value)[] Concretes =
        {
            ("NWC 3000 psi", "NWC_3000"),
            ("NWC 4000 psi", "NWC_4000"),
            ("NWC 5000 psi", "NWC_5000"),
            ("NWC 6000 psi", "NWC_6000"),
            ("Earthen 500 MPa", "Earthen_500"),
            ("Earthen 1000 MPa", "Earthen_1000"),
            ("Earthen 2000 MPa", "Earthen_2000"),
            ("Earthen 4000 MPa", "Earthen_4000"),
            ("Earthen 8000 MPa", "Earthen_8000"),
        };

        public SlabParams()
            : base("Slab Params",
                   "SlabParams",
                   "Face-scoped slab overrides (type/options/category) for Geometry Input + Design Params",
                   "Menegroth", "Component Params")
        { }

        public override Guid ComponentGuid =>
            new Guid("9D5B0162-AD81-4F7E-A2F5-88C29C9A74CA");

        protected override void RegisterInputParams(GH_InputParamManager pManager)
        {
            pManager.AddNumberParameter("Vault Lambda", "Lambda",
                "Vault span/rise ratio (dimensionless). Used when Slab Type is Vault.",
                GH_ParamAccess.item);
            pManager[0].Optional = true;

            pManager.AddNumberParameter("FEA Target Edge (m)", "Edge",
                "Optional FEA mesh target edge length in meters. Used when Analysis Method is FEA.",
                GH_ParamAccess.item);
            pManager[1].Optional = true;

            pManager.AddGeometryParameter("Faces", "Faces",
                "Optional scoped face geometry (planar surfaces or closed curves). " +
                "When omitted, this acts as a global slab override in Design Params.",
                GH_ParamAccess.list);
            pManager[2].Optional = true;
        }

        protected override void RegisterOutputParams(GH_OutputParamManager pManager)
        {
            pManager.AddGenericParameter("Param", "Param",
                "Slab override object for Design Params input 'Params' / 'Slab Params'",
                GH_ParamAccess.item);
        }

        protected override void AppendAdditionalComponentMenuItems(ToolStripDropDown menu)
        {
            base.AppendAdditionalComponentMenuItems(menu);
            Menu_AppendSeparator(menu);

            var categorySub = new ToolStripMenuItem($"Category: {LabelFor(CategoryChoices, _category)}");
            menu.Items.Add(categorySub);
            foreach (var (label, value) in CategoryChoices)
            {
                var item = new ToolStripMenuItem(label)
                {
                    Checked = _category == value,
                    Tag = value
                };
                item.Click += OnCategoryClicked;
                categorySub.DropDownItems.Add(item);
            }

            Menu_AppendSeparator(menu);

            var floorSub = new ToolStripMenuItem($"Slab Type: {LabelFor(FloorTypes, _floorType)}");
            menu.Items.Add(floorSub);
            foreach (var (label, value) in FloorTypes)
            {
                var item = new ToolStripMenuItem(label)
                {
                    Checked = _floorType == value,
                    Tag = ("floor_type", value)
                };
                item.Click += OnChoiceClicked;
                floorSub.DropDownItems.Add(item);
            }

            var methodSub = new ToolStripMenuItem($"Analysis: {LabelFor(Methods, _analysisMethod)}");
            menu.Items.Add(methodSub);
            foreach (var (label, value) in Methods)
            {
                var item = new ToolStripMenuItem(label)
                {
                    Checked = _analysisMethod == value,
                    Tag = ("analysis_method", value)
                };
                item.Click += OnChoiceClicked;
                methodSub.DropDownItems.Add(item);
            }

            var deflSub = new ToolStripMenuItem($"Deflection: {LabelFor(DeflLimits, _deflectionLimit)}");
            menu.Items.Add(deflSub);
            foreach (var (label, value) in DeflLimits)
            {
                var item = new ToolStripMenuItem(label)
                {
                    Checked = _deflectionLimit == value,
                    Tag = ("deflection_limit", value)
                };
                item.Click += OnChoiceClicked;
                deflSub.DropDownItems.Add(item);
            }

            var punchSub = new ToolStripMenuItem($"Punching: {LabelFor(PunchStrategies, _punchingStrategy)}");
            menu.Items.Add(punchSub);
            foreach (var (label, value) in PunchStrategies)
            {
                var item = new ToolStripMenuItem(label)
                {
                    Checked = _punchingStrategy == value,
                    Tag = ("punching_strategy", value)
                };
                item.Click += OnChoiceClicked;
                punchSub.DropDownItems.Add(item);
            }

            var concreteSub = new ToolStripMenuItem($"Concrete: {LabelFor(Concretes, _concrete)}");
            menu.Items.Add(concreteSub);
            foreach (var (label, value) in Concretes)
            {
                var item = new ToolStripMenuItem(label)
                {
                    Checked = _concrete == value,
                    Tag = ("concrete", value)
                };
                item.Click += OnChoiceClicked;
                concreteSub.DropDownItems.Add(item);
            }
        }

        private void OnCategoryClicked(object sender, EventArgs e)
        {
            _category = (string)((ToolStripMenuItem)sender).Tag;
            UpdateMessage();
            ExpireSolution(true);
        }

        private void OnChoiceClicked(object sender, EventArgs e)
        {
            var (field, value) = ((string, string))((ToolStripMenuItem)sender).Tag;
            switch (field)
            {
                case "floor_type": _floorType = value; break;
                case "analysis_method": _analysisMethod = value; break;
                case "deflection_limit": _deflectionLimit = value; break;
                case "punching_strategy": _punchingStrategy = value; break;
                case "concrete": _concrete = value; break;
            }
            UpdateMessage();
            ExpireSolution(true);
        }

        private static string LabelFor((string Label, string Value)[] choices, string value) =>
            choices.FirstOrDefault(c => c.Value == value).Label ?? value;

        public override bool Write(GH_IO.Serialization.GH_IWriter writer)
        {
            writer.SetString("Category", _category);
            writer.SetString("FloorType", _floorType);
            writer.SetString("AnalysisMethod", _analysisMethod);
            writer.SetString("DeflectionLimit", _deflectionLimit);
            writer.SetString("PunchingStrategy", _punchingStrategy);
            writer.SetString("Concrete", _concrete);
            return base.Write(writer);
        }

        public override bool Read(GH_IO.Serialization.GH_IReader reader)
        {
            if (reader.ItemExists("Category"))
                _category = reader.GetString("Category");
            if (reader.ItemExists("FloorType"))
                _floorType = reader.GetString("FloorType");
            if (reader.ItemExists("AnalysisMethod"))
                _analysisMethod = reader.GetString("AnalysisMethod");
            if (reader.ItemExists("DeflectionLimit"))
                _deflectionLimit = reader.GetString("DeflectionLimit");
            if (reader.ItemExists("PunchingStrategy"))
                _punchingStrategy = reader.GetString("PunchingStrategy");
            if (reader.ItemExists("Concrete"))
                _concrete = reader.GetString("Concrete");
            UpdateMessage();
            return base.Read(reader);
        }

        public override void AddedToDocument(GH_Document document)
        {
            base.AddedToDocument(document);
            UpdateMessage();
        }

        private void UpdateMessage()
        {
            Message = $"{LabelFor(CategoryChoices, _category)} | {LabelFor(FloorTypes, _floorType)}";
        }

        protected override void SolveInstance(IGH_DataAccess DA)
        {
            double lambda = 0.0;
            bool hasLambda = DA.GetData(0, ref lambda);
            if (hasLambda && lambda <= 0.0)
            {
                AddRuntimeMessage(GH_RuntimeMessageLevel.Error, "Vault Lambda must be greater than 0.");
                return;
            }

            double edgeM = 0.0;
            bool hasEdge = DA.GetData(1, ref edgeM);
            if (hasEdge && edgeM <= 0.0)
            {
                AddRuntimeMessage(GH_RuntimeMessageLevel.Error, "FEA Target Edge must be greater than 0.");
                return;
            }

            var faceInputs = new List<GeometryBase>();
            DA.GetDataList(2, faceInputs);

            var data = new SlabParamsData
            {
                Category = NormalizeCategory(_category),
                FloorType = NormalizeFloorType(_floorType),
                AnalysisMethod = NormalizeMethod(_analysisMethod),
                DeflectionLimit = NormalizeDeflection(_deflectionLimit),
                PunchingStrategy = NormalizePunching(_punchingStrategy),
                Concrete = NormalizeConcrete(_concrete),
                VaultLambda = hasLambda ? lambda : (double?)null,
                TargetEdgeM = hasEdge ? edgeM : (double?)null
            };

            foreach (var geom in faceInputs)
            {
                if (geom == null) continue;
                var coords = GeometryExtraction.GetBoundaryPolylineCoords(geom);
                if (coords == null || coords.Count < 3) continue;
                data.Faces.Add(coords);
            }

            DA.SetData(0, new SlabParamsDataGoo(data));
        }

        private static string NormalizeCategory(string category)
        {
            var c = (category ?? "floor").Trim().ToLowerInvariant();
            return (c == "roof" || c == "grade") ? c : "floor";
        }

        private static string NormalizeFloorType(string floorType)
        {
            var ft = (floorType ?? "vault").Trim().ToLowerInvariant();
            return ft == "flat_plate" || ft == "flat_slab" || ft == "one_way" || ft == "vault"
                ? ft : "vault";
        }

        private static string NormalizeMethod(string method)
        {
            var m = (method ?? "DDM").Trim().ToUpperInvariant();
            return m == "DDM" || m == "DDM_SIMPLIFIED" || m == "EFM" || m == "EFM_HARDY_CROSS" || m == "FEA"
                ? m : "DDM";
        }

        private static string NormalizeDeflection(string defl)
        {
            var d = (defl ?? "L_360").Trim().ToUpperInvariant();
            return d == "L_240" || d == "L_360" || d == "L_480" ? d : "L_360";
        }

        private static string NormalizePunching(string punching)
        {
            var p = (punching ?? "grow_columns").Trim().ToLowerInvariant();
            return p == "grow_columns" || p == "reinforce_last" || p == "reinforce_first"
                ? p : "grow_columns";
        }

        private static string NormalizeConcrete(string concrete)
        {
            var c = (concrete ?? "NWC_4000").Trim();
            return Concretes.Any(x => x.Value == c) ? c : "NWC_4000";
        }
    }
}
