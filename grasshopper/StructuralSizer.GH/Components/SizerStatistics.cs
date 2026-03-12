using System;
using Grasshopper.Kernel;
using Newtonsoft.Json.Linq;

namespace StructuralSizer.GH.Components
{
    /// <summary>
    /// Extract quantitative statistics from design results.
    /// Provides access to detailed data by element type.
    /// </summary>
    public class SizerStatistics : GH_Component
    {
        public SizerStatistics()
            : base("Sizer Statistics",
                   "SizerStats",
                   "Extract quantitative statistics from design results",
                   "Menegroth", "Statistics")
        { }

        public override Guid ComponentGuid =>
            new Guid("A1B2C3D4-AAAA-BBBB-CCCC-DDDDEEEE0004");

        protected override void RegisterInputParams(GH_InputParamManager pManager)
        {
            pManager.AddTextParameter("JSON", "J", "Raw JSON response from SizerRun", GH_ParamAccess.item);
            pManager.AddTextParameter("Data Type", "T", 
                "Data type: 'summary', 'slabs', 'columns', 'beams', 'foundations', or 'all'", 
                GH_ParamAccess.item, "summary");
        }

        protected override void RegisterOutputParams(GH_OutputParamManager pManager)
        {
            pManager.AddTextParameter("JSON Data", "J", "Raw JSON for selected data type", GH_ParamAccess.item);
            pManager.AddBooleanParameter("All Pass", "AP", "All elements pass design checks", GH_ParamAccess.item);
            pManager.AddNumberParameter("Critical Ratio", "CR", "Critical utilization ratio", GH_ParamAccess.item);
            pManager.AddTextParameter("Critical Element", "CE", "Critical element description", GH_ParamAccess.item);
        }

        protected override void SolveInstance(IGH_DataAccess DA)
        {
            string json = "";
            if (!DA.GetData(0, ref json) || string.IsNullOrWhiteSpace(json)) return;

            string dataType = "summary";
            DA.GetData(1, ref dataType);
            dataType = dataType?.ToLower() ?? "summary";

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

            JToken outputData = null;
            switch (dataType)
            {
                case "summary":
                    outputData = root["summary"];
                    break;
                case "slabs":
                    outputData = root["slabs"];
                    break;
                case "columns":
                    outputData = root["columns"];
                    break;
                case "beams":
                    outputData = root["beams"];
                    break;
                case "foundations":
                    outputData = root["foundations"];
                    break;
                case "all":
                    outputData = root;
                    break;
                default:
                    AddRuntimeMessage(GH_RuntimeMessageLevel.Error, 
                        "Data type must be: 'summary', 'slabs', 'columns', 'beams', 'foundations', or 'all'");
                    return;
            }

            var summary = root["summary"];
            bool allPass = summary?["all_pass"]?.ToObject<bool>() ?? true;
            double criticalRatio = summary?["critical_ratio"]?.ToObject<double>() ?? 0.0;
            string criticalElement = summary?["critical_element"]?.ToString() ?? "";

            DA.SetData(0, outputData?.ToString() ?? "{}");
            DA.SetData(1, allPass);
            DA.SetData(2, criticalRatio);
            DA.SetData(3, criticalElement);
        }
    }
}
