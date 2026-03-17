using System;
using System.Collections.Generic;
using System.Drawing;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;
using System.Windows.Forms;
using Grasshopper.Kernel;
using Grasshopper.Kernel.Types;
using Newtonsoft.Json.Linq;
using Rhino.Geometry;
using Menegroth.GH.Config;
using Menegroth.GH.Helpers;
using Menegroth.GH.Types;

namespace Menegroth.GH.Components
{
    /// <summary>
    /// Visualizes structural design geometry with optional deflection and coloring.
    /// Uses input-level dropdown parameters for Mode and Color By selection.
    /// </summary>
    public class Visualization : GH_Component
    {
        private const int DEFLECTION_GLOBAL = 0;
        private const int DEFLECTION_LOCAL = 1;
        private const int DEFLECTION_NONE = 2;

        private const int MODE_SIZED = 0;
        private const int MODE_ANALYTICAL = 1;

        private const int COLOR_NONE = 0;
        private const int COLOR_UTILIZATION = 1;
        private const int COLOR_DEFLECTION = 2;
        private const int COLOR_MATERIAL = 3;
        // Analytical sub-modes: slabs
        private const int COLOR_SLAB_BENDING = 10;
        private const int COLOR_SLAB_MEMBRANE = 11;
        private const int COLOR_SLAB_SHEAR = 12;
        private const int COLOR_SLAB_VON_MISES = 13;
        private const int COLOR_SLAB_SURFACE_STRESS = 14;
        // Analytical sub-modes: frames
        private const int COLOR_FRAME_AXIAL = 20;
        private const int COLOR_FRAME_MOMENT = 21;
        private const int COLOR_FRAME_SHEAR = 22;

        private static bool IsValidAnalyticalSlab(int value) =>
            value >= COLOR_SLAB_BENDING && value <= COLOR_SLAB_SURFACE_STRESS;

        private static bool IsValidAnalyticalBeam(int value) =>
            value >= COLOR_FRAME_AXIAL && value <= COLOR_FRAME_SHEAR;

        private static bool IsValidAnalyticalColumn(int value) =>
            value >= COLOR_FRAME_AXIAL && value <= COLOR_FRAME_SHEAR;

        /// <summary>
        /// Global analytical maxima for slab color normalization, bundled to avoid
        /// long parameter chains through slab helper methods.
        /// </summary>
        private readonly struct SlabAnalyticalMaxima
        {
            public readonly double Bending;
            public readonly double Membrane;
            public readonly double Shear;
            public readonly double VonMises;
            public readonly double SurfaceStress;

            public SlabAnalyticalMaxima(double bending, double membrane, double shear,
                double vonMises, double surfaceStress)
            {
                Bending = bending;
                Membrane = membrane;
                Shear = shear;
                VonMises = vonMises;
                SurfaceStress = surfaceStress;
            }
        }

        private bool _useInternalPreview = true;
        private bool _showOriginal = true;
        private bool _showSlabs = true;
        private bool _showBeams = true;
        private bool _showColumns = true;
        private bool _showFoundations = true;
        private int _deflection = DEFLECTION_GLOBAL;
        private int _mode = MODE_SIZED;
        private int _colorBy = COLOR_UTILIZATION;
        private int _analyticalSlab = COLOR_NONE;
        private int _analyticalBeam = COLOR_NONE;
        private int _analyticalColumn = COLOR_NONE;
        private bool _beamVisibilityInitialized = false;
        private readonly List<Curve> _previewColumnCurves = new List<Curve>();
        private readonly List<Color> _previewColumnColors = new List<Color>();
        private readonly List<Curve> _previewBeamCurves = new List<Curve>();
        private readonly List<Color> _previewBeamColors = new List<Color>();
        private readonly List<Curve> _previewOriginalCurves = new List<Curve>();
        private readonly List<Mesh> _previewShadedMeshes = new List<Mesh>();
        private readonly List<Color> _previewShadedColors = new List<Color>();
        private readonly List<bool> _previewShadedUseVertexColors = new List<bool>();
        private readonly List<Rhino.Display.DisplayMaterial> _previewShadedMaterials = new List<Rhino.Display.DisplayMaterial>();

        // ─── Mesh rebuild async state ────────────────────────────────────
        private enum RebuildState { Idle, Running, Done, Error }
        private RebuildState _rebuildState = RebuildState.Idle;
        private double _lastMeshEdgeM = 0;
        private JToken _pendingVisualization = null;
        private string _rebuildError = null;
        private CancellationTokenSource _rebuildCts = null;

        public Visualization()
            : base("Visualization",
                   "Visualization",
                   "Visualize structural design with geometry, deflections, and color mapping",
                   "Menegroth", " Results")
        { }

        public override Guid ComponentGuid =>
            new Guid("E7D94B2A-6C31-4D89-AF1E-2B8A3C5D7E9F");

        protected override void AppendAdditionalComponentMenuItems(ToolStripDropDown menu)
        {
            base.AppendAdditionalComponentMenuItems(menu);
            Menu_AppendSeparator(menu);

            Menu_AppendItem(menu, "Use Internal Preview", (s, e) =>
            {
                _useInternalPreview = !_useInternalPreview;
                ExpirePreview(true);
                ExpireSolution(true);
            }, true, _useInternalPreview);

            var showMenu = new ToolStripMenuItem("Show");
            showMenu.DropDownItems.Add(new ToolStripMenuItem("Original geometry", null, (s, e) =>
            {
                _showOriginal = !_showOriginal;
                ExpirePreview(true);
                ExpireSolution(true);
            }) { Checked = _showOriginal });
            showMenu.DropDownItems.Add(new ToolStripMenuItem("Beams", null, (s, e) =>
            {
                _showBeams = !_showBeams;
                _beamVisibilityInitialized = true;
                ExpirePreview(true);
                ExpireSolution(true);
            }) { Checked = _showBeams });
            showMenu.DropDownItems.Add(new ToolStripMenuItem("Columns", null, (s, e) =>
            {
                _showColumns = !_showColumns;
                ExpirePreview(true);
                ExpireSolution(true);
            }) { Checked = _showColumns });
            showMenu.DropDownItems.Add(new ToolStripMenuItem("Slabs", null, (s, e) =>
            {
                _showSlabs = !_showSlabs;
                ExpirePreview(true);
                ExpireSolution(true);
            }) { Checked = _showSlabs });
            showMenu.DropDownItems.Add(new ToolStripMenuItem("Foundations", null, (s, e) =>
            {
                _showFoundations = !_showFoundations;
                ExpirePreview(true);
                ExpireSolution(true);
            }) { Checked = _showFoundations });
            menu.Items.Add(showMenu);

            menu.Items.Add(new ToolStripSeparator());

            var modeMenu = new ToolStripMenuItem("Mode");
            modeMenu.DropDownItems.Add(CreateCheckedMenuItem("Sized", MODE_SIZED, v => _mode = v, () => _mode));
            modeMenu.DropDownItems.Add(CreateCheckedMenuItem("Analytical", MODE_ANALYTICAL, v => _mode = v, () => _mode));
            menu.Items.Add(modeMenu);

            var deflectionMenu = new ToolStripMenuItem("Deflection");
            deflectionMenu.DropDownItems.Add(CreateCheckedMenuItem("None", DEFLECTION_NONE, v => _deflection = v, () => _deflection));
            deflectionMenu.DropDownItems.Add(CreateCheckedMenuItem("Local", DEFLECTION_LOCAL, v => _deflection = v, () => _deflection));
            deflectionMenu.DropDownItems.Add(CreateCheckedMenuItem("Global", DEFLECTION_GLOBAL, v => _deflection = v, () => _deflection));
            menu.Items.Add(deflectionMenu);

            var colorMenu = new ToolStripMenuItem("Color By");
            colorMenu.DropDownItems.Add(CreateCheckedMenuItem("None", COLOR_NONE, v => _colorBy = v, () => _colorBy));
            colorMenu.DropDownItems.Add(CreateCheckedMenuItem("Material", COLOR_MATERIAL, v => _colorBy = v, () => _colorBy));
            colorMenu.DropDownItems.Add(CreateCheckedMenuItem("Utilization", COLOR_UTILIZATION, v => _colorBy = v, () => _colorBy));
            colorMenu.DropDownItems.Add(CreateCheckedMenuItem("Deflection", COLOR_DEFLECTION, v => _colorBy = v, () => _colorBy));
            colorMenu.DropDownItems.Add(new ToolStripSeparator());
            var beamMenu = new ToolStripMenuItem("Beam");
            beamMenu.DropDownItems.Add(CreateAnalyticalMenuItem("Axial Force", COLOR_FRAME_AXIAL, v => _analyticalBeam = v, () => _analyticalBeam));
            beamMenu.DropDownItems.Add(CreateAnalyticalMenuItem("Moment", COLOR_FRAME_MOMENT, v => _analyticalBeam = v, () => _analyticalBeam));
            beamMenu.DropDownItems.Add(CreateAnalyticalMenuItem("Shear", COLOR_FRAME_SHEAR, v => _analyticalBeam = v, () => _analyticalBeam));
            colorMenu.DropDownItems.Add(beamMenu);
            var columnMenu = new ToolStripMenuItem("Column");
            columnMenu.DropDownItems.Add(CreateAnalyticalMenuItem("Axial Force", COLOR_FRAME_AXIAL, v => _analyticalColumn = v, () => _analyticalColumn));
            columnMenu.DropDownItems.Add(CreateAnalyticalMenuItem("Moment", COLOR_FRAME_MOMENT, v => _analyticalColumn = v, () => _analyticalColumn));
            columnMenu.DropDownItems.Add(CreateAnalyticalMenuItem("Shear", COLOR_FRAME_SHEAR, v => _analyticalColumn = v, () => _analyticalColumn));
            colorMenu.DropDownItems.Add(columnMenu);
            var slabMenu = new ToolStripMenuItem("Slab");
            slabMenu.DropDownItems.Add(CreateAnalyticalMenuItem("Bending Moment", COLOR_SLAB_BENDING, v => _analyticalSlab = v, () => _analyticalSlab));
            slabMenu.DropDownItems.Add(CreateAnalyticalMenuItem("Membrane Force", COLOR_SLAB_MEMBRANE, v => _analyticalSlab = v, () => _analyticalSlab));
            slabMenu.DropDownItems.Add(CreateAnalyticalMenuItem("Shear Force", COLOR_SLAB_SHEAR, v => _analyticalSlab = v, () => _analyticalSlab));
            slabMenu.DropDownItems.Add(CreateAnalyticalMenuItem("Von Mises", COLOR_SLAB_VON_MISES, v => _analyticalSlab = v, () => _analyticalSlab));
            slabMenu.DropDownItems.Add(CreateAnalyticalMenuItem("Surface Stress", COLOR_SLAB_SURFACE_STRESS, v => _analyticalSlab = v, () => _analyticalSlab));
            colorMenu.DropDownItems.Add(slabMenu);
            menu.Items.Add(colorMenu);
        }

        /// <summary>
        /// Create a checked menu item that sets an int field and refreshes the component.
        /// </summary>
        private ToolStripMenuItem CreateCheckedMenuItem(string label, int value,
            Action<int> setter, Func<int> getter)
        {
            var item = new ToolStripMenuItem(label, null, (s, e) =>
            {
                setter(value);
                ExpirePreview(true);
                ExpireSolution(true);
            });
            item.Checked = getter() == value;
            return item;
        }

        /// <summary>
        /// Create a menu item for element-specific color (Beam/Column/Slab). Clicking the selected
        /// option again clears the selection (COLOR_NONE) so the global Color By is used.
        /// </summary>
        private ToolStripMenuItem CreateAnalyticalMenuItem(string label, int value,
            Action<int> setter, Func<int> getter)
        {
            var item = new ToolStripMenuItem(label, null, (s, e) =>
            {
                int current = getter();
                setter(current == value ? COLOR_NONE : value);
                ExpirePreview(true);
                ExpireSolution(true);
            });
            item.Checked = getter() == value;
            return item;
        }

        public override bool Write(GH_IO.Serialization.GH_IWriter writer)
        {
            writer.SetBoolean("UseInternalPreview", _useInternalPreview);
            writer.SetBoolean("ShowOriginal", _showOriginal);
            writer.SetBoolean("ShowSlabs", _showSlabs);
            writer.SetBoolean("ShowBeams", _showBeams);
            writer.SetBoolean("ShowColumns", _showColumns);
            writer.SetBoolean("ShowFoundations", _showFoundations);
            writer.SetInt32("Deflection", _deflection);
            writer.SetInt32("Mode", _mode);
            writer.SetBoolean("BeamVisibilityInitialized", _beamVisibilityInitialized);
            writer.SetInt32("ColorBy", _colorBy);
            writer.SetInt32("AnalyticalSlab", _analyticalSlab);
            writer.SetInt32("AnalyticalBeam", _analyticalBeam);
            writer.SetInt32("AnalyticalColumn", _analyticalColumn);
            return base.Write(writer);
        }

        public override bool Read(GH_IO.Serialization.GH_IReader reader)
        {
            if (reader.ItemExists("UseInternalPreview"))
                _useInternalPreview = reader.GetBoolean("UseInternalPreview");
            if (reader.ItemExists("ShowOriginal"))
                _showOriginal = reader.GetBoolean("ShowOriginal");
            if (reader.ItemExists("ShowSlabs"))
                _showSlabs = reader.GetBoolean("ShowSlabs");
            if (reader.ItemExists("ShowBeams"))
                _showBeams = reader.GetBoolean("ShowBeams");
            if (reader.ItemExists("ShowColumns"))
                _showColumns = reader.GetBoolean("ShowColumns");
            if (reader.ItemExists("ShowFoundations"))
                _showFoundations = reader.GetBoolean("ShowFoundations");

            // Deflection + Mode: prefer current keys, fall back to legacy encoding
            if (reader.ItemExists("Deflection"))
                _deflection = reader.GetInt32("Deflection");
            else if (reader.ItemExists("Mode"))
            {
                // Legacy: Mode used to encode deflection (0=Global, 1=Local, 2=None)
                int m = reader.GetInt32("Mode");
                _deflection = m == 2 ? DEFLECTION_NONE : m == 1 ? DEFLECTION_LOCAL : DEFLECTION_GLOBAL;
            }

            if (reader.ItemExists("Mode") && reader.ItemExists("Deflection"))
                _mode = reader.GetInt32("Mode");
            else if (reader.ItemExists("ShowVolumes"))
                _mode = reader.GetBoolean("ShowVolumes") ? MODE_SIZED : MODE_ANALYTICAL;

            if (reader.ItemExists("BeamVisibilityInitialized"))
                _beamVisibilityInitialized = reader.GetBoolean("BeamVisibilityInitialized");
            else if (reader.ItemExists("ShowBeams"))
                _beamVisibilityInitialized = true;

            if (reader.ItemExists("ColorBy"))
                _colorBy = reader.GetInt32("ColorBy");
            if (reader.ItemExists("AnalyticalSlab"))
                _analyticalSlab = reader.GetInt32("AnalyticalSlab");

            // Analytical beam/column: prefer split keys, fall back to legacy combined key
            if (reader.ItemExists("AnalyticalBeam"))
                _analyticalBeam = reader.GetInt32("AnalyticalBeam");
            else if (reader.ItemExists("AnalyticalFrame"))
                _analyticalBeam = reader.GetInt32("AnalyticalFrame");

            if (reader.ItemExists("AnalyticalColumn"))
                _analyticalColumn = reader.GetInt32("AnalyticalColumn");
            else if (reader.ItemExists("AnalyticalFrame"))
                _analyticalColumn = reader.GetInt32("AnalyticalFrame");

            return base.Read(reader);
        }

