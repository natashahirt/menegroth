using System;
using System.Collections.Generic;
using System.Linq;
using Grasshopper.Kernel;
using Newtonsoft.Json.Linq;

namespace StructuralSizer.GH.Components
{
    /// <summary>
    /// Parses the JSON response from the Julia sizing API into typed GH outputs.
    /// Utilisation ratios are 0–1 numbers suitable for gradient colour-mapping.
    /// Failed elements produce per-element failure messages.
    /// </summary>
    public class SizerResults : GH_Component
    {
        public SizerResults()
            : base("Sizer Results",
                   "SizerRes",
                   "Parse structural sizing results from the API response",
                   "Menegroth", "Results")
        { }

        public override Guid ComponentGuid =>
            new Guid("A1B2C3D4-AAAA-BBBB-CCCC-DDDDEEEE0002");

        // ─── Parameters ──────────────────────────────────────────────────

        protected override void RegisterInputParams(GH_InputParamManager pManager)
        {
            pManager.AddTextParameter("JSON", "J",
                "Raw JSON response from SizerRun", GH_ParamAccess.item);
        }

        protected override void RegisterOutputParams(GH_OutputParamManager pManager)
        {
            pManager.AddNumberParameter("Slab Thicknesses", "St",
                "Slab thickness in inches", GH_ParamAccess.list);
            pManager.AddTextParameter("Column Sections", "Cs",
                "Column section labels", GH_ParamAccess.list);
            pManager.AddNumberParameter("Column Utilizations", "Cu",
                "Column interaction ratios (0–1)", GH_ParamAccess.list);
            pManager.AddTextParameter("Beam Sections", "Bs",
                "Beam section labels", GH_ParamAccess.list);
            pManager.AddNumberParameter("Beam Utilizations", "Bu",
                "Beam max utilisation ratios (0–1)", GH_ParamAccess.list);
            pManager.AddBooleanParameter("All Pass", "OK",
                "True if all elements pass design checks", GH_ParamAccess.item);
            pManager.AddNumberParameter("Critical Ratio", "CR",
                "Highest utilisation ratio in the building", GH_ParamAccess.item);
            pManager.AddTextParameter("Critical Element", "CE",
                "Element with the highest utilisation ratio", GH_ParamAccess.item);
            pManager.AddTextParameter("Summary", "Sum",
                "Text summary of the design", GH_ParamAccess.item);
            pManager.AddTextParameter("Failure Messages", "Fail",
                "Per-element failure messages (empty for passing elements)",
                GH_ParamAccess.list);
        }

        // ─── Solve ───────────────────────────────────────────────────────

