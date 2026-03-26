using System;
using System.Collections.Generic;
using System.Text;
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
    /// Opens an LLM chat dialog for conversational design parameter selection.
    ///
    /// On each open the component:
    /// 1. Fetches GET /schema/applicability to display a method-eligibility banner.
    /// 2. Fetches GET /chat/history to resume any prior conversation for the same geometry.
    /// 3. Fires an auto-analysis on first open (no history) so the agent immediately
    ///    orients the user to the design space.
    ///
    /// Proposed parameter patches from the agent are shown with an Apply/Reject UI
    /// inside the dialog, and the accepted patch is output as updated params.
    /// </summary>
    public class DesignAssistant : GH_Component
    {
        private DesignParamsData? _lastProposed;

        public DesignAssistant()
            : base("Design Assistant",
                   "DesignAssist",
                   "Chat with an AI assistant to select appropriate design parameters",
                   "Menegroth", MenegrothSubcategories.Assistant)
        { }

        public override Guid ComponentGuid =>
            new Guid("A7E3C1D0-8B4F-4A2E-9C51-3D6F0E2B7A89");

        protected override void RegisterInputParams(GH_InputParamManager pManager)
        {
            pManager.AddGenericParameter("Geometry", "Geometry",
                "BuildingGeometry from the GeometryInput component", GH_ParamAccess.item);
            pManager.AddGenericParameter("Params", "Params",
                "Current DesignParamsData", GH_ParamAccess.item);
            pManager.AddBooleanParameter("Open", "Open",
                "Set to true to open the chat dialog", GH_ParamAccess.item, false);
        }

        protected override void RegisterOutputParams(GH_OutputParamManager pManager)
        {
            pManager.AddGenericParameter("Updated Params", "Params",
                "DesignParamsData with proposed changes merged in (or original if no changes)",
                GH_ParamAccess.item);
            pManager.AddTextParameter("Transcript", "Transcript",
                "Full conversation transcript", GH_ParamAccess.item);
        }

        protected override void SolveInstance(IGH_DataAccess DA)
        {
            BuildingGeometryGoo? geoGoo    = null;
            DesignParamsDataGoo? paramsGoo = null;
            bool    open       = false;

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
            DA.GetData(2, ref open);

            var currentParams = paramsGoo.Value;
            var geometry = geoGoo.Value;
            string geoSummary = BuildAssistantGeometrySummary(geometry);
            string sessionSeed = geometry.ComputeHash();

            if (!open)
            {
                DA.SetData(0, new DesignParamsDataGoo(_lastProposed ?? currentParams));
                DA.SetData(1, "");
                return;
            }

            try
            {
                string baseUrl = MenegrothConfig.LastServerUrl;
                using var cts = new CancellationTokenSource(TimeSpan.FromSeconds(10));

                // Pre-fetch applicability schema and history in parallel.
                var schemaTask  = DesignRunHttpClient.GetApplicabilitySchemaAsync(baseUrl, cts.Token);
                var historyTask = DesignRunHttpClient.GetChatHistoryAsync(
                    baseUrl,
                    ComputeSessionId(sessionSeed),
                    cts.Token);

                // Block briefly — these are cheap endpoints.
                JObject? applicabilitySchema = null;
                List<JObject> history        = new List<JObject>();
                try
                {
                    schemaTask.Wait(cts.Token);
                    historyTask.Wait(cts.Token);
                    applicabilitySchema = schemaTask.Result;
                    history             = historyTask.Result;
                }
                catch
                {
                    // Non-critical: open dialog with defaults if prefetch fails.
                }

                var dialog = new ChatDialog(
                    mode:               "design",
                    geometrySummary:    geoSummary,
                    currentParams:      currentParams,
                    result:             null,
                    sessionSeed:        sessionSeed,
                    applicabilitySchema: applicabilitySchema,
                    initialHistory:     history.Count > 0 ? history : null,
                    autoAnalyze:        true);

                dialog.ShowModal();

                if (dialog.ProposedParams != null)
                {
                    var merged = CloneParams(currentParams);
                    merged.MergeFromJson(dialog.ProposedParams);
                    _lastProposed = merged;
                }
                else
                {
                    _lastProposed = currentParams;
                }

                DA.SetData(0, new DesignParamsDataGoo(_lastProposed));
                DA.SetData(1, dialog.Transcript);
            }
            catch (Exception ex)
            {
                AddRuntimeMessage(GH_RuntimeMessageLevel.Error, $"Chat dialog error: {ex.Message}");
                DA.SetData(0, new DesignParamsDataGoo(currentParams));
                DA.SetData(1, "");
            }
        }

        /// <summary>
        /// Derive the same session ID that <see cref="ChatDialog"/> uses internally,
        /// so history keys are consistent between the prefetch and the dialog.
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
        /// Build a compact geometry context block for the LLM prompt from typed geometry.
        /// Keeps Geometry Summary as an internal context aid rather than a required GH input.
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
        /// Shallow clone via field copy so the original params are not mutated.
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
        };
    }
}