        protected override void RegisterInputParams(GH_InputParamManager pManager)
        {
            pManager.AddGenericParameter("Result", "Result",
                "DesignResult from the DesignRun component", GH_ParamAccess.item);

            pManager.AddNumberParameter("Scale", "Scale",
                "Deflection scale multiplier (0 = no deflection, 1 = auto-suggested, >1 = exaggerated)",
                GH_ParamAccess.item, 1.0);

            pManager.AddNumberParameter("Mesh Edge", "MeshEdge",
                "Target mesh edge length for visualization remeshing. Uses same units as the engineering report (ft or m). " +
                "0 = use server default. Changing triggers a server-side rebuild of the visualization mesh only.",
                GH_ParamAccess.item, 0.0);
        }

        protected override void RegisterOutputParams(GH_OutputParamManager pManager)
        {
            pManager.AddCurveParameter("Beam Curves", "BeamCurves",
                "Beam curves for preview/debug", GH_ParamAccess.list);
            pManager.AddCurveParameter("Column Curves", "ColumnCurves",
                "Column curves for preview/debug", GH_ParamAccess.list);
            pManager.AddGenericParameter("Slab Surfaces", "SlabSurfaces",
                "Slab top-surface proxies for preview/debug (Brep/Mesh)", GH_ParamAccess.list);
            pManager.AddGenericParameter("Beam Geometry", "BeamGeometry",
                "Beam section geometry as Meshes (faster rendering)", GH_ParamAccess.list);
            pManager.AddGenericParameter("Column Geometry", "ColumnGeometry",
                "Column section geometry as Meshes (faster rendering)", GH_ParamAccess.list);
            pManager.AddGenericParameter("Slab Geometry", "SlabGeometry",
                "Slab geometry only (Mesh for all modes)", GH_ParamAccess.list);
            pManager.AddGenericParameter("Foundation Geometry", "FoundationGeometry",
                "Foundation geometry only (Mesh)", GH_ParamAccess.list);
        }

        protected override void SolveInstance(IGH_DataAccess DA)
        {
            DesignResultGoo goo = null;
            if (!DA.GetData(0, ref goo) || goo?.Value == null) return;

            var result = goo.Value;
            if (result.IsError)
            {
                AddRuntimeMessage(GH_RuntimeMessageLevel.Error, result.ErrorMessage);
                return;
            }

            // ─── Mesh edge rebuild ──────────────────────────────────────
            double meshEdgeM = 0.0;
            DA.GetData(2, ref meshEdgeM);

            if (_rebuildState == RebuildState.Done)
            {
                // MeshEdge = 0 means "no change" to structural visualization: keep original, do not apply rebuild.
                if (meshEdgeM > 0 && _pendingVisualization != null)
                {
                    result.Visualization = _pendingVisualization;
                    result.SuggestedScaleFactor =
                        _pendingVisualization["suggested_scale_factor"]?.ToObject<double>() ?? 1.0;
                    result.MaxDisplacementFt =
                        _pendingVisualization["max_displacement"]?.ToObject<double>() ?? 0;
                    Message = "Mesh rebuilt";
                }
                _pendingVisualization = null;
                _rebuildState = RebuildState.Idle;
            }
            else if (_rebuildState == RebuildState.Error)
            {
                AddRuntimeMessage(GH_RuntimeMessageLevel.Warning,
                    $"Visualization rebuild failed: {_rebuildError}");
                _rebuildState = RebuildState.Idle;
            }

            string lengthUnit = !string.IsNullOrEmpty(result.DisplayLengthUnit)
                ? result.DisplayLengthUnit
                : result.LengthUnit ?? "ft";
            if (Params.Input.Count > 2)
            {
                var meshParam = Params.Input[2];
                var unitLabel = lengthUnit.Equals("m", StringComparison.OrdinalIgnoreCase) ? "m" : "ft";
                if (meshParam.NickName != $"Mesh Edge ({unitLabel})")
                {
                    meshParam.NickName = $"Mesh Edge ({unitLabel})";
                }
            }
            double targetEdgeM = lengthUnit.Equals("m", StringComparison.OrdinalIgnoreCase)
                ? meshEdgeM
                : meshEdgeM * 0.3048;  // ft → m

            if (meshEdgeM > 0 && Math.Abs(meshEdgeM - _lastMeshEdgeM) > 1e-9
                && _rebuildState != RebuildState.Running)
            {
                _lastMeshEdgeM = meshEdgeM;
                _rebuildCts?.Cancel();
                _rebuildCts = new CancellationTokenSource();
                var ct = _rebuildCts.Token;
                var url = MenegrothConfig.LastServerUrl;
                var edgeVal = targetEdgeM;
                var doc = OnPingDocument();

                _rebuildState = RebuildState.Running;
                Message = "Rebuilding mesh…";

                Task.Run(async () =>
                {
                    try
                    {
                        var json = await DesignRunHttpClient.PostRebuildVisualizationAsync(
                            url, edgeVal, ct);
                        var jobj = JObject.Parse(json);
                        _pendingVisualization = jobj["visualization"];
                        _rebuildState = RebuildState.Done;
                    }
                    catch (OperationCanceledException)
                    {
                        _rebuildState = RebuildState.Idle;
                    }
                    catch (Exception ex)
                    {
                        _rebuildError = ex.Message;
                        _rebuildState = RebuildState.Error;
                    }

                    if (doc != null)
                        doc.ScheduleSolution(MenegrothConfig.ScheduleSolutionIntervalMs,
                            _ => ExpireSolution(false));
                }, ct);
            }

            if (_rebuildState == RebuildState.Running)
            {
                AddRuntimeMessage(GH_RuntimeMessageLevel.Remark,
                    "Rebuilding visualization mesh on server…");
                return;
            }
            // ────────────────────────────────────────────────────────────

            var viz = result.Visualization;
            if (viz == null)
            {
                AddRuntimeMessage(GH_RuntimeMessageLevel.Warning,
                    "No visualization data available. Analysis model may not be built.");
                return;
            }

            // Read inputs with defaults
            int deflectionInt = _deflection;
            int modeInt = _mode;

            double scaleMult = 1.0;
            DA.GetData(1, ref scaleMult);

            bool showOriginal = _showOriginal;

            int colorByInt = _colorBy;
            int analyticalSlab = _analyticalSlab;
            int analyticalBeam = _analyticalBeam;
            int analyticalColumn = _analyticalColumn;

            // Element-specific choice (Beam/Column/Slab) overrides global Color By (Material, Utilization, Deflection) for that element.
            int effectiveColorBySlab = IsValidAnalyticalSlab(analyticalSlab) ? analyticalSlab : colorByInt;
            if (effectiveColorBySlab == COLOR_NONE) effectiveColorBySlab = COLOR_UTILIZATION;

            int effectiveColorByBeam = IsValidAnalyticalBeam(analyticalBeam) ? analyticalBeam : colorByInt;
            if (effectiveColorByBeam == COLOR_NONE) effectiveColorByBeam = COLOR_UTILIZATION;

            int effectiveColorByColumn = IsValidAnalyticalColumn(analyticalColumn) ? analyticalColumn : colorByInt;
            if (effectiveColorByColumn == COLOR_NONE) effectiveColorByColumn = COLOR_UTILIZATION;

            bool isDeflected = deflectionInt == DEFLECTION_GLOBAL || deflectionInt == DEFLECTION_LOCAL;
            bool isLocal = deflectionInt == DEFLECTION_LOCAL;
            bool isOriginalMode = deflectionInt == DEFLECTION_NONE;
            bool showFoundationsEffective = _showFoundations;
            bool isBeamlessSystem = viz["is_beamless_system"]?.ToObject<bool>() ?? false;
            if (isBeamlessSystem && !_beamVisibilityInitialized)
            {
                _showBeams = false;
                _beamVisibilityInitialized = true;
            }
            else if (!isBeamlessSystem && !_beamVisibilityInitialized)
            {
                _beamVisibilityInitialized = true;
            }

            // Extract nodes
            var nodes = new Dictionary<int, (Point3d pos, Vector3d disp, Point3d defPos)>();
            var nodesArray = viz["nodes"] as JArray ?? new JArray();

            foreach (var n in nodesArray)
            {
                int nodeId = n["node_id"]?.ToObject<int>() ?? 0;
                bool isSupport = n["is_support"]?.ToObject<bool>() ?? false;
                var posArr = n["position"]?.ToObject<double[]>() ?? new double[3];
                var dispArr = n["displacement"]?.ToObject<double[]>() ?? new double[3];
                var defPosArr = n["deflected_position"]?.ToObject<double[]>();
                var pos = new Point3d(posArr[0], posArr[1], posArr[2]);
                var defPos = defPosArr != null && defPosArr.Length >= 3
                    ? new Point3d(defPosArr[0], defPosArr[1], defPosArr[2])
                    : pos + new Vector3d(dispArr[0], dispArr[1], dispArr[2]);

                var disp = defPos - pos;
                nodes[nodeId] = (pos, disp, defPos);
            }

            double finalScale = scaleMult * result.SuggestedScaleFactor;
            double maxDisp = result.MaxDisplacementFt;

            // Analytical global maxima for color normalization
            double maxFrameAxial = viz["max_frame_axial"]?.ToObject<double>() ?? 0;
            double maxFrameMoment = viz["max_frame_moment"]?.ToObject<double>() ?? 0;
            double maxFrameShear = viz["max_frame_shear"]?.ToObject<double>() ?? 0;
            var slabMaxima = new SlabAnalyticalMaxima(
                bending: viz["max_slab_bending"]?.ToObject<double>() ?? 0,
                membrane: viz["max_slab_membrane"]?.ToObject<double>() ?? 0,
                shear: viz["max_slab_shear"]?.ToObject<double>() ?? 0,
                vonMises: viz["max_slab_von_mises"]?.ToObject<double>() ?? 0,
                surfaceStress: viz["max_slab_surface_stress"]?.ToObject<double>() ?? 0);
            bool isAnalyticalSlab = effectiveColorBySlab >= COLOR_SLAB_BENDING && effectiveColorBySlab <= COLOR_SLAB_SURFACE_STRESS;
            bool isAnalyticalBeam = effectiveColorByBeam >= COLOR_FRAME_AXIAL && effectiveColorByBeam <= COLOR_FRAME_SHEAR;
            bool isAnalyticalColumn = effectiveColorByColumn >= COLOR_FRAME_AXIAL && effectiveColorByColumn <= COLOR_FRAME_SHEAR;

            // Warn early when deflected mesh payload is likely to exhaust viewport memory.
            var slabMeshes = viz["deflected_slab_meshes"] as JArray ?? new JArray();
            int totalSlabVerts = 0;
            foreach (var sm in slabMeshes)
            {
                var vv = sm["vertices"]?.ToObject<double[][]>() ?? Array.Empty<double[]>();
                totalSlabVerts += vv.Length;
            }
            if (totalSlabVerts > MenegrothConfig.SlabVertexWarningThreshold)
            {
                AddRuntimeMessage(GH_RuntimeMessageLevel.Warning,
                    $"Large slab mesh payload ({totalSlabVerts:N0} vertices). Consider hiding slabs/foundations or reducing analysis mesh density.");
            }

            // ─── Frame elements: curves (always) + sized volumes (when MODE_SIZED) ───
            var frameCurves = new List<Curve>();
            var frameGeometry = new List<IGH_GeometricGoo>();
            var frameGeometryColors = new List<Color>();
            var frameColors = new List<Color>();
            var columnCurves = new List<Curve>();
            var beamCurves = new List<Curve>();
            var columnColors = new List<Color>();
            var beamColors = new List<Color>();
            var columnGeometry = new List<IGH_GeometricGoo>();
            var beamGeometry = new List<IGH_GeometricGoo>();
            var originalCurves = new List<Curve>();
            var frameElements = viz["frame_elements"] as JArray ?? new JArray();

            foreach (var elem in frameElements)
            {
                var origPts = elem["original_points"]?.ToObject<double[][]>() ?? new double[0][];
                var dispVecs = elem["displacement_vectors"]?.ToObject<double[][]>() ?? new double[0][];
                int ns = elem["node_start"]?.ToObject<int>() ?? 0;
                int ne = elem["node_end"]?.ToObject<int>() ?? 0;
                string elemType = NormalizeElementType(elem["element_type"]?.ToString() ?? "");
                bool isBeam = elemType == "beam";
                bool isColumn = elemType == "column";
                if ((isBeam && !_showBeams) || (isColumn && !_showColumns))
                    continue;
                bool hasStartNode = nodes.ContainsKey(ns);
                bool hasEndNode = nodes.ContainsKey(ne);

                Curve elementCurve;
                List<Point3d> origCurvePoints = null;

                if (origPts.Length == 0 || dispVecs.Length == 0)
                {
                    if (!nodes.ContainsKey(ns) || !nodes.ContainsKey(ne)) continue;

                    var p1 = nodes[ns].pos;
                    var p2 = nodes[ne].pos;

                    if (showOriginal && isDeflected && finalScale > 0)
                        originalCurves.Add(new Line(p1, p2).ToNurbsCurve());

                    if (isDeflected && finalScale > 0)
                        ResolveEffectiveFrameEndpoints(nodes, ns, ne, isLocal, isColumn, finalScale, out p1, out p2);

                    elementCurve = new Line(p1, p2).ToNurbsCurve();
                }
                else
                {
                    var pts = new List<Point3d>();
                    origCurvePoints = new List<Point3d>();

                    for (int i = 0; i < origPts.Length; i++)
                    {
                        var op = new Point3d(origPts[i][0], origPts[i][1], origPts[i][2]);
                        origCurvePoints.Add(op);

                        if (isDeflected && finalScale > 0)
                        {
                            double dvx = i < dispVecs.Length ? dispVecs[i][0] : 0;
                            double dvy = i < dispVecs.Length ? dispVecs[i][1] : 0;
                            double dvz = i < dispVecs.Length ? dispVecs[i][2] : 0;
                            var dv = new Vector3d(dvx, dvy, dvz);

                            if (isLocal && dispVecs.Length >= 2)
                            {
                                if (elemType == "column")
                                {
                                    // Column local frame uses the base floor as reference.
                                    dv -= GetColumnBaseDisplacement(nodes, ns, ne);
                                }
                                else
                                {
                                    var uStart = hasStartNode
                                        ? nodes[ns].disp
                                        : new Vector3d(dispVecs[0][0], dispVecs[0][1], dispVecs[0][2]);
                                    int last = dispVecs.Length - 1;
                                    var uEnd = hasEndNode
                                        ? nodes[ne].disp
                                        : new Vector3d(dispVecs[last][0], dispVecs[last][1], dispVecs[last][2]);
                                    double t = origPts.Length > 1 ? (double)i / (origPts.Length - 1) : 0.0;
                                    dv -= uStart + t * (uEnd - uStart);
                                }
                            }

                            pts.Add(op + dv * finalScale);
                        }
                        else
                        {
                            pts.Add(op);
                        }
                    }

                    if (isDeflected && finalScale > 0 && pts.Count > 1 && hasStartNode && hasEndNode)
                    {
                        ResolveEffectiveFrameEndpoints(nodes, ns, ne, isLocal, isColumn, finalScale,
                            out Point3d targetStart, out Point3d targetEnd);

                        // Apply linear endpoint correction so beams stay connected to column tops.
                        var corrStart = targetStart - pts[0];
                        int lastPt = pts.Count - 1;
                        var corrEnd = targetEnd - pts[lastPt];
                        for (int i = 0; i < pts.Count; i++)
                        {
                            double t = pts.Count > 1 ? (double)i / (pts.Count - 1) : 0.0;
                            pts[i] += corrStart + t * (corrEnd - corrStart);
                        }
                    }

                    elementCurve = pts.Count > 1 ? new PolylineCurve(pts) : null;

                    if (showOriginal && isDeflected && finalScale > 0 && origCurvePoints.Count > 1)
                        originalCurves.Add(new PolylineCurve(origCurvePoints));
                }

                if (elementCurve == null) continue;
                frameCurves.Add(elementCurve);

                int effectiveColorByElement = isBeam ? effectiveColorByBeam : effectiveColorByColumn;
                bool isAnalyticalElement = isBeam ? isAnalyticalBeam : isAnalyticalColumn;

                Color elementColor;
                if (effectiveColorByElement == COLOR_UTILIZATION)
                {
                    double ratio = elem["utilization_ratio"]?.ToObject<double>() ?? 0;
                    bool ok = elem["ok"]?.ToObject<bool>() ?? true;
                    elementColor = VisualizationColorMapper.UtilizationColor(ratio, ok, null);
                }
                else if (effectiveColorByElement == COLOR_DEFLECTION)
                {
                    double disp = ComputeElementDisplacement(elem, nodes, dispVecs);
                    elementColor = VisualizationColorMapper.DeflectionColor(disp, maxDisp, null);
                }
                else if (effectiveColorByElement == COLOR_MATERIAL)
                {
                    elementColor = VisualizationColorMapper.ResolveMaterialColor(elem["material_color_hex"]?.ToString(), VisualizationColorMapper.DefaultMaterialColor);
                }
                else if (isAnalyticalElement)
                {
                    double val = 0;
                    double maxVal = 0;
                    if (effectiveColorByElement == COLOR_FRAME_AXIAL)
                    {
                        val = elem["max_axial_force"]?.ToObject<double>() ?? 0;
                        maxVal = maxFrameAxial;
                    }
                    else if (effectiveColorByElement == COLOR_FRAME_MOMENT)
                    {
                        val = elem["max_moment"]?.ToObject<double>() ?? 0;
                        maxVal = maxFrameMoment;
                    }
                    else if (effectiveColorByElement == COLOR_FRAME_SHEAR)
                    {
                        val = elem["max_shear"]?.ToObject<double>() ?? 0;
                        maxVal = maxFrameShear;
                    }
                    elementColor = VisualizationColorMapper.AnalyticalColor(val, maxVal, isDiverging: true);
                }
                else
                {
                    // Fallback: use utilization when Color By is unexpected (avoids rigid material-only coloring).
                    double ratio = elem["utilization_ratio"]?.ToObject<double>() ?? 0;
                    bool ok = elem["ok"]?.ToObject<bool>() ?? true;
                    elementColor = VisualizationColorMapper.UtilizationColor(ratio, ok, null);
                }

                if (modeInt == MODE_SIZED)
                {
                    var frameMesh = TryGetFrameMeshForElement(elem, elementCurve);
                    if (frameMesh != null)
                    {
                        if (isDeflected && finalScale > 0 && hasStartNode && hasEndNode)
                        {
                            var origS = nodes[ns].pos;
                            var origE = nodes[ne].pos;
                            ResolveEffectiveFrameEndpoints(nodes, ns, ne, isLocal, isColumn, finalScale,
                                out Point3d defS, out Point3d defE);
                            frameMesh = TransformFrameMeshForDeflection(frameMesh, origS, origE, defS, defE);
                        }
                        var ghMesh = new GH_Mesh(frameMesh);
                        frameGeometry.Add(ghMesh);
                        frameGeometryColors.Add(elementColor);
                        if (elemType == "column")
                            columnGeometry.Add(ghMesh);
                        else if (elemType == "beam")
                            beamGeometry.Add(ghMesh);
                    }
                }

                // Always parallel to frameCurves
                frameColors.Add(elementColor);

                if (elemType == "column")
                {
                    if (effectiveColorByColumn == COLOR_DEFLECTION)
                    {
                        AppendDeflectionSegmentedCurves(
                            elementCurve, dispVecs, nodes, ns, ne, isLocal, maxDisp,
                            columnCurves, columnColors);
                    }
                    else
                    {
                        columnCurves.Add(elementCurve);
                        columnColors.Add(elementColor);
                    }
                }
                else if (elemType == "beam")
                {
                    if (effectiveColorByBeam == COLOR_DEFLECTION)
                    {
                        AppendDeflectionSegmentedCurves(
                            elementCurve, dispVecs, nodes, ns, ne, isLocal, maxDisp,
                            beamCurves, beamColors);
                    }
                    else
                    {
                        beamCurves.Add(elementCurve);
                        beamColors.Add(elementColor);
                    }
                }
            }

            // ─── Slabs + foundations: sized volumes or deflected meshes ───
            var slabGeometry = new List<IGH_GeometricGoo>();
            var slabColors = new List<Color>();
            var foundationGeometry = new List<IGH_GeometricGoo>();
            var foundationColors = new List<Color>();
            if (_showSlabs)
            {
                if (isOriginalMode)
                    BuildOriginalSlabs(viz, slabGeometry, slabColors, effectiveColorBySlab, maxDisp, slabMaxima,
                        showVolumes: modeInt == MODE_SIZED);
                // In Analytical mode, keep slab rendering on the deflected-mesh path
                // even at scale=0 so per-face/per-vertex analytical coloring remains visible.
                else if (isDeflected && (finalScale > 0 || modeInt == MODE_ANALYTICAL))
                    BuildDeflectedSlabs(viz, finalScale, slabGeometry,
                        slabColors, effectiveColorBySlab, maxDisp, isLocal, slabMaxima, nodes,
                        showVolumes: modeInt == MODE_SIZED);
                else
                    BuildSizedSlabs(viz, slabGeometry, slabColors, effectiveColorBySlab, maxDisp, slabMaxima,
                        showVolumes: modeInt == MODE_SIZED);
            }

            if (showFoundationsEffective)
                BuildFoundations(viz, foundationGeometry, foundationColors, effectiveColorBySlab);

            var visibleSlabGeometry = new List<IGH_GeometricGoo>();
            if (_showSlabs)
                visibleSlabGeometry.AddRange(slabGeometry);
            if (showFoundationsEffective)
                visibleSlabGeometry.AddRange(foundationGeometry);

            // SlabSurfaces is a top-level slab-only output slot for downstream GH wiring.
            // Keep it aligned with slab-only geometry across all modes.
            var slabSurfaces = new List<IGH_GeometricGoo>();
            if (_showSlabs)
                slabSurfaces.AddRange(slabGeometry);

            if (showOriginal && isOriginalMode)
            {
                originalCurves.AddRange(frameCurves);
            }

            // Set outputs in explicit downstream-friendly order.
            DA.SetDataList(0, beamCurves);
            DA.SetDataList(1, columnCurves);
            DA.SetDataList(2, slabSurfaces);
            DA.SetDataList(3, beamGeometry);
            DA.SetDataList(4, columnGeometry);
            DA.SetDataList(5, slabGeometry);
            DA.SetDataList(6, foundationGeometry);

            UpdateInternalPreviewCache(
                columnCurves, columnColors,
                beamCurves, beamColors,
                originalCurves,
                frameGeometry, frameGeometryColors,
                slabGeometry, slabColors,
                foundationGeometry, foundationColors);

            // Update message bar
            string deflectionName = deflectionInt == DEFLECTION_LOCAL ? "Local"
                : deflectionInt == DEFLECTION_NONE ? "None"
                : "Global";
            string modeName = modeInt == MODE_ANALYTICAL ? "Analytical" : "Sized";
            string colorName;
            if (isAnalyticalSlab || isAnalyticalBeam || isAnalyticalColumn)
            {
                string slabName = effectiveColorBySlab switch
                {
                    COLOR_SLAB_BENDING => "Slab Bending",
                    COLOR_SLAB_MEMBRANE => "Slab Membrane",
                    COLOR_SLAB_SHEAR => "Slab Shear",
                    COLOR_SLAB_VON_MISES => "Slab Von Mises",
                    COLOR_SLAB_SURFACE_STRESS => "Slab Surface σ",
                    COLOR_DEFLECTION => "Slab Deflection",
                    COLOR_MATERIAL => "Slab Material",
                    COLOR_UTILIZATION => "Slab Utilization",
                    _ => "Slab Utilization",
                };
                string beamName = effectiveColorByBeam switch
                {
                    COLOR_FRAME_AXIAL => "Beam Axial",
                    COLOR_FRAME_MOMENT => "Beam Moment",
                    COLOR_FRAME_SHEAR => "Beam Shear",
                    COLOR_DEFLECTION => "Beam Deflection",
                    COLOR_MATERIAL => "Beam Material",
                    COLOR_UTILIZATION => "Beam Utilization",
                    _ => "Beam Utilization",
                };
                string columnName = effectiveColorByColumn switch
                {
                    COLOR_FRAME_AXIAL => "Column Axial",
                    COLOR_FRAME_MOMENT => "Column Moment",
                    COLOR_FRAME_SHEAR => "Column Shear",
                    COLOR_DEFLECTION => "Column Deflection",
                    COLOR_MATERIAL => "Column Material",
                    COLOR_UTILIZATION => "Column Utilization",
                    _ => "Column Utilization",
                };
                colorName = $"{slabName} | {beamName} | {columnName}";
            }
            else
            {
                colorName = colorByInt switch
                {
                    COLOR_UTILIZATION => "Utilization",
                    COLOR_DEFLECTION => "Deflection",
                    COLOR_MATERIAL => "Material",
                    _ => "",
                };
            }
            Message = colorName.Length > 0 ? $"{deflectionName} | {modeName} | {colorName}" : $"{deflectionName} | {modeName}";
        }

