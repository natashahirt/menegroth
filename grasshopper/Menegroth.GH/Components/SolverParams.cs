using System;
using System.Collections.Generic;
using System.Linq;
using System.Windows.Forms;
using Grasshopper.Kernel;
using Grasshopper.Kernel.Parameters;
using Menegroth.GH.Types;

namespace Menegroth.GH.Components
{
    /// <summary>
    /// Configures solver parameters: MIP/NLP, section (beam/column), and catalog choices.
    /// Wire output to Design Params input "Params" to override beam or column catalog.
    /// </summary>
    public class SolverParams : GH_Component
    {
        private string _solverType = "nlp";
        private string _section = "column";
        private string _beamType = "rc_rect";
        private string _catalog = "large";
        private string _columnType = "steel_w";
        private string _columnCatalog = "preferred";
        private string _pixelFrameFcPreset = "standard";

        private static readonly (string L, string V)[] SolverChoices =
        {
            ("MIP (discrete catalog)", "mip"),
            ("NLP (continuous)", "nlp"),
        };

        private static readonly (string L, string V)[] SectionChoices =
        {
            ("Beam", "beam"),
            ("Column", "column"),
        };

        private static readonly (string L, string V)[] BeamTypeChoices =
        {
            ("RC Rectangular", "rc_rect"),
            ("RC T-beam", "rc_tbeam"),
            ("PixelFrame", "pixelframe"),
        };

        private static readonly (string L, string V)[] BeamCatalogChoices =
        {
            ("Standard (light–moderate)", "standard"),
            ("Small (light loads)", "small"),
            ("Large (heavy loads)", "large"),
            ("XLarge (vaults, heavy thrust)", "xlarge"),
            ("All (comprehensive)", "all"),
            ("Custom (bounds + resolution)", "custom"),
        };

        private static readonly (string L, string V)[] SteelColumnCatalogChoices =
        {
            ("Compact only", "compact_only"),
            ("Preferred", "preferred"),
            ("All", "all"),
        };

        private static readonly (string L, string V)[] RCRectColumnCatalogChoices =
        {
            ("Standard (square)", "standard"),
            ("Square only", "square"),
            ("Rectangular", "rectangular"),
            ("Low capacity", "low_capacity"),
            ("High capacity", "high_capacity"),
            ("All", "all"),
        };

        private static readonly (string L, string V)[] RCCircularColumnCatalogChoices =
        {
            ("Standard", "standard"),
            ("Low capacity", "low_capacity"),
            ("High capacity", "high_capacity"),
            ("All", "all"),
        };

        private static readonly (string L, string V)[] ColumnTypeChoices =
        {
            ("Steel W-shape", "steel_w"),
            ("Steel HSS", "steel_hss"),
            ("RC Rectangular", "rc_rect"),
            ("RC Circular", "rc_circular"),
            ("PixelFrame", "pixelframe"),
        };

        private static readonly (string L, string V)[] PixelFrameFcPresetChoices =
        {
            ("Standard (4–8 ksi)", "standard"),
            ("Low (3–5 ksi)", "low"),
            ("High (6–10 ksi)", "high"),
            ("Extended (4–14 ksi)", "extended"),
            ("Custom (min/max/resolution)", "custom"),
        };

        private const int CustomParamCount = 5;
        private const int PixelFrameCustomParamCount = 3;  // MinKsi, MaxKsi, ResolutionKsi

        public SolverParams()
            : base("Solver Params",
                   "SolverParams",
                   "MIP/NLP solver and catalog for beam or column sizing",
                   "Menegroth", "Params")
        { }

        public override Guid ComponentGuid =>
            new Guid("A1B2C3D4-E5F6-7890-ABCD-EF1234567890");

