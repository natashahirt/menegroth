using System;
using System.Collections.Generic;
using System.Linq;
using System.Windows.Forms;
using Grasshopper.Kernel;
using StructuralSizer.GH.Types;

namespace StructuralSizer.GH.Components
{
    /// <summary>
    /// Packages design parameters for the structural sizing API.
    ///
    /// Numeric inputs (loads) are wired inputs with defaults.
    /// All enum-like selections are embedded in nested right-click menus —
    /// no external ValueList components needed.
    ///
    /// Menu structure:
    ///   Floor System ▸ Flat Plate ▸ Analysis Method ▸ ...
    ///                              ▸ Punching Strategy ▸ ...
    ///                  Flat Slab ▸ Analysis Method ▸ ...
    ///                           ▸ Punching Strategy ▸ ...
    ///                  One-Way
    ///                  Vault
    ///                  Deflection Limit ▸ ...
    ///   Columns ▸ Type ▸ ...
    ///   Beams ▸ Type ▸ ...
    ///   Materials ▸ Concrete ▸ ...
    ///              ▸ Rebar ▸ ...
    ///              ▸ Steel ▸ ...
    ///   Design ▸ Optimize For ▸ ...
    ///          ▸ Fire Rating ▸ ...
    ///   Output ▸ Units ▸ ...
    /// </summary>
    public class SizerDesignParams : GH_Component
    {
        // ─── Persisted dropdown state ────────────────────────────────────
        private string _floorType = "flat_plate";
        private string _method = "DDM";
        private string _deflLimit = "L_360";
        private string _punchStrat = "grow_columns";
        private string _concrete = "NWC_4000";
        private string _rebar = "Rebar_60";
        private string _steel = "A992";
        private string _columnType = "rc_rect";
        private string _beamType = "steel_w";
        private string _optimizeFor = "weight";
        private string _fireRating = "0";
        private string _unitSystem = "imperial";

        // ─── Choice tables ───────────────────────────────────────────────

        private static readonly Choice[] FloorTypes =
        {
            new("Flat Plate",  "flat_plate"),
            new("Flat Slab",   "flat_slab"),
            new("One-Way",     "one_way"),
            new("Vault",       "vault"),
        };

        private static readonly Choice[] Methods =
        {
            new("DDM",               "DDM"),
            new("DDM (Simplified)",  "DDM_SIMPLIFIED"),
            new("EFM",              "EFM"),
            new("EFM (Hardy Cross)", "EFM_HARDY_CROSS"),
            new("FEA",              "FEA"),
        };

        private static readonly Choice[] DeflLimits =
        {
            new("L / 240  (total after attachment)",  "L_240"),
            new("L / 360  (immediate live load)",     "L_360"),
            new("L / 480  (sensitive elements)",      "L_480"),
        };

        private static readonly Choice[] PunchStrategies =
        {
            new("Grow Columns Only",             "grow_columns"),
            new("Grow First → Reinforce Last",   "reinforce_last"),
            new("Reinforce First → Grow Last",   "reinforce_first"),
        };

        private static readonly Choice[] Concretes =
        {
            new("NWC 3000 psi", "NWC_3000"),
            new("NWC 4000 psi", "NWC_4000"),
            new("NWC 5000 psi", "NWC_5000"),
            new("NWC 6000 psi", "NWC_6000"),
        };

        private static readonly Choice[] Rebars =
        {
            new("Grade 40", "Rebar_40"),
            new("Grade 60", "Rebar_60"),
            new("Grade 75", "Rebar_75"),
            new("Grade 80", "Rebar_80"),
        };

        private static readonly Choice[] Steels =
        {
            new("A992", "A992"),
        };

        private static readonly Choice[] ColumnTypes =
        {
            new("RC Rectangular", "rc_rect"),
            new("RC Circular",   "rc_circular"),
            new("Steel W-shape",  "steel_w"),
            new("Steel HSS",     "steel_hss"),
            new("Steel Pipe",    "steel_pipe"),
        };