        public override void DrawViewportWires(IGH_PreviewArgs args)
        {
            base.DrawViewportWires(args);
            if (!_useInternalPreview || Hidden)
                return;

            DrawPreviewCurves(args, _previewColumnCurves, _previewColumnColors, 2);
            DrawPreviewCurves(args, _previewBeamCurves, _previewBeamColors, 2);
            if (_showOriginal)
            {
                var gray = Enumerable.Repeat(Color.FromArgb(120, 120, 120), _previewOriginalCurves.Count).ToList();
                DrawPreviewCurves(args, _previewOriginalCurves, gray, 1);
            }
        }

        public override void DrawViewportMeshes(IGH_PreviewArgs args)
        {
            base.DrawViewportMeshes(args);
            if (!_useInternalPreview || Hidden)
                return;

            int n = Math.Min(_previewShadedMeshes.Count, _previewShadedMaterials.Count);
            for (int i = 0; i < n; i++)
            {
                var m = _previewShadedMeshes[i];
                if (m == null) continue;
                if (i < _previewShadedUseVertexColors.Count && _previewShadedUseVertexColors[i])
                    args.Display.DrawMeshFalseColors(m);
                else
                    args.Display.DrawMeshShaded(m, _previewShadedMaterials[i]);
            }
        }

        // ─── Displacement magnitude for a frame element ──────────────────

        private static double ComputeElementDisplacement(JToken elem,
            Dictionary<int, (Point3d pos, Vector3d disp, Point3d defPos)> nodes,
            double[][] dispVecs)
        {
            if (dispVecs != null && dispVecs.Length > 0)
            {
                double maxMag = 0;
                foreach (var dv in dispVecs)
                {
                    if (dv.Length >= 3)
                    {
                        double mag = Math.Sqrt(dv[0] * dv[0] + dv[1] * dv[1] + dv[2] * dv[2]);
                        if (mag > maxMag) maxMag = mag;
                    }
                }
                return maxMag;
            }

            int ns = elem["node_start"]?.ToObject<int>() ?? 0;
            int ne = elem["node_end"]?.ToObject<int>() ?? 0;
            double d1 = nodes.ContainsKey(ns) ? nodes[ns].disp.Length : 0;
            double d2 = nodes.ContainsKey(ne) ? nodes[ne].disp.Length : 0;
            return Math.Max(d1, d2);
        }

        // ─── Section sweep ──────────────────────────────────────────────
        // Robust sweep using PerpendicularFrameAt for orientation (handles vertical/near-vertical
        // elements without degenerate cross-products). Falls back to pipe when sweep fails.