        protected override void RegisterInputParams(GH_InputParamManager pManager)
        {
            // Custom bounds added dynamically when Section=beam and Catalog=custom
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

            // Solver: MIP | NLP
            var solverSub = new ToolStripMenuItem($"Solver: {LabelFor(SolverChoices, _solverType)}");
            menu.Items.Add(solverSub);
            foreach (var (label, value) in SolverChoices)
            {
                var item = new ToolStripMenuItem(label) { Checked = _solverType == value, Tag = ("solver", value) };
                item.Click += OnChoiceClicked;
                solverSub.DropDownItems.Add(item);
            }

            // Section: Beam | Column
            var sectionSub = new ToolStripMenuItem($"Section: {LabelFor(SectionChoices, _section)}");
            menu.Items.Add(sectionSub);
            foreach (var (label, value) in SectionChoices)
            {
                var item = new ToolStripMenuItem(label) { Checked = _section == value, Tag = ("section", value) };
                item.Click += OnChoiceClicked;
                sectionSub.DropDownItems.Add(item);
            }

            Menu_AppendSeparator(menu);

            if (_section == "beam")
            {
                // Beam Type
                var beamTypeSub = new ToolStripMenuItem($"Beam Type: {LabelFor(BeamTypeChoices, _beamType)}");
                menu.Items.Add(beamTypeSub);
                foreach (var (label, value) in BeamTypeChoices)
                {
                    var item = new ToolStripMenuItem(label) { Checked = _beamType == value, Tag = ("beamType", value) };
                    item.Click += OnChoiceClicked;
                    beamTypeSub.DropDownItems.Add(item);
                }

                // Beam Catalog or PixelFrame Fc Preset
                if (_beamType == "pixelframe")
                {
                    var fcSub = new ToolStripMenuItem($"Fc Preset: {LabelFor(PixelFrameFcPresetChoices, _pixelFrameFcPreset)}");
                    menu.Items.Add(fcSub);
                    foreach (var (label, value) in PixelFrameFcPresetChoices)
                    {
                        var item = new ToolStripMenuItem(label) { Checked = _pixelFrameFcPreset == value, Tag = ("pixelFrameFcPreset", value) };
                        item.Click += OnChoiceClicked;
                        fcSub.DropDownItems.Add(item);
                    }
                }
                else
                {
                    var catalogSub = new ToolStripMenuItem($"Catalog: {LabelFor(BeamCatalogChoices, _catalog)}");
                    menu.Items.Add(catalogSub);
                    foreach (var (label, value) in BeamCatalogChoices)
                    {
                        var item = new ToolStripMenuItem(label) { Checked = _catalog == value, Tag = ("catalog", value) };
                        item.Click += OnChoiceClicked;
                        catalogSub.DropDownItems.Add(item);
                    }
                }
            }
            else
            {
                // Column Type
                var colTypeSub = new ToolStripMenuItem($"Column Type: {LabelFor(ColumnTypeChoices, _columnType)}");
                menu.Items.Add(colTypeSub);
                foreach (var (label, value) in ColumnTypeChoices)
                {
                    var item = new ToolStripMenuItem(label) { Checked = _columnType == value, Tag = ("columnType", value) };
                    item.Click += OnChoiceClicked;
                    colTypeSub.DropDownItems.Add(item);
                }

                // Column Catalog or PixelFrame Fc Preset
                if (_columnType == "pixelframe")
                {
                    var fcSub = new ToolStripMenuItem($"Fc Preset: {LabelFor(PixelFrameFcPresetChoices, _pixelFrameFcPreset)}");
                    menu.Items.Add(fcSub);
                    foreach (var (label, value) in PixelFrameFcPresetChoices)
                    {
                        var item = new ToolStripMenuItem(label) { Checked = _pixelFrameFcPreset == value, Tag = ("pixelFrameFcPreset", value) };
                        item.Click += OnChoiceClicked;
                        fcSub.DropDownItems.Add(item);
                    }
                }
                else
                {
                    var colCatalogChoices = GetColumnCatalogChoices(_columnType);
                    var colCatalogSub = new ToolStripMenuItem($"Catalog: {LabelFor(colCatalogChoices, _columnCatalog)}");
                    menu.Items.Add(colCatalogSub);
                    foreach (var (label, value) in colCatalogChoices)
                    {
                        var item = new ToolStripMenuItem(label) { Checked = _columnCatalog == value, Tag = ("columnCatalog", value) };
                        item.Click += OnChoiceClicked;
                        colCatalogSub.DropDownItems.Add(item);
                    }
                }
            }
        }

