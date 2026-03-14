using System;
using System.Collections.Generic;
using System.Drawing;
using System.Globalization;
using System.Linq;
using System.Windows.Forms;
using Grasshopper.Kernel;
using Grasshopper.Kernel.Parameters;
using Grasshopper.Kernel.Types;
using Newtonsoft.Json.Linq;
using Rhino.Geometry;
using Menegroth.GH.Types;

namespace Menegroth.GH.Components
{
    /// <summary>
    /// Visualizes structural design geometry with optional deflection and coloring.
    /// Uses input-level dropdown parameters for Mode and Color By selection.
    /// </summary>
    public class Visualization : GH_Component
    {
        private const int MODE_SIZED = 0;
        private const int MODE_DEFLECTED_GLOBAL = 1;
        private const int MODE_DEFLECTED_LOCAL = 2;
        private const int MODE_ORIGINAL = 3;

        private const int COLOR_NONE = 0;
        private const int COLOR_UTILIZATION = 1;
        private const int COLOR_DEFLECTION = 2;
        private static readonly Color COLUMN_TYPE_COLOR = Color.SteelBlue;
        private static readonly Color BEAM_TYPE_COLOR = Color.Coral;
        private static readonly Color OTHER_TYPE_COLOR = Color.DimGray;
        private const int DEFLECTION_SEGMENTS_MIN = 3;
        private const int DEFLECTION_SEGMENTS_MAX = 6;
        private const int SLAB_VERTEX_WARNING_THRESHOLD = 200000;
        private bool _useInternalPreview = true;
        private bool _showOriginal = true;
        private bool _showSlabs = true;
        private bool _showBeams = true;
        private bool _showColumns = true;
        private bool _showFoundations = true;
        private bool _beamVisibilityInitialized = false;
        private readonly List<Curve> _previewColumnCurves = new List<Curve>();
        private readonly List<Color> _previewColumnColors = new List<Color>();
        private readonly List<Curve> _previewBeamCurves = new List<Curve>();
        private readonly List<Color> _previewBeamColors = new List<Color>();
        private readonly List<Curve> _previewOriginalCurves = new List<Curve>();
        private readonly List<Mesh> _previewShadedMeshes = new List<Mesh>();
        private readonly List<Color> _previewShadedColors = new List<Color>();

        public Visualization()
            : base("Visualization",
                   "Viz",
                   "Visualize structural design with geometry, deflections, and color mapping",
                   "Menegroth", "Core")
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
            Menu_AppendItem(menu, "Show Original", (s, e) =>
            {
                _showOriginal = !_showOriginal;
                ExpirePreview(true);
                ExpireSolution(true);
            }, true, _showOriginal);

            var showMenu = new ToolStripMenuItem("Show");
            showMenu.DropDownItems.Add(new ToolStripMenuItem("Slabs", null, (s, e) =>
            {
                _showSlabs = !_showSlabs;
                ExpirePreview(true);
                ExpireSolution(true);
            }) { Checked = _showSlabs });
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
            showMenu.DropDownItems.Add(new ToolStripMenuItem("Foundations", null, (s, e) =>
            {
                _showFoundations = !_showFoundations;
                ExpirePreview(true);
                ExpireSolution(true);
            }) { Checked = _showFoundations });
            menu.Items.Add(showMenu);
        }

        public override bool Write(GH_IO.Serialization.GH_IWriter writer)
        {
            writer.SetBoolean("UseInternalPreview", _useInternalPreview);
            writer.SetBoolean("ShowOriginal", _showOriginal);
            writer.SetBoolean("ShowSlabs", _showSlabs);
            writer.SetBoolean("ShowBeams", _showBeams);
            writer.SetBoolean("ShowColumns", _showColumns);
            writer.SetBoolean("ShowFoundations", _showFoundations);
            writer.SetBoolean("BeamVisibilityInitialized", _beamVisibilityInitialized);
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
            if (reader.ItemExists("BeamVisibilityInitialized"))
                _beamVisibilityInitialized = reader.GetBoolean("BeamVisibilityInitialized");
            else if (reader.ItemExists("ShowBeams"))
                _beamVisibilityInitialized = true;
            return base.Read(reader);
        }

        protected override void RegisterInputParams(GH_InputParamManager pManager)
        {
            pManager.AddGenericParameter("Result", "Result",
                "DesignResult from the DesignRun component", GH_ParamAccess.item);

            var modeParam = new Param_Integer();
            modeParam.AddNamedValue("Sized", MODE_SIZED);
            modeParam.AddNamedValue("Deflected (Global)", MODE_DEFLECTED_GLOBAL);
            modeParam.AddNamedValue("Deflected (Local)", MODE_DEFLECTED_LOCAL);
            modeParam.AddNamedValue("Original", MODE_ORIGINAL);
            pManager.AddParameter(modeParam, "Mode", "Mode",
                "Visualization mode: Sized shows as-designed geometry, " +
                "Deflected Global/Local shows displaced shapes",
                GH_ParamAccess.item);
            pManager[1].Optional = true;

            pManager.AddNumberParameter("Scale", "Scale",
                "Deflection scale multiplier (0 = no deflection, 1 = auto-suggested, >1 = exaggerated)",
                GH_ParamAccess.item, 1.0);

            var colorParam = new Param_Integer();
            colorParam.AddNamedValue("None", COLOR_NONE);
            colorParam.AddNamedValue("Utilization", COLOR_UTILIZATION);
            colorParam.AddNamedValue("Deflection", COLOR_DEFLECTION);
            pManager.AddParameter(colorParam, "Color By", "ColorBy",
                "Color mapping: None, Utilization (green→red by demand/capacity), " +
                "Deflection (blue→red by displacement magnitude)",
                GH_ParamAccess.item);
            pManager[3].Optional = true;

            pManager.AddColourParameter("Utilization Gradient", "UtilizationGradient",
                "Optional utilization gradient colors (low→high). Leave empty for defaults.",
                GH_ParamAccess.list);
            pManager[4].Optional = true;

            pManager.AddColourParameter("Deflection Gradient", "DeflectionGradient",
                "Optional deflection gradient colors (low→high). Leave empty for defaults.",
                GH_ParamAccess.list);
            pManager[5].Optional = true;
        }

