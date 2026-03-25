using System;
using System.Linq;
using System.Text;
using System.Windows.Forms;
using Grasshopper.Kernel;
using Menegroth.GH.Config;
using Menegroth.GH.Types;

namespace Menegroth.GH.Components
{
    /// <summary>
    /// Lightweight design-parameter component focused on analysis runtime controls.
    /// Outputs the same DesignParamsData type consumed by DesignRun.
    /// </summary>
    public class AnalysisParams : GH_Component
    {
        private string _floorType = "flat_plate";
        private string _analysisMethod = "DDM";
        private string _deflectionLimit = "L_360";
        private string _punchingStrategy = "grow_columns";

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

        public AnalysisParams()
            : base("Analysis Params",
                   "AnalysisParams",
                   "Analysis-focused design parameters for Design Run (iterations + mesh controls)",
                   "Menegroth", MenegrothSubcategories.Inputs)
        { }

        public override Guid ComponentGuid =>
            new Guid("A1BE4B33-6E28-4F11-BF4D-2B2D3A4B3C98");

        protected override void RegisterInputParams(GH_InputParamManager pManager)
        {
            pManager.AddIntegerParameter("Max Iterations", "Iter",
                "Maximum beam/column sizing iterations (must be >= 1).", GH_ParamAccess.item, 20);

            pManager.AddNumberParameter("FEA Target Edge (m)", "FEA Edge",
                "Optional FEA mesh target edge length in meters. Used when Analysis Method is FEA.",
                GH_ParamAccess.item);
            pManager[1].Optional = true;
        }

        protected override void RegisterOutputParams(GH_OutputParamManager pManager)
        {
            pManager.AddGenericParameter("Params", "Params",
                "DesignParams object for the Design Run component",
                GH_ParamAccess.item);

            pManager.AddTextParameter("Summary", "Summary",
                "Human-readable summary for debugging",
                GH_ParamAccess.item);
        }

        protected override void AppendAdditionalComponentMenuItems(ToolStripDropDown menu)
        {
            base.AppendAdditionalComponentMenuItems(menu);
            Menu_AppendSeparator(menu);

            var floorSub = new ToolStripMenuItem($"Floor Type: {LabelFor(FloorTypes, _floorType)}");
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
            }

            UpdateMessage();
            ExpireSolution(true);
        }

        public override bool Write(GH_IO.Serialization.GH_IWriter writer)
        {
            writer.SetString("FloorType", _floorType);
            writer.SetString("AnalysisMethod", _analysisMethod);
            writer.SetString("DeflectionLimit", _deflectionLimit);
            writer.SetString("PunchingStrategy", _punchingStrategy);
            return base.Write(writer);
        }

        public override bool Read(GH_IO.Serialization.GH_IReader reader)
        {
            if (reader.ItemExists("FloorType"))
                _floorType = reader.GetString("FloorType");
            if (reader.ItemExists("AnalysisMethod"))
                _analysisMethod = reader.GetString("AnalysisMethod");
            if (reader.ItemExists("DeflectionLimit"))
                _deflectionLimit = reader.GetString("DeflectionLimit");
            if (reader.ItemExists("PunchingStrategy"))
                _punchingStrategy = reader.GetString("PunchingStrategy");
            UpdateMessage();
            return base.Read(reader);
        }

        public override void AddedToDocument(GH_Document document)
        {
            base.AddedToDocument(document);
            UpdateMessage();
        }

        protected override void SolveInstance(IGH_DataAccess DA)
        {
            int maxIterations = 20;
            if (!DA.GetData(0, ref maxIterations)) return;
            if (maxIterations < 1)
            {
                AddRuntimeMessage(GH_RuntimeMessageLevel.Error, "Max Iterations must be at least 1.");
                return;
            }

            double feaEdge = 0.0;
            bool hasFeaEdge = DA.GetData(1, ref feaEdge);
            if (hasFeaEdge && feaEdge <= 0.0)
            {
                AddRuntimeMessage(GH_RuntimeMessageLevel.Error, "FEA Target Edge must be greater than 0.");
                return;
            }

            var p = new DesignParamsData
            {
                FloorType = NormalizeFloorType(_floorType),
                AnalysisMethod = NormalizeMethod(_analysisMethod),
                DeflectionLimit = NormalizeDeflection(_deflectionLimit),
                PunchingStrategy = NormalizePunching(_punchingStrategy),
                MaxIterations = maxIterations,
                FeaTargetEdgeM = hasFeaEdge ? feaEdge : (double?)null,
            };

            DA.SetData(0, new DesignParamsDataGoo(p));
            DA.SetData(1, BuildSummary(p));
        }

        private void UpdateMessage()
        {
            Message = $"{LabelFor(Methods, _analysisMethod)} | {LabelFor(FloorTypes, _floorType)}";
        }

        private static string LabelFor((string Label, string Value)[] choices, string value) =>
            choices.FirstOrDefault(c => c.Value == value).Label ?? value;

        private static string NormalizeFloorType(string floorType)
        {
            var ft = (floorType ?? "flat_plate").Trim().ToLowerInvariant();
            return ft == "flat_plate" || ft == "flat_slab" || ft == "one_way" || ft == "vault"
                ? ft : "flat_plate";
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

        private static string BuildSummary(DesignParamsData p)
        {
            var sb = new StringBuilder();
            sb.AppendLine("Analysis Parameters Summary");
            sb.AppendLine("──────────────────────────");
            sb.Append("Floor Type: ").Append(p.FloorType).AppendLine();
            sb.Append("Analysis Method: ").Append(p.AnalysisMethod).AppendLine();
            sb.Append("Deflection Limit: ").Append(p.DeflectionLimit).AppendLine();
            sb.Append("Punching Strategy: ").Append(p.PunchingStrategy).AppendLine();
            sb.Append("Max Iterations: ").Append(p.MaxIterations?.ToString() ?? "default").AppendLine();
            sb.Append("FEA Target Edge (m): ").Append(p.FeaTargetEdgeM?.ToString("F3") ?? "default");
            return sb.ToString();
        }
    }
}