        private static Brep SweepSection(Curve elementCurve, JToken elem)
        {
            var poly = ParseSectionPolygon(elem["section_polygon"]);
            var polyInner = ParseSectionPolygon(elem["section_polygon_inner"]);
            double depth = elem["section_depth"]?.ToObject<double>() ?? 0;
            double width = elem["section_width"]?.ToObject<double>() ?? 0;
            double flangeWidth = elem["flange_width"]?.ToObject<double>() ?? 0;
            double webThickness = elem["web_thickness"]?.ToObject<double>() ?? 0;
            double flangeThickness = elem["flange_thickness"]?.ToObject<double>() ?? 0;
            double orientAngle = elem["orientation_angle"]?.ToObject<double>() ?? 0;
            string sectionType = elem["section_type"]?.ToString() ?? "";

            bool isRound = sectionType == "circular" || sectionType == "HSS_round";

            if (poly.Length < 3)
            {
                if (depth <= 0 || width <= 0) return null;
                poly = BuildPolygonFromSectionType(sectionType, depth, width,
                    flangeWidth, webThickness, flangeThickness);
            }

            double tol = Rhino.RhinoDoc.ActiveDoc?.ModelAbsoluteTolerance ?? 0.001;
            if (elementCurve == null || !elementCurve.IsValid) return null;

            try
            {
                elementCurve.Domain = new Interval(0.0, 1.0);
                double t0 = elementCurve.Domain.T0;

                Plane frame;
                var tangent = elementCurve.TangentAtStart;
                if (!tangent.Unitize()) return PipeFallback(elementCurve, width, depth, tol);

                bool isVertical = Math.Abs(tangent.Z) > 0.9;

                if (isVertical)
                {
                    double sign = tangent.Z >= 0 ? 1.0 : -1.0;
                    var localX = new Vector3d(1, 0, 0);
                    var localY = new Vector3d(0, sign, 0);

                    if (Math.Abs(orientAngle) > 1e-9)
                    {
                        double cos = Math.Cos(orientAngle);
                        double sin = Math.Sin(orientAngle);
                        localX = new Vector3d(cos, sin, 0);
                        localY = new Vector3d(-sign * sin, sign * cos, 0);
                    }
                    frame = new Plane(elementCurve.PointAtStart, localX, localY);
                }
                else if (!elementCurve.PerpendicularFrameAt(t0, out frame))
                {
                    Vector3d up = new Vector3d(0, 0, 1);
                    var localY = Vector3d.CrossProduct(up, tangent);
                    if (!localY.Unitize()) return PipeFallback(elementCurve, width, depth, tol);
                    var localZ = Vector3d.CrossProduct(tangent, localY);
                    if (!localZ.Unitize()) return PipeFallback(elementCurve, width, depth, tol);
                    frame = new Plane(elementCurve.PointAtStart, localY, localZ);
                }

                // For round sections, use a true circle instead of the polygon approximation.
                Curve outerCurve;
                Curve innerCurve = null;

                if (isRound && width > 0)
                {
                    double outerRadius = width / 2.0;
                    outerCurve = new ArcCurve(new Circle(frame, outerRadius));

                    if (polyInner.Length >= 3)
                    {
                        double innerRadius = ComputePolygonRadius(polyInner);
                        if (innerRadius > 0)
                            innerCurve = new ArcCurve(new Circle(frame, innerRadius));
                    }
                }
                else
                {
                    outerCurve = BuildSectionCurve(poly, frame, tol);
                    if (polyInner.Length >= 3)
                        innerCurve = BuildSectionCurve(polyInner, frame, tol);
                }

                if (outerCurve == null || !outerCurve.IsValid)
                    return PipeFallback(elementCurve, width, depth, tol);

                // Hollow section: sweep outer and inner, then boolean difference.
                if (innerCurve != null && innerCurve.IsValid)
                {
                    var outerSweep = Brep.CreateFromSweep(elementCurve, outerCurve, true, tol);
                    var innerSweep = Brep.CreateFromSweep(elementCurve, innerCurve, true, tol);
                    if (outerSweep != null && outerSweep.Length > 0 && innerSweep != null && innerSweep.Length > 0)
                    {
                        var diff = Brep.CreateBooleanDifference(outerSweep[0], innerSweep[0], tol);
                        if (diff != null && diff.Length > 0)
                        {
                            var capped = diff[0].CapPlanarHoles(tol);
                            return capped ?? diff[0];
                        }
                    }
                }

                // Solid section: sweep outer and cap.
                var sweep = Brep.CreateFromSweep(elementCurve, outerCurve, true, tol);
                if (sweep != null && sweep.Length > 0)
                {
                    var brep = sweep[0];
                    var capped = brep.CapPlanarHoles(tol);
                    return capped ?? brep;
                }
            }
            catch
            {
                // Fall through to pipe fallback.
            }

            return PipeFallback(elementCurve, width, depth, tol);
        }

        /// <summary>
        /// Parse section polygon from JSON. Handles ToObject failure and JArray of JArray formats.
        /// Returns empty array on parse failure.
        /// </summary>
        private static double[][] ParseSectionPolygon(JToken token)
        {
            if (token == null) return new double[0][];
            try
            {
                var arr = token as JArray;
                if (arr == null || arr.Count < 3) return new double[0][];
                var result = new List<double[]>();
                foreach (var item in arr)
                {
                    if (item is JArray inner && inner.Count >= 2)
                    {
                        try
                        {
                            result.Add(new[] { inner[0].Value<double>(), inner[1].Value<double>() });
                        }
                        catch { /* skip invalid vertex */ }
                    }
                    else
                    {
                        var row = item?.ToObject<double[]>();
                        if (row != null && row.Length >= 2) result.Add(row);
                    }
                }
                return result.Count >= 3 ? result.ToArray() : new double[0][];
            }
            catch
            {
                try
                {
                    var fallback = token.ToObject<double[][]>();
                    return fallback ?? new double[0][];
                }
                catch
                {
                    return new double[0][];
                }
            }
        }

        /// <summary>
        /// Build section polygon from section_type and dimensions when section_polygon is empty.
        /// Vertices in [y, z] local coords: y = width, z = depth; centroid at origin.
        /// </summary>
        private static double[][] BuildPolygonFromSectionType(string sectionType,
            double depth, double width, double flangeWidth, double webThickness, double flangeThickness)
        {
            if (sectionType == "W-shape" && (flangeWidth > 0 || width > 0) && depth > 0)
            {
                double bf = flangeWidth > 0 ? flangeWidth : width;
                double tw = webThickness > 0 ? webThickness : Math.Max(bf * 0.01, 0.005);
                double tf = flangeThickness > 0 ? flangeThickness : Math.Max(depth * 0.05, 0.005);
                double d2 = depth / 2;
                return new[]
                {
                    new[] { -bf / 2, -d2 }, new[] { -bf / 2, -d2 + tf }, new[] { -tw / 2, -d2 + tf },
                    new[] { -tw / 2, d2 - tf }, new[] { -bf / 2, d2 - tf }, new[] { -bf / 2, d2 },
                    new[] { bf / 2, d2 }, new[] { bf / 2, d2 - tf }, new[] { tw / 2, d2 - tf },
                    new[] { tw / 2, -d2 + tf }, new[] { bf / 2, -d2 + tf }, new[] { bf / 2, -d2 },
                };
            }
            // Rectangular fallback for rectangular, HSS_rect, T-beam, other, or unknown
            return new[]
            {
                new[] { -width / 2, -depth / 2 },
                new[] { width / 2, -depth / 2 },
                new[] { width / 2, depth / 2 },
                new[] { -width / 2, depth / 2 },
            };
        }

        /// <summary>
        /// Build a closed PolylineCurve from polygon vertices [y, z] in the frame's local coordinates.
        /// The frame from PerpendicularFrameAt has ZAxis = tangent, so the section should be built
        /// in the XY plane (perpendicular to the curve). v[0] maps to XAxis (width), v[1] maps to YAxis (depth).
        /// </summary>
        private static PolylineCurve BuildSectionCurve(double[][] poly, Plane frame, double tol)
        {
            var pts = new List<Point3d>();
            foreach (var v in poly)
            {
                if (v == null || v.Length < 2) continue;
                // Section polygon is in the XY plane of the frame (perpendicular to ZAxis/tangent)
                pts.Add(frame.Origin + frame.XAxis * v[0] + frame.YAxis * v[1]);
            }
            if (pts.Count < 3) return null;
            if (pts[0].DistanceTo(pts[pts.Count - 1]) > tol)
                pts.Add(pts[0]);
            return new PolylineCurve(pts);
        }

        /// <summary>
        /// Compute average distance from origin for a 2D polygon (used to derive the
        /// inner radius of a hollow round section from its polygon approximation).
        /// </summary>
        private static double ComputePolygonRadius(double[][] poly)
        {
            if (poly == null || poly.Length == 0) return 0;
            double sum = 0;
            int count = 0;
            foreach (var v in poly)
            {
                if (v == null || v.Length < 2) continue;
                sum += Math.Sqrt(v[0] * v[0] + v[1] * v[1]);
                count++;
            }
            return count > 0 ? sum / count : 0;
        }

        private static Brep PipeFallback(Curve path, double width, double depth, double tol)
        {
            if (path == null || !path.IsValid) return null;
            double minDim = Math.Max(Math.Max(width, depth), 0.05);
            double area = minDim * minDim;
            double radius = Math.Max(Math.Sqrt(area / Math.PI), 0.01);
            var pipe = Brep.CreatePipe(path, radius, false, PipeCapMode.Flat, true, tol, tol);
            return pipe != null && pipe.Length > 0 ? pipe[0] : null;
        }

        /// <summary>
        /// Get sized frame mesh for an element. Prefers API mesh_vertices/mesh_faces when present;
        /// otherwise sweeps section along path and tessellates to mesh (hollow sections).
        /// </summary>
        private static Mesh TryGetFrameMeshForElement(JToken elem, Curve elementCurve)
        {
            var meshVerts = elem["mesh_vertices"] as JArray;
            var meshFaces = elem["mesh_faces"] as JArray;
            if (meshVerts != null && meshFaces != null && meshVerts.Count >= 3 && meshFaces.Count > 0)
            {
                var m = BuildMeshFromVerticesFaces(meshVerts, meshFaces);
                if (m != null) return m;
            }
            var brep = SweepSection(elementCurve, elem);
            return brep != null ? BrepToMesh(brep) : null;
        }

        /// <summary>
        /// Deform a frame element mesh so its axis follows deflection.
        /// Projects each vertex onto the original axis, computes a parameter t ∈ [0,1],
        /// then moves it to the corresponding point on the deflected axis (preserving
        /// the cross-section offset). Works for both columns and beams.
        /// </summary>
        private static Mesh TransformFrameMeshForDeflection(
            Mesh mesh,
            Point3d origStart,
            Point3d origEnd,
            Point3d deflectedStart,
            Point3d deflectedEnd)
        {
            if (mesh == null || mesh.Vertices.Count == 0)
                return mesh;

            Vector3d axisOrig = origEnd - origStart;
            double axisLen = axisOrig.Length;
            if (axisLen < 1e-10)
                return mesh;

            var result = new Mesh();
            for (int i = 0; i < mesh.Vertices.Count; i++)
            {
                var v = new Point3d(mesh.Vertices[i]);
                double t = Vector3d.Multiply(v - origStart, axisOrig) / (axisLen * axisLen);
                t = Math.Max(0, Math.Min(1, t));
                Point3d onAxisOrig = origStart + t * axisOrig;
                Vector3d offset = v - onAxisOrig;
                Point3d onAxisNew = deflectedStart + (deflectedEnd - deflectedStart) * t;
                result.Vertices.Add(onAxisNew + offset);
            }
            foreach (var f in mesh.Faces)
            {
                if (f.IsQuad)
                    result.Faces.AddFace(f.A, f.B, f.C, f.D);
                else
                    result.Faces.AddFace(f.A, f.B, f.C);
            }
            result.Normals.ComputeNormals();
            result.Compact();
            return result;
        }

        /// <summary>
        /// Build a Rhino Mesh from API vertices and faces (same pattern as deflected_slab_meshes).
        /// Vertices: [[x,y,z], ...], faces: [[i1,i2,i3], ...] (1-based indices).
        /// </summary>
        private static Mesh BuildMeshFromVerticesFaces(JArray meshVerts, JArray meshFaces)
        {
            if (meshVerts == null || meshFaces == null || meshVerts.Count == 0 || meshFaces.Count == 0)
                return null;
            var m = new Mesh();
            foreach (JToken v in meshVerts)
            {
                var arr = v as JArray;
                if (arr == null || arr.Count < 3) continue;
                m.Vertices.Add(new Point3d(arr[0].Value<double>(), arr[1].Value<double>(), arr[2].Value<double>()));
            }
            foreach (JToken f in meshFaces)
            {
                var arr = f as JArray;
                if (arr == null || arr.Count < 3) continue;
                int i0 = arr[0].Value<int>() - 1;
                int i1 = arr[1].Value<int>() - 1;
                int i2 = arr[2].Value<int>() - 1;
                if (i0 >= 0 && i1 >= 0 && i2 >= 0 && i0 < m.Vertices.Count && i1 < m.Vertices.Count && i2 < m.Vertices.Count)
                    m.Faces.AddFace(i0, i1, i2);
            }
            if (m.Vertices.Count == 0 || m.Faces.Count == 0) return null;
            m.Normals.ComputeNormals();
            m.Compact();
            return m;
        }

        /// <summary>
        /// Create a mesh from an axis-aligned box. Used for foundations and drop panels.
        /// </summary>
        private static Mesh CreateBoxMesh(BoundingBox bbox)
        {
            return Mesh.CreateFromBox(new Box(bbox), 1, 1, 1);
        }

        /// <summary>
        /// Convert a Brep to a single Mesh (fallback for hollow frame sections).
        /// Uses MeshingParameters.FastRenderMesh for display-optimized tessellation.
        /// </summary>
        private static Mesh BrepToMesh(Brep brep)
        {
            if (brep == null || !brep.IsValid) return null;
            var meshes = Mesh.CreateFromBrep(brep, MeshingParameters.FastRenderMesh);
            if (meshes == null || meshes.Length == 0) return null;
            var combined = new Mesh();
            foreach (var m in meshes)
            {
                if (m != null && m.Vertices.Count > 0)
                    combined.Append(m);
            }
            if (combined.Vertices.Count == 0) return null;
            combined.Compact();
            return combined;
        }

        private static void AppendDeflectionSegmentedCurves(
            Curve sourceCurve,
            double[][] dispVecs,
            Dictionary<int, (Point3d pos, Vector3d disp, Point3d defPos)> nodes,
            int nodeStart,
            int nodeEnd,
            bool isLocal,
            double maxDisp,
            List<Curve> targetCurves,
            List<Color> targetColors)
        {
            if (sourceCurve == null)
                return;

            var mags = ComputeDisplacementMagnitudes(dispVecs, nodes, nodeStart, nodeEnd, isLocal);
            int baseSegments = mags.Length > 1 ? mags.Length - 1 : MenegrothConfig.DeflectionSegmentsMin;
            int segments = Math.Max(MenegrothConfig.DeflectionSegmentsMin, Math.Min(MenegrothConfig.DeflectionSegmentsMax, baseSegments));

            if (segments <= 1)
            {
                targetCurves.Add(sourceCurve);
                targetColors.Add(VisualizationColorMapper.DeflectionColor(mags.Length > 0 ? mags[0] : 0.0, maxDisp, null));
                return;
            }

            var domain = sourceCurve.Domain;
            for (int s = 0; s < segments; s++)
            {
                double t0n = (double)s / segments;
                double t1n = (double)(s + 1) / segments;
                double tmn = 0.5 * (t0n + t1n);

                double t0 = domain.T0 + t0n * domain.Length;
                double t1 = domain.T0 + t1n * domain.Length;
                var p0 = sourceCurve.PointAt(t0);
                var p1 = sourceCurve.PointAt(t1);

                targetCurves.Add(new Line(p0, p1).ToNurbsCurve());
                targetColors.Add(VisualizationColorMapper.DeflectionColor(InterpolateMagnitude(mags, tmn), maxDisp, null));
            }
        }

        private static double[] ComputeDisplacementMagnitudes(
            double[][] dispVecs,
            Dictionary<int, (Point3d pos, Vector3d disp, Point3d defPos)> nodes,
            int nodeStart,
            int nodeEnd,
            bool isLocal)
        {
            if (dispVecs != null && dispVecs.Length > 0)
            {
                int n = dispVecs.Length;
                var mags = new double[n];

                Vector3d uStart, uEnd;
                if (nodes.ContainsKey(nodeStart))
                    uStart = nodes[nodeStart].disp;
                else
                    uStart = dispVecs[0].Length >= 3
                        ? new Vector3d(dispVecs[0][0], dispVecs[0][1], dispVecs[0][2])
                        : Vector3d.Zero;

                if (nodes.ContainsKey(nodeEnd))
                    uEnd = nodes[nodeEnd].disp;
                else
                {
                    int last = n - 1;
                    uEnd = dispVecs[last].Length >= 3
                        ? new Vector3d(dispVecs[last][0], dispVecs[last][1], dispVecs[last][2])
                        : Vector3d.Zero;
                }

                for (int i = 0; i < n; i++)
                {
                    var dv = dispVecs[i].Length >= 3
                        ? new Vector3d(dispVecs[i][0], dispVecs[i][1], dispVecs[i][2])
                        : Vector3d.Zero;

                    if (isLocal && n > 1)
                    {
                        double t = (double)i / (n - 1);
                        var uChord = uStart + t * (uEnd - uStart);
                        dv -= uChord;
                    }

                    mags[i] = dv.Length;
                }

                return mags;
            }

            var dStart = nodes.ContainsKey(nodeStart) ? nodes[nodeStart].disp : Vector3d.Zero;
            var dEnd = nodes.ContainsKey(nodeEnd) ? nodes[nodeEnd].disp : Vector3d.Zero;

            if (isLocal)
                return new[] { 0.0, 0.0 };

            return new[] { dStart.Length, dEnd.Length };
        }