        private static readonly Choice[] BeamTypes =
        {
            new("Steel W-shape",  "steel_w"),
            new("Steel HSS",     "steel_hss"),
            new("RC Rectangular", "rc_rect"),
            new("RC T-beam",     "rc_tbeam"),
        };

        private static readonly Choice[] Objectives =
        {
            new("Weight", "weight"),
            new("Carbon", "carbon"),
            new("Cost",   "cost"),
        };

        private static readonly Choice[] FireRatings =
        {
            new("None",     "0"),
            new("1 hour",   "1"),
            new("1.5 hour", "1.5"),
            new("2 hour",   "2"),
            new("3 hour",   "3"),
            new("4 hour",   "4"),
        };

        private static readonly Choice[] UnitSystems =
        {
            new("Imperial", "imperial"),
            new("Metric",   "metric"),
        };

        // ─── Constructor ─────────────────────────────────────────────────
        public SizerDesignParams()
            : base("Sizer Design Params",
                   "SizerParams",
                   "Configure design parameters for structural sizing",
                   "Menegroth", "Input")
        { }

        public override Guid ComponentGuid =>
            new Guid("A1B2C3D4-5555-6666-7777-888899990000");

        // ─── Wired inputs (numeric only) ─────────────────────────────────
        protected override void RegisterInputParams(GH_InputParamManager pManager)
        {
            pManager.AddNumberParameter("Floor LL (psf)", "Floor LL",
                "Floor live load in psf", GH_ParamAccess.item, 80.0);

            pManager.AddNumberParameter("Roof LL (psf)", "Roof LL",
                "Roof live load in psf", GH_ParamAccess.item, 20.0);

            pManager.AddNumberParameter("Floor SDL (psf)", "Floor SDL",
                "Floor superimposed dead load in psf", GH_ParamAccess.item, 15.0);

            pManager.AddNumberParameter("Roof SDL (psf)", "Roof SDL",
                "Roof superimposed dead load in psf", GH_ParamAccess.item, 15.0);
        }

        protected override void RegisterOutputParams(GH_OutputParamManager pManager)
        {
            pManager.AddGenericParameter("Params", "Params",
                "SizerParams object for the SizerRun component",
                GH_ParamAccess.item);
        }

        // ─── Nested right-click menu ─────────────────────────────────────
        protected override void AppendAdditionalComponentMenuItems(ToolStripDropDown menu)
        {
            base.AppendAdditionalComponentMenuItems(menu);
            Menu_AppendSeparator(menu);

            // ── Floor System ▸ ──
            var floorMenu = Menu_AppendItem(menu, "Floor System");

            // Floor types as direct children
            foreach (var ft in FloorTypes)
            {
                var ftItem = new ToolStripMenuItem(ft.Label)
                {
                    Checked = _floorType == ft.Value,
                    Tag = new ChoiceTag { Field = "Floor Type", Value = ft.Value }
                };
                ftItem.Click += OnChoiceClicked;
                floorMenu.DropDownItems.Add(ftItem);

                // Add sub-options for Flat Plate and Flat Slab
                if (ft.Value == "flat_plate" || ft.Value == "flat_slab")
                {
                    // Analysis Method submenu
                    string methodLabel = LabelFor(Methods, _method);
                    var methodSub = new ToolStripMenuItem($"Analysis Method: {methodLabel}");
                    ftItem.DropDownItems.Add(methodSub);

                    foreach (var m in Methods)
                    {
                        var mItem = new ToolStripMenuItem(m.Label)
                        {
                            Checked = _method == m.Value,
                            Tag = new ChoiceTag { Field = "Analysis Method", Value = m.Value }
                        };
                        mItem.Click += OnChoiceClicked;
                        methodSub.DropDownItems.Add(mItem);
                    }

                    // Punching Strategy submenu
                    string punchLabel = LabelFor(PunchStrategies, _punchStrat);
                    var punchSub = new ToolStripMenuItem($"Punching Strategy: {punchLabel}");
                    ftItem.DropDownItems.Add(punchSub);

                    foreach (var p in PunchStrategies)
                    {
                        var pItem = new ToolStripMenuItem(p.Label)
                        {
                            Checked = _punchStrat == p.Value,
                            Tag = new ChoiceTag { Field = "Punching Strategy", Value = p.Value }
                        };
                        pItem.Click += OnChoiceClicked;
                        punchSub.DropDownItems.Add(pItem);
                    }
                }
            }

            Menu_AppendSeparator(floorMenu.DropDown);

            // Deflection Limit (shared across all floor types)
            AddSubChoices(floorMenu, "Deflection Limit", DeflLimits, _deflLimit);

            // ── Columns ▸ ──
            var colMenu = Menu_AppendItem(menu, "Columns");
            AddSubChoices(colMenu, "Column Type", ColumnTypes, _columnType);

            // ── Beams ▸ ──
            var beamMenu = Menu_AppendItem(menu, "Beams");
            AddSubChoices(beamMenu, "Beam Type", BeamTypes, _beamType);

            // ── Materials ▸ ──
            var matMenu = Menu_AppendItem(menu, "Materials");
            AddSubChoices(matMenu, "Concrete", Concretes, _concrete);
            AddSubChoices(matMenu, "Rebar",    Rebars,    _rebar);
            AddSubChoices(matMenu, "Steel",    Steels,    _steel);

            // ── Design ▸ ──
            var designMenu = Menu_AppendItem(menu, "Design");
            AddSubChoices(designMenu, "Optimize For", Objectives,  _optimizeFor);
            AddSubChoices(designMenu, "Fire Rating",  FireRatings, _fireRating);

            Menu_AppendSeparator(menu);

            // ── Output ▸ ──
            var outputMenu = Menu_AppendItem(menu, "Output");
            AddSubChoices(outputMenu, "Units", UnitSystems, _unitSystem);
        }