        private static (string L, string V)[] GetColumnCatalogChoices(string columnType)
        {
            if (columnType == "pixelframe")
                return Array.Empty<(string, string)>();  // Fc Preset shown instead
            if (columnType == "steel_w" || columnType == "steel_hss")
                return SteelColumnCatalogChoices;
            if (columnType == "rc_rect")
                return RCRectColumnCatalogChoices;
            if (columnType == "rc_circular")
                return RCCircularColumnCatalogChoices;
            return RCRectColumnCatalogChoices;
        }

        private void OnChoiceClicked(object sender, EventArgs e)
        {
            var (field, value) = ((string, string))((ToolStripMenuItem)sender).Tag;

            bool wasBeamCustom = _catalog == "custom" && _section == "beam" && _beamType != "pixelframe";
            bool wasPixelFrameCustom = _pixelFrameFcPreset == "custom" && (_beamType == "pixelframe" || _columnType == "pixelframe");
            bool sectionChanged = field == "section";

            switch (field)
            {
                case "solver": _solverType = value; break;
                case "section": _section = value; break;
                case "beamType": _beamType = value; break;
                case "catalog": _catalog = value; break;
                case "pixelFrameFcPreset": _pixelFrameFcPreset = value; break;
                case "columnType":
                    _columnType = value;
                    var colChoices = GetColumnCatalogChoices(value);
                    if (colChoices.Length > 0)
                        _columnCatalog = colChoices[0].V;
                    break;
                case "columnCatalog": _columnCatalog = value; break;
            }

            bool nowBeamCustom = _catalog == "custom" && _section == "beam" && _beamType != "pixelframe";
            bool nowPixelFrameCustom = _pixelFrameFcPreset == "custom" && (_beamType == "pixelframe" || _columnType == "pixelframe");

            if (wasBeamCustom && !nowBeamCustom)
                RemoveCustomBoundsInputs();
            else if (!wasBeamCustom && nowBeamCustom)
                AddCustomBoundsInputs();
            else if (wasPixelFrameCustom && !nowPixelFrameCustom)
                RemovePixelFrameCustomInputs();
            else if (!wasPixelFrameCustom && nowPixelFrameCustom)
                AddPixelFrameCustomInputs();
            else if (sectionChanged)
            {
                RemoveCustomBoundsInputs();
                RemovePixelFrameCustomInputs();
                if (_section == "beam" && _catalog == "custom" && _beamType != "pixelframe")
                    AddCustomBoundsInputs();
                else if (_section == "beam" && _beamType == "pixelframe" && _pixelFrameFcPreset == "custom")
                    AddPixelFrameCustomInputs();
                else if (_section == "column" && _columnType == "pixelframe" && _pixelFrameFcPreset == "custom")
                    AddPixelFrameCustomInputs();
            }

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

        private void AddPixelFrameCustomInputs()
        {
            if (Params.Input.Count >= PixelFrameCustomParamCount) return;

            var names = new[] { "Min fc (ksi)", "Max fc (ksi)", "Resolution (ksi)" };
            var nicks = new[] { "MinKsi", "MaxKsi", "ResKsi" };
            var descs = new[]
            {
                "Minimum concrete strength in ksi",
                "Maximum concrete strength in ksi",
                "Step size in ksi for strength sweep"
            };
            var defaults = new object[] { 4.0, 8.0, 1.0 };

            for (int i = 0; i < PixelFrameCustomParamCount; i++)
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

        private void RemovePixelFrameCustomInputs()
        {
            while (Params.Input.Count >= PixelFrameCustomParamCount)
            {
                var p = Params.Input[Params.Input.Count - 1];
                Params.UnregisterInputParameter(p);
            }
            Params.OnParametersChanged();
        }

        private static string LabelFor((string L, string V)[] choices, string value) =>
            choices.FirstOrDefault(c => c.V == value).L ?? value;

        public override bool Write(GH_IO.Serialization.GH_IWriter writer)
        {
            writer.SetString("SolverType", _solverType);
            writer.SetString("Section", _section);
            writer.SetString("BeamType", _beamType);
            writer.SetString("Catalog", _catalog);
            writer.SetString("ColumnType", _columnType);
            writer.SetString("ColumnCatalog", _columnCatalog);
            writer.SetString("PixelFrameFcPreset", _pixelFrameFcPreset);
            return base.Write(writer);
        }

        public override bool Read(GH_IO.Serialization.GH_IReader reader)
        {
            if (reader.ItemExists("SolverType")) _solverType = reader.GetString("SolverType");
            if (reader.ItemExists("Section")) _section = reader.GetString("Section");
            if (reader.ItemExists("BeamType")) _beamType = reader.GetString("BeamType");
            if (reader.ItemExists("Catalog")) _catalog = reader.GetString("Catalog");
            if (reader.ItemExists("ColumnType")) _columnType = reader.GetString("ColumnType");
            if (reader.ItemExists("ColumnCatalog")) _columnCatalog = reader.GetString("ColumnCatalog");
            if (reader.ItemExists("PixelFrameFcPreset")) _pixelFrameFcPreset = reader.GetString("PixelFrameFcPreset");
            return base.Read(reader);
        }

        public override void AddedToDocument(GH_Document document)
        {
            base.AddedToDocument(document);
            if (_section == "beam" && _catalog == "custom" && _beamType != "pixelframe" && Params.Input.Count < CustomParamCount)
                AddCustomBoundsInputs();
            if (_pixelFrameFcPreset == "custom" && (_beamType == "pixelframe" || _columnType == "pixelframe") && Params.Input.Count < PixelFrameCustomParamCount)
                AddPixelFrameCustomInputs();
            UpdateMessage();
        }

        private void UpdateMessage()
        {
            if (_section == "beam")
            {
                if (_beamType == "pixelframe")
                    Message = $"{LabelFor(SolverChoices, _solverType)} | PixelFrame {LabelFor(PixelFrameFcPresetChoices, _pixelFrameFcPreset)}";
                else
                    Message = $"{LabelFor(SolverChoices, _solverType)} | Beam {LabelFor(BeamCatalogChoices, _catalog)}";
            }
            else
            {
                if (_columnType == "pixelframe")
                    Message = $"{LabelFor(SolverChoices, _solverType)} | PixelFrame {LabelFor(PixelFrameFcPresetChoices, _pixelFrameFcPreset)}";
                else
                    Message = $"{LabelFor(SolverChoices, _solverType)} | Column {LabelFor(GetColumnCatalogChoices(_columnType), _columnCatalog)}";
            }
        }

        protected override void SolveInstance(IGH_DataAccess DA)
        {
            var data = new SolverParamsData
            {
                SolverType = _solverType,
                Section = _section,
                BeamType = _beamType,
                Catalog = _catalog,
                ColumnType = _columnType,
                ColumnCatalog = _section == "column" ? _columnCatalog : null,
                PixelFrameFcPreset = _pixelFrameFcPreset
            };

            if (_section == "beam" && _catalog == "custom" && _beamType != "pixelframe" && Params.Input.Count >= CustomParamCount)
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
            else if ((_beamType == "pixelframe" || _columnType == "pixelframe") && _pixelFrameFcPreset == "custom" && Params.Input.Count >= PixelFrameCustomParamCount)
            {
                double minKsi = 4, maxKsi = 8, resKsi = 1;
                DA.GetData(0, ref minKsi);
                DA.GetData(1, ref maxKsi);
                DA.GetData(2, ref resKsi);

                data.PixelFrameFcMinKsi = minKsi;
                data.PixelFrameFcMaxKsi = maxKsi;
                data.PixelFrameFcResolutionKsi = resKsi;
            }

            DA.SetData(0, new SolverParamsDataGoo(data));
        }
    }
}