        private static double InterpolateMagnitude(double[] mags, double tNorm)
        {
            if (mags == null || mags.Length == 0)
                return 0.0;
            if (mags.Length == 1)
                return mags[0];

            tNorm = Math.Max(0.0, Math.Min(1.0, tNorm));
            double idx = tNorm * (mags.Length - 1);
            int i0 = (int)Math.Floor(idx);
            int i1 = Math.Min(i0 + 1, mags.Length - 1);
            double a = idx - i0;
            return mags[i0] * (1.0 - a) + mags[i1] * a;
        }

        /// <summary>
        /// Compute local deflected endpoints for a column so each member is referenced to
        /// the original floor it rises from: base stays at original position, top moves by
        /// relative displacement (u_top - u_base).
        /// </summary>
        private static void ResolveLocalColumnEndpoints(
            Dictionary<int, (Point3d pos, Vector3d disp, Point3d defPos)> nodes,
            int nodeStart,
            int nodeEnd,
            double scale,
            out Point3d startPoint,
            out Point3d endPoint)
        {
            var s = nodes[nodeStart];
            var e = nodes[nodeEnd];
            bool startIsBottom = s.pos.Z <= e.pos.Z;

            if (startIsBottom)
            {
                startPoint = s.pos;
                endPoint = e.pos + (e.disp - s.disp) * scale;
            }
            else
            {
                startPoint = s.pos + (s.disp - e.disp) * scale;
                endPoint = e.pos;
            }
        }

        /// <summary>
        /// Resolve effective deformed endpoints for a frame element.
        /// - Global (or non-column local): absolute displaced endpoints.
        /// - Local column: base anchored at original floor, top moves by relative column compression.
        /// </summary>
        private static void ResolveEffectiveFrameEndpoints(
            Dictionary<int, (Point3d pos, Vector3d disp, Point3d defPos)> nodes,
            int nodeStart,
            int nodeEnd,
            bool isLocal,
            bool isColumn,
            double scale,
            out Point3d startPoint,
            out Point3d endPoint)
        {
            if (isLocal && isColumn)
            {
                ResolveLocalColumnEndpoints(nodes, nodeStart, nodeEnd, scale, out startPoint, out endPoint);
                return;
            }

            var s = nodes[nodeStart];
            var e = nodes[nodeEnd];
            startPoint = s.pos + s.disp * scale;
            endPoint = e.pos + e.disp * scale;
        }

        private static Vector3d GetColumnBaseDisplacement(
            Dictionary<int, (Point3d pos, Vector3d disp, Point3d defPos)> nodes,
            int nodeStart,
            int nodeEnd)
        {
            bool startIsBottom = nodes[nodeStart].pos.Z <= nodes[nodeEnd].pos.Z;
            return startIsBottom ? nodes[nodeStart].disp : nodes[nodeEnd].disp;
        }

        private static string NormalizeElementType(string rawType)
        {
            return (rawType ?? "").Trim().ToLowerInvariant();
        }

        private void UpdateInternalPreviewCache(
            List<Curve> columnCurves, List<Color> columnColors,
            List<Curve> beamCurves, List<Color> beamColors,
            List<Curve> originalCurves,
            List<IGH_GeometricGoo> frameGeometry, List<Color> frameGeometryColors,
            List<IGH_GeometricGoo> slabGeometry, List<Color> slabColors,
            List<IGH_GeometricGoo> foundationGeometry, List<Color> foundationColors)
        {
            _previewColumnCurves.Clear();
            _previewColumnColors.Clear();
            _previewBeamCurves.Clear();
            _previewBeamColors.Clear();
            _previewOriginalCurves.Clear();
            _previewShadedMeshes.Clear();
            _previewShadedColors.Clear();
            _previewShadedUseVertexColors.Clear();
            _previewShadedMaterials.Clear();

            // Transfer ownership directly -- source lists are freshly built
            // in SolveInstance and never referenced again, so duplication is unnecessary.
            for (int i = 0; i < Math.Min(columnCurves.Count, columnColors.Count); i++)
            {
                if (columnCurves[i] == null) continue;
                _previewColumnCurves.Add(columnCurves[i]);
                _previewColumnColors.Add(columnColors[i]);
            }

            for (int i = 0; i < Math.Min(beamCurves.Count, beamColors.Count); i++)
            {
                if (beamCurves[i] == null) continue;
                _previewBeamCurves.Add(beamCurves[i]);
                _previewBeamColors.Add(beamColors[i]);
            }

            foreach (var c in originalCurves)
            {
                if (c == null) continue;
                _previewOriginalCurves.Add(c);
            }

            CacheShadedGeometry(frameGeometry, frameGeometryColors);
            CacheShadedGeometry(slabGeometry, slabColors);
            CacheShadedGeometry(foundationGeometry, foundationColors);
        }

        /// <summary>
        /// Cache geometry for internal shaded preview. Handles both GH_Mesh (direct) and GH_Brep (tessellated).
        /// </summary>
        private void CacheShadedGeometry(List<IGH_GeometricGoo> geometry, List<Color> colors)
        {
            if (geometry == null || colors == null) return;
            int n = Math.Min(geometry.Count, colors.Count);
            for (int i = 0; i < n; i++)
            {
                var color = colors[i];
                if (geometry[i] is GH_Brep ghBrep && ghBrep.Value != null)
                {
                    var meshes = Mesh.CreateFromBrep(ghBrep.Value, MeshingParameters.FastRenderMesh);
                    if (meshes != null && meshes.Length > 0)
                    {
                        var mat = new Rhino.Display.DisplayMaterial(color);
                        foreach (var m in meshes)
                        {
                            if (m == null) continue;
                            _previewShadedMeshes.Add(m);
                            _previewShadedColors.Add(color);
                            _previewShadedUseVertexColors.Add(false);
                            _previewShadedMaterials.Add(mat);
                        }
                    }
                }
                else if (geometry[i] is GH_Mesh ghMesh && ghMesh.Value != null)
                {
                    var mesh = ghMesh.Value;
                    if (mesh.Vertices.Count > 0 && mesh.Faces.Count > 0)
                    {
                        bool hasVertexColors = mesh.VertexColors.Count == mesh.Vertices.Count && mesh.VertexColors.Count > 0;
                        if (!hasVertexColors)
                        {
                            for (int v = 0; v < mesh.Vertices.Count; v++)
                                mesh.VertexColors.Add(color);
                        }
                        _previewShadedMeshes.Add(mesh);
                        _previewShadedColors.Add(color);
                        _previewShadedUseVertexColors.Add(hasVertexColors);
                        _previewShadedMaterials.Add(new Rhino.Display.DisplayMaterial(
                            hasVertexColors ? Color.White : color));
                    }
                }
            }
        }

        private static void DrawPreviewCurves(
            IGH_PreviewArgs args, List<Curve> curves, List<Color> colors, int thickness)
        {
            int n = Math.Min(curves.Count, colors.Count);
            for (int i = 0; i < n; i++)
            {
                var c = curves[i];
                if (c == null) continue;
                args.Display.DrawCurve(c, colors[i], thickness);
            }
        }

        // ─── Slab helpers ───────────────────────────────────────────────

        /// <summary>
        /// Add a slab mesh to output and append its color. Keeps geometry and color lists in sync.
        /// </summary>
        private static void AddSlabMeshAndColor(List<IGH_GeometricGoo> output, List<Color> colors,
            Mesh mesh, JToken analyticalSource, int colorBy, double maxDisp, SlabAnalyticalMaxima maxima)
        {
            if (mesh == null) return;
            output.Add(new GH_Mesh(mesh));
            AppendSlabColor(colors, analyticalSource, colorBy, maxDisp, "vertex_displacements", maxima);
        }

        private static void BuildSizedSlabs(JToken viz, List<IGH_GeometricGoo> output,
            List<Color> colors, int colorBy, double maxDisp,
            SlabAnalyticalMaxima maxima, bool showVolumes = true)
        {
            var slabs = viz["sized_slabs"] as JArray ?? new JArray();
            var deflectedMeshes = viz["deflected_slab_meshes"] as JArray ?? new JArray();

            var meshBySlabId = new Dictionary<int, JToken>();
            foreach (var meshToken in deflectedMeshes)
            {
                int id = meshToken?["slab_id"]?.ToObject<int>() ?? -1;
                if (id > 0 && !meshBySlabId.ContainsKey(id))
                    meshBySlabId[id] = meshToken;
            }

            foreach (var slab in slabs)
            {
                int slabId = slab["slab_id"]?.ToObject<int>() ?? -1;
                double thickness = slab["thickness"]?.ToObject<double>() ?? 0;
                double zTop = slab["z_top"]?.ToObject<double>() ?? 0;
                meshBySlabId.TryGetValue(slabId, out var analyticalMesh);
                var analyticalSource = analyticalMesh ?? slab;

                // 1. Vault: mesh from vault_mesh_vertices/faces
                if (slab["is_vault"]?.ToObject<bool>() == true && TryBuildVaultMesh(slab, thickness, output))
                {
                    AppendSlabColor(colors, analyticalSource, colorBy, maxDisp, "vertex_displacements", maxima);
                    continue;
                }

                // 2. Curved/mesh-based: use deflected_slab_meshes undeformed vertices
                //    with thickness volume so the slab appears solid.
                bool isVault = slab["is_vault"]?.ToObject<bool>() == true;
                if (analyticalMesh != null && TryBuildSizedSlabFromMesh(analyticalMesh, thickness, showVolumes, output, offsetAlongNormal: isVault))
                {
                    AppendSlabColor(colors, analyticalSource, colorBy, maxDisp, "vertex_displacements", maxima);
                    AppendDropPanelSizedGeometry(slab, zTop, thickness, output, colors, analyticalSource,
                        colorBy, maxDisp, maxima);
                    continue;
                }

                // 3. Flat slab: boundary_vertices → top/bottom planar meshes
                var boundary = slab["boundary_vertices"]?.ToObject<double[][]>() ?? new double[0][];
                if (boundary.Length < 3) continue;

                var topPts = boundary.Select(v => new Point3d(v[0], v[1], zTop)).ToList();
                topPts.Add(topPts[0]);
                var bottomPts = topPts.Select(p => new Point3d(p.X, p.Y, p.Z - thickness)).ToList();

                if (showVolumes)
                {
                    var topMesh = CreatePlanarPolygonMesh(topPts);
                    var bottomMesh = CreatePlanarPolygonMesh(bottomPts);
                    if (topMesh != null && bottomMesh != null && thickness > 0)
                    {
                        var combined = new Mesh();
                        combined.Append(topMesh);
                        combined.Append(bottomMesh);

                        int nBoundary = topPts.Count - 1;
                        for (int i = 0; i < nBoundary; i++)
                        {
                            int j = (i + 1) % nBoundary;
                            int baseIdx = combined.Vertices.Count;
                            combined.Vertices.Add(topPts[i]);
                            combined.Vertices.Add(topPts[j]);
                            combined.Vertices.Add(bottomPts[j]);
                            combined.Vertices.Add(bottomPts[i]);
                            combined.Faces.AddFace(baseIdx, baseIdx + 1, baseIdx + 2, baseIdx + 3);
                        }
                        combined.Normals.ComputeNormals();
                        combined.Compact();
                        AddSlabMeshAndColor(output, colors, combined,
                            analyticalSource, colorBy, maxDisp, maxima);
                    }
                    else
                    {
                        AddSlabMeshAndColor(output, colors, topMesh,
                            analyticalSource, colorBy, maxDisp, maxima);
                    }
                    AppendDropPanelSizedGeometry(slab, zTop, thickness, output, colors, analyticalSource,
                        colorBy, maxDisp, maxima);
                }
                else
                {
                    AddSlabMeshAndColor(output, colors, CreatePlanarPolygonMesh(topPts),
                        analyticalSource, colorBy, maxDisp, maxima);
                }
            }
        }

        /// <summary>
        /// Creates a planar mesh from a closed polygon (last point equals first).
        /// Uses Rhino's Mesh.CreateFromClosedPolyline for correct concave triangulation,
        /// falling back to fan triangulation only when Rhino's method fails.
        /// </summary>
        private static Mesh CreatePlanarPolygonMesh(List<Point3d> closedPts)
        {
            int n = closedPts.Count - 1; // exclude duplicate closing point
            if (n < 3) return null;

            var polyline = new Polyline(closedPts);
            var mesh = Mesh.CreateFromClosedPolyline(polyline);
            if (mesh != null && mesh.Faces.Count > 0)
            {
                mesh.Normals.ComputeNormals();
                mesh.Compact();
                return mesh;
            }

            // Fan triangulation fallback (only correct for convex polygons)
            mesh = new Mesh();
            for (int i = 0; i < n; i++)
                mesh.Vertices.Add(closedPts[i]);
            for (int i = 1; i < n - 1; i++)
                mesh.Faces.AddFace(0, i, i + 1);
            mesh.Normals.ComputeNormals();
            mesh.Compact();
            return mesh;
        }