        /// <summary>
        /// Build a 2nd-level submenu: parent ▸ title ▸ [choices with checkmarks]
        /// </summary>
        private void AddSubChoices(
            ToolStripMenuItem parent,
            string title,
            Choice[] choices,
            string currentValue)
        {
            string currentLabel = choices.FirstOrDefault(c => c.Value == currentValue)?.Label ?? currentValue;
            var sub = new ToolStripMenuItem($"{title}: {currentLabel}");
            parent.DropDownItems.Add(sub);

            foreach (var choice in choices)
            {
                var item = new ToolStripMenuItem(choice.Label)
                {
                    Checked = choice.Value == currentValue,
                    Tag = new ChoiceTag { Field = title, Value = choice.Value }
                };
                item.Click += OnChoiceClicked;
                sub.DropDownItems.Add(item);
            }
        }

        private void OnChoiceClicked(object sender, EventArgs e)
        {
            var tag = (ChoiceTag)((ToolStripMenuItem)sender).Tag;

            switch (tag.Field)
            {
                case "Floor Type":        _floorType   = tag.Value; break;
                case "Analysis Method":   _method      = tag.Value; break;
                case "Deflection Limit":  _deflLimit   = tag.Value; break;
                case "Punching Strategy": _punchStrat  = tag.Value; break;
                case "Concrete":          _concrete    = tag.Value; break;
                case "Rebar":             _rebar       = tag.Value; break;
                case "Steel":             _steel        = tag.Value; break;
                case "Column Type":       _columnType = tag.Value; break;
                case "Beam Type":         _beamType   = tag.Value; break;
                case "Optimize For":      _optimizeFor = tag.Value; break;
                case "Fire Rating":       _fireRating  = tag.Value; break;
                case "Units":             _unitSystem  = tag.Value; break;
            }

            UpdateMessage();
            ExpireSolution(true);
        }

