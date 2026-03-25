using System;
using System.Collections.Generic;
using System.Threading;
using Grasshopper.Kernel;
using Menegroth.GH.Config;
using Menegroth.GH.Helpers;
using Menegroth.GH.Types;
using Menegroth.GH.UI;
using Newtonsoft.Json.Linq;

namespace Menegroth.GH.Components
{
    /// <summary>
    /// Opens an LLM chat dialog for conversational analysis of design results.
    ///
    /// On each open the component:
    /// 1. Fetches GET /chat/history to resume any prior results conversation for the same geometry.
    /// 2. Fires an auto-analysis on first open (no history) so the agent immediately
    ///    summarizes failures and governing limit states.
    ///
    /// The assistant can explain check failures, demand/capacity ratios, and suggest
    /// parameter changes to improve the design. Proposed parameter patches are surfaced
    /// through the dialog's Apply/Reject UI.
    /// </summary>
    public class ResultsAssistant : GH_Component
    {
        private string _lastTranscript = "";

        public ResultsAssistant()
            : base("Results Assistant",
                   "ResultsAssist",
                   "Chat with an AI assistant to understand your design results",
                   "Menegroth", MenegrothSubcategories.Assistant)
        { }

        public override Guid ComponentGuid =>
            new Guid("B8F4D2E1-9C50-4B3F-AD62-4E7A1F3C8B90");

        protected override void RegisterInputParams(GH_InputParamManager pManager)
        {
            pManager.AddGenericParameter("Result", "Result",
                "DesignResult from the DesignRun component", GH_ParamAccess.item);
            pManager.AddGenericParameter("Geometry", "Geometry",
                "BuildingGeometry from the GeometryInput component", GH_ParamAccess.item);
            pManager.AddTextParameter("Geometry Summary", "GeoSummary",
                "Geometry summary text (from GeometryInput)", GH_ParamAccess.item, "");
            pManager.AddBooleanParameter("Open", "Open",
                "Set to true to open the chat dialog", GH_ParamAccess.item, false);
        }

        protected override void RegisterOutputParams(GH_OutputParamManager pManager)
        {
            pManager.AddTextParameter("Transcript", "Transcript",
                "Full conversation transcript", GH_ParamAccess.item);
        }

        protected override void SolveInstance(IGH_DataAccess DA)
        {
            DesignResultGoo?    resultGoo = null;
            BuildingGeometryGoo? geoGoo   = null;
            string geoSummary = "";
            bool   open       = false;

            if (!DA.GetData(0, ref resultGoo) || resultGoo?.Value == null)
            {
                AddRuntimeMessage(GH_RuntimeMessageLevel.Warning, "No result connected.");
                DA.SetData(0, "");
                return;
            }
            DA.GetData(1, ref geoGoo);
            DA.GetData(2, ref geoSummary);
            DA.GetData(3, ref open);

            if (!open)
            {
                DA.SetData(0, _lastTranscript);
                return;
            }

            try
            {
                string baseUrl = MenegrothConfig.LastServerUrl;
                using var cts  = new CancellationTokenSource(TimeSpan.FromSeconds(10));

                // Pre-fetch conversation history for this geometry session.
                var historyTask = DesignRunHttpClient.GetChatHistoryAsync(
                    baseUrl,
                    ComputeSessionId(geoSummary),
                    cts.Token);

                List<JObject> history = new List<JObject>();
                try
                {
                    historyTask.Wait(cts.Token);
                    history = historyTask.Result;
                }
                catch { /* non-critical */ }

                var dialog = new ChatDialog(
                    mode:               "results",
                    geometrySummary:    geoSummary,
                    currentParams:      null,
                    result:             resultGoo.Value,
                    applicabilitySchema: null,
                    initialHistory:     history.Count > 0 ? history : null,
                    autoAnalyze:        true);

                dialog.ShowModal();
                _lastTranscript = dialog.Transcript;
            }
            catch (Exception ex)
            {
                AddRuntimeMessage(GH_RuntimeMessageLevel.Error, $"Chat dialog error: {ex.Message}");
            }

            DA.SetData(0, _lastTranscript);
        }

        /// <summary>
        /// Derive the session ID that <see cref="ChatDialog"/> uses internally.
        /// Keying by geometry summary ensures history is tied to the specific geometry.
        /// </summary>
        private static string ComputeSessionId(string? geoSummary)
        {
            if (string.IsNullOrEmpty(geoSummary)) return "";
            using var sha = System.Security.Cryptography.SHA256.Create();
            var bytes = sha.ComputeHash(System.Text.Encoding.UTF8.GetBytes(geoSummary));
            return BitConverter.ToString(bytes).Replace("-", "").Substring(0, 16).ToLowerInvariant();
        }
    }
}