        /// <summary>
        /// Build parabolic vault mesh from vault_mesh_vertices and vault_mesh_faces.
        /// Intrados + extrados (offset along surface normals) + side caps as a single mesh.
        /// </summary>
        private static bool TryBuildVaultMesh(JToken slab, double thickness, List<IGH_GeometricGoo> output)
        {
            var verts = slab["vault_mesh_vertices"]?.ToObject<double[][]>() ?? new double[0][];
            var faces = slab["vault_mesh_faces"]?.ToObject<int[][]>() ?? new int[0][];

            if (verts.Length == 0 || faces.Length == 0)
                return false;

            var intradosMesh = new Mesh();
            for (int i = 0; i < verts.Length; i++)
            {
                if (verts[i].Length < 3) continue;
                intradosMesh.Vertices.Add(new Point3d(verts[i][0], verts[i][1], verts[i][2]));
            }

            foreach (var face in faces)
            {
                if (face == null || face.Length < 3) continue;
                int i0 = face[0] - 1;
                int i1 = face[1] - 1;
                int i2 = face[2] - 1;
                if (i0 < 0 || i1 < 0 || i2 < 0 ||
                    i0 >= intradosMesh.Vertices.Count ||
                    i1 >= intradosMesh.Vertices.Count ||
                    i2 >= intradosMesh.Vertices.Count)
                    continue;
                intradosMesh.Faces.AddFace(i0, i1, i2);
            }

            if (intradosMesh.Vertices.Count == 0 || intradosMesh.Faces.Count == 0)
                return false;

            intradosMesh.Normals.ComputeNormals();
            intradosMesh.Compact();

            // Build extrados by offsetting each vertex along its surface normal
            var extradosMesh = new Mesh();
            for (int i = 0; i < intradosMesh.Vertices.Count; i++)
            {
                var pt = new Point3d(intradosMesh.Vertices[i]);
                var n = new Vector3d(intradosMesh.Normals[i]);
                extradosMesh.Vertices.Add(pt + n * thickness);
            }

            foreach (var face in intradosMesh.Faces)
            {
                if (face.IsTriangle)
                    extradosMesh.Faces.AddFace(face.A, face.C, face.B);
                else
                    extradosMesh.Faces.AddFace(face.A, face.D, face.C, face.B);
            }
            extradosMesh.Normals.ComputeNormals();
            extradosMesh.Compact();

            var combinedMesh = new Mesh();
            combinedMesh.Append(intradosMesh);
            combinedMesh.Append(extradosMesh);

            // Stitch boundary edges between intrados and extrados
            var boundary = intradosMesh.GetNakedEdges();
            if (boundary != null && boundary.Length > 0)
            {
                const double tol = 1e-6;
                var cloud = new Rhino.Geometry.PointCloud(
                    Enumerable.Range(0, intradosMesh.Vertices.Count)
                              .Select(i => new Point3d(intradosMesh.Vertices[i])));
                int nV = intradosMesh.Vertices.Count;

                foreach (var edge in boundary)
                {
                    if (edge == null || edge.Count < 2) continue;
                    for (int i = 0; i < edge.Count - 1; i++)
                    {
                        int i0 = cloud.ClosestPoint(edge[i]);
                        int i1 = cloud.ClosestPoint(edge[i + 1]);
                        if (i0 < 0 || i1 < 0 || i0 >= nV || i1 >= nV) continue;
                        if (new Point3d(intradosMesh.Vertices[i0]).DistanceToSquared(edge[i]) > tol * tol) continue;
                        if (new Point3d(intradosMesh.Vertices[i1]).DistanceToSquared(edge[i + 1]) > tol * tol) continue;
                        int baseIdx = combinedMesh.Vertices.Count;
                        combinedMesh.Vertices.Add(intradosMesh.Vertices[i0]);
                        combinedMesh.Vertices.Add(intradosMesh.Vertices[i1]);
                        combinedMesh.Vertices.Add(extradosMesh.Vertices[i1]);
                        combinedMesh.Vertices.Add(extradosMesh.Vertices[i0]);
                        combinedMesh.Faces.AddFace(baseIdx, baseIdx + 1, baseIdx + 2, baseIdx + 3);
                    }
                }
            }

            combinedMesh.Normals.ComputeNormals();
            combinedMesh.Compact();

            output.Add(new GH_Mesh(combinedMesh));
            return true;
        }

        /// <summary>
        /// Build sized slab geometry from the analytical mesh (deflected_slab_meshes undeformed vertices).
        /// Uses the triangulated mesh topology for correct concave shapes. When showVolumes is true,
        /// offsets downward by thickness to create a solid volume; otherwise outputs the top surface only.
        /// </summary>
        private static bool TryBuildSizedSlabFromMesh(JToken meshToken, double thickness,
            bool showVolumes, List<IGH_GeometricGoo> output, bool offsetAlongNormal = false)
        {
            var verts = meshToken["vertices"]?.ToObject<double[][]>() ?? new double[0][];
            var faces = meshToken["faces"]?.ToObject<int[][]>() ?? new int[0][];
            if (verts.Length == 0 || faces.Length == 0)
                return false;

            var topMesh = new Mesh();
            for (int i = 0; i < verts.Length; i++)
            {
                if (verts[i].Length < 3) continue;
                topMesh.Vertices.Add(new Point3d(verts[i][0], verts[i][1], verts[i][2]));
            }

            foreach (var face in faces)
            {
                if (face == null || face.Length < 3) continue;
                int i0 = face[0] - 1;
                int i1 = face[1] - 1;
                int i2 = face[2] - 1;
                if (i0 < 0 || i1 < 0 || i2 < 0 ||
                    i0 >= topMesh.Vertices.Count ||
                    i1 >= topMesh.Vertices.Count ||
                    i2 >= topMesh.Vertices.Count)
                    continue;
                topMesh.Faces.AddFace(i0, i1, i2);
            }

            if (topMesh.Vertices.Count == 0 || topMesh.Faces.Count == 0)
                return false;

            topMesh.Normals.ComputeNormals();
            topMesh.Compact();

            if (!showVolumes || thickness <= 0)
            {
                output.Add(new GH_Mesh(topMesh));
                return true;
            }

            // Build solid volume: top + bottom + stitched boundary
            var bottomMesh = new Mesh();
            for (int i = 0; i < topMesh.Vertices.Count; i++)
            {
                var pt = new Point3d(topMesh.Vertices[i]);
                if (offsetAlongNormal)
                {
                    var n = new Vector3d(topMesh.Normals[i]);
                    bottomMesh.Vertices.Add(pt + n * (-thickness));
                }
                else
                {
                    bottomMesh.Vertices.Add(pt + new Vector3d(0, 0, -thickness));
                }
            }
            foreach (var face in topMesh.Faces)
            {
                if (face.IsTriangle)
                    bottomMesh.Faces.AddFace(face.A, face.B, face.C);
                else
                    bottomMesh.Faces.AddFace(face.A, face.B, face.C, face.D);
            }
            bottomMesh.Normals.ComputeNormals();
            bottomMesh.Compact();

            var combined = new Mesh();
            combined.Append(topMesh);
            combined.Append(bottomMesh);

            // Stitch boundary edges between top and bottom
            var boundary = topMesh.GetNakedEdges();
            if (boundary != null && boundary.Length > 0)
            {
                const double tol = 1e-6;
                var cloud = new Rhino.Geometry.PointCloud(
                    Enumerable.Range(0, topMesh.Vertices.Count)
                              .Select(i => new Point3d(topMesh.Vertices[i])));
                int nV = topMesh.Vertices.Count;

                foreach (var edge in boundary)
                {
                    if (edge == null || edge.Count < 2) continue;
                    for (int i = 0; i < edge.Count - 1; i++)
                    {
                        int i0 = cloud.ClosestPoint(edge[i]);
                        int i1 = cloud.ClosestPoint(edge[i + 1]);
                        if (i0 < 0 || i1 < 0 || i0 >= nV || i1 >= nV) continue;
                        if (new Point3d(topMesh.Vertices[i0]).DistanceToSquared(edge[i]) > tol * tol) continue;
                        if (new Point3d(topMesh.Vertices[i1]).DistanceToSquared(edge[i + 1]) > tol * tol) continue;
                        int baseIdx = combined.Vertices.Count;
                        combined.Vertices.Add(topMesh.Vertices[i0]);
                        combined.Vertices.Add(topMesh.Vertices[i1]);
                        combined.Vertices.Add(bottomMesh.Vertices[i1]);
                        combined.Vertices.Add(bottomMesh.Vertices[i0]);
                        combined.Faces.AddFace(baseIdx, baseIdx + 1, baseIdx + 2, baseIdx + 3);
                    }
                }
            }

            combined.Normals.ComputeNormals();
            combined.Compact();
            output.Add(new GH_Mesh(combined));
            return true;
        }

        private static void BuildDeflectedSlabs(JToken viz, double scale,
            List<IGH_GeometricGoo> output,
            List<Color> colors, int colorBy, double maxDisp, bool isLocal,
            SlabAnalyticalMaxima maxima,
            Dictionary<int, (Point3d pos, Vector3d disp, Point3d defPos)> nodes,
            bool showVolumes = false)
        {
            bool isAnalyticalSlab = colorBy >= COLOR_SLAB_BENDING && colorBy <= COLOR_SLAB_SURFACE_STRESS;
            var meshes = viz["deflected_slab_meshes"] as JArray ?? new JArray();
            var localColumnTops = BuildLocalColumnTopDisplacements(viz, nodes);
            var slabsWithMeshDropPanels = new HashSet<int>();
            foreach (var meshToken in meshes)
            {
                int sid = meshToken?["slab_id"]?.ToObject<int>() ?? -1;
                var tokenDpMeshes = meshToken?["drop_panel_meshes"] as JArray;
                if (sid > 0 && tokenDpMeshes != null && tokenDpMeshes.Count > 0)
                    slabsWithMeshDropPanels.Add(sid);
            }
            var slabsWithDropPanelsRendered = new HashSet<int>();
            foreach (var m in meshes)
            {
                var verts = m["vertices"]?.ToObject<double[][]>() ?? new double[0][];
                var dispsGlobal = m["vertex_displacements"]?.ToObject<double[][]>() ?? new double[0][];
                var dispsLocal = m["vertex_displacements_local"]?.ToObject<double[][]>() ?? new double[0][];
                bool localValid = dispsLocal.Length == verts.Length;
                bool globalValid = dispsGlobal.Length == verts.Length;
                var faces = m["faces"]?.ToObject<int[][]>() ?? new int[0][];
                if (verts.Length == 0) continue;
                var shapeDisps = SelectSlabShapeDisplacements(dispsGlobal, dispsLocal, isLocal, globalValid, localValid);
                var colorDisps = SelectSlabColorDisplacements(dispsGlobal, dispsLocal, isLocal, globalValid, localValid);
                if (isLocal && globalValid)
                    shapeDisps = ComposeLocalSlabShapeDisplacements(verts, dispsGlobal, localColumnTops);

                double[] faceAnalytical = null;
                double analyticalMax = 0;
                bool analyticalDiverging = false;
                if (isAnalyticalSlab)
                    ResolveSlabAnalyticalData(m, colorBy, maxima,
                        out faceAnalytical, out analyticalMax, out analyticalDiverging);

                var rhinoMesh = new Mesh();

                for (int i = 0; i < verts.Length; i++)
                {
                    var op = new Point3d(verts[i][0], verts[i][1], verts[i][2]);

                    double dx = i < shapeDisps.Length ? shapeDisps[i][0] : 0;
                    double dy = i < shapeDisps.Length ? shapeDisps[i][1] : 0;
                    double dz = i < shapeDisps.Length ? shapeDisps[i][2] : 0;
                    rhinoMesh.Vertices.Add(op + new Vector3d(dx, dy, dz) * scale);
                }

                foreach (var face in faces)
                {
                    if (face.Length < 3) continue;
                    int i0 = face[0] - 1, i1 = face[1] - 1, i2 = face[2] - 1;
                    if (i0 < 0 || i1 < 0 || i2 < 0 ||
                        i0 >= rhinoMesh.Vertices.Count ||
                        i1 >= rhinoMesh.Vertices.Count ||
                        i2 >= rhinoMesh.Vertices.Count) continue;
                    rhinoMesh.Faces.AddFace(i0, i1, i2);
                }

                if (colorBy == COLOR_DEFLECTION && colorDisps.Length > 0)
                {
                    for (int i = 0; i < rhinoMesh.Vertices.Count; i++)
                    {
                        double mag = 0;
                        if (i < colorDisps.Length && colorDisps[i].Length >= 3)
                            mag = Math.Sqrt(colorDisps[i][0] * colorDisps[i][0] +
                                            colorDisps[i][1] * colorDisps[i][1] +
                                            colorDisps[i][2] * colorDisps[i][2]);
                        rhinoMesh.VertexColors.Add(VisualizationColorMapper.DeflectionColor(mag, maxDisp, null));
                    }
                }
                else if (colorBy == COLOR_UTILIZATION)
                {
                    double ratio = m["utilization_ratio"]?.ToObject<double>() ?? 0;
                    bool ok = m["ok"]?.ToObject<bool>() ?? true;
                    var utilColor = VisualizationColorMapper.UtilizationColor(ratio, ok, null);
                    for (int i = 0; i < rhinoMesh.Vertices.Count; i++)
                        rhinoMesh.VertexColors.Add(utilColor);
                }
                else if (isAnalyticalSlab && faceAnalytical != null)
                {
                    ApplyPerFaceVertexColors(rhinoMesh, faces, faceAnalytical, analyticalMax, analyticalDiverging);
                }

                if (rhinoMesh.Vertices.Count > 0 && rhinoMesh.Faces.Count > 0)
                {
                    rhinoMesh.Normals.ComputeNormals();
                    rhinoMesh.Compact();

                    string dispField = ReferenceEquals(colorDisps, dispsLocal)
                        ? "vertex_displacements_local"
                        : "vertex_displacements";

                    if (showVolumes)
                    {
                        double thickness = m["thickness"]?.ToObject<double>() ?? 0;
                        bool isVault = m["is_vault"]?.ToObject<bool>() == true;
                        if (thickness > 0 && TryBuildDeflectedSlabVolume(rhinoMesh, thickness, output, offsetAlongNormal: isVault))
                        {
                            AppendSlabColor(colors, m, colorBy, maxDisp, dispField, maxima);
                        }
                        else
                        {
                            output.Add(new GH_Mesh(rhinoMesh));
                            AppendSlabColor(colors, m, colorBy, maxDisp, dispField, maxima);
                        }
                    }
                    else
                    {
                        output.Add(new GH_Mesh(rhinoMesh));
                        AppendSlabColor(colors, m, colorBy, maxDisp, dispField, maxima);
                    }

                    // Drop panel solids are only shown in Sized mode. In Analytical mode, keep slab
                    // output to the shell mesh only (no boxed/solid drop panel geometry).
                    if (showVolumes)
                    {
                        // Drop panels are slab-level geometry. Some payloads include multiple mesh
                        // tokens per slab; render once per slab and prefer mesh-based
                        // drop_panel_meshes over fallback sized-slab boxes to avoid duplicates.
                        int slabId = m["slab_id"]?.ToObject<int>() ?? -1;
                        bool tokenHasMeshDropPanels = (m["drop_panel_meshes"] as JArray)?.Count > 0;
                        bool dropPanelsAlreadyRendered = slabId > 0 && slabsWithDropPanelsRendered.Contains(slabId);
                        bool skipFallbackForThisToken =
                            slabId > 0 &&
                            slabsWithMeshDropPanels.Contains(slabId) &&
                            !tokenHasMeshDropPanels;

                        if (!dropPanelsAlreadyRendered && !skipFallbackForThisToken)
                        {
                            AppendDropPanelDeflectedGeometry(viz, m, rhinoMesh,
                                m["thickness"]?.ToObject<double>() ?? 0,
                                output, colors, colorBy, maxDisp, dispField, maxima);
                            if (slabId > 0)
                                slabsWithDropPanelsRendered.Add(slabId);
                        }
                    }
                }
            }
        }

        /// <summary>
        /// Geometry displacement source for slab mesh vertices.
        /// In local mode, geometry follows the same base shape path as global mode.
        /// Local placement offsets are applied later via ComposeLocalSlabShapeDisplacements.
        /// </summary>
        private static double[][] SelectSlabShapeDisplacements(
            double[][] dispsGlobal, double[][] dispsLocal,
            bool isLocalMode, bool globalValid, bool localValid)
        {
            if (!isLocalMode)
            {
                if (globalValid) return dispsGlobal;
                if (localValid) return dispsLocal;
                return Array.Empty<double[]>();
            }

            if (globalValid) return dispsGlobal;
            if (localValid) return dispsLocal;
            return Array.Empty<double[]>();
        }

