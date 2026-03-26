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
            bool   open       = false;

            if (!DA.GetData(0, ref resultGoo) || resultGoo?.Value == null)
            {
                AddRuntimeMessage(GH_RuntimeMessageLevel.Warning, "No result connected.");
                DA.SetData(0, "");
                return;
            }
            DA.GetData(1, ref open);

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
                    ComputeSessionId(BuildSessionSeed(resultGoo.Value)),
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
                    geometrySummary:    "",
                    currentParams:      null,
                    result:             resultGoo.Value,
                    sessionSeed:        BuildSessionSeed(resultGoo.Value),
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
        /// Keying by result geometry hash ensures history is tied to one geometry.
        /// </summary>
        private static string ComputeSessionId(string? seed)
        {
            if (string.IsNullOrEmpty(seed)) return "";
            using var sha = System.Security.Cryptography.SHA256.Create();
            var bytes = sha.ComputeHash(System.Text.Encoding.UTF8.GetBytes(seed));
            return BitConverter.ToString(bytes).Replace("-", "").Substring(0, 16).ToLowerInvariant();
        }

        private static string BuildSessionSeed(DesignResult result)
        {
            if (!string.IsNullOrWhiteSpace(result.GeometryHash))
                return result.GeometryHash;
            if (!string.IsNullOrWhiteSpace(result.RawJson))
                return result.RawJson;
            return $"results:{result.Status}:{result.ComputeTime:F3}";
        }
    }
}
