using System;
using System.Collections.Generic;
using System.Linq;
using System.Text;
using System.Threading;
using Grasshopper.Kernel;
using Menegroth.GH.Config;
using Menegroth.GH.Helpers;
using Menegroth.GH.Types;
using Menegroth.GH.UI;
using Newtonsoft.Json.Linq;
using Rhino;
using Rhino.UI;

namespace Menegroth.GH.Components
{
    /// <summary>
    /// Unified assistant that supports both pre-result and post-result phases.
    ///
    /// - Pre-result (no DesignResult connected): design-orientation mode.
    /// - Post-result (DesignResult connected): results-diagnosis mode.
    /// When Open is true, switching between these phases closes and reopens the chat so a design
    /// session is never left up after a result arrives (and vice versa).
    ///
    /// Proposed patches are staged first and only applied when the external
    /// Apply input receives a rising-edge true signal. Apply also queues the patch for
    /// <see cref="DesignRun"/> (merged into the wired Design Params on the next Run=true solve).
    /// Do not wire Params History → Design Run Params when Result feeds this component from that Run
    /// (Grasshopper recursive data stream); keep Params on Design Run from Design Params only.
    /// Use List Item on Params History (e.g. last index) to pick a snapshot for panels or replay.
    /// </summary>
    public class UnifiedAssistant : GH_Component
    {
        private const int ParamsHistoryMaxEntries = 50;

        private DesignParamsData? _lastAppliedParams;
        private JObject? _pendingProposal;
        private string _lastTranscript = "";
        private string _lastSourceHash = "";
        private bool _prevApply;
        private bool _prevOpen;
        /// <summary>Prior solve: had a non-unknown DesignResult (post-result vs pre-result).</summary>
        private bool _prevHasResult;
        private ChatDialog? _chatDialog;
        private string _chatDialogMode = "";
        private string _chatDialogSessionSeed = "";
        /// <summary>From chat Apply / Apply &amp; Run — processed next SolveInstance.</summary>
        private JObject? _dialogPatchPending;
        private bool _dialogApplyRunDesign;

        /// <summary>Baseline + each assistant apply (same order as <see cref="_paramsHistoryLabels"/>).</summary>
        private readonly List<DesignParamsData> _paramsHistory = new List<DesignParamsData>();

        private readonly List<string> _paramsHistoryLabels = new List<string>();

        public UnifiedAssistant()
            : base("Unified Assistant",
                   "Assistant",
                   "Single assistant for both pre-result design guidance and post-result diagnostics",
                   "Menegroth", MenegrothSubcategories.Assistant)
        { }

        public override Guid ComponentGuid =>
            new Guid("C1AE9D7F-5A74-4D2C-BE1F-8D21A06F5F32");

        protected override void RegisterInputParams(GH_InputParamManager pManager)
        {
            pManager.AddGenericParameter("Geometry", "Geometry",
                "BuildingGeometry from GeometryInput", GH_ParamAccess.item);
            pManager.AddGenericParameter("Params", "Params",
                "Current DesignParamsData", GH_ParamAccess.item);
            pManager.AddGenericParameter("Result", "Result",
                "Optional DesignResult from DesignRun (leave empty in pre-result phase)", GH_ParamAccess.item);
            pManager.AddBooleanParameter("Apply", "Apply",
                "Rising-edge apply signal: apply the latest staged assistant patch to Params", GH_ParamAccess.item, false);
            pManager.AddBooleanParameter("Open", "Open",
                "Set true to open the chat dialog", GH_ParamAccess.item, false);

            pManager[2].Optional = true;
        }

        protected override void RegisterOutputParams(GH_OutputParamManager pManager)
        {
            pManager.AddGenericParameter("Params History", "History",
                "Baseline from wire, then one entry per assistant apply. Use List Item (e.g. last index) for the current merged params. For Design Run when Result recurses here, use the patch queue + wired Params instead of wiring history.", GH_ParamAccess.list);
            pManager.AddTextParameter("History Labels", "Labels",
                "Parallel labels: Baseline (wire) vs each step. Steps prefer the model’s `_history_label` in the JSON patch; else patch keys.", GH_ParamAccess.list);
            pManager.AddTextParameter("Pending Patch", "Patch",
                "Latest staged JSON patch from assistant (applied only when Apply rises true)", GH_ParamAccess.item);
            pManager.AddTextParameter("Transcript", "Transcript",
                "Full conversation transcript", GH_ParamAccess.item);
        }