        // ─── Persistence ─────────────────────────────────────────────────
        public override bool Write(GH_IO.Serialization.GH_IWriter writer)
        {
            writer.SetString("FloorType",   _floorType);
            writer.SetString("Method",      _method);
            writer.SetString("DeflLimit",   _deflLimit);
            writer.SetString("PunchStrat",  _punchStrat);
            writer.SetString("Concrete",    _concrete);
            writer.SetString("Rebar",       _rebar);
            writer.SetString("Steel",       _steel);
            writer.SetString("ColumnType",  _columnType);
            writer.SetString("BeamType",    _beamType);
            writer.SetString("OptimizeFor", _optimizeFor);
            writer.SetString("FireRating",  _fireRating);
            writer.SetString("UnitSystem",  _unitSystem);
            return base.Write(writer);
        }

        public override bool Read(GH_IO.Serialization.GH_IReader reader)
        {
            if (reader.ItemExists("FloorType"))   _floorType   = reader.GetString("FloorType");
            if (reader.ItemExists("Method"))       _method      = reader.GetString("Method");
            if (reader.ItemExists("DeflLimit"))    _deflLimit   = reader.GetString("DeflLimit");
            if (reader.ItemExists("PunchStrat"))   _punchStrat  = reader.GetString("PunchStrat");
            if (reader.ItemExists("Concrete"))     _concrete    = reader.GetString("Concrete");
            if (reader.ItemExists("Rebar"))        _rebar       = reader.GetString("Rebar");
            if (reader.ItemExists("Steel"))        _steel       = reader.GetString("Steel");
            if (reader.ItemExists("ColumnType"))   _columnType  = reader.GetString("ColumnType");
            if (reader.ItemExists("BeamType"))     _beamType    = reader.GetString("BeamType");
            if (reader.ItemExists("OptimizeFor"))  _optimizeFor = reader.GetString("OptimizeFor");
            if (reader.ItemExists("FireRating"))   _fireRating  = reader.GetString("FireRating");
            if (reader.ItemExists("UnitSystem"))   _unitSystem  = reader.GetString("UnitSystem");
            UpdateMessage();
            return base.Read(reader);
        }

        // ─── Message bar ─────────────────────────────────────────────────
        public override void AddedToDocument(GH_Document document)
        {
            base.AddedToDocument(document);
            UpdateMessage();
        }

        private void UpdateMessage()
        {
            Message = string.Join(" | ",
                LabelFor(FloorTypes, _floorType),
                LabelFor(ColumnTypes, _columnType),
                LabelFor(BeamTypes, _beamType));
        }

        private static string LabelFor(Choice[] choices, string value)
        {
            return choices.FirstOrDefault(c => c.Value == value)?.Label ?? value;
        }

        // ─── Solve ───────────────────────────────────────────────────────
        protected override void SolveInstance(IGH_DataAccess DA)
        {
            double floorLL = 80, roofLL = 20, floorSDL = 15, roofSDL = 15;

            DA.GetData(0, ref floorLL);
            DA.GetData(1, ref roofLL);
            DA.GetData(2, ref floorSDL);
            DA.GetData(3, ref roofSDL);

            double fireRatingVal = 0;
            if (double.TryParse(_fireRating, System.Globalization.NumberStyles.Any,
                                System.Globalization.CultureInfo.InvariantCulture,
                                out double parsed))
                fireRatingVal = parsed;

            var p = new SizerParams
            {
                FloorLL         = floorLL,
                RoofLL          = roofLL,
                FloorSDL        = floorSDL,
                RoofSDL         = roofSDL,
                FireRating      = fireRatingVal,
                FloorType       = _floorType,
                AnalysisMethod  = _method,
                DeflectionLimit = _deflLimit,
                PunchingStrategy = _punchStrat,
                Concrete        = _concrete,
                Rebar           = _rebar,
                Steel           = _steel,
                ColumnType      = _columnType,
                BeamType        = _beamType,
                OptimizeFor     = _optimizeFor,
                UnitSystem      = _unitSystem,
            };

            DA.SetData(0, new GH_SizerParams(p));
        }

        // ─── Helper types ────────────────────────────────────────────────
        private class Choice
        {
            public string Label { get; }
            public string Value { get; }
            public Choice(string label, string value) { Label = label; Value = value; }
        }

        private class ChoiceTag
        {
            public string Field { get; set; } = "";
            public string Value { get; set; } = "";
        }
    }
}