        /// <summary>
        /// Build per-floor top displacement samples for columns.
        /// For each column we keep:
        /// - global top displacement (u_top)
        /// - local top displacement relative to column base (u_top - u_base)
        /// </summary>
        private static List<(Point3d topPos, Vector3d globalDisp, Vector3d localDisp)> BuildLocalColumnTopDisplacements(
            JToken viz,
            Dictionary<int, (Point3d pos, Vector3d disp, Point3d defPos)> nodes)
        {
            var outPts = new List<(Point3d, Vector3d, Vector3d)>();
            var frameElements = viz["frame_elements"] as JArray ?? new JArray();
            var seenTop = new HashSet<int>();

            foreach (var elem in frameElements)
            {
                string elemType = NormalizeElementType(elem["element_type"]?.ToString() ?? "");
                if (elemType != "column") continue;

                int ns = elem["node_start"]?.ToObject<int>() ?? 0;
                int ne = elem["node_end"]?.ToObject<int>() ?? 0;
                if (!nodes.ContainsKey(ns) || !nodes.ContainsKey(ne)) continue;

                bool startIsBottom = nodes[ns].pos.Z <= nodes[ne].pos.Z;
                int baseId = startIsBottom ? ns : ne;
                int topId = startIsBottom ? ne : ns;
                if (seenTop.Contains(topId)) continue;

                var globalTop = nodes[topId].disp;
                var localTop = globalTop - nodes[baseId].disp;
                outPts.Add((nodes[topId].pos, globalTop, localTop));
                seenTop.Add(topId);
            }

            return outPts;
        }

        /// <summary>
        /// In local mode, keep the global slab shape (same shape logic as global mode),
        /// then translate it to the local column-top frame:
        /// shape_local = shape_global + interpolated(localTop - globalTop).
        /// </summary>
        private static double[][] ComposeLocalSlabShapeDisplacements(
            double[][] verts,
            double[][] dispsGlobal,
            List<(Point3d topPos, Vector3d globalDisp, Vector3d localDisp)> localColumnTops)
        {
            int n = verts?.Length ?? 0;
            if (n == 0) return Array.Empty<double[]>();
            if (dispsGlobal == null || dispsGlobal.Length != n) return dispsGlobal ?? Array.Empty<double[]>();

            double zRef = 0.0;
            for (int i = 0; i < n; i++) zRef += verts[i][2];
            zRef /= n;

            var floorSupports = localColumnTops
                .Where(p => Math.Abs(p.topPos.Z - zRef) <= 0.25)
                .ToList();
            if (floorSupports.Count == 0)
                floorSupports = localColumnTops
                    .Where(p => Math.Abs(p.topPos.Z - zRef) <= 0.75)
                    .ToList();
            if (floorSupports.Count == 0)
                return dispsGlobal;

            var composed = new double[n][];
            for (int i = 0; i < n; i++)
            {
                double x = verts[i][0];
                double y = verts[i][1];
                var supportDelta = InterpolateSupportDeltaIdw2D(x, y, floorSupports);
                var dglob = dispsGlobal[i];
                composed[i] = new[]
                {
                    dglob[0] + supportDelta.X,
                    dglob[1] + supportDelta.Y,
                    dglob[2] + supportDelta.Z,
                };
            }
            return composed;
        }

        private static Vector3d InterpolateSupportDeltaIdw2D(
            double qx, double qy,
            List<(Point3d topPos, Vector3d globalDisp, Vector3d localDisp)> samples,
            double power = 2.0)
        {
            if (samples == null || samples.Count == 0) return Vector3d.Zero;
            if (samples.Count == 1) return samples[0].localDisp - samples[0].globalDisp;

            for (int i = 0; i < samples.Count; i++)
            {
                var p = samples[i].topPos;
                double dx = qx - p.X;
                double dy = qy - p.Y;
                if (Math.Sqrt(dx * dx + dy * dy) < 1e-8)
                    return samples[i].localDisp - samples[i].globalDisp;
            }

            var acc = Vector3d.Zero;
            double wSum = 0.0;
            for (int i = 0; i < samples.Count; i++)
            {
                var p = samples[i].topPos;
                double dx = qx - p.X;
                double dy = qy - p.Y;
                double d = Math.Sqrt(dx * dx + dy * dy);
                double w = 1.0 / Math.Pow(Math.Max(d, 1e-8), power);
                acc += (samples[i].localDisp - samples[i].globalDisp) * w;
                wSum += w;
            }
            return wSum > 0 ? acc / wSum : Vector3d.Zero;
        }

        /// <summary>
        /// Color displacement source for slab deflection maps.
        /// Local mode colors by local field when available.
        /// </summary>
        private static double[][] SelectSlabColorDisplacements(
            double[][] dispsGlobal, double[][] dispsLocal,
            bool isLocalMode, bool globalValid, bool localValid)
        {
            if (isLocalMode && localValid) return dispsLocal;
            if (globalValid) return dispsGlobal;
            if (localValid) return dispsLocal;
            return Array.Empty<double[]>();
        }

        /// <summary>
        /// Build a solid slab volume from a deflected mesh by offsetting along normals by thickness.
        /// Top surface = deflected mesh; bottom = offset downward; sides from boundary edges.
        /// Outputs a solid Brep (via loft-like closed mesh then Brep.CreateFromMesh).
        /// </summary>
        private static bool TryBuildDeflectedSlabVolume(Mesh topMesh, double thickness, List<IGH_GeometricGoo> output, bool offsetAlongNormal = false)
        {
            if (topMesh.Vertices.Count == 0 || topMesh.Faces.Count == 0 || thickness <= 0)
                return false;

            var bottomMesh = new Mesh();
            for (int i = 0; i < topMesh.Vertices.Count; i++)
            {
                var pt = new Point3d(topMesh.Vertices[i]);
                if (offsetAlongNormal)
                {
                    var n = new Vector3d(topMesh.Normals[i]);
                    bottomMesh.Vertices.Add(pt + n * (-thickness));
                }
                else
                {
                    bottomMesh.Vertices.Add(pt + new Vector3d(0, 0, -thickness));
                }
            }
            foreach (var face in topMesh.Faces)
            {
                if (face.IsTriangle)
                    bottomMesh.Faces.AddFace(face.A, face.B, face.C);
                else
                    bottomMesh.Faces.AddFace(face.A, face.B, face.C, face.D);
            }
            bottomMesh.Normals.ComputeNormals();
            bottomMesh.Compact();

            var combined = new Mesh();
            combined.Append(topMesh);
            combined.Append(bottomMesh);

            // Stitch boundary edges between top and bottom (loft the edges together)
            var boundary = topMesh.GetNakedEdges();
            if (boundary != null && boundary.Length > 0)
            {
                const double tol = 1e-6;
                var cloud = new Rhino.Geometry.PointCloud(
                    Enumerable.Range(0, topMesh.Vertices.Count)
                              .Select(i => new Point3d(topMesh.Vertices[i])));
                int nV = topMesh.Vertices.Count;

                foreach (var edge in boundary)
                {
                    if (edge == null || edge.Count < 2) continue;
                    for (int i = 0; i < edge.Count - 1; i++)
                    {
                        int i0 = cloud.ClosestPoint(edge[i]);
                        int i1 = cloud.ClosestPoint(edge[i + 1]);
                        if (i0 < 0 || i1 < 0 || i0 >= nV || i1 >= nV) continue;
                        if (new Point3d(topMesh.Vertices[i0]).DistanceToSquared(edge[i]) > tol * tol) continue;
                        if (new Point3d(topMesh.Vertices[i1]).DistanceToSquared(edge[i + 1]) > tol * tol) continue;
                        int baseIdx = combined.Vertices.Count;
                        combined.Vertices.Add(topMesh.Vertices[i0]);
                        combined.Vertices.Add(topMesh.Vertices[i1]);
                        combined.Vertices.Add(bottomMesh.Vertices[i1]);
                        combined.Vertices.Add(bottomMesh.Vertices[i0]);
                        combined.Faces.AddFace(baseIdx, baseIdx + 1, baseIdx + 2, baseIdx + 3);
                    }
                }
            }

            combined.Normals.ComputeNormals();
            combined.Compact();

            // Output mesh directly for faster rendering (skip Brep conversion)
            output.Add(new GH_Mesh(combined));
            return true;
        }

        /// <summary>
        /// Resolve the correct per-face analytical array, global max, and whether the
        /// quantity uses a diverging color scheme (signed) vs sequential (always ≥ 0).
        /// </summary>
        private static void ResolveSlabAnalyticalData(JToken m, int colorBy,
            SlabAnalyticalMaxima maxima,
            out double[] faceValues, out double maxValue, out bool isDiverging)
        {
            string field;
            switch (colorBy)
            {
                case COLOR_SLAB_BENDING:
                    field = "face_bending_moment"; maxValue = maxima.Bending; isDiverging = true; break;
                case COLOR_SLAB_MEMBRANE:
                    field = "face_membrane_force"; maxValue = maxima.Membrane; isDiverging = true; break;
                case COLOR_SLAB_SHEAR:
                    field = "face_shear_force"; maxValue = maxima.Shear; isDiverging = false; break;
                case COLOR_SLAB_VON_MISES:
                    field = "face_von_mises"; maxValue = maxima.VonMises; isDiverging = false; break;
                case COLOR_SLAB_SURFACE_STRESS:
                    field = "face_surface_stress"; maxValue = maxima.SurfaceStress; isDiverging = true; break;
                default:
                    faceValues = null; maxValue = 0; isDiverging = false; return;
            }
            faceValues = m[field]?.ToObject<double[]>() ?? null;
        }

        /// <summary>
        /// Apply per-face analytical colors to a mesh via vertex colors.
        /// For signed (diverging) quantities, each vertex receives the value from the
        /// adjacent face with the largest absolute magnitude, preserving sign.
        /// For unsigned (sequential) quantities, each vertex gets the max adjacent face value.
        /// </summary>
        private static void ApplyPerFaceVertexColors(Mesh mesh, int[][] faces,
            double[] faceValues, double maxValue, bool isDiverging)
        {
            int nVerts = mesh.Vertices.Count;
            var vertVal = new double[nVerts];
            var vertAbs = new double[nVerts]; // tracks |value| for signed extremum selection

            for (int fi = 0; fi < faces.Length && fi < faceValues.Length; fi++)
            {
                double val = faceValues[fi];
                double absVal = Math.Abs(val);
                var face = faces[fi];
                if (face == null || face.Length < 3) continue;
                for (int k = 0; k < 3; k++)
                {
                    int vi = face[k] - 1;
                    if (vi < 0 || vi >= nVerts) continue;
                    if (isDiverging)
                    {
                        if (absVal > vertAbs[vi])
                        {
                            vertVal[vi] = val;
                            vertAbs[vi] = absVal;
                        }
                    }
                    else
                    {
                        if (val > vertVal[vi])
                            vertVal[vi] = val;
                    }
                }
            }

            for (int i = 0; i < nVerts; i++)
                mesh.VertexColors.Add(VisualizationColorMapper.AnalyticalColor(vertVal[i], maxValue, isDiverging));
        }

        private static void AppendDropPanelSizedGeometry(JToken slab, double zTop, double slabThickness,
            List<IGH_GeometricGoo> output, List<Color> colors, JToken analyticalSource, int colorBy,
            double maxDisp, SlabAnalyticalMaxima maxima)
        {
            var dropPanels = slab["drop_panels"] as JArray ?? new JArray();
            foreach (var dp in dropPanels)
            {
                var c = dp["center"]?.ToObject<double[]>() ?? new double[0];
                if (c.Length < 2) continue;
                double length = dp["length"]?.ToObject<double>() ?? 0.0;
                double width = dp["width"]?.ToObject<double>() ?? 0.0;
                double extra = dp["extra_depth"]?.ToObject<double>() ?? 0.0;
                if (length <= 0 || width <= 0 || extra <= 0) continue;

                double x0 = c[0] - length / 2.0;
                double x1 = c[0] + length / 2.0;
                double y0 = c[1] - width / 2.0;
                double y1 = c[1] + width / 2.0;
                double zTopDrop = zTop - slabThickness;
                double zBotDrop = zTopDrop - extra;
                var bbox = new BoundingBox(new[]
                {
                    new Point3d(x0, y0, zBotDrop), new Point3d(x1, y0, zBotDrop),
                    new Point3d(x1, y1, zBotDrop), new Point3d(x0, y1, zBotDrop),
                    new Point3d(x0, y0, zTopDrop), new Point3d(x1, y0, zTopDrop),
                    new Point3d(x1, y1, zTopDrop), new Point3d(x0, y1, zTopDrop),
                });
                var dropMesh = CreateBoxMesh(bbox);
                if (dropMesh != null)
                {
                    output.Add(new GH_Mesh(dropMesh));
                    AppendSlabColor(colors, analyticalSource, colorBy, maxDisp, "vertex_displacements", maxima);
                }
            }
        }

        /// <summary>
        /// Build deflected drop panel volumes from the slab's deflected mesh.
        /// Each drop_panel_meshes entry contains face indices into the parent mesh;
        /// the drop panel is an offset solid below the slab soffit.
        /// No fallback box geometry is generated when drop_panel_meshes is absent.
        /// </summary>
        private static void AppendDropPanelDeflectedGeometry(JToken viz, JToken meshToken, Mesh deflectedSlabMesh,
            double slabThickness, List<IGH_GeometricGoo> output,
            List<Color> colors, int colorBy, double maxDisp, string displacementField, SlabAnalyticalMaxima maxima)
        {
            var dpMeshes = meshToken["drop_panel_meshes"] as JArray;
            if (dpMeshes != null && dpMeshes.Count > 0 && deflectedSlabMesh != null)
            {
                AppendDropPanelDeflectedFromMeshes(meshToken, deflectedSlabMesh, slabThickness,
                    output, colors, colorBy, maxDisp, displacementField, maxima);
            }
        }

