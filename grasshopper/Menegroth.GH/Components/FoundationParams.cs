using System;
using System.Linq;
using Grasshopper.Kernel;
using Menegroth.GH.Config;
using Menegroth.GH.Types;

namespace Menegroth.GH.Components
{
    /// <summary>
    /// Configures foundation design parameter overrides.
    /// Wire output to Design Params input "Foundation Params" (add via + button).
    /// </summary>
    public class FoundationParams : GH_Component
    {
        private string _soil = "medium_sand";
        private string _concrete = "NWC_3000";
        private string _strategy = "auto";

        private static readonly (string Label, string Value)[] SoilChoices =
        {
            ("Loose Sand (qa=75 kPa)", "loose_sand"),
            ("Medium Sand (qa=150 kPa)", "medium_sand"),
            ("Dense Sand (qa=300 kPa)", "dense_sand"),
            ("Soft Clay (qa=50 kPa)", "soft_clay"),
            ("Stiff Clay (qa=150 kPa)", "stiff_clay"),
            ("Hard Clay (qa=300 kPa)", "hard_clay"),
        };

        private static readonly (string Label, string Value)[] ConcreteChoices =
        {
            ("NWC 3000 psi", "NWC_3000"),
            ("NWC 4000 psi", "NWC_4000"),
            ("NWC 5000 psi", "NWC_5000"),
            ("NWC 6000 psi", "NWC_6000"),
        };

        private static readonly (string Label, string Value)[] StrategyChoices =
        {
            ("Auto (spread → strip → mat by coverage)", "auto"),
            ("All Spread Footings", "all_spread"),
            ("All Strip/Combined", "all_strip"),
            ("Mat Foundation", "mat"),
        };

        public FoundationParams()
            : base("Foundation Params",
                   "FoundationParams",
                   "Foundation design overrides: soil, concrete, strategy",
                   "Menegroth", MenegrothSubcategories.ComponentParameters)
        { }

        public override Guid ComponentGuid =>
            new Guid("B2C3D4E5-F6A7-8901-BCDE-F23456789012");

        protected override void RegisterInputParams(GH_InputParamManager pManager)
        {
            pManager.AddNumberParameter("Mat Coverage Threshold", "MatThresh",
                "Switch to mat when coverage ratio exceeds this (0–1). Optional.",
                GH_ParamAccess.item);
            pManager[0].Optional = true;
        }

        protected override void RegisterOutputParams(GH_OutputParamManager pManager)
        {
            pManager.AddGenericParameter("Params", "Params",
                "Foundation params override for Design Params input 'Foundation Params'",
                GH_ParamAccess.item);
        }

        protected override void AppendAdditionalComponentMenuItems(System.Windows.Forms.ToolStripDropDown menu)
        {
            base.AppendAdditionalComponentMenuItems(menu);
            Menu_AppendSeparator(menu);

            var soilSub = new System.Windows.Forms.ToolStripMenuItem($"Soil: {LabelFor(SoilChoices, _soil)}");
            menu.Items.Add(soilSub);
            foreach (var (label, value) in SoilChoices)
            {
                var item = new System.Windows.Forms.ToolStripMenuItem(label)
                {
                    Checked = _soil == value,
                    Tag = ("soil", value)
                };
                item.Click += OnChoiceClicked;
                soilSub.DropDownItems.Add(item);
            }

            var concSub = new System.Windows.Forms.ToolStripMenuItem($"Concrete: {LabelFor(ConcreteChoices, _concrete)}");
            menu.Items.Add(concSub);
            foreach (var (label, value) in ConcreteChoices)
            {
                var item = new System.Windows.Forms.ToolStripMenuItem(label)
                {
                    Checked = _concrete == value,
                    Tag = ("concrete", value)
                };
                item.Click += OnChoiceClicked;
                concSub.DropDownItems.Add(item);
            }

            var stratSub = new System.Windows.Forms.ToolStripMenuItem($"Strategy: {LabelFor(StrategyChoices, _strategy)}");
            menu.Items.Add(stratSub);
            foreach (var (label, value) in StrategyChoices)
            {
                var item = new System.Windows.Forms.ToolStripMenuItem(label)
                {
                    Checked = _strategy == value,
                    Tag = ("strategy", value)
                };
                item.Click += OnChoiceClicked;
                stratSub.DropDownItems.Add(item);
            }
        }

        private void OnChoiceClicked(object sender, EventArgs e)
        {
            var (field, value) = ((string, string))((System.Windows.Forms.ToolStripMenuItem)sender).Tag;
            switch (field)
            {
                case "soil":     _soil = value; break;
                case "concrete": _concrete = value; break;
                case "strategy": _strategy = value; break;
            }
            UpdateMessage();
            ExpireSolution(true);
        }

        private static string LabelFor((string Label, string Value)[] choices, string value) =>
            choices.FirstOrDefault(c => c.Value == value).Label ?? value;

        public override bool Write(GH_IO.Serialization.GH_IWriter writer)
        {
            writer.SetString("Soil", _soil);
            writer.SetString("Concrete", _concrete);
            writer.SetString("Strategy", _strategy);
            return base.Write(writer);
        }

        public override bool Read(GH_IO.Serialization.GH_IReader reader)
        {
            if (reader.ItemExists("Soil")) _soil = reader.GetString("Soil");
            if (reader.ItemExists("Concrete")) _concrete = reader.GetString("Concrete");
            if (reader.ItemExists("Strategy")) _strategy = reader.GetString("Strategy");
            return base.Read(reader);
        }

        public override void AddedToDocument(GH_Document document)
        {
            base.AddedToDocument(document);
            UpdateMessage();
        }

        private void UpdateMessage()
        {
            Message = $"{LabelFor(SoilChoices, _soil)} | {LabelFor(StrategyChoices, _strategy)}";
        }

        protected override void SolveInstance(IGH_DataAccess DA)
        {
            double matThresh = 0.5;
            bool hasMatThresh = DA.GetData(0, ref matThresh);

            var data = new FoundationParamsData
            {
                Soil = _soil,
                Concrete = _concrete,
                Strategy = _strategy,
                MatCoverageThreshold = hasMatThresh ? (double?)matThresh : null
            };

            DA.SetData(0, new FoundationParamsDataGoo(data));
        }
    }
}