        protected override void SolveInstance(IGH_DataAccess DA)
        {
            BuildingGeometryGoo? geoGoo = null;
            DesignParamsDataGoo? paramsGoo = null;
            DesignResultGoo? resultGoo = null;
            bool apply = false;
            bool open = false;

            if (!DA.GetData(0, ref geoGoo) || geoGoo?.Value == null)
            {
                AddRuntimeMessage(GH_RuntimeMessageLevel.Warning, "No geometry connected.");
                return;
            }
            if (!geoGoo.IsValid)
            {
                AddRuntimeMessage(GH_RuntimeMessageLevel.Warning,
                    "Geometry is not valid yet (need at least 4 vertices). Ensure GeometryInput has solved.");
            }
            if (!DA.GetData(1, ref paramsGoo) || paramsGoo?.Value == null)
            {
                AddRuntimeMessage(GH_RuntimeMessageLevel.Warning, "No params connected.");
                return;
            }
            DA.GetData(2, ref resultGoo);
            DA.GetData(3, ref apply);
            DA.GetData(4, ref open);

            var geometry = geoGoo.Value;
            var currentParams = paramsGoo.Value;
            var currentHash = currentParams.ComputeHash();

            // Reset assistant-local applied state if upstream params changed externally.
            if (!string.Equals(_lastSourceHash, currentHash, StringComparison.Ordinal))
            {
                _lastAppliedParams = currentParams.Clone();
                _lastSourceHash = currentHash;
                ResetParamsHistoryFromBaseline(currentParams);
            }

            bool hasResult = resultGoo?.Value != null &&
                             !string.Equals(resultGoo.Value.Status, "unknown", StringComparison.OrdinalIgnoreCase);
            bool resultPhaseChanged = hasResult != _prevHasResult;
            string phase = hasResult ? "post_result" : "pre_result";
            string mode = hasResult ? "results" : "design";
            // Pre-result: include params so the dialog is rebuilt when either geometry or params change
            // (ChatDialog freezes geometry_summary and params at construction; Open often stays true.)
            string sessionSeed = hasResult
                ? $"{BuildResultSessionSeed(resultGoo!.Value)}:{currentParams.ComputeHash()}"
                : $"{geometry.ComputeHash()}:{currentParams.ComputeHash()}";

            bool applyRising = apply && !_prevApply;
            _prevApply = apply;
            bool appliedThisSolve = false;
            bool openRising = open && !_prevOpen;
            _prevOpen = open;

            // Switching between design (no result) and results (or back) must tear down the old dialog so we
            // never keep a "design" window after a result arrives (Close() may not null _chatDialog synchronously).
            if (open && resultPhaseChanged && _chatDialog != null)
                CloseChatDialogSynchronously();

            // Keep the chat window in sync with live geometry/params while Open is true (not only on Open rising edge).
            if (open)
            {
                if (_chatDialog != null &&
                    (!string.Equals(_chatDialogMode, mode, StringComparison.Ordinal) ||
                     !string.Equals(_chatDialogSessionSeed, sessionSeed, StringComparison.Ordinal)))
                {
                    CloseChatDialogSynchronously();
                }

                if (openRising || (_chatDialog == null && open))
                    EnsureDialog(geometry, _lastAppliedParams ?? currentParams, hasResult ? resultGoo!.Value : null, mode, sessionSeed);
            }

            _prevHasResult = hasResult;

            // Staged patch + transcript (must run after EnsureDialog so the chat exists when Open is true).
            SyncDialogState();

            if (_dialogPatchPending != null)
            {
                var p = _dialogPatchPending;
                _dialogPatchPending = null;
                bool runDesign = _dialogApplyRunDesign;
                _dialogApplyRunDesign = false;
                ApplyAssistantPatch(p, currentParams, ref appliedThisSolve, runDesign);
            }
            else if (applyRising && _pendingProposal != null)
            {
                var p = _pendingProposal;
                ApplyAssistantPatch(p, currentParams, ref appliedThisSolve, requestDesignRun: false);
                _chatDialog?.DismissStagedProposedParams();
            }

            // Canvas UX cue: compact state indicator for phase + patch/apply flow.
            Message = BuildStatusMessage(
                phase: phase,
                hasPendingPatch: _pendingProposal != null && _pendingProposal.Count > 0,
                applySignal: apply,
                applyRising: applyRising,
                appliedThisSolve: appliedThisSolve,
                openSignal: open,
                windowOpen: _chatDialog != null,
                resultsLine: hasResult ? BuildResultsStatusLine(resultGoo!.Value) : null
            );

            if (_paramsHistory.Count == 0)
                ResetParamsHistoryFromBaseline(currentParams);

            DA.SetDataList(0, _paramsHistory.Select(p => new DesignParamsDataGoo(p)).ToList());
            DA.SetDataList(1, _paramsHistoryLabels);
            DA.SetData(2, _pendingProposal?.ToString(Newtonsoft.Json.Formatting.None) ?? "");
            DA.SetData(3, _lastTranscript);
        }

