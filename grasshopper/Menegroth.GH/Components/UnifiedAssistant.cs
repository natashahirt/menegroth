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
    ///
    /// Proposed patches are staged first and only applied when the external
    /// Apply input receives a rising-edge true signal. This keeps DesignRun's
    /// Run input as the only execution control for a full building run.
    /// </summary>
    public class UnifiedAssistant : GH_Component
    {
        private DesignParamsData? _lastAppliedParams;
        private JObject? _pendingProposal;
        private string _lastTranscript = "";
        private string _lastSourceHash = "";
        private bool _prevApply;
        private bool _prevOpen;
        private ChatDialog? _chatDialog;
        private string _chatDialogMode = "";
        private string _chatDialogSessionSeed = "";

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
            pManager.AddGenericParameter("Updated Params", "Params",
                "DesignParamsData after applying accepted assistant patches", GH_ParamAccess.item);
            pManager.AddTextParameter("Pending Patch", "Patch",
                "Latest staged JSON patch from assistant (applied only when Apply rises true)", GH_ParamAccess.item);
            pManager.AddTextParameter("Transcript", "Transcript",
                "Full conversation transcript", GH_ParamAccess.item);
            pManager.AddTextParameter("Phase", "Phase",
                "Assistant phase: pre_result or post_result", GH_ParamAccess.item);
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
                _lastAppliedParams = CloneParams(currentParams);
                _lastSourceHash = currentHash;
            }

            bool hasResult = resultGoo?.Value != null &&
                             !string.Equals(resultGoo.Value.Status, "unknown", StringComparison.OrdinalIgnoreCase);
            string phase = hasResult ? "post_result" : "pre_result";
            string mode = hasResult ? "results" : "design";
            string sessionSeed = hasResult ? BuildResultSessionSeed(resultGoo!.Value) : geometry.ComputeHash();

            bool applyRising = apply && !_prevApply;
            _prevApply = apply;
            bool appliedThisSolve = false;
            bool openRising = open && !_prevOpen;
            _prevOpen = open;

            if (applyRising && _pendingProposal != null)
            {
                var merged = CloneParams(_lastAppliedParams ?? currentParams);
                merged.MergeFromJson(_pendingProposal);
                _lastAppliedParams = merged;
                _pendingProposal = null;
                appliedThisSolve = true;
            }

            if (openRising)
                EnsureDialog(geometry, _lastAppliedParams ?? currentParams, hasResult ? resultGoo!.Value : null, mode, sessionSeed);

            // Keep outputs synced from the live modeless dialog without requiring close.
            SyncDialogState();

            // Canvas UX cue: compact state indicator for phase + patch/apply flow.
            Message = BuildStatusMessage(
                phase: phase,
                hasPendingPatch: _pendingProposal != null && _pendingProposal.Count > 0,
                applySignal: apply,
                applyRising: applyRising,
                appliedThisSolve: appliedThisSolve,
                openSignal: open,
                windowOpen: _chatDialog != null
            );

            DA.SetData(0, new DesignParamsDataGoo(_lastAppliedParams ?? currentParams));
            DA.SetData(1, _pendingProposal?.ToString(Newtonsoft.Json.Formatting.None) ?? "");
            DA.SetData(2, _lastTranscript);
            DA.SetData(3, phase);
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
                {
                    _chatDialog.Close();
                    _chatDialog = null;
                }

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

                _chatDialog = new ChatDialog(
                    mode: mode,
                    geometrySummary: geometrySummary,
                    sessionSeed: sessionSeed,
                    currentParams: currentParams,
                    result: result,
                    applicabilitySchema: applicabilitySchema,
                    initialHistory: history.Count > 0 ? history : null,
                    autoAnalyze: true);
                _chatDialogMode = mode;
                _chatDialogSessionSeed = sessionSeed;

                _chatDialog.Closed += (_, __) =>
                {
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
        }

        private static string BuildResultSessionSeed(DesignResult result)
        {
            if (!string.IsNullOrWhiteSpace(result.GeometryHash))
                return result.GeometryHash;
            if (!string.IsNullOrWhiteSpace(result.RawJson))
                return result.RawJson;
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
            bool windowOpen)
        {
            var parts = new List<string>
            {
                phase == "post_result" ? "post-result" : "pre-result"
            };

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

        /// <summary>
        /// Clone params so upstream input is never mutated.
        /// </summary>
        private static DesignParamsData CloneParams(DesignParamsData src) => new DesignParamsData
        {
            FloorLL                   = src.FloorLL,
            RoofLL                    = src.RoofLL,
            GradeLL                   = src.GradeLL,
            FloorSDL                  = src.FloorSDL,
            RoofSDL                   = src.RoofSDL,
            WallSDL                   = src.WallSDL,
            FloorType                 = src.FloorType,
            AnalysisMethod            = src.AnalysisMethod,
            DeflectionLimit           = src.DeflectionLimit,
            PunchingStrategy          = src.PunchingStrategy,
            VaultLambda               = src.VaultLambda,
            MaxIterations             = src.MaxIterations,
            FeaTargetEdgeM            = src.FeaTargetEdgeM,
            Concrete                  = src.Concrete,
            Rebar                     = src.Rebar,
            Steel                     = src.Steel,
            ColumnType                = src.ColumnType,
            ColumnCatalog             = src.ColumnCatalog,
            ColumnSizingStrategy      = src.ColumnSizingStrategy,
            MipTimeLimitSec           = src.MipTimeLimitSec,
            BeamType                  = src.BeamType,
            BeamCatalog               = src.BeamCatalog,
            BeamSizingStrategy        = src.BeamSizingStrategy,
            SteelWBounds              = src.SteelWBounds,
            SteelHSSBounds            = src.SteelHSSBounds,
            RCRectBounds              = src.RCRectBounds,
            RCCircularBounds          = src.RCCircularBounds,
            PixelFrameFcPreset        = src.PixelFrameFcPreset,
            PixelFrameFcMinKsi        = src.PixelFrameFcMinKsi,
            PixelFrameFcMaxKsi        = src.PixelFrameFcMaxKsi,
            PixelFrameFcResolutionKsi = src.PixelFrameFcResolutionKsi,
            FireRating                = src.FireRating,
            OptimizeFor               = src.OptimizeFor,
            SizeFoundations           = src.SizeFoundations,
            FoundationSoil            = src.FoundationSoil,
            FoundationConcrete        = src.FoundationConcrete,
            FoundationStrategy        = src.FoundationStrategy,
            MatCoverageThreshold      = src.MatCoverageThreshold,
            UnitSystem                = src.UnitSystem,
            ScopedSlabOverrides       = src.ScopedSlabOverrides?.Select(s => s.Clone()).ToList() ?? new List<SlabParamsData>(),
        };

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
