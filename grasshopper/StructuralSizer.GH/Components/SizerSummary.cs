using System;
using Grasshopper.Kernel;
using Newtonsoft.Json.Linq;

namespace StructuralSizer.GH.Components
{
    /// <summary>
    /// High-level design summary statistics.
    /// Provides quick overview of design status and material quantities.
    /// </summary>
    public class SizerSummary : GH_Component
    {
        public SizerSummary()
            : base("Sizer Summary",
                   "SizerSum",
                   "High-level design summary statistics",
                   "Menegroth", "Statistics")
        { }

        public override Guid ComponentGuid =>
            new Guid("A1B2C3D4-AAAA-BBBB-CCCC-DDDDEEEE0006");

        protected override void RegisterInputParams(GH_InputParamManager pManager)
        {
            pManager.AddTextParameter("JSON", "J", "JSON response from SizerRun", GH_ParamAccess.item);
        }

        protected override void RegisterOutputParams(GH_OutputParamManager pManager)
        {
            pManager.AddBooleanParameter("All Pass", "AP", "All elements pass design checks", GH_ParamAccess.item);
            pManager.AddNumberParameter("Critical Ratio", "CR", "Critical utilization ratio", GH_ParamAccess.item);
            pManager.AddTextParameter("Critical Element", "CE", "Critical element description", GH_ParamAccess.item);
            pManager.AddNumberParameter("Concrete Volume", "CV", "Concrete volume (ft³)", GH_ParamAccess.item);
            pManager.AddNumberParameter("Steel Weight", "SW", "Steel weight (lb)", GH_ParamAccess.item);
            pManager.AddNumberParameter("Rebar Weight", "RW", "Rebar weight (lb)", GH_ParamAccess.item);
            pManager.AddNumberParameter("Embodied Carbon", "EC", "Embodied carbon (kg CO₂e)", GH_ParamAccess.item);
            pManager.AddNumberParameter("Compute Time", "CT", "Compute time (seconds)", GH_ParamAccess.item);
        }

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
                AddRuntimeMessage(GH_RuntimeMessageLevel.Error, $"Failed to parse JSON: {ex.Message}");
                return;
            }

            string status = root["status"]?.ToString() ?? "unknown";
            if (status == "error")
            {
                AddRuntimeMessage(GH_RuntimeMessageLevel.Error, root["message"]?.ToString() ?? "Unknown error");
                return;
            }

            var summary = root["summary"];
            if (summary == null)
            {
                AddRuntimeMessage(GH_RuntimeMessageLevel.Warning, "No summary data found");
                return;
            }

            DA.SetData(0, summary["all_pass"]?.ToObject<bool>() ?? true);
            DA.SetData(1, summary["critical_ratio"]?.ToObject<double>() ?? 0.0);
            DA.SetData(2, summary["critical_element"]?.ToString() ?? "");
            DA.SetData(3, summary["concrete_volume_ft3"]?.ToObject<double>() ?? 0.0);
            DA.SetData(4, summary["steel_weight_lb"]?.ToObject<double>() ?? 0.0);
            DA.SetData(5, summary["rebar_weight_lb"]?.ToObject<double>() ?? 0.0);
            DA.SetData(6, summary["embodied_carbon_kgCO2e"]?.ToObject<double>() ?? 0.0);
            DA.SetData(7, root["compute_time_s"]?.ToObject<double>() ?? 0.0);
        }
    }
}