        protected override void SolveInstance(IGH_DataAccess DA)
        {
            string json = "";
            if (!DA.GetData(0, ref json) || string.IsNullOrWhiteSpace(json)) return;

            JObject root;
            try
            {
                root = JObject.Parse(json);
            }
            catch (Exception ex)
            {
                AddRuntimeMessage(GH_RuntimeMessageLevel.Error,
                    $"Failed to parse JSON: {ex.Message}");
                return;
            }

            string status = root["status"]?.ToString() ?? "unknown";
            if (status == "error")
            {
                string msg = root["message"]?.ToString() ?? "Unknown error";
                AddRuntimeMessage(GH_RuntimeMessageLevel.Error, msg);
                return;
            }

            // ─── Slabs ──────────────────────────────────────────────────
            var slabThicknesses = new List<double>();
            var failures = new List<string>();
            var slabs = root["slabs"] as JArray ?? new JArray();
            foreach (var s in slabs)
            {
                slabThicknesses.Add(s["thickness_in"]?.ToObject<double>() ?? 0);
                bool converged = s["converged"]?.ToObject<bool>() ?? true;
                if (!converged)
                {
                    string reason = s["failure_reason"]?.ToString() ?? "unknown";
                    string check = s["failing_check"]?.ToString() ?? "";
                    int id = s["id"]?.ToObject<int>() ?? 0;
                    failures.Add($"Slab {id}: {reason}" +
                        (string.IsNullOrEmpty(check) ? "" : $" ({check})"));
                }
                else
                {
                    failures.Add("");
                }
            }

            // ─── Columns ────────────────────────────────────────────────
            var colSections = new List<string>();
            var colUtils = new List<double>();
            var columns = root["columns"] as JArray ?? new JArray();
            foreach (var c in columns)
            {
                colSections.Add(c["section"]?.ToString() ?? "");
                colUtils.Add(c["interaction_ratio"]?.ToObject<double>() ?? 0);
                bool ok = c["ok"]?.ToObject<bool>() ?? true;
                if (!ok)
                {
                    int id = c["id"]?.ToObject<int>() ?? 0;
                    double ratio = c["interaction_ratio"]?.ToObject<double>() ?? 0;
                    failures.Add($"Column {id}: interaction ratio {ratio:F2}");
                }
                else
                {
                    failures.Add("");
                }
            }

            // ─── Beams ──────────────────────────────────────────────────
            var beamSections = new List<string>();
            var beamUtils = new List<double>();
            var beams = root["beams"] as JArray ?? new JArray();
            foreach (var b in beams)
            {
                beamSections.Add(b["section"]?.ToString() ?? "");
                double flex = b["flexure_ratio"]?.ToObject<double>() ?? 0;
                double shear = b["shear_ratio"]?.ToObject<double>() ?? 0;
                beamUtils.Add(Math.Max(flex, shear));
                bool ok = b["ok"]?.ToObject<bool>() ?? true;
                if (!ok)
                {
                    int id = b["id"]?.ToObject<int>() ?? 0;
                    failures.Add($"Beam {id}: flex={flex:F2}, shear={shear:F2}");
                }
                else
                {
                    failures.Add("");
                }
            }

            // ─── Summary ────────────────────────────────────────────────
            var summary = root["summary"];
            bool allPass = summary?["all_pass"]?.ToObject<bool>() ?? false;
            double critRatio = summary?["critical_ratio"]?.ToObject<double>() ?? 0;
            string critElement = summary?["critical_element"]?.ToString() ?? "";

            double concreteVol = summary?["concrete_volume_ft3"]?.ToObject<double>() ?? 0;
            double steelWt = summary?["steel_weight_lb"]?.ToObject<double>() ?? 0;
            double rebarWt = summary?["rebar_weight_lb"]?.ToObject<double>() ?? 0;
            double ec = summary?["embodied_carbon_kgCO2e"]?.ToObject<double>() ?? 0;
            double computeTime = root["compute_time_s"]?.ToObject<double>() ?? 0;

            string summaryText =
                $"All Pass: {allPass}\n" +
                $"Critical: {critElement} ({critRatio:F2})\n" +
                $"Concrete: {concreteVol:F1} ft³\n" +
                $"Steel: {steelWt:F0} lb\n" +
                $"Rebar: {rebarWt:F0} lb\n" +
                $"Embodied Carbon: {ec:F0} kgCO₂e\n" +
                $"Compute Time: {computeTime:F2} s";

            // ─── Warnings for failed elements ────────────────────────────
            var failedMsgs = failures.Where(f => !string.IsNullOrEmpty(f)).ToList();
            foreach (var fm in failedMsgs)
                AddRuntimeMessage(GH_RuntimeMessageLevel.Warning, fm);

            // ─── Set outputs ─────────────────────────────────────────────
            DA.SetDataList(0, slabThicknesses);
            DA.SetDataList(1, colSections);
            DA.SetDataList(2, colUtils);
            DA.SetDataList(3, beamSections);
            DA.SetDataList(4, beamUtils);
            DA.SetData(5, allPass);
            DA.SetData(6, critRatio);
            DA.SetData(7, critElement);
            DA.SetData(8, summaryText);
            DA.SetDataList(9, failures);
        }
    }
}
