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
    /// Configures element-specific sizing parameters with NLP bounds.
    /// Component name updates dynamically based on selection (e.g., "Steel W Beam NLP").
    /// </summary>
    public class ElementParams : GH_Component
    {
        private string _solverType = "nlp";
        private string _section = "beam";
        private string _elementType = "steel_w";
        private double _mipTimeLimitSec = 30.0;

        private static readonly (string L, string V)[] SolverChoices =
        {
            ("MIP (discrete)", "mip"),
            ("NLP (continuous)", "nlp"),
        };

        private static readonly (string L, string V)[] SectionChoices =
        {
            ("Beam", "beam"),
            ("Column", "column"),
        };

        private static readonly (string L, string V)[] BeamTypeChoices =
        {
            ("Steel W-shape", "steel_w"),
            ("Steel HSS", "steel_hss"),
            ("RC Rectangular", "rc_rect"),
            ("RC T-beam", "rc_tbeam"),
            ("PixelFrame", "pixelframe"),
        };

        private static readonly (string L, string V)[] ColumnTypeChoices =
        {
            ("Steel W-shape", "steel_w"),
            ("Steel HSS", "steel_hss"),
            ("RC Rectangular", "rc_rect"),
            ("RC Circular", "rc_circular"),
            ("PixelFrame", "pixelframe"),
        };

        public ElementParams()
            : base("Element Params",
                   "ElemParams",
                   "Configure element sizing parameters (beam/column, MIP/NLP bounds)",
                   "Menegroth", "Component Params")
        { }

        public override Guid ComponentGuid =>
            new Guid("A1B2C3D4-E5F6-7890-ABCD-EF1234567890");

        protected override void RegisterInputParams(GH_InputParamManager pManager)
        {
            // Inputs registered dynamically based on element type
        }

        protected override void RegisterOutputParams(GH_OutputParamManager pManager)
        {
            pManager.AddGenericParameter("Params", "P",
                "Element params override for Design Params",
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

            // Element Type (depends on section)
            var typeChoices = _section == "beam" ? BeamTypeChoices : ColumnTypeChoices;
            var typeSub = new ToolStripMenuItem($"Type: {LabelFor(typeChoices, _elementType)}");
            menu.Items.Add(typeSub);
            foreach (var (label, value) in typeChoices)
            {
                var item = new ToolStripMenuItem(label) { Checked = _elementType == value, Tag = ("elementType", value) };
                item.Click += OnChoiceClicked;
                typeSub.DropDownItems.Add(item);
            }
        }

        private void OnChoiceClicked(object sender, EventArgs e)
        {
            var (field, value) = ((string, string))((ToolStripMenuItem)sender).Tag;

            switch (field)
            {
                case "solver": _solverType = value; break;
                case "section":
                    _section = value;
                    // Reset element type to first valid choice for new section
                    var choices = value == "beam" ? BeamTypeChoices : ColumnTypeChoices;
                    if (!choices.Any(c => c.V == _elementType))
                        _elementType = choices[0].V;
                    break;
                case "elementType": _elementType = value; break;
            }

            UpdateInputsForCurrentType();
            UpdateComponentName();
            ExpireSolution(true);
        }

        private void ClearAllInputs()
        {
            while (Params.Input.Count > 0)
                Params.UnregisterInputParameter(Params.Input[Params.Input.Count - 1]);
        }

        private void AddIntervalInput(string name, string nick, string desc, double min, double max)
        {
            var p = new Param_Interval
            {
                Name = name,
                NickName = nick,
                Description = desc,
                Access = GH_ParamAccess.item
            };
            p.SetPersistentData(new Grasshopper.Kernel.Types.GH_Interval(new Rhino.Geometry.Interval(min, max)));
            Params.RegisterInputParam(p, Params.Input.Count);
        }

        private void AddMipTimeLimitInput()
        {
            var p = new Param_Number
            {
                Name = "MIP Time Limit (s)",
                NickName = "t",
                Description = "MIP solver time limit in seconds (default: 30)",
                Access = GH_ParamAccess.item
            };
            p.SetPersistentData(_mipTimeLimitSec);
            Params.RegisterInputParam(p, 0);
        }

        private void UpdateInputsForCurrentType()
        {
            bool needMipInput = _solverType == "mip";
            string expectedFirstParam = GetExpectedFirstParamName(_elementType, _solverType);
            if (Params.Input.Count > 0 && Params.Input[0].Name == expectedFirstParam)
                return; // Already correct

            ClearAllInputs();

            if (needMipInput)
                AddMipTimeLimitInput();

            switch (_elementType)
            {
                case "steel_w":
                    // W-shape: d, bf, tf, tw
                    AddIntervalInput("Depth (in)", "d", "Overall depth range", 8, 36);
                    AddIntervalInput("Flange Width (in)", "bf", "Flange width range", 4, 18);
                    AddIntervalInput("Flange Thickness (in)", "tf", "Flange thickness range", 0.25, 2.0);
                    AddIntervalInput("Web Thickness (in)", "tw", "Web thickness range", 0.25, 1.0);
                    break;

                case "steel_hss":
                    // HSS: outer dimension, wall thickness
                    AddIntervalInput("Outer Dimension (in)", "OD", "Outer dimension range (B or H)", 4, 20);
                    AddIntervalInput("Wall Thickness (in)", "t", "Wall thickness range", 0.125, 0.625);
                    break;

                case "rc_rect":
                    // RC Rectangular: width, depth
                    AddIntervalInput("Width (in)", "b", "Section width range", 12, 24);
                    AddIntervalInput("Depth (in)", "h", "Section depth range", 12, 48);
                    break;

                case "rc_tbeam":
                    // RC T-beam: same as rect for now (flange handled separately)
                    AddIntervalInput("Width (in)", "b", "Web width range", 12, 24);
                    AddIntervalInput("Depth (in)", "h", "Overall depth range", 18, 36);
                    break;

                case "rc_circular":
                    // RC Circular column: diameter only
                    AddIntervalInput("Diameter (in)", "D", "Column diameter range", 12, 48);
                    break;

                case "pixelframe":
                    // PixelFrame: fc strength only (geometry is fixed)
                    AddIntervalInput("fc (ksi)", "fc", "Concrete strength range", 4, 8);
                    break;
            }

            Params.OnParametersChanged();
        }

        private static string GetExpectedFirstParamName(string elementType, string solverType)
        {
            if (solverType == "mip") return "MIP Time Limit (s)";
            return elementType switch
            {
                "steel_w" => "Depth (in)",
                "steel_hss" => "Outer Dimension (in)",
                "rc_rect" => "Width (in)",
                "rc_tbeam" => "Width (in)",
                "rc_circular" => "Diameter (in)",
                "pixelframe" => "fc (ksi)",
                _ => ""
            };
        }

        private static string LabelFor((string L, string V)[] choices, string value) =>
            choices.FirstOrDefault(c => c.V == value).L ?? value;

        private string GetTypeLabel()
        {
            return _elementType switch
            {
                "steel_w" => "W",
                "steel_hss" => "HSS",
                "rc_rect" => "RC Rect",
                "rc_tbeam" => "RC T",
                "rc_circular" => "RC Circ",
                "pixelframe" => "PxF",
                _ => _elementType
            };
        }

        private void UpdateComponentName()
        {
            string solver = _solverType.ToUpperInvariant();
            string section = _section == "beam" ? "Beam" : "Col";
            string type = GetTypeLabel();
            
            // NickName is what shows on the component itself
            // Message shows below the component
            string displayName = $"{type} {section} {solver}";
            NickName = displayName;
            Message = displayName;
        }

        public override bool Write(GH_IO.Serialization.GH_IWriter writer)
        {
            writer.SetString("SolverType", _solverType);
            writer.SetString("Section", _section);
            writer.SetString("ElementType", _elementType);
            writer.SetDouble("MipTimeLimitSec", _mipTimeLimitSec);
            return base.Write(writer);
        }

        public override bool Read(GH_IO.Serialization.GH_IReader reader)
        {
            if (reader.ItemExists("SolverType")) _solverType = reader.GetString("SolverType");
            if (reader.ItemExists("Section")) _section = reader.GetString("Section");
            if (reader.ItemExists("ElementType")) _elementType = reader.GetString("ElementType");
            if (reader.ItemExists("MipTimeLimitSec")) _mipTimeLimitSec = reader.GetDouble("MipTimeLimitSec");
            return base.Read(reader);
        }

        public override void AddedToDocument(GH_Document document)
        {
            base.AddedToDocument(document);
            UpdateInputsForCurrentType();
            UpdateComponentName();
        }

        protected override void SolveInstance(IGH_DataAccess DA)
        {
            var data = new ElementParamsData
            {
                SolverType = _solverType,
                Section = _section,
                ElementType = _elementType
            };

            int idx = 0;
            if (_solverType == "mip")
            {
                double t = _mipTimeLimitSec;
                if (Params.Input.Count > 0 && DA.GetData(0, ref t))
                {
                    _mipTimeLimitSec = Math.Max(0.1, t);
                    data.MipTimeLimitSec = _mipTimeLimitSec;
                }
                idx = 1;
            }

            // Read interval inputs; guard uses idx so the check is correct
            // regardless of whether the MIP time-limit input is present.
            int remaining = Params.Input.Count - idx;
            switch (_elementType)
            {
                case "steel_w":
                    if (remaining >= 4)
                    {
                        var d = new Rhino.Geometry.Interval(8, 36);
                        var bf = new Rhino.Geometry.Interval(4, 18);
                        var tf = new Rhino.Geometry.Interval(0.25, 2.0);
                        var tw = new Rhino.Geometry.Interval(0.25, 1.0);
                        DA.GetData(idx++, ref d);
                        DA.GetData(idx++, ref bf);
                        DA.GetData(idx++, ref tf);
                        DA.GetData(idx++, ref tw);
                        data.DepthIn = (d.Min, d.Max);
                        data.FlangeWidthIn = (bf.Min, bf.Max);
                        data.FlangeThicknessIn = (tf.Min, tf.Max);
                        data.WebThicknessIn = (tw.Min, tw.Max);
                    }
                    break;

                case "steel_hss":
                    if (remaining >= 2)
                    {
                        var od = new Rhino.Geometry.Interval(4, 20);
                        var t = new Rhino.Geometry.Interval(0.125, 0.625);
                        DA.GetData(idx++, ref od);
                        DA.GetData(idx++, ref t);
                        data.OuterDimensionIn = (od.Min, od.Max);
                        data.WallThicknessIn = (t.Min, t.Max);
                    }
                    break;

                case "rc_rect":
                case "rc_tbeam":
                    if (remaining >= 2)
                    {
                        var b = new Rhino.Geometry.Interval(12, 24);
                        var h = new Rhino.Geometry.Interval(12, 48);
                        DA.GetData(idx++, ref b);
                        DA.GetData(idx++, ref h);
                        data.WidthIn = (b.Min, b.Max);
                        data.DepthIn = (h.Min, h.Max);
                    }
                    break;

                case "rc_circular":
                    if (remaining >= 1)
                    {
                        var d = new Rhino.Geometry.Interval(12, 48);
                        DA.GetData(idx++, ref d);
                        data.DiameterIn = (d.Min, d.Max);
                    }
                    break;

                case "pixelframe":
                    if (remaining >= 1)
                    {
                        var fc = new Rhino.Geometry.Interval(4, 8);
                        DA.GetData(idx++, ref fc);
                        data.FcKsi = (fc.Min, fc.Max);
                    }
                    break;
            }

            DA.SetData(0, new ElementParamsDataGoo(data));
        }
    }
}