        /// <summary>LLM-provided short label in the JSON patch; stripped before merge and queue.</summary>
        private const string HistoryLabelKey = "_history_label";

        private void ApplyAssistantPatch(JObject patch, DesignParamsData currentParams, ref bool appliedThisSolve, bool requestDesignRun)
        {
            var cleaned = StripHistoryLabel(patch, out string? aiLabel);
            MenegrothConfig.QueueAssistantParamsPatch((JObject)cleaned.DeepClone());
            var merged = (_lastAppliedParams ?? currentParams).Clone();
            merged.MergeFromJson(cleaned);
            _lastAppliedParams = merged;
            AppendParamsHistoryAfterApply(merged, cleaned, requestDesignRun, aiLabel);
            _pendingProposal = null;
            appliedThisSolve = true;
            ScheduleExpireDesignRuns();
            if (requestDesignRun)
                MenegrothConfig.RequestDesignRunAfterAssistantPatch();
        }

        /// <summary>Remove <see cref="HistoryLabelKey"/> from a copy; it is not a structural field.</summary>
        private static JObject StripHistoryLabel(JObject patch, out string? label)
        {
            label = null;
            var clone = (JObject)patch.DeepClone();
            if (clone.TryGetValue(HistoryLabelKey, out var tok))
            {
                if (tok.Type == JTokenType.String)
                {
                    var s = tok.ToString()?.Trim();
                    if (!string.IsNullOrEmpty(s))
                        label = s;
                }

                clone.Remove(HistoryLabelKey);
            }

            return clone;
        }

        private void ResetParamsHistoryFromBaseline(DesignParamsData baseline)
        {
            _paramsHistory.Clear();
            _paramsHistoryLabels.Clear();
            _paramsHistory.Add(baseline.Clone());
            _paramsHistoryLabels.Add("Baseline (wire)");
        }

        /// <summary>Record merged params after an assistant apply. Keeps index 0 as baseline; drops oldest assistant rows when over cap.</summary>
        private void AppendParamsHistoryAfterApply(DesignParamsData mergedSnapshot, JObject patch, bool requestDesignRun, string? aiLabel)
        {
            string label = FormatHistoryLabel(aiLabel, patch, requestDesignRun);
            _paramsHistory.Add(mergedSnapshot.Clone());
            _paramsHistoryLabels.Add(label);
            TrimParamsHistory();
        }

        private void TrimParamsHistory()
        {
            while (_paramsHistory.Count > ParamsHistoryMaxEntries && _paramsHistory.Count > 1)
            {
                _paramsHistory.RemoveAt(1);
                _paramsHistoryLabels.RemoveAt(1);
            }
        }