        protected override void RegisterOutputParams(GH_OutputParamManager pManager)
        {
            pManager.AddGenericParameter("Frame Geometry", "FrameGeometry",
                "Frame element 3D section geometry (Brep)", GH_ParamAccess.list);
            pManager.AddGenericParameter("Slab Geometry", "SlabGeometry",
                "Slab + foundation geometry (Brep for Sized, Mesh for Deflected)", GH_ParamAccess.list);
            pManager.AddCurveParameter("Column Curves", "ColumnCurves",
                "Column curves for preview/debug", GH_ParamAccess.list);
            pManager.AddCurveParameter("Beam Curves", "BeamCurves",
                "Beam curves for preview/debug", GH_ParamAccess.list);
            pManager.AddGenericParameter("Column Geometry", "ColumnGeometry",
                "Column section geometry as Breps", GH_ParamAccess.list);
            pManager.AddGenericParameter("Beam Geometry", "BeamGeometry",
                "Beam section geometry as Breps", GH_ParamAccess.list);
        }

        protected override void SolveInstance(IGH_DataAccess DA)
        {
            GH_DesignResult goo = null;
            if (!DA.GetData(0, ref goo) || goo?.Value == null) return;

            var result = goo.Value;
            if (result.IsError)
            {
                AddRuntimeMessage(GH_RuntimeMessageLevel.Error, result.ErrorMessage);
                return;
            }

            var viz = result.Visualization;
            if (viz == null)
            {
                AddRuntimeMessage(GH_RuntimeMessageLevel.Warning,
                    "No visualization data available. Analysis model may not be built.");
                return;
            }

            // Read inputs with defaults
            int modeInt = MODE_DEFLECTED_GLOBAL;
            DA.GetData(1, ref modeInt);

            double scaleMult = 1.0;
            DA.GetData(2, ref scaleMult);

            bool showOriginal = _showOriginal;

            int colorByInt = COLOR_UTILIZATION;
            DA.GetData(3, ref colorByInt);

            var utilizationGradient = new List<Color>();
            DA.GetDataList(4, utilizationGradient);
            var deflectionGradient = new List<Color>();
            DA.GetDataList(5, deflectionGradient);

            bool isDeflected = modeInt == MODE_DEFLECTED_GLOBAL || modeInt == MODE_DEFLECTED_LOCAL;
            bool isLocal = modeInt == MODE_DEFLECTED_LOCAL;
            bool isOriginalMode = modeInt == MODE_ORIGINAL;
            bool showFoundationsEffective = _showFoundations && !isDeflected;
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
                var posArr = n["position"]?.ToObject<double[]>() ?? n["position_ft"]?.ToObject<double[]>() ?? new double[3];
                var dispArr = n["displacement"]?.ToObject<double[]>() ?? n["displacement_ft"]?.ToObject<double[]>() ?? new double[3];
                var defPosArr = n["deflected_position"]?.ToObject<double[]>() ?? n["deflected_position_ft"]?.ToObject<double[]>();
                var pos = new Point3d(posArr[0], posArr[1], posArr[2]);
                var disp = new Vector3d(dispArr[0], dispArr[1], dispArr[2]);
                var defPos = defPosArr != null && defPosArr.Length >= 3
                    ? new Point3d(defPosArr[0], defPosArr[1], defPosArr[2])
                    : pos + disp;
                nodes[nodeId] = (
                    pos,
                    disp,
                    defPos
                );
            }

            double finalScale = scaleMult * result.SuggestedScaleFactor;
            double maxDisp = result.MaxDisplacementFt;

            // Warn early when deflected mesh payload is likely to exhaust viewport memory.
            var slabMeshes = viz["deflected_slab_meshes"] as JArray ?? new JArray();
            int totalSlabVerts = 0;
            foreach (var sm in slabMeshes)
            {
                var vv = sm["vertices"]?.ToObject<double[][]>() ?? Array.Empty<double[]>();
                totalSlabVerts += vv.Length;
            }
            if (totalSlabVerts > SLAB_VERTEX_WARNING_THRESHOLD)
            {
                AddRuntimeMessage(GH_RuntimeMessageLevel.Warning,
                    $"Large slab mesh payload ({totalSlabVerts:N0} vertices). Consider hiding slabs/foundations or reducing analysis mesh density.");
            }

            // Frame elements
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
                    {
                        if (isLocal && elemType == "column")
                        {
                            // Local mode: keep column bases at original floor coordinates and move tops.
                            bool startIsBottom = nodes[ns].pos.Z <= nodes[ne].pos.Z;
                            if (startIsBottom)
                            {
                                p1 = nodes[ns].pos;
                                p2 = nodes[ne].pos + (nodes[ne].defPos - nodes[ne].pos) * finalScale;
                            }
                            else
                            {
                                p2 = nodes[ne].pos;
                                p1 = nodes[ns].pos + (nodes[ns].defPos - nodes[ns].pos) * finalScale;
                            }
                        }
                        else
                        {
                            // Global mode (and local non-columns): follow displaced node coordinates.
                            p1 = p1 + (nodes[ns].defPos - nodes[ns].pos) * finalScale;
                            p2 = p2 + (nodes[ne].defPos - nodes[ne].pos) * finalScale;
                        }
                    }

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