        private static void AppendDropPanelDeflectedFromMeshes(JToken meshToken, Mesh deflectedSlabMesh,
            double slabThickness, List<IGH_GeometricGoo> output,
            List<Color> colors, int colorBy, double maxDisp, string displacementField, SlabAnalyticalMaxima maxima)
        {
            var dpMeshes = meshToken["drop_panel_meshes"] as JArray;
            if (dpMeshes == null || dpMeshes.Count == 0 || deflectedSlabMesh == null) return;

            var allFaces = meshToken["faces"]?.ToObject<int[][]>() ?? new int[0][];
            int nSlabVerts = deflectedSlabMesh.Vertices.Count;
            if (nSlabVerts == 0 || allFaces.Length == 0) return;

            foreach (var dpm in dpMeshes)
            {
                var faceIndices = dpm["face_indices"]?.ToObject<int[]>() ?? new int[0];
                double extra = dpm["extra_depth"]?.ToObject<double>() ?? 0.0;
                if (faceIndices.Length == 0 || extra <= 0) continue;

                // Extract sub-mesh from the deflected slab mesh
                var subMesh = new Mesh();
                var vertRemap = new Dictionary<int, int>();

                foreach (int fi1 in faceIndices)
                {
                    int fi = fi1 - 1; // 1-based → 0-based
                    if (fi < 0 || fi >= allFaces.Length) continue;
                    var tri = allFaces[fi];
                    if (tri.Length < 3) continue;

                    int[] localIdx = new int[3];
                    for (int k = 0; k < 3; k++)
                    {
                        int vi = tri[k] - 1; // 1-based → 0-based
                        if (!vertRemap.TryGetValue(vi, out int li))
                        {
                            if (vi < 0 || vi >= nSlabVerts) { li = -1; }
                            else
                            {
                                li = subMesh.Vertices.Count;
                                subMesh.Vertices.Add(deflectedSlabMesh.Vertices[vi]);
                            }
                            vertRemap[vi] = li;
                        }
                        localIdx[k] = li;
                    }
                    if (localIdx[0] < 0 || localIdx[1] < 0 || localIdx[2] < 0) continue;
                    subMesh.Faces.AddFace(localIdx[0], localIdx[1], localIdx[2]);
                }

                if (subMesh.Vertices.Count == 0 || subMesh.Faces.Count == 0) continue;
                subMesh.Normals.ComputeNormals();
                subMesh.Compact();

                // Build soffit vertices (top of drop panel region) for stitching side walls,
                // and bottom vertices for the visible bottom face.
                // The top face is omitted — it's redundant with the slab soffit.
                var soffitVerts = new List<Point3d>();
                var botVerts = new List<Point3d>();
                bool isVault = meshToken["is_vault"]?.ToObject<bool>() == true;
                for (int i = 0; i < subMesh.Vertices.Count; i++)
                {
                    var pt = new Point3d(subMesh.Vertices[i]);
                    if (isVault)
                    {
                        var n = new Vector3d(subMesh.Normals[i]);
                        soffitVerts.Add(pt + n * (-slabThickness));
                        botVerts.Add(pt + n * (-(slabThickness + extra)));
                    }
                    else
                    {
                        soffitVerts.Add(pt + new Vector3d(0, 0, -slabThickness));
                        botVerts.Add(pt + new Vector3d(0, 0, -(slabThickness + extra)));
                    }
                }

                var botMesh = new Mesh();
                foreach (var bv in botVerts) botMesh.Vertices.Add(bv);
                foreach (var face in subMesh.Faces)
                {
                    if (face.IsTriangle)
                        botMesh.Faces.AddFace(face.A, face.B, face.C);
                }
                botMesh.Normals.ComputeNormals();

                var combined = new Mesh();
                combined.Append(botMesh);

                // Stitch side walls from soffit edge to bottom edge
                var soffitMesh = new Mesh();
                foreach (var sv in soffitVerts) soffitMesh.Vertices.Add(sv);
                foreach (var face in subMesh.Faces)
                {
                    if (face.IsTriangle)
                        soffitMesh.Faces.AddFace(face.A, face.B, face.C);
                }
                soffitMesh.Normals.ComputeNormals();

                var boundary = soffitMesh.GetNakedEdges();
                if (boundary != null && boundary.Length > 0)
                {
                    const double tol = 1e-6;
                    var cloud = new Rhino.Geometry.PointCloud(soffitVerts);
                    int nV = soffitVerts.Count;

                    foreach (var edge in boundary)
                    {
                        if (edge == null || edge.Count < 2) continue;
                        for (int i = 0; i < edge.Count - 1; i++)
                        {
                            int i0 = cloud.ClosestPoint(edge[i]);
                            int i1 = cloud.ClosestPoint(edge[i + 1]);
                            if (i0 < 0 || i1 < 0 || i0 >= nV || i1 >= nV) continue;
                            if (soffitVerts[i0].DistanceToSquared(edge[i]) > tol * tol) continue;
                            if (soffitVerts[i1].DistanceToSquared(edge[i + 1]) > tol * tol) continue;
                            int baseIdx = combined.Vertices.Count;
                            combined.Vertices.Add(soffitVerts[i0]);
                            combined.Vertices.Add(soffitVerts[i1]);
                            combined.Vertices.Add(botVerts[i1]);
                            combined.Vertices.Add(botVerts[i0]);
                            combined.Faces.AddFace(baseIdx, baseIdx + 1, baseIdx + 2, baseIdx + 3);
                        }
                    }
                }

                combined.Normals.ComputeNormals();
                combined.Compact();

                output.Add(new GH_Mesh(combined));
                AppendSlabColor(colors, meshToken, colorBy, maxDisp, displacementField, maxima);
            }
        }

        /// <summary>
        /// Build undeformed slab meshes from the deflected slab payload.
        /// Used by "Original" mode (Deflection=None) so users can color original geometry
        /// by utilization/deflection without drawing displaced geometry.
        /// When showVolumes is true, produces solid slab volumes with drop panels.
        /// </summary>
        private static void BuildOriginalSlabs(JToken viz, List<IGH_GeometricGoo> output,
            List<Color> colors, int colorBy, double maxDisp, SlabAnalyticalMaxima maxima,
            bool showVolumes = false)
        {
            bool isAnalyticalSlab = colorBy >= COLOR_SLAB_BENDING && colorBy <= COLOR_SLAB_SURFACE_STRESS;
            var meshes = viz["deflected_slab_meshes"] as JArray ?? new JArray();
            if (meshes.Count == 0)
            {
                BuildSizedSlabs(viz, output, colors, colorBy, maxDisp, maxima, showVolumes);
                return;
            }

            var sizedSlabs = viz["sized_slabs"] as JArray ?? new JArray();
            var sizedBySlabId = new Dictionary<int, JToken>();
            foreach (var s in sizedSlabs)
            {
                int id = s["slab_id"]?.ToObject<int>() ?? -1;
                if (id > 0 && !sizedBySlabId.ContainsKey(id))
                    sizedBySlabId[id] = s;
            }

            foreach (var m in meshes)
            {
                var verts = m["vertices"]?.ToObject<double[][]>() ?? new double[0][];
                var faces = m["faces"]?.ToObject<int[][]>() ?? new int[0][];
                if (verts.Length == 0) continue;

                int slabId = m["slab_id"]?.ToObject<int>() ?? -1;
                sizedBySlabId.TryGetValue(slabId, out var sizedSlab);
                double thickness = m["thickness"]?.ToObject<double>()
                    ?? sizedSlab?["thickness"]?.ToObject<double>() ?? 0;
                double zTop = sizedSlab?["z_top"]?.ToObject<double>() ?? 0;

                // Volume path: reuse TryBuildSizedSlabFromMesh for correct solid geometry
                bool isVault = m["is_vault"]?.ToObject<bool>() == true;
                if (showVolumes && TryBuildSizedSlabFromMesh(m, thickness, true, output, offsetAlongNormal: isVault))
                {
                    AppendSlabColor(colors, m, colorBy, maxDisp, "vertex_displacements", maxima);
                    if (sizedSlab != null)
                        AppendDropPanelSizedGeometry(sizedSlab, zTop, thickness, output, colors,
                            m, colorBy, maxDisp, maxima);
                    continue;
                }

                // Surface-only path: build mesh with vertex colors
                double[] faceAnalytical = null;
                double analyticalMax = 0;
                bool analyticalDiverging = false;
                if (isAnalyticalSlab)
                    ResolveSlabAnalyticalData(m, colorBy, maxima,
                        out faceAnalytical, out analyticalMax, out analyticalDiverging);

                var rhinoMesh = new Mesh();
                for (int i = 0; i < verts.Length; i++)
                    rhinoMesh.Vertices.Add(new Point3d(verts[i][0], verts[i][1], verts[i][2]));

                foreach (var face in faces)
                {
                    if (face.Length < 3) continue;
                    int i0 = face[0] - 1, i1 = face[1] - 1, i2 = face[2] - 1;
                    if (i0 < 0 || i1 < 0 || i2 < 0 ||
                        i0 >= rhinoMesh.Vertices.Count ||
                        i1 >= rhinoMesh.Vertices.Count ||
                        i2 >= rhinoMesh.Vertices.Count) continue;
                    rhinoMesh.Faces.AddFace(i0, i1, i2);
                }

                if (colorBy == COLOR_UTILIZATION)
                {
                    double ratio = m["utilization_ratio"]?.ToObject<double>() ?? 0;
                    bool ok = m["ok"]?.ToObject<bool>() ?? true;
                    var utilColor = VisualizationColorMapper.UtilizationColor(ratio, ok, null);
                    for (int i = 0; i < rhinoMesh.Vertices.Count; i++)
                        rhinoMesh.VertexColors.Add(utilColor);
                }
                else if (colorBy == COLOR_DEFLECTION)
                {
                    var disps = m["vertex_displacements"]?.ToObject<double[][]>() ?? Array.Empty<double[]>();
                    for (int i = 0; i < rhinoMesh.Vertices.Count; i++)
                    {
                        double mag = 0;
                        if (i < disps.Length && disps[i].Length >= 3)
                            mag = Math.Sqrt(disps[i][0] * disps[i][0] +
                                            disps[i][1] * disps[i][1] +
                                            disps[i][2] * disps[i][2]);
                        rhinoMesh.VertexColors.Add(VisualizationColorMapper.DeflectionColor(mag, maxDisp, null));
                    }
                }
                else if (isAnalyticalSlab && faceAnalytical != null)
                {
                    ApplyPerFaceVertexColors(rhinoMesh, faces, faceAnalytical, analyticalMax, analyticalDiverging);
                }

                if (rhinoMesh.Vertices.Count > 0 && rhinoMesh.Faces.Count > 0)
                {
                    rhinoMesh.Normals.ComputeNormals();
                    rhinoMesh.Compact();
                    output.Add(new GH_Mesh(rhinoMesh));
                    AppendSlabColor(colors, m, colorBy, maxDisp, "vertex_displacements", maxima);
                }
            }
        }

        private static void BuildFoundations(JToken viz, List<IGH_GeometricGoo> output,
            List<Color> foundationColors, int colorBy)
        {
            var foundations = viz["foundations"] as JArray ?? new JArray();
            foreach (var f in foundations)
            {
                var c = f["center"]?.ToObject<double[]>() ?? new double[3];
                if (c.Length < 3) continue;
                double length = f["length"]?.ToObject<double>() ?? 0;
                double width = f["width"]?.ToObject<double>() ?? 0;
                double depth = f["depth"]?.ToObject<double>() ?? 0;
                if (length <= 0 || width <= 0 || depth <= 0) continue;

                // Strip footings: when along_x is true, long axis (length) runs in X
                bool alongX = f["along_x"]?.ToObject<bool>() ?? false;
                double halfX = alongX ? length / 2.0 : width / 2.0;
                double halfY = alongX ? width / 2.0 : length / 2.0;
                double x0 = c[0] - halfX;
                double x1 = c[0] + halfX;
                double y0 = c[1] - halfY;
                double y1 = c[1] + halfY;
                double zTop = c[2];
                double zBot = zTop - depth;

                var bbox = new BoundingBox(new[]
                {
                    new Point3d(x0, y0, zBot), new Point3d(x1, y0, zBot),
                    new Point3d(x1, y1, zBot), new Point3d(x0, y1, zBot),
                    new Point3d(x0, y0, zTop), new Point3d(x1, y0, zTop),
                    new Point3d(x1, y1, zTop), new Point3d(x0, y1, zTop),
                });
                var mesh = CreateBoxMesh(bbox);
                if (mesh != null)
                {
                    output.Add(new GH_Mesh(mesh));
                    if (colorBy == COLOR_UTILIZATION)
                    {
                        double ratio = f["utilization_ratio"]?.ToObject<double>() ?? 0;
                        bool ok = f["ok"]?.ToObject<bool>() ?? true;
                        foundationColors.Add(VisualizationColorMapper.UtilizationColor(ratio, ok, null));
                    }
                    else if (colorBy == COLOR_DEFLECTION)
                    {
                        foundationColors.Add(VisualizationColorMapper.DeflectionColor(0.0, 1.0, null));
                    }
                    else if (colorBy == COLOR_MATERIAL)
                    {
                        foundationColors.Add(VisualizationColorMapper.ResolveMaterialColor(f["material_color_hex"]?.ToString(), VisualizationColorMapper.ConcreteMaterialColor));
                    }
                    else
                    {
                        foundationColors.Add(VisualizationColorMapper.ConcreteMaterialColor);
                    }
                }
            }
        }

        /// <summary>
        /// Append one color per slab/mesh element to the parallel color list.
        /// For deflection mode on meshes, per-vertex coloring is handled above;
        /// this still outputs one representative color for the Custom Preview pipeline.
        /// Vaults use earthen material color; flat slabs use concrete color.
        /// </summary>
        private static void AppendSlabColor(List<Color> colors, JToken element,
            int colorBy, double maxDisp, string displacementField, SlabAnalyticalMaxima maxima)
        {
            bool isVault = element["is_vault"]?.ToObject<bool>() ?? false;
            bool isAnalyticalSlab = colorBy >= COLOR_SLAB_BENDING && colorBy <= COLOR_SLAB_SURFACE_STRESS;

            if (colorBy == COLOR_UTILIZATION)
            {
                double ratio = element["utilization_ratio"]?.ToObject<double>() ?? 0;
                bool ok = element["ok"]?.ToObject<bool>() ?? true;
                colors.Add(VisualizationColorMapper.UtilizationColor(ratio, ok, null));
            }
            else if (colorBy == COLOR_DEFLECTION)
            {
                var disps = element[displacementField]?.ToObject<double[][]>();
                double maxVertDisp = 0;
                if (disps != null)
                {
                    foreach (var d in disps)
                    {
                        if (d.Length >= 3)
                        {
                            double mag = Math.Sqrt(d[0] * d[0] + d[1] * d[1] + d[2] * d[2]);
                            if (mag > maxVertDisp) maxVertDisp = mag;
                        }
                    }
                }
                colors.Add(VisualizationColorMapper.DeflectionColor(maxVertDisp, maxDisp, null));
            }
            else if (colorBy == COLOR_MATERIAL)
            {
                var fallback = isVault
                    ? VisualizationColorMapper.EarthenMaterialColor
                    : VisualizationColorMapper.ConcreteMaterialColor;
                colors.Add(VisualizationColorMapper.ResolveMaterialColor(
                    element["material_color_hex"]?.ToString(), fallback));
            }
            else if (isAnalyticalSlab)
            {
                ResolveSlabAnalyticalData(element, colorBy, maxima,
                    out var faceValues, out var maxVal, out var diverging);
                double repValue = 0;
                if (faceValues != null && faceValues.Length > 0)
                {
                    if (diverging)
                    {
                        double repAbs = 0;
                        foreach (var v in faceValues)
                        {
                            if (Math.Abs(v) > repAbs) { repAbs = Math.Abs(v); repValue = v; }
                        }
                    }
                    else
                    {
                        foreach (var v in faceValues)
                            if (v > repValue) repValue = v;
                    }
                }
                colors.Add(VisualizationColorMapper.AnalyticalColor(repValue, maxVal, diverging));
            }
            else
            {
                var fallback = isVault
                    ? VisualizationColorMapper.EarthenMaterialColor
                    : VisualizationColorMapper.ConcreteMaterialColor;
                colors.Add(VisualizationColorMapper.ResolveMaterialColor(
                    element["material_color_hex"]?.ToString(), fallback));
            }
        }
    }
}
