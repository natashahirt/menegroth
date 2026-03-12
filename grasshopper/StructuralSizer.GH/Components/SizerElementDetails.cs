using System;
using System.Collections.Generic;
using System.Linq;
using Grasshopper.Kernel;
using Newtonsoft.Json.Linq;

namespace StructuralSizer.GH.Components
{
    /// <summary>
    /// Detailed breakdown by element type.
    /// Provides per-element statistics with filtering options.
    /// </summary>
    public class SizerElementDetails : GH_Component
    {
        public SizerElementDetails()
            : base("Sizer Element Details",
                   "SizerDetails",
                   "Detailed breakdown by element type",
                   "Menegroth", "Statistics")
        { }

        public override Guid ComponentGuid =>
            new Guid("A1B2C3D4-AAAA-BBBB-CCCC-DDDDEEEE0005");

        protected override void RegisterInputParams(GH_InputParamManager pManager)
        {
            pManager.AddTextParameter("JSON", "J", "JSON response from SizerRun", GH_ParamAccess.item);
            pManager.AddTextParameter("Type", "T", 
                "Element type: 'slabs', 'columns', 'beams', or 'foundations'", 
                GH_ParamAccess.item);
            pManager.AddTextParameter("Filter", "F", 
                "Filter: 'all', 'passing', or 'failing'", 
                GH_ParamAccess.item, "all");
        }

        protected override void RegisterOutputParams(GH_OutputParamManager pManager)
        {
            pManager.AddIntegerParameter("IDs", "ID", "Element IDs", GH_ParamAccess.list);
            pManager.AddNumberParameter("Ratios", "R", "Utilization ratios", GH_ParamAccess.list);
            pManager.AddBooleanParameter("Pass", "P", "Pass/fail status", GH_ParamAccess.list);
            pManager.AddTextParameter("Sections", "S", "Section names/details", GH_ParamAccess.list);
            pManager.AddTextParameter("Details", "D", "Full JSON details for all elements", GH_ParamAccess.item);
        }

        protected override void SolveInstance(IGH_DataAccess DA)
        {
            string json = "";
            if (!DA.GetData(0, ref json) || string.IsNullOrWhiteSpace(json)) return;

            string elemType = "";
            DA.GetData(1, ref elemType);
            elemType = elemType?.ToLower() ?? "";

            string filter = "all";
            DA.GetData(2, ref filter);
            filter = filter?.ToLower() ?? "all";

            JObject root;
            try
            {
                root = JObject.Parse(json);
            }
            catch (Exception ex)
            {
                AddRuntimeMessage(GH_RuntimeMessageLevel.Error, $"Failed to parse JSON: {ex.Message}");
                return;
            }

            string status = root["status"]?.ToString() ?? "unknown";
            if (status == "error")
            {
                AddRuntimeMessage(GH_RuntimeMessageLevel.Error, root["message"]?.ToString() ?? "Unknown error");
                return;
            }

            JArray elements = null;
            Func<JToken, double> getRatio = null;
            Func<JToken, bool> getOk = null;
            Func<JToken, string> getSection = null;

            switch (elemType)
            {
                case "slabs":
                    elements = root["slabs"] as JArray;
                    getRatio = (e) => Math.Max(
                        e["deflection_ratio"]?.ToObject<double>() ?? 0.0,
                        e["punching_max_ratio"]?.ToObject<double>() ?? 0.0);
                    getOk = (e) => (e["deflection_ok"]?.ToObject<bool>() ?? true) && 
                                   (e["punching_ok"]?.ToObject<bool>() ?? true);
                    getSection = (e) => $"t={e["thickness_in"]?.ToObject<double>() ?? 0.0:F2}\"";
                    break;
                case "columns":
                    elements = root["columns"] as JArray;
                    getRatio = (e) => Math.Max(
                        e["axial_ratio"]?.ToObject<double>() ?? 0.0,
                        e["interaction_ratio"]?.ToObject<double>() ?? 0.0);
                    getOk = (e) => e["ok"]?.ToObject<bool>() ?? true;
                    getSection = (e) => e["section"]?.ToString() ?? "";
                    break;
                case "beams":
                    elements = root["beams"] as JArray;
                    getRatio = (e) => Math.Max(
                        e["flexure_ratio"]?.ToObject<double>() ?? 0.0,
                        e["shear_ratio"]?.ToObject<double>() ?? 0.0);
                    getOk = (e) => e["ok"]?.ToObject<bool>() ?? true;
                    getSection = (e) => e["section"]?.ToString() ?? "";
                    break;
                case "foundations":
                    elements = root["foundations"] as JArray;
                    getRatio = (e) => e["bearing_ratio"]?.ToObject<double>() ?? 0.0;
                    getOk = (e) => e["ok"]?.ToObject<bool>() ?? true;
                    getSection = (e) => $"{e["length_ft"]?.ToObject<double>() ?? 0.0:F1}' x {e["width_ft"]?.ToObject<double>() ?? 0.0:F1}'";
                    break;
                default:
                    AddRuntimeMessage(GH_RuntimeMessageLevel.Error, 
                        "Type must be: 'slabs', 'columns', 'beams', or 'foundations'");
                    return;
            }

            if (elements == null)
            {
                AddRuntimeMessage(GH_RuntimeMessageLevel.Warning, $"No {elemType} data found");
                return;
            }

            var ids = new List<int>();
            var ratios = new List<double>();
            var pass = new List<bool>();
            var sections = new List<string>();

            foreach (var elem in elements)
            {
                int id = elem["id"]?.ToObject<int>() ?? 0;
                double ratio = getRatio(elem);
                bool ok = getOk(elem);
                string section = getSection(elem);

                if (filter == "all" || 
                    (filter == "passing" && ok) || 
                    (filter == "failing" && !ok))
                {
                    ids.Add(id);
                    ratios.Add(ratio);
                    pass.Add(ok);
                    sections.Add(section);
                }
            }

            DA.SetDataList(0, ids);
            DA.SetDataList(1, ratios);
            DA.SetDataList(2, pass);
            DA.SetDataList(3, sections);
            DA.SetData(4, elements.ToString());
        }
    }
}
