using System;
using System.Collections.Generic;
using System.Linq;
using System.Windows.Forms;
using Grasshopper.Kernel;
using Menegroth.GH.Types;

namespace Menegroth.GH.Components
{
    /// <summary>
    /// Unified results component. Accepts a <see cref="DesignResult"/> object from DesignRun
    /// and outputs summary statistics plus per-element data.
    ///
    /// Right-click menu selects the element type for per-element outputs:
    ///   Slabs | Columns | Beams | Foundations
    ///
    /// Also supports a filter: All | Passing | Failing
    /// </summary>
    public class DesignResults : GH_Component
    {
        private string _elementType = "columns";
        private string _filter = "all";

        public DesignResults()
            : base("Design Results",
                   "DesignRes",
                   "Design results: summary statistics and per-element data",
                   "Menegroth", "Core")
        { }

        public override Guid ComponentGuid =>
            new Guid("33F12765-4E2E-43AD-86F0-697FECEF4BCD");

        // ─── Parameters ─────────────────────────────────────────────────

        protected override void RegisterInputParams(GH_InputParamManager pManager)
        {
            pManager.AddGenericParameter("Result", "Result",
                "DesignResult from the DesignRun component", GH_ParamAccess.item);
        }

        protected override void RegisterOutputParams(GH_OutputParamManager pManager)
        {
            // Summary outputs (always available)
            pManager.AddBooleanParameter("All Pass", "AllPass",
                "True if all elements pass design checks", GH_ParamAccess.item);
            pManager.AddNumberParameter("Critical Ratio", "CriticalRatio",
                "Highest utilization ratio in the building", GH_ParamAccess.item);
            pManager.AddTextParameter("Critical Element", "CriticalElement",
                "Element with the highest utilization ratio", GH_ParamAccess.item);
            pManager.AddNumberParameter("Concrete Volume", "ConcreteVolume",
                "Concrete volume (ft\u00b3)", GH_ParamAccess.item);
            pManager.AddNumberParameter("Steel Weight", "SteelWeight",
                "Steel weight (lb)", GH_ParamAccess.item);
            pManager.AddNumberParameter("Rebar Weight", "RebarWeight",
                "Rebar weight (lb)", GH_ParamAccess.item);
            pManager.AddNumberParameter("Embodied Carbon", "EmbodiedCarbon",
                "Embodied carbon (kg CO\u2082e)", GH_ParamAccess.item);
            pManager.AddNumberParameter("Compute Time", "ComputeTime",
                "Compute time (seconds)", GH_ParamAccess.item);

            // Per-element outputs (filtered by menu selection)
            pManager.AddIntegerParameter("IDs", "IDs",
                "Element IDs", GH_ParamAccess.list);
            pManager.AddTextParameter("Sections", "Sections",
                "Section labels", GH_ParamAccess.list);
            pManager.AddNumberParameter("Utilization", "Utilization",
                "Max utilization ratios (0\u20131)", GH_ParamAccess.list);
            pManager.AddBooleanParameter("Pass", "Pass",
                "Pass/fail per element", GH_ParamAccess.list);
            pManager.AddTextParameter("Failures", "Failures",
                "Failure messages (empty for passing elements)", GH_ParamAccess.list);
        }

        // ─── Right-click menu ───────────────────────────────────────────

        protected override void AppendAdditionalComponentMenuItems(ToolStripDropDown menu)
        {
            base.AppendAdditionalComponentMenuItems(menu);
            Menu_AppendSeparator(menu);

            var typeMenu = Menu_AppendItem(menu, "Element Type");
            foreach (var (label, value) in new[]
            {
                ("Slabs", "slabs"), ("Columns", "columns"),
                ("Beams", "beams"), ("Foundations", "foundations")
            })
            {
                var item = new ToolStripMenuItem(label) { Checked = _elementType == value, Tag = value };
                item.Click += (s, _) => { _elementType = (string)((ToolStripMenuItem)s).Tag; UpdateMessage(); ExpireSolution(true); };
                typeMenu.DropDownItems.Add(item);
            }

            Menu_AppendSeparator(menu);

            var filterMenu = Menu_AppendItem(menu, "Filter");
            foreach (var (label, value) in new[]
            {
                ("All", "all"), ("Passing", "passing"), ("Failing", "failing")
            })
            {
                var item = new ToolStripMenuItem(label) { Checked = _filter == value, Tag = value };
                item.Click += (s, _) => { _filter = (string)((ToolStripMenuItem)s).Tag; UpdateMessage(); ExpireSolution(true); };
                filterMenu.DropDownItems.Add(item);
            }
        }