                            if (isLocal && dispVecs.Length >= 2 && elemType != "column")
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

                            pts.Add(op + dv * finalScale);
                        }
                        else
                        {
                            pts.Add(op);
                        }
                    }

                    if (isDeflected && finalScale > 0 && pts.Count > 1 && hasStartNode && hasEndNode)
                    {
                        Point3d targetStart;
                        Point3d targetEnd;
                        if (isLocal && elemType == "column")
                        {
                            bool startIsBottom = nodes[ns].pos.Z <= nodes[ne].pos.Z;
                            if (startIsBottom)
                            {
                                targetStart = nodes[ns].pos;
                                targetEnd = nodes[ne].pos + (nodes[ne].defPos - nodes[ne].pos) * finalScale;
                            }
                            else
                            {
                                targetEnd = nodes[ne].pos;
                                targetStart = nodes[ns].pos + (nodes[ns].defPos - nodes[ns].pos) * finalScale;
                            }
                        }
                        else
                        {
                            targetStart = nodes[ns].pos + (nodes[ns].defPos - nodes[ns].pos) * finalScale;
                            targetEnd = nodes[ne].pos + (nodes[ne].defPos - nodes[ne].pos) * finalScale;
                        }

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

                Color elementColor;
                if (colorByInt == COLOR_UTILIZATION)
                {
                    double ratio = elem["utilization_ratio"]?.ToObject<double>() ?? 0;
                    bool ok = elem["ok"]?.ToObject<bool>() ?? true;
                    elementColor = UtilizationColor(ratio, ok, utilizationGradient);
                }
                else if (colorByInt == COLOR_DEFLECTION)
                {
                    double disp = ComputeElementDisplacement(elem, nodes, dispVecs);
                    elementColor = DeflectionColor(disp, maxDisp, deflectionGradient);
                }
                else
                {
                    // Keep line colors visible when Color By = None.
                    // Member-type defaults make CC/BC previews immediately readable.
                    elementColor = elemType == "column" ? COLUMN_TYPE_COLOR
                        : elemType == "beam" ? BEAM_TYPE_COLOR
                        : OTHER_TYPE_COLOR;
                    var materialColor = ParseHexColor(elem["material_color_hex"]?.ToString());
                    if (materialColor.HasValue)
                        elementColor = materialColor.Value;
                }

                var brep = SweepSection(elementCurve, elem);
                if (brep != null)
                {
                    frameGeometry.Add(new GH_Brep(brep));
                    frameGeometryColors.Add(elementColor);
                    if (elemType == "column")
                        columnGeometry.Add(new GH_Brep(brep));
                    else if (elemType == "beam")
                        beamGeometry.Add(new GH_Brep(brep));
                }

                // Always parallel to frameCurves
                frameColors.Add(elementColor);

                if (elemType == "column")
                {
                    if (colorByInt == COLOR_DEFLECTION)
                    {
                        AppendDeflectionSegmentedCurves(
                            elementCurve, dispVecs, nodes, ns, ne, isLocal, maxDisp,
                            columnCurves, columnColors, deflectionGradient);
                    }
                    else
                    {
                        columnCurves.Add(elementCurve);
                        columnColors.Add(elementColor);
                    }
                }
                else if (elemType == "beam")
                {
                    if (colorByInt == COLOR_DEFLECTION)
                    {
                        AppendDeflectionSegmentedCurves(
                            elementCurve, dispVecs, nodes, ns, ne, isLocal, maxDisp,
                            beamCurves, beamColors, deflectionGradient);
                    }
                    else
                    {
                        beamCurves.Add(elementCurve);
                        beamColors.Add(elementColor);
                    }
                }
            }

            // Slab geometry + colors
            var slabGeometry = new List<IGH_GeometricGoo>();
            var foundationGeometry = new List<IGH_GeometricGoo>();
            var slabColors = new List<Color>();
            var originalSlabs = new List<IGH_GeometricGoo>();

            if (_showSlabs)
            {
                if (isOriginalMode)
                    BuildOriginalSlabs(viz, slabGeometry, slabColors, colorByInt, maxDisp, utilizationGradient, deflectionGradient);
                else if (!isDeflected || finalScale <= 0)
                    BuildSizedSlabs(viz, slabGeometry, slabColors, colorByInt, maxDisp, utilizationGradient, deflectionGradient);
                else
                    BuildDeflectedSlabs(viz, finalScale, showOriginal, slabGeometry, originalSlabs,
                        slabColors, colorByInt, maxDisp, isLocal, utilizationGradient, deflectionGradient);
            }

            if (showFoundationsEffective)
                BuildFoundations(viz, foundationGeometry, slabColors, colorByInt, utilizationGradient, deflectionGradient);

            var visibleSlabGeometry = new List<IGH_GeometricGoo>();
            if (_showSlabs)
                visibleSlabGeometry.AddRange(slabGeometry);
            if (showFoundationsEffective)
                visibleSlabGeometry.AddRange(foundationGeometry);

            if (showOriginal && isOriginalMode)
            {
                originalCurves.AddRange(frameCurves);
                originalSlabs.AddRange(visibleSlabGeometry);
            }

            // Set outputs (trimmed surface API; component provides internal preview colors)
            DA.SetDataList(0, frameGeometry);
            DA.SetDataList(1, visibleSlabGeometry);
            DA.SetDataList(2, columnCurves);
            DA.SetDataList(3, beamCurves);
            DA.SetDataList(4, columnGeometry);
            DA.SetDataList(5, beamGeometry);

            UpdateInternalPreviewCache(
                columnCurves, columnColors,
                beamCurves, beamColors,
                originalCurves,
                frameGeometry, frameGeometryColors,
                visibleSlabGeometry, slabColors);

            // Update message bar
            string modeName = modeInt == MODE_SIZED ? "Sized"
                : modeInt == MODE_DEFLECTED_LOCAL ? "Deflected (Local)"
                : modeInt == MODE_ORIGINAL ? "Original"
                : "Deflected (Global)";
            string colorName = colorByInt == COLOR_UTILIZATION ? "Utilization"
                : colorByInt == COLOR_DEFLECTION ? "Deflection" : "";
            Message = colorName.Length > 0 ? $"{modeName} | {colorName}" : modeName;
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

            int n = Math.Min(_previewShadedMeshes.Count, _previewShadedColors.Count);
            for (int i = 0; i < n; i++)
            {
                var m = _previewShadedMeshes[i];
                if (m == null) continue;
                var material = new Rhino.Display.DisplayMaterial(_previewShadedColors[i]);
                args.Display.DrawMeshShaded(m, material);
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

        private static Brep SweepSection(Curve elementCurve, JToken elem)
        {
            var poly = elem["section_polygon"]?.ToObject<double[][]>() ?? new double[0][];
            double depth = elem["section_depth"]?.ToObject<double>() ?? elem["section_depth_ft"]?.ToObject<double>() ?? 0;
            double width = elem["section_width"]?.ToObject<double>() ?? elem["section_width_ft"]?.ToObject<double>() ?? 0;

            if (poly.Length < 3)
            {
                if (depth <= 0 || width <= 0) return null;
                poly = new[]
                {
                    new[] { -width / 2, -depth / 2 },
                    new[] {  width / 2, -depth / 2 },
                    new[] {  width / 2,  depth / 2 },
                    new[] { -width / 2,  depth / 2 },
                };
            }

            try
            {
                elementCurve.Domain = new Interval(0.0, 1.0);
                var tangent = elementCurve.TangentAtStart;
                tangent.Unitize();

                Vector3d up = Math.Abs(tangent.Z) < 0.9
                    ? new Vector3d(0, 0, 1)
                    : new Vector3d(1, 0, 0);
                var localY = Vector3d.CrossProduct(up, tangent); localY.Unitize();
                var localZ = Vector3d.CrossProduct(tangent, localY); localZ.Unitize();

                var pts = new List<Point3d>();
                var origin = elementCurve.PointAtStart;
                foreach (var v in poly)
                    pts.Add(origin + localY * v[0] + localZ * v[1]);
                if (pts.Count > 0 && pts[0].DistanceTo(pts[pts.Count - 1]) > 1e-6)
                    pts.Add(pts[0]);

                var sectionCurve = new PolylineCurve(pts);
                var sweep = Brep.CreateFromSweep(elementCurve, sectionCurve, true, 0.01);
                if (sweep?.Length > 0) return sweep[0];
            }
            catch
            {
                // Fall through to robust pipe fallback.
            }

            // Robust fallback for unsupported/degenerate section sweeps.
            // Equivalent radius from rectangular area keeps approximate visual mass.
            double area = Math.Max(width, 0.01) * Math.Max(depth, 0.01);
            double radius = Math.Sqrt(area / Math.PI);
            var pipe = Brep.CreatePipe(elementCurve, radius, false, PipeCapMode.Flat, true, 0.01, 0.01);
            return pipe != null && pipe.Length > 0 ? pipe[0] : null;
        }

        // ─── Utilization color mapping ────────────────────────────────

        /// <summary>
        /// Green → yellow → red gradient by utilization ratio (0 → 1).
        /// Elements above 1.0 or failing are magenta.
        /// </summary>
        private static Color UtilizationColor(double ratio, bool ok, IList<Color> gradient = null)
        {
            if (!ok || ratio > 1.0)
                return Color.FromArgb(200, 0, 120);

            ratio = Math.Max(0.0, Math.Min(ratio, 1.0));
            if (gradient != null && gradient.Count >= 2)
                return InterpolateGradient(gradient, ratio);

            int r, g, b;
            if (ratio <= 0.5)
            {
                double t = ratio / 0.5;
                r = (int)(0 + t * 220);
                g = (int)(180 + t * 20);
                b = 0;
            }
            else
            {
                double t = (ratio - 0.5) / 0.5;
                r = 220;
                g = (int)(200 - t * 160);
                b = 0;
            }

            return Color.FromArgb(r, g, b);
        }

        // ─── Deflection color mapping ─────────────────────────────────

        /// <summary>
        /// Blue → cyan → yellow → red gradient by displacement magnitude.
        /// Normalized against the building's max displacement.
        /// </summary>
        private static Color DeflectionColor(double displacement, double maxDisplacement, IList<Color> gradient = null)
        {
            if (maxDisplacement < 1e-12)
                return Color.FromArgb(40, 80, 200);

            double t = Math.Max(0.0, Math.Min(displacement / maxDisplacement, 1.0));
            if (gradient != null && gradient.Count >= 2)
                return InterpolateGradient(gradient, t);

            int r, g, b;
            if (t <= 0.33)
            {
                double s = t / 0.33;
                r = (int)(40 * (1 - s));
                g = (int)(80 + s * 175);
                b = (int)(200 * (1 - s) + s * 200);
            }
            else if (t <= 0.66)
            {
                double s = (t - 0.33) / 0.33;
                r = (int)(s * 240);
                g = (int)(255 - s * 55);
                b = (int)(200 * (1 - s));
            }
            else
            {
                double s = (t - 0.66) / 0.34;
                r = (int)(240 - s * 20);
                g = (int)(200 * (1 - s) + s * 30);
                b = 0;
            }

            return Color.FromArgb(
                Math.Max(0, Math.Min(255, r)),
                Math.Max(0, Math.Min(255, g)),
                Math.Max(0, Math.Min(255, b)));
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
            List<Color> targetColors,
            IList<Color> deflectionGradient)
        {
            if (sourceCurve == null)
                return;

            var mags = ComputeDisplacementMagnitudes(dispVecs, nodes, nodeStart, nodeEnd, isLocal);
            int baseSegments = mags.Length > 1 ? mags.Length - 1 : DEFLECTION_SEGMENTS_MIN;
            int segments = Math.Max(DEFLECTION_SEGMENTS_MIN, Math.Min(DEFLECTION_SEGMENTS_MAX, baseSegments));

            if (segments <= 1)
            {
                targetCurves.Add(sourceCurve);
                targetColors.Add(DeflectionColor(mags.Length > 0 ? mags[0] : 0.0, maxDisp, deflectionGradient));
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
                targetColors.Add(DeflectionColor(InterpolateMagnitude(mags, tmn), maxDisp, deflectionGradient));
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

        private static string NormalizeElementType(string rawType)
        {
            string t = (rawType ?? "").Trim().ToLowerInvariant();
            if (t == "brace")
                return "strut";
            return t;
        }

        private static Color? ParseHexColor(string hex)
        {
            if (string.IsNullOrWhiteSpace(hex))
                return null;

            string s = hex.Trim();
            if (s.StartsWith("#", StringComparison.Ordinal))
                s = s.Substring(1);

            if (s.Length == 6)
            {
                if (!int.TryParse(s.Substring(0, 2), NumberStyles.HexNumber, CultureInfo.InvariantCulture, out int r) ||
                    !int.TryParse(s.Substring(2, 2), NumberStyles.HexNumber, CultureInfo.InvariantCulture, out int g) ||
                    !int.TryParse(s.Substring(4, 2), NumberStyles.HexNumber, CultureInfo.InvariantCulture, out int b))
                    return null;
                return Color.FromArgb(r, g, b);
            }

            if (s.Length == 8)
            {
                if (!int.TryParse(s.Substring(0, 2), NumberStyles.HexNumber, CultureInfo.InvariantCulture, out int r) ||
                    !int.TryParse(s.Substring(2, 2), NumberStyles.HexNumber, CultureInfo.InvariantCulture, out int g) ||
                    !int.TryParse(s.Substring(4, 2), NumberStyles.HexNumber, CultureInfo.InvariantCulture, out int b) ||
                    !int.TryParse(s.Substring(6, 2), NumberStyles.HexNumber, CultureInfo.InvariantCulture, out int a))
                    return null;
                return Color.FromArgb(a, r, g, b);
            }

            return null;
        }

        private static Color InterpolateGradient(IList<Color> gradient, double t)
        {
            if (gradient == null || gradient.Count == 0)
                return Color.White;
            if (gradient.Count == 1)
                return gradient[0];

            t = Math.Max(0.0, Math.Min(1.0, t));
            double pos = t * (gradient.Count - 1);
            int i0 = (int)Math.Floor(pos);
            int i1 = Math.Min(i0 + 1, gradient.Count - 1);
            double a = pos - i0;
            var c0 = gradient[i0];
            var c1 = gradient[i1];
            return Color.FromArgb(
                (int)(c0.R * (1.0 - a) + c1.R * a),
                (int)(c0.G * (1.0 - a) + c1.G * a),
                (int)(c0.B * (1.0 - a) + c1.B * a));
        }

        private void UpdateInternalPreviewCache(
            List<Curve> columnCurves, List<Color> columnColors,
            List<Curve> beamCurves, List<Color> beamColors,
            List<Curve> originalCurves,
            List<IGH_GeometricGoo> frameGeometry, List<Color> frameGeometryColors,
            List<IGH_GeometricGoo> slabGeometry, List<Color> slabColors)
        {
            _previewColumnCurves.Clear();
            _previewColumnColors.Clear();
            _previewBeamCurves.Clear();
            _previewBeamColors.Clear();
            _previewOriginalCurves.Clear();
            _previewShadedMeshes.Clear();
            _previewShadedColors.Clear();

            for (int i = 0; i < Math.Min(columnCurves.Count, columnColors.Count); i++)
            {
                if (columnCurves[i] == null) continue;
                _previewColumnCurves.Add(columnCurves[i].DuplicateCurve());
                _previewColumnColors.Add(columnColors[i]);
            }

            for (int i = 0; i < Math.Min(beamCurves.Count, beamColors.Count); i++)
            {
                if (beamCurves[i] == null) continue;
                _previewBeamCurves.Add(beamCurves[i].DuplicateCurve());
                _previewBeamColors.Add(beamColors[i]);
            }

            foreach (var c in originalCurves)
            {
                if (c == null) continue;
                _previewOriginalCurves.Add(c.DuplicateCurve());
            }

            CacheShadedBreps(frameGeometry, frameGeometryColors);
            CacheShadedBreps(slabGeometry, slabColors);
        }

        private void CacheShadedBreps(List<IGH_GeometricGoo> geometry, List<Color> colors)
        {
            if (geometry == null || colors == null) return;
            int n = Math.Min(geometry.Count, colors.Count);
            for (int i = 0; i < n; i++)
            {
                if (!(geometry[i] is GH_Brep ghBrep) || ghBrep.Value == null)
                    continue;
                var meshes = Mesh.CreateFromBrep(ghBrep.Value, MeshingParameters.FastRenderMesh);
                if (meshes == null || meshes.Length == 0)
                    continue;
                foreach (var m in meshes)
                {
                    if (m == null) continue;
                    _previewShadedMeshes.Add(m.DuplicateMesh());
                    _previewShadedColors.Add(colors[i]);
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

        private static void BuildSizedSlabs(JToken viz, List<IGH_GeometricGoo> output,
            List<Color> colors, int colorBy, double maxDisp, IList<Color> utilGradient, IList<Color> deflectionGradient)
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
                if (slabId > 0 &&
                    meshBySlabId.TryGetValue(slabId, out var meshToken) &&
                    TryBuildCurvedSizedSlabFromMesh(meshToken, output))
                {
                    AppendSlabColor(colors, slab, colorBy, maxDisp, "vertex_displacements", utilGradient, deflectionGradient);
                    continue;
                }

                var boundary = slab["boundary_vertices"]?.ToObject<double[][]>() ?? new double[0][];
                double thickness = slab["thickness"]?.ToObject<double>() ?? slab["thickness_ft"]?.ToObject<double>() ?? 0;
                double zTop = slab["z_top"]?.ToObject<double>() ?? slab["z_top_ft"]?.ToObject<double>() ?? 0;
                if (boundary.Length < 3) continue;

                var topPts = boundary.Select(v => new Point3d(v[0], v[1], zTop)).ToList();
                topPts.Add(topPts[0]);
                var bottomPts = topPts.Select(p => new Point3d(p.X, p.Y, p.Z - thickness)).ToList();

                var loft = Brep.CreateFromLoft(
                    new[] { new PolylineCurve(topPts), new PolylineCurve(bottomPts) },
                    Point3d.Unset, Point3d.Unset, LoftType.Normal, false);

                if (loft?.Length > 0)
                {
                    try
                    {
                        var capped = loft[0].CapPlanarHoles(
                            Rhino.RhinoDoc.ActiveDoc?.ModelAbsoluteTolerance ?? 0.001);
                        output.Add(new GH_Brep(capped ?? loft[0]));
                    }
                    catch
                    {
                        output.Add(new GH_Brep(loft[0]));
                    }

                    AppendSlabColor(colors, slab, colorBy, maxDisp, "vertex_displacements", utilGradient, deflectionGradient);
                }

                AppendDropPanelSizedGeometry(slab, zTop, thickness, output);
            }
        }

        /// <summary>
        /// Build sized slab geometry from undeformed shell mesh when the mesh is curved.
        /// This preserves vault geometry in Sized mode instead of flattening to z_top.
        /// </summary>
        private static bool TryBuildCurvedSizedSlabFromMesh(JToken meshToken, List<IGH_GeometricGoo> output)
        {
            var verts = meshToken["vertices"]?.ToObject<double[][]>() ?? new double[0][];
            var faces = meshToken["faces"]?.ToObject<int[][]>() ?? new int[0][];
            if (verts.Length == 0 || faces.Length == 0)
                return false;

            // Only use this path for genuinely curved slabs.
            double minZ = double.PositiveInfinity;
            double maxZ = double.NegativeInfinity;
            for (int i = 0; i < verts.Length; i++)
            {
                if (verts[i].Length < 3) continue;
                double z = verts[i][2];
                if (z < minZ) minZ = z;
                if (z > maxZ) maxZ = z;
            }
            if (double.IsNaN(minZ) || double.IsInfinity(minZ) ||
                double.IsNaN(maxZ) || double.IsInfinity(maxZ) ||
                (maxZ - minZ) <= 1e-5)
                return false;

            var rhinoMesh = new Mesh();
            for (int i = 0; i < verts.Length; i++)
            {
                if (verts[i].Length < 3) continue;
                rhinoMesh.Vertices.Add(new Point3d(verts[i][0], verts[i][1], verts[i][2]));
            }

            foreach (var face in faces)
            {
                if (face == null || face.Length < 3) continue;
                int i0 = face[0] - 1;
                int i1 = face[1] - 1;
                int i2 = face[2] - 1;
                if (i0 < 0 || i1 < 0 || i2 < 0 ||
                    i0 >= rhinoMesh.Vertices.Count ||
                    i1 >= rhinoMesh.Vertices.Count ||
                    i2 >= rhinoMesh.Vertices.Count)
                    continue;
                rhinoMesh.Faces.AddFace(i0, i1, i2);
            }

            if (rhinoMesh.Vertices.Count == 0 || rhinoMesh.Faces.Count == 0)
                return false;

            rhinoMesh.Normals.ComputeNormals();
            rhinoMesh.Compact();
            output.Add(new GH_Mesh(rhinoMesh));
            return true;
        }

        private static void BuildDeflectedSlabs(JToken viz, double scale, bool showOriginal,
            List<IGH_GeometricGoo> output, List<IGH_GeometricGoo> origOutput,
            List<Color> colors, int colorBy, double maxDisp, bool isLocal, IList<Color> utilGradient, IList<Color> deflectionGradient)
        {
            var meshes = viz["deflected_slab_meshes"] as JArray ?? new JArray();
            foreach (var m in meshes)
            {
                var verts = m["vertices"]?.ToObject<double[][]>() ?? new double[0][];
                var dispsGlobal = m["vertex_displacements"]?.ToObject<double[][]>() ?? new double[0][];
                var dispsLocal = m["vertex_displacements_local"]?.ToObject<double[][]>() ?? new double[0][];
                var disps = isLocal && dispsLocal.Length > 0 ? dispsLocal : dispsGlobal;
                var faces = m["faces"]?.ToObject<int[][]>() ?? new int[0][];
                if (verts.Length == 0) continue;

                var rhinoMesh = new Mesh();
                var origMesh = showOriginal ? new Mesh() : null;

                for (int i = 0; i < verts.Length; i++)
                {
                    var op = new Point3d(verts[i][0], verts[i][1], verts[i][2]);
                    origMesh?.Vertices.Add(op);

                    double dx = i < disps.Length ? disps[i][0] : 0;
                    double dy = i < disps.Length ? disps[i][1] : 0;
                    double dz = i < disps.Length ? disps[i][2] : 0;
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
                    origMesh?.Faces.AddFace(i0, i1, i2);
                }

                // Per-vertex coloring for mesh preview:
                // - Deflection mode: color by per-vertex displacement magnitude
                // - Utilization mode: apply a uniform utilization color per mesh vertex
                if (colorBy == COLOR_DEFLECTION && disps.Length > 0)
                {
                    for (int i = 0; i < rhinoMesh.Vertices.Count; i++)
                    {
                        double mag = 0;
                        if (i < disps.Length && disps[i].Length >= 3)
                            mag = Math.Sqrt(disps[i][0] * disps[i][0] +
                                            disps[i][1] * disps[i][1] +
                                            disps[i][2] * disps[i][2]);
                        rhinoMesh.VertexColors.Add(DeflectionColor(mag, maxDisp, deflectionGradient));
                    }
                }
                else if (colorBy == COLOR_UTILIZATION)
                {
                    double ratio = m["utilization_ratio"]?.ToObject<double>() ?? 0;
                    bool ok = m["ok"]?.ToObject<bool>() ?? true;
                    var utilColor = UtilizationColor(ratio, ok, utilGradient);
                    for (int i = 0; i < rhinoMesh.Vertices.Count; i++)
                        rhinoMesh.VertexColors.Add(utilColor);
                }

                if (rhinoMesh.Vertices.Count > 0 && rhinoMesh.Faces.Count > 0)
                {
                    rhinoMesh.Normals.ComputeNormals();
                    rhinoMesh.Compact();
                    output.Add(new GH_Mesh(rhinoMesh));
                    AppendDropPanelDeflectedGeometry(m, verts, disps, scale, output);

                    if (origMesh?.Vertices.Count > 0 && origMesh.Faces.Count > 0)
                    {
                        origMesh.Normals.ComputeNormals();
                        origMesh.Compact();
                        origOutput.Add(new GH_Mesh(origMesh));
                    }

                    string dispField = isLocal && dispsLocal.Length > 0
                        ? "vertex_displacements_local"
                        : "vertex_displacements";
                    AppendSlabColor(colors, m, colorBy, maxDisp, dispField, utilGradient, deflectionGradient);
                }
            }
        }

        private static void AppendDropPanelSizedGeometry(JToken slab, double zTop, double slabThickness,
            List<IGH_GeometricGoo> output)
        {
            var dropPanels = slab["drop_panels"] as JArray ?? new JArray();
            foreach (var dp in dropPanels)
            {
                var c = dp["center"]?.ToObject<double[]>() ?? dp["center_ft"]?.ToObject<double[]>() ?? new double[0];
                if (c.Length < 2) continue;
                double length = dp["length"]?.ToObject<double>() ?? dp["length_ft"]?.ToObject<double>() ?? 0.0;
                double width = dp["width"]?.ToObject<double>() ?? dp["width_ft"]?.ToObject<double>() ?? 0.0;
                double extra = dp["extra_depth"]?.ToObject<double>() ?? dp["extra_depth_ft"]?.ToObject<double>() ?? 0.0;
                if (length <= 0 || width <= 0 || extra <= 0) continue;

                double x0 = c[0] - length / 2.0;
                double x1 = c[0] + length / 2.0;
                double y0 = c[1] - width / 2.0;
                double y1 = c[1] + width / 2.0;
                double zTopDrop = zTop - slabThickness;
                double zBotDrop = zTopDrop - extra;
                var brep = new BoundingBox(new[]
                {
                    new Point3d(x0, y0, zBotDrop), new Point3d(x1, y0, zBotDrop),
                    new Point3d(x1, y1, zBotDrop), new Point3d(x0, y1, zBotDrop),
                    new Point3d(x0, y0, zTopDrop), new Point3d(x1, y0, zTopDrop),
                    new Point3d(x1, y1, zTopDrop), new Point3d(x0, y1, zTopDrop),
                }).ToBrep();
                if (brep != null)
                    output.Add(new GH_Brep(brep));
            }
        }

        private static void AppendDropPanelDeflectedGeometry(JToken meshToken, double[][] verts, double[][] disps,
            double scale, List<IGH_GeometricGoo> output)
        {
            var dropPanels = meshToken["drop_panels"] as JArray ?? new JArray();
            if (dropPanels.Count == 0 || verts == null || verts.Length == 0)
                return;

            double slabThickness = meshToken["thickness"]?.ToObject<double>() ?? meshToken["thickness_ft"]?.ToObject<double>() ?? 0.0;
            foreach (var dp in dropPanels)
            {
                var c = dp["center"]?.ToObject<double[]>() ?? dp["center_ft"]?.ToObject<double[]>() ?? new double[0];
                if (c.Length < 2) continue;
                double length = dp["length"]?.ToObject<double>() ?? dp["length_ft"]?.ToObject<double>() ?? 0.0;
                double width = dp["width"]?.ToObject<double>() ?? dp["width_ft"]?.ToObject<double>() ?? 0.0;
                double extra = dp["extra_depth"]?.ToObject<double>() ?? dp["extra_depth_ft"]?.ToObject<double>() ?? 0.0;
                if (length <= 0 || width <= 0 || extra <= 0) continue;

                int nearest = 0;
                double best = double.MaxValue;
                for (int i = 0; i < verts.Length; i++)
                {
                    double dx = verts[i][0] - c[0];
                    double dy = verts[i][1] - c[1];
                    double d2 = dx * dx + dy * dy;
                    if (d2 < best)
                    {
                        best = d2;
                        nearest = i;
                    }
                }

                double zTopDef = verts[nearest][2];
                if (nearest < disps.Length && disps[nearest].Length >= 3)
                    zTopDef += disps[nearest][2] * scale;

                double x0 = c[0] - length / 2.0;
                double x1 = c[0] + length / 2.0;
                double y0 = c[1] - width / 2.0;
                double y1 = c[1] + width / 2.0;
                double zTopDrop = zTopDef - slabThickness;
                double zBotDrop = zTopDrop - extra;

                var brep = new BoundingBox(new[]
                {
                    new Point3d(x0, y0, zBotDrop), new Point3d(x1, y0, zBotDrop),
                    new Point3d(x1, y1, zBotDrop), new Point3d(x0, y1, zBotDrop),
                    new Point3d(x0, y0, zTopDrop), new Point3d(x1, y0, zTopDrop),
                    new Point3d(x1, y1, zTopDrop), new Point3d(x0, y1, zTopDrop),
                }).ToBrep();
                if (brep != null)
                    output.Add(new GH_Brep(brep));
            }
        }

        /// <summary>
        /// Build undeformed slab meshes from the deflected slab payload.
        /// This is used by "Original" mode so users can color original geometry
        /// by utilization/deflection without drawing displaced geometry.
        /// </summary>
        private static void BuildOriginalSlabs(JToken viz, List<IGH_GeometricGoo> output,
            List<Color> colors, int colorBy, double maxDisp, IList<Color> utilGradient, IList<Color> deflectionGradient)
        {
            var meshes = viz["deflected_slab_meshes"] as JArray ?? new JArray();
            if (meshes.Count == 0)
            {
                BuildSizedSlabs(viz, output, colors, colorBy, maxDisp, utilGradient, deflectionGradient);
                return;
            }

            foreach (var m in meshes)
            {
                var verts = m["vertices"]?.ToObject<double[][]>() ?? new double[0][];
                var faces = m["faces"]?.ToObject<int[][]>() ?? new int[0][];
                if (verts.Length == 0) continue;

                var rhinoMesh = new Mesh();
                for (int i = 0; i < verts.Length; i++)
                {
                    var op = new Point3d(verts[i][0], verts[i][1], verts[i][2]);
                    rhinoMesh.Vertices.Add(op);
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

                if (rhinoMesh.Vertices.Count > 0 && rhinoMesh.Faces.Count > 0)
                {
                    rhinoMesh.Normals.ComputeNormals();
                    rhinoMesh.Compact();
                    output.Add(new GH_Mesh(rhinoMesh));
                    AppendSlabColor(colors, m, colorBy, maxDisp, "vertex_displacements", utilGradient, deflectionGradient);
                }
            }
        }

        private static void BuildFoundations(JToken viz, List<IGH_GeometricGoo> output,
            List<Color> colors, int colorBy, IList<Color> utilGradient, IList<Color> deflectionGradient)
        {
            var foundations = viz["foundations"] as JArray ?? new JArray();
            foreach (var f in foundations)
            {
                var c = f["center"]?.ToObject<double[]>() ?? f["center_ft"]?.ToObject<double[]>() ?? new double[3];
                if (c.Length < 3) continue;
                double length = f["length"]?.ToObject<double>() ?? f["length_ft"]?.ToObject<double>() ?? 0;
                double width = f["width"]?.ToObject<double>() ?? f["width_ft"]?.ToObject<double>() ?? 0;
                double depth = f["depth"]?.ToObject<double>() ?? f["depth_ft"]?.ToObject<double>() ?? 0;
                if (length <= 0 || width <= 0 || depth <= 0) continue;

                double x0 = c[0] - length / 2.0;
                double x1 = c[0] + length / 2.0;
                double y0 = c[1] - width / 2.0;
                double y1 = c[1] + width / 2.0;
                double zTop = c[2];
                double zBot = zTop - depth;

                var corners = new[]
                {
                    new Point3d(x0, y0, zBot), new Point3d(x1, y0, zBot),
                    new Point3d(x1, y1, zBot), new Point3d(x0, y1, zBot),
                    new Point3d(x0, y0, zTop), new Point3d(x1, y0, zTop),
                    new Point3d(x1, y1, zTop), new Point3d(x0, y1, zTop),
                };
                var brep = new BoundingBox(corners).ToBrep();
                if (brep == null) continue;

                output.Add(new GH_Brep(brep));
                if (colorBy == COLOR_UTILIZATION)
                {
                    double ratio = f["utilization_ratio"]?.ToObject<double>() ?? 0;
                    bool ok = f["ok"]?.ToObject<bool>() ?? true;
                    colors.Add(UtilizationColor(ratio, ok, utilGradient));
                }
                else if (colorBy == COLOR_DEFLECTION)
                {
                    colors.Add(DeflectionColor(0.0, 1.0, deflectionGradient));
                }
            }
        }

        /// <summary>
        /// Append one color per slab/mesh element to the parallel color list.
        /// For deflection mode on meshes, per-vertex coloring is handled above;
        /// this still outputs one representative color for the Custom Preview pipeline.
        /// </summary>
        private static void AppendSlabColor(List<Color> colors, JToken element,
            int colorBy, double maxDisp, string displacementField = "vertex_displacements",
            IList<Color> utilGradient = null, IList<Color> deflectionGradient = null)
        {
            if (colorBy == COLOR_UTILIZATION)
            {
                double ratio = element["utilization_ratio"]?.ToObject<double>() ?? 0;
                bool ok = element["ok"]?.ToObject<bool>() ?? true;
                colors.Add(UtilizationColor(ratio, ok, utilGradient));
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
                colors.Add(DeflectionColor(maxVertDisp, maxDisp, deflectionGradient));
            }
        }
    }
}