        /// <summary>Prefer LLM <paramref name="aiLabel"/>; otherwise flatten patch keys.</summary>
        private static string FormatHistoryLabel(string? aiLabel, JObject patch, bool requestDesignRun)
        {
            var sb = new StringBuilder();
            sb.Append(DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss"));
            sb.Append(" — ");
            sb.Append(requestDesignRun ? "Apply & Run: " : "Apply: ");
            if (!string.IsNullOrWhiteSpace(aiLabel))
            {
                var s = aiLabel.Trim().Replace("\r", " ").Replace("\n", " ");
                if (s.Length > 80)
                    s = s.Substring(0, 77) + "...";
                sb.Append(s);
            }
            else
                sb.Append(DescribePatchKeys(patch));

            return sb.ToString();
        }

        /// <summary>Flatten top-level and one nested level of JSON keys for labels (fallback when no <see cref="HistoryLabelKey"/>).</summary>
        private static string DescribePatchKeys(JObject? patch)
        {
            if (patch == null || patch.Count == 0)
                return "(empty patch)";

            var parts = new List<string>();
            foreach (var prop in patch.Properties())
            {
                if (string.Equals(prop.Name, HistoryLabelKey, StringComparison.Ordinal))
                    continue;
                if (prop.Value is JObject obj && obj.Count > 0)
                {
                    foreach (var sub in obj.Properties())
                        parts.Add($"{prop.Name}.{sub.Name}");
                }
                else if (prop.Value is JArray arr)
                    parts.Add($"{prop.Name}[n={arr.Count}]");
                else
                    parts.Add(prop.Name);
            }

            return parts.Count == 0 ? "(no mapped keys)" : string.Join(", ", parts);
        }

        /// <summary>
        /// Chat window invoked Apply / Apply &amp; Run — schedule a Grasshopper solution to merge the patch.
        /// </summary>
        private void OnAssistantDialogApplyPatch(JObject patch, bool runDesign)
        {
            _dialogPatchPending = (JObject)patch.DeepClone();
            _dialogApplyRunDesign = runDesign;
            var doc = OnPingDocument();
            if (doc != null)
                doc.ScheduleSolution(MenegrothConfig.ScheduleSolutionIntervalMs, _ => ExpireSolution(false));
            else
                ExpireSolution(false);
        }

        /// <summary>
        /// After Apply, refresh Design Run so a pending assistant patch can merge on the next Run=true solve.
        /// </summary>
        private void ScheduleExpireDesignRuns()
        {
            var doc = OnPingDocument();
            if (doc == null)
                return;
            doc.ScheduleSolution(MenegrothConfig.ScheduleSolutionIntervalMs, d =>
            {
                foreach (var obj in d.Objects)
                {
                    if (obj is DesignRun dr)
                        dr.ExpireSolution(false);
                }
            });
        }

        private void CloseChatDialogSynchronously()
        {
            if (_chatDialog == null)
                return;
            SyncDialogState();
            try
            {
                _chatDialog.Close();
            }
            catch
            {
                // Best-effort; still clear fields so a fresh dialog can open.
            }

            _chatDialog = null;
            _chatDialogMode = "";
            _chatDialogSessionSeed = "";
        }

        private void EnsureDialog(
            BuildingGeometry geometry,
            DesignParamsData currentParams,
            DesignResult? result,
            string mode,
            string sessionSeed)
        {
            try
            {
                // Reuse and foreground existing window when context matches.
                if (_chatDialog != null &&
                    string.Equals(_chatDialogMode, mode, StringComparison.Ordinal) &&
                    string.Equals(_chatDialogSessionSeed, sessionSeed, StringComparison.Ordinal))
                {
                    _chatDialog.BringToFrontAndFocus();
                    return;
                }

                // If context changed, close old window and create a fresh one.
                if (_chatDialog != null)
                    CloseChatDialogSynchronously();

                string baseUrl = MenegrothConfig.LastServerUrl;
                string geometrySummary = BuildAssistantGeometrySummary(geometry);
                string sessionId = ComputeSessionId(sessionSeed);

                using var cts = new CancellationTokenSource(TimeSpan.FromSeconds(10));

                var historyTask = DesignRunHttpClient.GetChatHistoryAsync(baseUrl, sessionId, cts.Token);
                System.Threading.Tasks.Task<JObject?>? schemaTask = null;
                if (result == null)
                    schemaTask = DesignRunHttpClient.GetApplicabilitySchemaAsync(baseUrl, cts.Token);

                List<JObject> history = new List<JObject>();
                JObject? applicabilitySchema = null;
                try
                {
                    historyTask.Wait(cts.Token);
                    history = historyTask.Result;

                    if (schemaTask != null)
                    {
                        schemaTask.Wait(cts.Token);
                        applicabilitySchema = schemaTask.Result;
                    }
                }
                catch
                {
                    // Non-critical; continue with defaults.
                }

                string? resultsSummary = result != null ? BuildAssistantResultsSummary(result) : null;

                _chatDialog = new ChatDialog(
                    mode: mode,
                    geometrySummary: geometrySummary,
                    sessionSeed: sessionSeed,
                    currentParams: currentParams,
                    result: result,
                    applicabilitySchema: applicabilitySchema,
                    initialHistory: history.Count > 0 ? history : null,
                    autoAnalyze: true,
                    resultsSummary: resultsSummary,
                    onApplyPatch: p => OnAssistantDialogApplyPatch(p, runDesign: false),
                    onApplyAndRunPatch: p => OnAssistantDialogApplyPatch(p, runDesign: true));
                _chatDialogMode = mode;
                _chatDialogSessionSeed = sessionSeed;

                var dialogRef = _chatDialog;
                _chatDialog!.Closed += (_, __) =>
                {
                    // Ignore stale close events if we already replaced this window.
                    if (!ReferenceEquals(_chatDialog, dialogRef))
                        return;
                    SyncDialogState();
                    _chatDialog = null;
                    _chatDialogMode = "";
                    _chatDialogSessionSeed = "";
                    ExpireSolution(true);
                };

                // Modeless show: keeps GH canvas interactive and avoids hidden-modal dead-ends.
                var doc = RhinoDoc.ActiveDoc;
                if (doc != null)
                    _chatDialog.Show(doc);
                else
                    _chatDialog.Show();

                _chatDialog.BringToFrontAndFocus();
            }
            catch (Exception ex)
            {
                AddRuntimeMessage(GH_RuntimeMessageLevel.Error, $"Chat dialog error: {ex.Message}");
            }
        }

        private void SyncDialogState()
        {
            if (_chatDialog == null)
                return;

            _lastTranscript = _chatDialog.Transcript;
            if (_chatDialog.ProposedParams != null && _chatDialog.ProposedParams.Count > 0)
                _pendingProposal = (JObject)_chatDialog.ProposedParams.DeepClone();
            else
            {
                var staged = _chatDialog.PeekPendingStagedPatch();
                _pendingProposal = staged != null && staged.Count > 0 ? staged : null;
            }
        }

        /// <summary>
        /// Stable key that changes when a new design result JSON arrives (not just geometry hash).
        /// </summary>
        private static string BuildResultSessionSeed(DesignResult result)
        {
            if (!string.IsNullOrWhiteSpace(result.RawJson))
            {
                using var sha = System.Security.Cryptography.SHA256.Create();
                var bytes = sha.ComputeHash(Encoding.UTF8.GetBytes(result.RawJson));
                return BitConverter.ToString(bytes).Replace("-", "").Substring(0, 32).ToLowerInvariant();
            }
            if (!string.IsNullOrWhiteSpace(result.GeometryHash))
                return result.GeometryHash;
            return $"results:{result.Status}:{result.ComputeTime:F3}";
        }

        /// <summary>
        /// Build short component-message text for canvas-level status visibility.
        /// </summary>
        private static string BuildStatusMessage(
            string phase,
            bool hasPendingPatch,
            bool applySignal,
            bool applyRising,
            bool appliedThisSolve,
            bool openSignal,
            bool windowOpen,
            string? resultsLine = null)
        {
            var parts = new List<string>
            {
                phase == "post_result" ? "post-result" : "pre-result"
            };

            if (!string.IsNullOrEmpty(resultsLine))
                parts.Add(resultsLine);

            if (hasPendingPatch)
                parts.Add("patch pending");
            else
                parts.Add("no patch");

            if (appliedThisSolve)
                parts.Add("applied");
            else if (applyRising && !hasPendingPatch)
                parts.Add("apply(no patch)");
            else if (applySignal)
                parts.Add("apply held");

            if (openSignal)
                parts.Add("open");
            if (windowOpen)
                parts.Add("window");

            return string.Join(" | ", parts);
        }

        /// <summary>
        /// Keep session key derivation consistent with ChatDialog internals.
        /// </summary>
        private static string ComputeSessionId(string? seed)
        {
            if (string.IsNullOrEmpty(seed))
                return "";
            using var sha = System.Security.Cryptography.SHA256.Create();
            var bytes = sha.ComputeHash(System.Text.Encoding.UTF8.GetBytes(seed));
            return BitConverter.ToString(bytes).Replace("-", "").Substring(0, 16).ToLowerInvariant();
        }

        /// <summary>
        /// One-line status for the canvas when a design result is wired in.
        /// </summary>
        private static string BuildResultsStatusLine(DesignResult r)
        {
            if (r.IsError)
                return "result: error";
            return r.AllPass
                ? $"result: pass | U={r.CriticalRatio:F2}"
                : $"result: {r.FailureCount} fail | U={r.CriticalRatio:F2}";
        }

        /// <summary>
        /// Short digest for results mode: shown in the chat and sent with geometry_summary to the API.
        /// </summary>
        private static string BuildAssistantResultsSummary(DesignResult r)
        {
            if (r.IsError)
            {
                return "Design result summary\n" +
                       "────────────────\n" +
                       "Status: error\n" +
                       (string.IsNullOrWhiteSpace(r.ErrorMessage) ? "" : r.ErrorMessage.Trim());
            }

            var sb = new StringBuilder();
            sb.AppendLine("Design result summary");
            sb.AppendLine("────────────────");
            sb.Append("Status: ").Append(r.Status);
            sb.Append("  |  All checks pass: ").AppendLine(r.AllPass ? "yes" : "no");
            sb.Append("Failures: ").Append(r.FailureCount);
            sb.Append("  |  Max utilization: ").Append(r.CriticalRatio.ToString("F3"));
            if (!string.IsNullOrWhiteSpace(r.CriticalElement))
                sb.Append(" (").Append(r.CriticalElement).Append(')');
            sb.AppendLine();
            sb.Append("Slabs: ").Append(r.Slabs.Count)
              .Append("  Columns: ").Append(r.Columns.Count)
              .Append("  Beams: ").Append(r.Beams.Count)
              .Append("  Foundations: ").AppendLine(r.Foundations.Count.ToString());
            if (r.ConcreteVolumeFt3 > 0 || r.SteelWeightLb > 0 || r.RebarWeightLb > 0)
            {
                sb.Append("Concrete: ").Append(r.ConcreteVolumeFt3.ToString("F1")).Append(" ft³");
                sb.Append("  |  Steel: ").Append(r.SteelWeightLb.ToString("F0")).Append(" lb");
                if (r.RebarWeightLb > 0)
                    sb.Append("  |  Rebar: ").Append(r.RebarWeightLb.ToString("F0")).Append(" lb");
                sb.AppendLine();
            }
            if (r.EmbodiedCarbonKgCO2e > 0)
                sb.Append("Embodied carbon (est.): ").AppendLine(r.EmbodiedCarbonKgCO2e.ToString("F0") + " kg CO2e");
            if (r.MaxDisplacementFt > 0)
                sb.Append("Max displacement: ").Append(r.MaxDisplacementFt.ToString("F4")).Append(" ").AppendLine(r.LengthUnit);
            return sb.ToString().TrimEnd();
        }

        /// <summary>
        /// Build compact geometry context text for the assistant prompt.
        /// </summary>
        private static string BuildAssistantGeometrySummary(BuildingGeometry geo)
        {
            int nV = geo.Vertices?.Count ?? 0;
            int nBeam = geo.BeamEdges?.Count ?? 0;
            int nCol = geo.ColumnEdges?.Count ?? 0;
            int nStrut = geo.StrutEdges?.Count ?? 0;
            int nSup = geo.Supports?.Count ?? 0;
            int nFaces = 0;
            if (geo.Faces != null)
            {
                foreach (var kv in geo.Faces)
                    nFaces += kv.Value?.Count ?? 0;
            }

            var sb = new StringBuilder();
            sb.AppendLine("Geometry Summary");
            sb.AppendLine("────────────────");
            sb.Append("Units: ").AppendLine(string.IsNullOrWhiteSpace(geo.Units) ? "unknown" : geo.Units);
            sb.Append("Mode: ").AppendLine(geo.GeometryIsCenterline ? "Centerline" : "Reference (columns offset)");
            sb.Append("Structure: ")
              .Append(nV).Append(" vertices, ")
              .Append(nBeam).Append(" beams, ")
              .Append(nCol).Append(" columns, ")
              .Append(nStrut).Append(" struts, ")
              .Append(nSup).Append(" supports, ")
              .Append(nFaces).AppendLine(" faces");
            return sb.ToString();
        }

        public override void RemovedFromDocument(GH_Document document)
        {
            try
            {
                if (_chatDialog != null)
                    _chatDialog.Close();
            }
            catch
            {
                // Best-effort cleanup.
            }
            finally
            {
                _chatDialog = null;
                _chatDialogMode = "";
                _chatDialogSessionSeed = "";
            }

            base.RemovedFromDocument(document);
        }
    }
}