        // ─── Persistence ────────────────────────────────────────────────

        public override bool Write(GH_IO.Serialization.GH_IWriter writer)
        {
            writer.SetString("ElementType", _elementType);
            writer.SetString("Filter", _filter);
            return base.Write(writer);
        }

        public override bool Read(GH_IO.Serialization.GH_IReader reader)
        {
            if (reader.ItemExists("ElementType")) _elementType = reader.GetString("ElementType");
            if (reader.ItemExists("Filter")) _filter = reader.GetString("Filter");
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
            string typeLabel = _elementType.Substring(0, 1).ToUpper() + _elementType.Substring(1);
            Message = _filter == "all" ? typeLabel : $"{typeLabel} ({_filter})";
        }

        // ─── Solve ──────────────────────────────────────────────────────

        protected override void SolveInstance(IGH_DataAccess DA)
        {
            GH_DesignResult goo = null;
            if (!DA.GetData(0, ref goo) || goo?.Value == null) return;

            var r = goo.Value;

            if (r.IsError)
            {
                AddRuntimeMessage(GH_RuntimeMessageLevel.Error, r.ErrorMessage);
                return;
            }

            // Summary outputs
            DA.SetData(0, r.AllPass);
            DA.SetData(1, r.CriticalRatio);
            DA.SetData(2, r.CriticalElement);
            DA.SetData(3, r.ConcreteVolumeFt3);
            DA.SetData(4, r.SteelWeightLb);
            DA.SetData(5, r.RebarWeightLb);
            DA.SetData(6, r.EmbodiedCarbonKgCO2e);
            DA.SetData(7, r.ComputeTime);

            // Per-element outputs
            var ids = new List<int>();
            var sections = new List<string>();
            var ratios = new List<double>();
            var pass = new List<bool>();
            var failures = new List<string>();

            switch (_elementType)
            {
                case "slabs":
                    foreach (var s in r.Slabs)
                    {
                        if (!MatchesFilter(s.Ok)) continue;
                        ids.Add(s.Id);
                        sections.Add(s.Label);
                        ratios.Add(s.MaxRatio);
                        pass.Add(s.Ok);
                        failures.Add(s.Ok ? "" : FormatSlabFailure(s));
                    }
                    break;

                case "columns":
                    foreach (var c in r.Columns)
                    {
                        if (!MatchesFilter(c.Ok)) continue;
                        ids.Add(c.Id);
                        sections.Add(c.Section);
                        ratios.Add(c.MaxRatio);
                        pass.Add(c.Ok);
                        failures.Add(c.Ok ? "" : $"Column {c.Id}: interaction={c.InteractionRatio:F2}");
                    }
                    break;

                case "beams":
                    foreach (var b in r.Beams)
                    {
                        if (!MatchesFilter(b.Ok)) continue;
                        ids.Add(b.Id);
                        sections.Add(b.Section);
                        ratios.Add(b.MaxRatio);
                        pass.Add(b.Ok);
                        failures.Add(b.Ok ? "" : $"Beam {b.Id}: flex={b.FlexureRatio:F2}, shear={b.ShearRatio:F2}");
                    }
                    break;

                case "foundations":
                    foreach (var f in r.Foundations)
                    {
                        if (!MatchesFilter(f.Ok)) continue;
                        ids.Add(f.Id);
                        sections.Add(f.Label);
                        ratios.Add(f.BearingRatio);
                        pass.Add(f.Ok);
                        failures.Add(f.Ok ? "" : $"Foundation {f.Id}: bearing={f.BearingRatio:F2}");
                    }
                    break;
            }

            DA.SetDataList(8, ids);
            DA.SetDataList(9, sections);
            DA.SetDataList(10, ratios);
            DA.SetDataList(11, pass);
            DA.SetDataList(12, failures);

            // Warnings for failing elements
            foreach (var fm in failures.Where(f => !string.IsNullOrEmpty(f)))
                AddRuntimeMessage(GH_RuntimeMessageLevel.Warning, fm);
        }

        private bool MatchesFilter(bool ok) =>
            _filter == "all" || (_filter == "passing" && ok) || (_filter == "failing" && !ok);

        private static string FormatSlabFailure(SlabResult s)
        {
            string msg = $"Slab {s.Id}";
            if (!s.Converged)
                msg += $": {s.FailureReason}" + (string.IsNullOrEmpty(s.FailingCheck) ? "" : $" ({s.FailingCheck})");
            else
                msg += $": defl={s.DeflectionRatio:F2}, punch={s.PunchingMaxRatio:F2}";
            return msg;
        }
    }
}
