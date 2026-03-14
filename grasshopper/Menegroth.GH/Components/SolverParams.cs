using System;
using System.Collections.Generic;
using System.Linq;
using System.Windows.Forms;
using Grasshopper.Kernel;
using Grasshopper.Kernel.Parameters;
using Grasshopper.Kernel.Types;
using Menegroth.GH.Types;

namespace Menegroth.GH.Components
{
    /// <summary>
    /// Configures beam solver parameters: catalog preset or custom bounds.
    /// When Catalog is "Custom", inputs for MinW, MaxW, MinD, MaxD, Resolution appear.
    /// Wire output to Design Params input "Params" (list) to override beam catalog.
    /// </summary>
    public class SolverParams : GH_Component
    {
        private string _catalog = "large";

        private static readonly (string Label, string Value)[] CatalogChoices =
        {
            ("Standard (light–moderate)", "standard"),
            ("Small (light loads)", "small"),
            ("Large (heavy loads)", "large"),
            ("XLarge (vaults, heavy thrust)", "xlarge"),
            ("All (comprehensive)", "all"),
            ("Custom (bounds + resolution)", "custom"),
        };

        private const int FirstCustomParamIndex = 0;
        private const int CustomParamCount = 5;

        public SolverParams()
            : base("Solver Params",
                   "SolverParams",
                   "Beam catalog: preset or custom bounds for MIP sizing",
                   "Menegroth", "   Input")
        { }

        public override Guid ComponentGuid =>
            new Guid("A1B2C3D4-E5F6-7890-ABCD-EF1234567890");

        protected override void RegisterInputParams(GH_InputParamManager pManager)
        {
            // No base inputs; custom bounds are added dynamically when Catalog = "custom"
        }

        protected override void RegisterOutputParams(GH_OutputParamManager pManager)
        {
            pManager.AddGenericParameter("Params", "Params",
                "Solver params override for Design Params input",
                GH_ParamAccess.item);
        }

        protected override void AppendAdditionalComponentMenuItems(ToolStripDropDown menu)
        {
            base.AppendAdditionalComponentMenuItems(menu);
            Menu_AppendSeparator(menu);

            var catalogSub = new ToolStripMenuItem($"Catalog: {LabelFor(_catalog)}");
            menu.Items.Add(catalogSub);

            foreach (var (label, value) in CatalogChoices)
            {
                var item = new ToolStripMenuItem(label)
                {
                    Checked = _catalog == value,
                    Tag = value
                };
                item.Click += OnCatalogClicked;
                catalogSub.DropDownItems.Add(item);
            }
        }

        private void OnCatalogClicked(object sender, EventArgs e)
        {
            var value = (string)((ToolStripMenuItem)sender).Tag;
            if (_catalog == value) return;

            bool wasCustom = _catalog == "custom";
            bool nowCustom = value == "custom";

            _catalog = value;

            if (wasCustom && !nowCustom)
                RemoveCustomBoundsInputs();
            else if (!wasCustom && nowCustom)
                AddCustomBoundsInputs();

            UpdateMessage();
            ExpireSolution(true);
        }

        private void AddCustomBoundsInputs()
        {
            if (Params.Input.Count >= CustomParamCount) return;

            var names = new[] { "MinW (in)", "MaxW (in)", "MinD (in)", "MaxD (in)", "Resolution (in)" };
            var nicks = new[] { "MinW", "MaxW", "MinD", "MaxD", "Res" };
            var descs = new[]
            {
                "Minimum beam width in inches",
                "Maximum beam width in inches",
                "Minimum beam depth in inches",
                "Maximum beam depth in inches",
                "Step size in inches for width and depth"
            };
            var defaults = new object[] { 12.0, 36.0, 18.0, 48.0, 2.0 };

            for (int i = 0; i < CustomParamCount; i++)
            {
                var p = new Param_Number
                {
                    Name = names[i],
                    NickName = nicks[i],
                    Description = descs[i],
                    Access = GH_ParamAccess.item
                };
                p.SetPersistentData(defaults[i]);
                Params.RegisterInputParam(p, Params.Input.Count);
            }
            Params.OnParametersChanged();
        }

        private void RemoveCustomBoundsInputs()
        {
            while (Params.Input.Count >= CustomParamCount)
            {
                var p = Params.Input[Params.Input.Count - 1];
                Params.UnregisterInputParameter(p);
            }
            Params.OnParametersChanged();
        }

        private static string LabelFor(string value)
        {
            return CatalogChoices.FirstOrDefault(c => c.Value == value).Label ?? value;
        }

        public override bool Write(GH_IO.Serialization.GH_IWriter writer)
        {
            writer.SetString("Catalog", _catalog);
            return base.Write(writer);
        }

        public override bool Read(GH_IO.Serialization.GH_IReader reader)
        {
            if (reader.ItemExists("Catalog"))
                _catalog = reader.GetString("Catalog");
            return base.Read(reader);
        }

        public override void AddedToDocument(GH_Document document)
        {
            base.AddedToDocument(document);
            if (_catalog == "custom" && Params.Input.Count < CustomParamCount)
                AddCustomBoundsInputs();
            UpdateMessage();
        }

        private void UpdateMessage()
        {
            Message = _catalog == "custom"
                ? "Custom bounds"
                : LabelFor(_catalog);
        }

        protected override void SolveInstance(IGH_DataAccess DA)
        {
            var data = new SolverParamsData { Catalog = _catalog };

            if (_catalog == "custom" && Params.Input.Count >= CustomParamCount)
            {
                double minW = 12, maxW = 36, minD = 18, maxD = 48, res = 2;
                DA.GetData(0, ref minW);
                DA.GetData(1, ref maxW);
                DA.GetData(2, ref minD);
                DA.GetData(3, ref maxD);
                DA.GetData(4, ref res);

                data.MinWidthIn = minW;
                data.MaxWidthIn = maxW;
                data.MinDepthIn = minD;
                data.MaxDepthIn = maxD;
                data.ResolutionIn = res;
            }

            DA.SetData(0, new SolverParamsDataGoo(data));
        }
    }
}
