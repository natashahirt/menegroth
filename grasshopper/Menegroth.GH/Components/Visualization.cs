using System;
using System.Collections.Generic;
using System.Drawing;
using System.Linq;
using System.Windows.Forms;
using Grasshopper.Kernel;
using Grasshopper.Kernel.Attributes;
using Grasshopper.Kernel.Parameters;
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

        public Visualization()
            : base("Visualization",
                   "Visualization",
                   "Visualize structural design with geometry, deflections, and color mapping",
                   "Menegroth", " Results")
        { }

        public override Guid ComponentGuid =>
            new Guid("E7D94B2A-6C31-4D89-AF1E-2B8A3C5D7E9F");

        public override void CreateAttributes()
        {
            m_attributes = new VisualizationAttributes(this);
        }

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
            modeMenu.DropDownItems.Add(CreateModeMenuItem("Sized", MODE_SIZED));
            modeMenu.DropDownItems.Add(CreateModeMenuItem("Analytical", MODE_ANALYTICAL));
            menu.Items.Add(modeMenu);

            var deflectionMenu = new ToolStripMenuItem("Deflection");
            deflectionMenu.DropDownItems.Add(CreateDeflectionMenuItem("None", DEFLECTION_NONE));
            deflectionMenu.DropDownItems.Add(CreateDeflectionMenuItem("Local", DEFLECTION_LOCAL));
            deflectionMenu.DropDownItems.Add(CreateDeflectionMenuItem("Global", DEFLECTION_GLOBAL));
            menu.Items.Add(deflectionMenu);

            var colorMenu = new ToolStripMenuItem("Color By");
            colorMenu.DropDownItems.Add(CreateColorMenuItem("None", COLOR_NONE));
            colorMenu.DropDownItems.Add(CreateColorMenuItem("Material", COLOR_MATERIAL));
            var wholeBuildingMenu = new ToolStripMenuItem("Whole Building");
            wholeBuildingMenu.DropDownItems.Add(CreateColorMenuItem("Deflection", COLOR_DEFLECTION));
            wholeBuildingMenu.DropDownItems.Add(CreateColorMenuItem("Utilization", COLOR_UTILIZATION));
            colorMenu.DropDownItems.Add(wholeBuildingMenu);
            colorMenu.DropDownItems.Add(new ToolStripSeparator());
            var beamMenu = new ToolStripMenuItem("Beam");
            beamMenu.DropDownItems.Add(CreateAnalyticalBeamMenuItem("None", COLOR_NONE));
            beamMenu.DropDownItems.Add(CreateAnalyticalBeamMenuItem("Axial Force", COLOR_FRAME_AXIAL));
            beamMenu.DropDownItems.Add(CreateAnalyticalBeamMenuItem("Moment", COLOR_FRAME_MOMENT));
            beamMenu.DropDownItems.Add(CreateAnalyticalBeamMenuItem("Shear", COLOR_FRAME_SHEAR));
            colorMenu.DropDownItems.Add(beamMenu);
            var columnMenu = new ToolStripMenuItem("Column");
            columnMenu.DropDownItems.Add(CreateAnalyticalColumnMenuItem("None", COLOR_NONE));
            columnMenu.DropDownItems.Add(CreateAnalyticalColumnMenuItem("Axial Force", COLOR_FRAME_AXIAL));
            columnMenu.DropDownItems.Add(CreateAnalyticalColumnMenuItem("Moment", COLOR_FRAME_MOMENT));
            columnMenu.DropDownItems.Add(CreateAnalyticalColumnMenuItem("Shear", COLOR_FRAME_SHEAR));
            colorMenu.DropDownItems.Add(columnMenu);
            var slabMenu = new ToolStripMenuItem("Slab");
            slabMenu.DropDownItems.Add(CreateAnalyticalSlabMenuItem("None", COLOR_NONE));
            slabMenu.DropDownItems.Add(CreateAnalyticalSlabMenuItem("Bending Moment", COLOR_SLAB_BENDING));
            slabMenu.DropDownItems.Add(CreateAnalyticalSlabMenuItem("Membrane Force", COLOR_SLAB_MEMBRANE));
            slabMenu.DropDownItems.Add(CreateAnalyticalSlabMenuItem("Shear Force", COLOR_SLAB_SHEAR));
            slabMenu.DropDownItems.Add(CreateAnalyticalSlabMenuItem("Von Mises", COLOR_SLAB_VON_MISES));
            slabMenu.DropDownItems.Add(CreateAnalyticalSlabMenuItem("Surface Stress", COLOR_SLAB_SURFACE_STRESS));
            colorMenu.DropDownItems.Add(slabMenu);
            menu.Items.Add(colorMenu);
        }

        private ToolStripMenuItem CreateDeflectionMenuItem(string label, int value)
        {
            var item = new ToolStripMenuItem(label, null, (s, e) =>
            {
                _deflection = value;
                ExpirePreview(true);
                ExpireSolution(true);
            });
            item.Checked = _deflection == value;
            return item;
        }

        private ToolStripMenuItem CreateModeMenuItem(string label, int value)
        {
            var item = new ToolStripMenuItem(label, null, (s, e) =>
            {
                _mode = value;
                ExpirePreview(true);
                ExpireSolution(true);
            });
            item.Checked = _mode == value;
            return item;
        }

        private ToolStripMenuItem CreateColorMenuItem(string label, int value)
        {
            var item = new ToolStripMenuItem(label, null, (s, e) =>
            {
                _colorBy = value;
                ExpirePreview(true);
                ExpireSolution(true);
            });
            item.Checked = _colorBy == value;
            return item;
        }

        private ToolStripMenuItem CreateAnalyticalSlabMenuItem(string label, int value)
        {
            var item = new ToolStripMenuItem(label, null, (s, e) =>
            {
                _analyticalSlab = value;
                ExpirePreview(true);
                ExpireSolution(true);
            });
            item.Checked = _analyticalSlab == value;
            return item;
        }

        private ToolStripMenuItem CreateAnalyticalBeamMenuItem(string label, int value)
        {
            var item = new ToolStripMenuItem(label, null, (s, e) =>
            {
                _analyticalBeam = value;
                ExpirePreview(true);
                ExpireSolution(true);
            });
            item.Checked = _analyticalBeam == value;
            return item;
        }

        private ToolStripMenuItem CreateAnalyticalColumnMenuItem(string label, int value)
        {
            var item = new ToolStripMenuItem(label, null, (s, e) =>
            {
                _analyticalColumn = value;
                ExpirePreview(true);
                ExpireSolution(true);
            });
            item.Checked = _analyticalColumn == value;
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
            if (reader.ItemExists("Deflection"))
            {
                _deflection = reader.GetInt32("Deflection");
                if (reader.ItemExists("Mode"))
                    _mode = reader.GetInt32("Mode");
            }
            else if (reader.ItemExists("Mode"))
            {
                int m = reader.GetInt32("Mode");
                if (m == 2) _deflection = DEFLECTION_NONE;
                else if (m == 1) _deflection = DEFLECTION_LOCAL;
                else _deflection = DEFLECTION_GLOBAL;
            }
            if (reader.ItemExists("ShowVolumes"))
                _mode = reader.GetBoolean("ShowVolumes") ? MODE_SIZED : MODE_ANALYTICAL;
            if (reader.ItemExists("BeamVisibilityInitialized"))
                _beamVisibilityInitialized = reader.GetBoolean("BeamVisibilityInitialized");
            else if (reader.ItemExists("ShowBeams"))
                _beamVisibilityInitialized = true;
            if (reader.ItemExists("ColorBy"))
                _colorBy = reader.GetInt32("ColorBy");
            if (reader.ItemExists("AnalyticalSlab"))
                _analyticalSlab = reader.GetInt32("AnalyticalSlab");
            if (reader.ItemExists("AnalyticalBeam"))
                _analyticalBeam = reader.GetInt32("AnalyticalBeam");
            else if (reader.ItemExists("AnalyticalFrame"))
                _analyticalBeam = _analyticalColumn = reader.GetInt32("AnalyticalFrame");
            if (reader.ItemExists("AnalyticalColumn"))
                _analyticalColumn = reader.GetInt32("AnalyticalColumn");
            return base.Read(reader);
        }

        protected override void RegisterInputParams(GH_InputParamManager pManager)
        {
            pManager.AddGenericParameter("Result", "Result",
                "DesignResult from the DesignRun component", GH_ParamAccess.item);

            pManager.AddNumberParameter("Scale", "Scale",
                "Deflection scale multiplier (0 = no deflection, 1 = auto-suggested, >1 = exaggerated)",
                GH_ParamAccess.item, 1.0);
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
                "Beam section geometry as Breps", GH_ParamAccess.list);
            pManager.AddGenericParameter("Column Geometry", "ColumnGeometry",
                "Column section geometry as Breps", GH_ParamAccess.list);
            pManager.AddGenericParameter("Slab Geometry", "SlabGeometry",
                "Slab geometry only (Brep for Sized, Mesh for Deflected)", GH_ParamAccess.list);
            pManager.AddGenericParameter("Foundation Geometry", "FoundationGeometry",
                "Foundation geometry only (Brep)", GH_ParamAccess.list);
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

            // Slab/Beam/Column menus override base color when a valid analytical option is selected.
            // Material from base menu overrides submenu so Color by Material always applies.
            int effectiveColorBySlab = (colorByInt == COLOR_MATERIAL)
                ? COLOR_MATERIAL
                : (IsValidAnalyticalSlab(analyticalSlab) ? analyticalSlab : colorByInt);
            if (effectiveColorBySlab == COLOR_NONE) effectiveColorBySlab = COLOR_UTILIZATION;

            int effectiveColorByBeam = (colorByInt == COLOR_MATERIAL)
                ? COLOR_MATERIAL
                : (IsValidAnalyticalBeam(analyticalBeam) ? analyticalBeam : colorByInt);
            if (effectiveColorByBeam == COLOR_NONE) effectiveColorByBeam = COLOR_UTILIZATION;

            int effectiveColorByColumn = (colorByInt == COLOR_MATERIAL)
                ? COLOR_MATERIAL
                : (IsValidAnalyticalColumn(analyticalColumn) ? analyticalColumn : colorByInt);
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
            double maxSlabBending = viz["max_slab_bending"]?.ToObject<double>() ?? 0;
            double maxSlabMembrane = viz["max_slab_membrane"]?.ToObject<double>() ?? 0;
            double maxSlabShear = viz["max_slab_shear"]?.ToObject<double>() ?? 0;
            double maxSlabVonMises = viz["max_slab_von_mises"]?.ToObject<double>() ?? 0;
            double maxSlabSurfaceStress = viz["max_slab_surface_stress"]?.ToObject<double>() ?? 0;
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

                var brep = SweepSection(elementCurve, elem);
                if (brep != null)
                {
                    // Geometry depends only on Mode: Sized = volumes (colored by Color By), Analytical = centerlines only.
                    bool showFrameGeometry = (modeInt == MODE_SIZED);

                    if (showFrameGeometry)
                    {
                        frameGeometry.Add(new GH_Brep(brep));
                        frameGeometryColors.Add(elementColor);
                        if (elemType == "column")
                            columnGeometry.Add(new GH_Brep(brep));
                        else if (elemType == "beam")
                            beamGeometry.Add(new GH_Brep(brep));
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

            // Slab geometry + colors
            var slabGeometry = new List<IGH_GeometricGoo>();
            var foundationGeometry = new List<IGH_GeometricGoo>();
            var slabColors = new List<Color>();
            var originalSlabs = new List<IGH_GeometricGoo>();

            if (_showSlabs)
            {
                if (isOriginalMode)
                    BuildOriginalSlabs(viz, slabGeometry, slabColors, effectiveColorBySlab, maxDisp,
                        maxSlabBending, maxSlabMembrane, maxSlabShear, maxSlabVonMises, maxSlabSurfaceStress);
                else if (isDeflected && finalScale > 0)
                    BuildDeflectedSlabs(viz, finalScale, showOriginal, slabGeometry, originalSlabs,
                        slabColors, effectiveColorBySlab, maxDisp, isLocal,
                        maxSlabBending, maxSlabMembrane, maxSlabShear, maxSlabVonMises, maxSlabSurfaceStress,
                        showVolumes: modeInt == MODE_SIZED);
                else
                    BuildSizedSlabs(viz, slabGeometry, slabColors, effectiveColorBySlab, maxDisp,
                        maxSlabBending, maxSlabMembrane, maxSlabShear, maxSlabVonMises, maxSlabSurfaceStress,
                        showVolumes: modeInt == MODE_SIZED);
            }

            if (showFoundationsEffective)
                BuildFoundations(viz, foundationGeometry, slabColors, effectiveColorBySlab);

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
                originalSlabs.AddRange(visibleSlabGeometry);
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
                visibleSlabGeometry, slabColors);

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
                    _ => "Slab Utilization",
                };
                string beamName = effectiveColorByBeam switch
                {
                    COLOR_FRAME_AXIAL => "Beam Axial",
                    COLOR_FRAME_MOMENT => "Beam Moment",
                    COLOR_FRAME_SHEAR => "Beam Shear",
                    _ => "Beam Utilization",
                };
                string columnName = effectiveColorByColumn switch
                {
                    COLOR_FRAME_AXIAL => "Column Axial",
                    COLOR_FRAME_MOMENT => "Column Moment",
                    COLOR_FRAME_SHEAR => "Column Shear",
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

            int n = Math.Min(_previewShadedMeshes.Count, _previewShadedColors.Count);
            for (int i = 0; i < n; i++)
            {
                var m = _previewShadedMeshes[i];
                if (m == null) continue;
                var useVertexColors = i < _previewShadedUseVertexColors.Count && _previewShadedUseVertexColors[i];
                var material = new Rhino.Display.DisplayMaterial(
                    useVertexColors ? Color.White : _previewShadedColors[i]);
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
        // Robust sweep using PerpendicularFrameAt for orientation (handles vertical/near-vertical
        // elements without degenerate cross-products). Falls back to pipe when sweep fails.

        private static Brep SweepSection(Curve elementCurve, JToken elem)
        {
            var poly = elem["section_polygon"]?.ToObject<double[][]>() ?? new double[0][];
            var polyInner = elem["section_polygon_inner"]?.ToObject<double[][]>() ?? new double[0][];
            double depth = elem["section_depth"]?.ToObject<double>() ?? 0;
            double width = elem["section_width"]?.ToObject<double>() ?? 0;

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

            double tol = Rhino.RhinoDoc.ActiveDoc?.ModelAbsoluteTolerance ?? 0.001;
            if (elementCurve == null || !elementCurve.IsValid) return null;

            try
            {
                elementCurve.Domain = new Interval(0.0, 1.0);
                double t0 = elementCurve.Domain.T0;

                // Use PerpendicularFrameAt for robust orientation (handles vertical elements).
                Plane frame;
                if (!elementCurve.PerpendicularFrameAt(t0, out frame))
                {
                    // Fallback: manual frame when PerpendicularFrameAt fails (e.g. zero-length curve).
                    var tangent = elementCurve.TangentAtStart;
                    if (!tangent.Unitize()) return PipeFallback(elementCurve, width, depth, tol);
                    Vector3d up = Math.Abs(tangent.Z) < 0.9 ? new Vector3d(0, 0, 1) : new Vector3d(1, 0, 0);
                    var localY = Vector3d.CrossProduct(up, tangent);
                    if (!localY.Unitize()) return PipeFallback(elementCurve, width, depth, tol);
                    var localZ = Vector3d.CrossProduct(tangent, localY);
                    if (!localZ.Unitize()) return PipeFallback(elementCurve, width, depth, tol);
                    frame = new Plane(elementCurve.PointAtStart, localY, localZ);
                }

                // Build outer section curve.
                var sectionCurve = BuildSectionCurve(poly, frame, tol);
                if (sectionCurve == null || !sectionCurve.IsValid)
                    return PipeFallback(elementCurve, width, depth, tol);

                // Hollow section: sweep outer and inner, then boolean difference.
                if (polyInner.Length >= 3)
                {
                    var innerCurve = BuildSectionCurve(polyInner, frame, tol);
                    if (innerCurve != null && innerCurve.IsValid)
                    {
                        var outerSweep = Brep.CreateFromSweep(elementCurve, sectionCurve, true, tol);
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
                }

                // Solid section: sweep outer and cap.
                var sweep = Brep.CreateFromSweep(elementCurve, sectionCurve, true, tol);
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

        private static Brep PipeFallback(Curve path, double width, double depth, double tol)
        {
            if (path == null || !path.IsValid) return null;
            double minDim = Math.Max(Math.Max(width, depth), 0.05);
            double area = minDim * minDim;
            double radius = Math.Max(Math.Sqrt(area / Math.PI), 0.01);
            var pipe = Brep.CreatePipe(path, radius, false, PipeCapMode.Flat, true, tol, tol);
            return pipe != null && pipe.Length > 0 ? pipe[0] : null;
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

        private static string NormalizeElementType(string rawType)
        {
            return (rawType ?? "").Trim().ToLowerInvariant();
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
            _previewShadedUseVertexColors.Clear();

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
                var color = colors[i];
                if (geometry[i] is GH_Brep ghBrep && ghBrep.Value != null)
                {
                    var meshes = Mesh.CreateFromBrep(ghBrep.Value, MeshingParameters.FastRenderMesh);
                    if (meshes != null && meshes.Length > 0)
                    {
                        foreach (var m in meshes)
                        {
                            if (m == null) continue;
                            _previewShadedMeshes.Add(m.DuplicateMesh());
                            _previewShadedColors.Add(color);
                            _previewShadedUseVertexColors.Add(false);
                        }
                    }
                }
                else if (geometry[i] is GH_Mesh ghMesh && ghMesh.Value != null)
                {
                    var mesh = ghMesh.Value;
                    if (mesh.Vertices.Count > 0 && mesh.Faces.Count > 0)
                    {
                        var dup = mesh.DuplicateMesh();
                        bool hasVertexColors = mesh.VertexColors.Count == mesh.Vertices.Count && mesh.VertexColors.Count > 0;
                        if (!hasVertexColors)
                        {
                            for (int v = 0; v < dup.Vertices.Count; v++)
                                dup.VertexColors.Add(color);
                        }
                        _previewShadedMeshes.Add(dup);
                        _previewShadedColors.Add(color);
                        _previewShadedUseVertexColors.Add(hasVertexColors);
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

        private static void BuildSizedSlabs(JToken viz, List<IGH_GeometricGoo> output,
            List<Color> colors, int colorBy, double maxDisp,
            double maxSlabBending = 0, double maxSlabMembrane = 0, double maxSlabShear = 0,
            double maxSlabVonMises = 0, double maxSlabSurfaceStress = 0, bool showVolumes = true)
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
                
                // For analytical coloring in sized mode, use the deflected mesh data (has face values)
                meshBySlabId.TryGetValue(slabId, out var analyticalMesh);
                var analyticalSource = analyticalMesh ?? slab;

                // Check for vault-specific curved mesh (new API field)
                bool isVault = slab["is_vault"]?.ToObject<bool>() ?? false;
                if (isVault && TryBuildVaultBrep(slab, thickness, output))
                {
                    AppendSlabColor(colors, analyticalSource, colorBy, maxDisp, "vertex_displacements",
                        maxSlabBending, maxSlabMembrane, maxSlabShear, maxSlabVonMises, maxSlabSurfaceStress);
                    continue;
                }
                
                // Fallback: try deflected mesh (for curved slabs from analysis model)
                if (analyticalMesh != null &&
                    TryBuildCurvedSizedSlabFromMesh(analyticalMesh, output))
                {
                    AppendSlabColor(colors, analyticalSource, colorBy, maxDisp, "vertex_displacements",
                        maxSlabBending, maxSlabMembrane, maxSlabShear, maxSlabVonMises, maxSlabSurfaceStress);
                    continue;
                }

                // Standard flat slab: loft boundary to create box (volumes) or planar mesh (analytical)
                var boundary = slab["boundary_vertices"]?.ToObject<double[][]>() ?? new double[0][];
                if (boundary.Length < 3) continue;

                var topPts = boundary.Select(v => new Point3d(v[0], v[1], zTop)).ToList();
                topPts.Add(topPts[0]);
                var bottomPts = topPts.Select(p => new Point3d(p.X, p.Y, p.Z - thickness)).ToList();

                if (showVolumes)
                {
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

                        AppendSlabColor(colors, analyticalSource, colorBy, maxDisp, "vertex_displacements",
                            maxSlabBending, maxSlabMembrane, maxSlabShear, maxSlabVonMises, maxSlabSurfaceStress);
                    }

                    AppendDropPanelSizedGeometry(slab, zTop, thickness, output, colors, analyticalSource,
                        colorBy, maxDisp, maxSlabBending, maxSlabMembrane, maxSlabShear,
                        maxSlabVonMises, maxSlabSurfaceStress);
                }
                else
                {
                    var mesh = new Mesh();
                    foreach (var p in topPts)
                        mesh.Vertices.Add(p);
                    int n = topPts.Count - 1;
                    if (n >= 3)
                    {
                        for (int i = 1; i < n - 1; i++)
                            mesh.Faces.AddFace(0, i, i + 1);
                        mesh.Normals.ComputeNormals();
                        mesh.Compact();
                        output.Add(new GH_Mesh(mesh));
                        AppendSlabColor(colors, analyticalSource, colorBy, maxDisp, "vertex_displacements",
                            maxSlabBending, maxSlabMembrane, maxSlabShear, maxSlabVonMises, maxSlabSurfaceStress);
                    }

                    // Omit solid drop panels in analytical mode; slab mesh suffices for coloring
                }
            }
        }

        /// <summary>
        /// Build parabolic vault geometry from vault_mesh_vertices and vault_mesh_faces.
        /// Creates a Brep with intrados and extrados surfaces plus end caps.
        /// </summary>
        private static bool TryBuildVaultBrep(JToken slab, double thickness, List<IGH_GeometricGoo> output)
        {
            var verts = slab["vault_mesh_vertices"]?.ToObject<double[][]>() ?? new double[0][];
            var faces = slab["vault_mesh_faces"]?.ToObject<int[][]>() ?? new int[0][];
            
            if (verts.Length == 0 || faces.Length == 0)
                return false;
            
            // Build intrados mesh
            var intradosMesh = new Mesh();
            for (int i = 0; i < verts.Length; i++)
            {
                if (verts[i].Length < 3) continue;
                intradosMesh.Vertices.Add(new Point3d(verts[i][0], verts[i][1], verts[i][2]));
            }
            
            foreach (var face in faces)
            {
                if (face == null || face.Length < 3) continue;
                int i0 = face[0] - 1;  // Convert from 1-based to 0-based
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
            
            // Build extrados mesh (offset by thickness in Z direction)
            var extradosMesh = new Mesh();
            for (int i = 0; i < verts.Length; i++)
            {
                if (verts[i].Length < 3) continue;
                extradosMesh.Vertices.Add(new Point3d(verts[i][0], verts[i][1], verts[i][2] + thickness));
            }
            
            // Reverse face winding for extrados (normals point up)
            foreach (var face in faces)
            {
                if (face == null || face.Length < 3) continue;
                int i0 = face[0] - 1;
                int i1 = face[1] - 1;
                int i2 = face[2] - 1;
                if (i0 < 0 || i1 < 0 || i2 < 0 ||
                    i0 >= extradosMesh.Vertices.Count ||
                    i1 >= extradosMesh.Vertices.Count ||
                    i2 >= extradosMesh.Vertices.Count)
                    continue;
                extradosMesh.Faces.AddFace(i0, i2, i1);  // Reversed winding
            }
            
            extradosMesh.Normals.ComputeNormals();
            extradosMesh.Compact();
            
            // Combine into single mesh with both surfaces
            var combinedMesh = new Mesh();
            combinedMesh.Append(intradosMesh);
            combinedMesh.Append(extradosMesh);
            
            // Add end caps (vertical surfaces at vault abutments)
            // Extract boundary edges from intrados and connect to extrados
            var boundary = intradosMesh.GetNakedEdges();
            if (boundary != null && boundary.Length > 0)
            {
                foreach (var edge in boundary)
                {
                    if (edge == null || edge.Count < 2) continue;

                    // Create vertical strip connecting intrados edge to extrados
                    for (int i = 0; i < edge.Count - 1; i++)
                    {
                        var p1 = edge[i];
                        var p2 = edge[i + 1];
                        var p3 = new Point3d(p2.X, p2.Y, p2.Z + thickness);
                        var p4 = new Point3d(p1.X, p1.Y, p1.Z + thickness);
                        
                        int baseIdx = combinedMesh.Vertices.Count;
                        combinedMesh.Vertices.Add(p1);
                        combinedMesh.Vertices.Add(p2);
                        combinedMesh.Vertices.Add(p3);
                        combinedMesh.Vertices.Add(p4);
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
            List<Color> colors, int colorBy, double maxDisp, bool isLocal,
            double maxSlabBending = 0, double maxSlabMembrane = 0, double maxSlabShear = 0,
            double maxSlabVonMises = 0, double maxSlabSurfaceStress = 0, bool showVolumes = false)
        {
            bool isAnalyticalSlab = colorBy >= COLOR_SLAB_BENDING && colorBy <= COLOR_SLAB_SURFACE_STRESS;
            var meshes = viz["deflected_slab_meshes"] as JArray ?? new JArray();
            foreach (var m in meshes)
            {
                var verts = m["vertices"]?.ToObject<double[][]>() ?? new double[0][];
                var dispsGlobal = m["vertex_displacements"]?.ToObject<double[][]>() ?? new double[0][];
                var dispsLocal = m["vertex_displacements_local"]?.ToObject<double[][]>() ?? new double[0][];
                var disps = isLocal && dispsLocal.Length > 0 ? dispsLocal : dispsGlobal;
                var faces = m["faces"]?.ToObject<int[][]>() ?? new int[0][];
                if (verts.Length == 0) continue;

                // Load per-face analytical arrays when needed
                double[] faceAnalytical = null;
                double analyticalMax = 0;
                bool analyticalDiverging = false;
                if (isAnalyticalSlab)
                    ResolveSlabAnalyticalData(m, colorBy, maxSlabBending, maxSlabMembrane,
                        maxSlabShear, maxSlabVonMises, maxSlabSurfaceStress,
                        out faceAnalytical, out analyticalMax, out analyticalDiverging);

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

                if (colorBy == COLOR_DEFLECTION && disps.Length > 0)
                {
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
                else if (colorBy == COLOR_UTILIZATION)
                {
                    double ratio = m["utilization_ratio"]?.ToObject<double>() ?? 0;
                    bool ok = m["ok"]?.ToObject<bool>() ?? true;
                    var utilColor = VisualizationColorMapper.UtilizationColor(ratio, ok, null);
                    for (int i = 0; i < rhinoMesh.Vertices.Count; i++)
                        rhinoMesh.VertexColors.Add(utilColor);
                }
                else if (colorBy == COLOR_MATERIAL)
                {
                    bool isVault = m["is_vault"]?.ToObject<bool>() ?? false;
                    var materialColor = isVault
                        ? VisualizationColorMapper.EarthenMaterialColor
                        : VisualizationColorMapper.ResolveMaterialColor(
                            m["material_color_hex"]?.ToString(),
                            VisualizationColorMapper.ConcreteMaterialColor);
                    for (int i = 0; i < rhinoMesh.Vertices.Count; i++)
                        rhinoMesh.VertexColors.Add(materialColor);
                }
                else if (isAnalyticalSlab && faceAnalytical != null)
                {
                    ApplyPerFaceVertexColors(rhinoMesh, faces, faceAnalytical, analyticalMax, analyticalDiverging);
                }

                if (rhinoMesh.Vertices.Count > 0 && rhinoMesh.Faces.Count > 0)
                {
                    rhinoMesh.Normals.ComputeNormals();
                    rhinoMesh.Compact();

                    if (showVolumes)
                    {
                        double thickness = m["thickness"]?.ToObject<double>() ?? 0;
                        if (thickness > 0 && TryBuildDeflectedSlabVolume(rhinoMesh, thickness, output))
                        {
                            AppendDropPanelDeflectedGeometry(m, verts, disps, scale, output);
                        }
                        else
                        {
                            output.Add(new GH_Mesh(rhinoMesh));
                            AppendDropPanelDeflectedGeometry(m, verts, disps, scale, output);
                        }
                    }
                    else
                    {
                        output.Add(new GH_Mesh(rhinoMesh));
                        AppendDropPanelDeflectedGeometry(m, verts, disps, scale, output);
                    }

                    if (origMesh?.Vertices.Count > 0 && origMesh.Faces.Count > 0)
                    {
                        origMesh.Normals.ComputeNormals();
                        origMesh.Compact();
                        origOutput.Add(new GH_Mesh(origMesh));
                    }

                    string dispField = isLocal && dispsLocal.Length > 0
                        ? "vertex_displacements_local"
                        : "vertex_displacements";
                    AppendSlabColor(colors, m, colorBy, maxDisp, dispField,
                        maxSlabBending, maxSlabMembrane, maxSlabShear, maxSlabVonMises, maxSlabSurfaceStress);
                }
            }
        }

        /// <summary>
        /// Build a solid slab volume from a deflected mesh by offsetting along normals by thickness.
        /// Top surface = deflected mesh; bottom = offset downward; sides from boundary edges.
        /// </summary>
        private static bool TryBuildDeflectedSlabVolume(Mesh topMesh, double thickness, List<IGH_GeometricGoo> output)
        {
            if (topMesh.Vertices.Count == 0 || topMesh.Faces.Count == 0 || thickness <= 0)
                return false;

            var bottomMesh = new Mesh();
            for (int i = 0; i < topMesh.Vertices.Count; i++)
            {
                var pt = new Point3d(topMesh.Vertices[i]);
                var n = new Vector3d(topMesh.Normals[i]);
                bottomMesh.Vertices.Add(pt + n * (-thickness));
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

            // GetNakedEdges returns Polyline[] of 3D points; map to vertex indices for top/bottom correspondence
            var boundary = topMesh.GetNakedEdges();
            if (boundary != null && boundary.Length > 0)
            {
                const double tol = 1e-6;
                foreach (var edge in boundary)
                {
                    if (edge == null || edge.Count < 2) continue;
                    int nV = topMesh.Vertices.Count;
                    for (int i = 0; i < edge.Count - 1; i++)
                    {
                        var pt1 = edge[i];
                        var pt2 = edge[i + 1];
                        int i0 = FindClosestVertexIndex(topMesh, pt1, tol);
                        int i1 = FindClosestVertexIndex(topMesh, pt2, tol);
                        if (i0 < 0 || i1 < 0 || i0 >= nV || i1 >= nV) continue;
                        var p1 = topMesh.Vertices[i0];
                        var p2 = topMesh.Vertices[i1];
                        var p3 = bottomMesh.Vertices[i1];
                        var p4 = bottomMesh.Vertices[i0];
                        int baseIdx = combined.Vertices.Count;
                        combined.Vertices.Add(p1);
                        combined.Vertices.Add(p2);
                        combined.Vertices.Add(p3);
                        combined.Vertices.Add(p4);
                        combined.Faces.AddFace(baseIdx, baseIdx + 1, baseIdx + 2, baseIdx + 3);
                    }
                }
            }

            combined.Normals.ComputeNormals();
            combined.Compact();
            output.Add(new GH_Mesh(combined));
            return true;
        }

        /// <summary>
        /// Find the mesh vertex index closest to the given point.
        /// Returns -1 if the closest vertex is farther than tolerance.
        /// </summary>
        private static int FindClosestVertexIndex(Mesh mesh, Point3d pt, double tol)
        {
            int best = -1;
            double bestSq = double.PositiveInfinity;
            for (int i = 0; i < mesh.Vertices.Count; i++)
            {
                double dSq = new Point3d(mesh.Vertices[i]).DistanceToSquared(pt);
                if (dSq < bestSq)
                {
                    bestSq = dSq;
                    best = i;
                }
            }
            return bestSq <= tol * tol ? best : -1;
        }

        /// <summary>
        /// Resolve the correct per-face analytical array, global max, and whether the
        /// quantity uses a diverging color scheme (signed) vs sequential (always ≥ 0).
        /// </summary>
        private static void ResolveSlabAnalyticalData(JToken m, int colorBy,
            double maxBending, double maxMembrane, double maxShear, double maxVM, double maxSurf,
            out double[] faceValues, out double maxValue, out bool isDiverging)
        {
            string field;
            switch (colorBy)
            {
                case COLOR_SLAB_BENDING:
                    field = "face_bending_moment"; maxValue = maxBending; isDiverging = true; break;
                case COLOR_SLAB_MEMBRANE:
                    field = "face_membrane_force"; maxValue = maxMembrane; isDiverging = true; break;
                case COLOR_SLAB_SHEAR:
                    field = "face_shear_force"; maxValue = maxShear; isDiverging = false; break;
                case COLOR_SLAB_VON_MISES:
                    field = "face_von_mises"; maxValue = maxVM; isDiverging = false; break;
                case COLOR_SLAB_SURFACE_STRESS:
                    field = "face_surface_stress"; maxValue = maxSurf; isDiverging = true; break;
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
            double maxDisp, double maxSlabBending, double maxSlabMembrane, double maxSlabShear,
            double maxSlabVonMises, double maxSlabSurfaceStress)
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
                var brep = new BoundingBox(new[]
                {
                    new Point3d(x0, y0, zBotDrop), new Point3d(x1, y0, zBotDrop),
                    new Point3d(x1, y1, zBotDrop), new Point3d(x0, y1, zBotDrop),
                    new Point3d(x0, y0, zTopDrop), new Point3d(x1, y0, zTopDrop),
                    new Point3d(x1, y1, zTopDrop), new Point3d(x0, y1, zTopDrop),
                }).ToBrep();
                if (brep != null)
                {
                    output.Add(new GH_Brep(brep));
                    AppendSlabColor(colors, analyticalSource, colorBy, maxDisp, "vertex_displacements",
                        maxSlabBending, maxSlabMembrane, maxSlabShear, maxSlabVonMises, maxSlabSurfaceStress);
                }
            }
        }

        private static void AppendDropPanelDeflectedGeometry(JToken meshToken, double[][] verts, double[][] disps,
            double scale, List<IGH_GeometricGoo> output)
        {
            var dropPanels = meshToken["drop_panels"] as JArray ?? new JArray();
            if (dropPanels.Count == 0 || verts == null || verts.Length == 0)
                return;

            double slabThickness = meshToken["thickness"]?.ToObject<double>() ?? 0.0;
            foreach (var dp in dropPanels)
            {
                var c = dp["center"]?.ToObject<double[]>() ?? new double[0];
                if (c.Length < 2) continue;
                double dpLength = dp["length"]?.ToObject<double>() ?? 0.0;
                double dpWidth = dp["width"]?.ToObject<double>() ?? 0.0;
                double extra = dp["extra_depth"]?.ToObject<double>() ?? 0.0;
                if (dpLength <= 0 || dpWidth <= 0 || extra <= 0) continue;

                double x0 = c[0] - dpLength / 2.0;
                double x1 = c[0] + dpLength / 2.0;
                double y0 = c[1] - dpWidth / 2.0;
                double y1 = c[1] + dpWidth / 2.0;

                var corners = new[] {
                    new Point3d(x0, y0, 0), new Point3d(x1, y0, 0),
                    new Point3d(x1, y1, 0), new Point3d(x0, y1, 0),
                };

                var topPts = new Point3d[4];
                var botPts = new Point3d[4];

                for (int ci = 0; ci < 4; ci++)
                {
                    var disp = InterpolateDisplacement(corners[ci].X, corners[ci].Y, verts, disps);
                    double zRef = disp[2]; // undeflected Z from nearest vertex
                    double dzScaled = disp[3] * scale;

                    double zTop = zRef + dzScaled - slabThickness;
                    double zBot = zTop - extra;
                    double xDef = corners[ci].X + disp[0] * scale;
                    double yDef = corners[ci].Y + disp[1] * scale;
                    topPts[ci] = new Point3d(xDef, yDef, zTop);
                    botPts[ci] = new Point3d(xDef, yDef, zBot);
                }

                var mesh = new Mesh();
                for (int ci = 0; ci < 4; ci++) mesh.Vertices.Add(topPts[ci]);
                for (int ci = 0; ci < 4; ci++) mesh.Vertices.Add(botPts[ci]);
                // Top face
                mesh.Faces.AddFace(0, 1, 2, 3);
                // Bottom face (reversed winding)
                mesh.Faces.AddFace(7, 6, 5, 4);
                // Side faces
                mesh.Faces.AddFace(0, 4, 5, 1);
                mesh.Faces.AddFace(1, 5, 6, 2);
                mesh.Faces.AddFace(2, 6, 7, 3);
                mesh.Faces.AddFace(3, 7, 4, 0);
                mesh.Normals.ComputeNormals();
                mesh.Compact();
                output.Add(new GH_Mesh(mesh));
            }
        }

        /// <summary>
        /// Inverse-distance-weighted interpolation of displacement at an XY query point
        /// from the slab mesh vertices. Returns (dx, dy, zRef, dz) where zRef is the
        /// undeflected Z of the nearest vertex and (dx, dy, dz) are displacement components.
        /// </summary>
        private static double[] InterpolateDisplacement(double qx, double qy, double[][] verts, double[][] disps)
        {
            const int K = 6;
            const double Eps = 1e-12;

            var nearest = new (int idx, double dist2)[K];
            for (int i = 0; i < K; i++)
                nearest[i] = (-1, double.MaxValue);

            for (int i = 0; i < verts.Length; i++)
            {
                double dx = verts[i][0] - qx;
                double dy = verts[i][1] - qy;
                double d2 = dx * dx + dy * dy;

                int worstSlot = 0;
                for (int j = 1; j < K; j++)
                {
                    if (nearest[j].dist2 > nearest[worstSlot].dist2)
                        worstSlot = j;
                }
                if (d2 < nearest[worstSlot].dist2)
                    nearest[worstSlot] = (i, d2);
            }

            // Check for exact coincidence with a vertex
            for (int j = 0; j < K; j++)
            {
                if (nearest[j].idx >= 0 && nearest[j].dist2 < Eps)
                {
                    int idx = nearest[j].idx;
                    double ddx = idx < disps.Length && disps[idx].Length >= 3 ? disps[idx][0] : 0;
                    double ddy = idx < disps.Length && disps[idx].Length >= 3 ? disps[idx][1] : 0;
                    double ddz = idx < disps.Length && disps[idx].Length >= 3 ? disps[idx][2] : 0;
                    return new[] { ddx, ddy, verts[idx][2], ddz };
                }
            }

            double wSum = 0, wDx = 0, wDy = 0, wDz = 0, wZ = 0;
            for (int j = 0; j < K; j++)
            {
                if (nearest[j].idx < 0) continue;
                int idx = nearest[j].idx;
                double w = 1.0 / Math.Sqrt(nearest[j].dist2);
                wSum += w;
                wZ += w * verts[idx][2];
                if (idx < disps.Length && disps[idx].Length >= 3)
                {
                    wDx += w * disps[idx][0];
                    wDy += w * disps[idx][1];
                    wDz += w * disps[idx][2];
                }
            }

            if (wSum < Eps)
            {
                int fallback = nearest[0].idx >= 0 ? nearest[0].idx : 0;
                double ddx = fallback < disps.Length && disps[fallback].Length >= 3 ? disps[fallback][0] : 0;
                double ddy = fallback < disps.Length && disps[fallback].Length >= 3 ? disps[fallback][1] : 0;
                double ddz = fallback < disps.Length && disps[fallback].Length >= 3 ? disps[fallback][2] : 0;
                return new[] { ddx, ddy, verts[fallback][2], ddz };
            }

            return new[] { wDx / wSum, wDy / wSum, wZ / wSum, wDz / wSum };
        }

        /// <summary>
        /// Build undeformed slab meshes from the deflected slab payload.
        /// This is used by "Original" mode so users can color original geometry
        /// by utilization/deflection without drawing displaced geometry.
        /// </summary>
        private static void BuildOriginalSlabs(JToken viz, List<IGH_GeometricGoo> output,
            List<Color> colors, int colorBy, double maxDisp,
            double maxSlabBending = 0, double maxSlabMembrane = 0, double maxSlabShear = 0,
            double maxSlabVonMises = 0, double maxSlabSurfaceStress = 0)
        {
            bool isAnalyticalSlab = colorBy >= COLOR_SLAB_BENDING && colorBy <= COLOR_SLAB_SURFACE_STRESS;
            var meshes = viz["deflected_slab_meshes"] as JArray ?? new JArray();
            if (meshes.Count == 0)
            {
                BuildSizedSlabs(viz, output, colors, colorBy, maxDisp,
                    maxSlabBending, maxSlabMembrane, maxSlabShear, maxSlabVonMises, maxSlabSurfaceStress);
                return;
            }

            foreach (var m in meshes)
            {
                var verts = m["vertices"]?.ToObject<double[][]>() ?? new double[0][];
                var faces = m["faces"]?.ToObject<int[][]>() ?? new int[0][];
                if (verts.Length == 0) continue;

                double[] faceAnalytical = null;
                double analyticalMax = 0;
                bool analyticalDiverging = false;
                if (isAnalyticalSlab)
                    ResolveSlabAnalyticalData(m, colorBy, maxSlabBending, maxSlabMembrane,
                        maxSlabShear, maxSlabVonMises, maxSlabSurfaceStress,
                        out faceAnalytical, out analyticalMax, out analyticalDiverging);

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
                    var defColor = VisualizationColorMapper.DeflectionColor(0.0, maxDisp, null);
                    for (int i = 0; i < rhinoMesh.Vertices.Count; i++)
                        rhinoMesh.VertexColors.Add(defColor);
                }
                else if (colorBy == COLOR_MATERIAL)
                {
                    bool isVault = m["is_vault"]?.ToObject<bool>() ?? false;
                    var materialColor = isVault
                        ? VisualizationColorMapper.EarthenMaterialColor
                        : VisualizationColorMapper.ResolveMaterialColor(
                            m["material_color_hex"]?.ToString(),
                            VisualizationColorMapper.ConcreteMaterialColor);
                    for (int i = 0; i < rhinoMesh.Vertices.Count; i++)
                        rhinoMesh.VertexColors.Add(materialColor);
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
                    AppendSlabColor(colors, m, colorBy, maxDisp, "vertex_displacements",
                        maxSlabBending, maxSlabMembrane, maxSlabShear, maxSlabVonMises, maxSlabSurfaceStress);
                }
            }
        }

        private static void BuildFoundations(JToken viz, List<IGH_GeometricGoo> output,
            List<Color> colors, int colorBy)
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
                    colors.Add(VisualizationColorMapper.UtilizationColor(ratio, ok, null));
                }
                else if (colorBy == COLOR_DEFLECTION)
                {
                    colors.Add(VisualizationColorMapper.DeflectionColor(0.0, 1.0, null));
                }
                else if (colorBy == COLOR_MATERIAL)
                {
                    colors.Add(VisualizationColorMapper.ResolveMaterialColor(f["material_color_hex"]?.ToString(), VisualizationColorMapper.DefaultMaterialColor));
                }
                else
                {
                    colors.Add(VisualizationColorMapper.DefaultMaterialColor);
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
            int colorBy, double maxDisp, string displacementField = "vertex_displacements",
            double maxSlabBending = 0, double maxSlabMembrane = 0, double maxSlabShear = 0,
            double maxSlabVonMises = 0, double maxSlabSurfaceStress = 0)
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
                if (isVault)
                    colors.Add(VisualizationColorMapper.EarthenMaterialColor);
                else
                    colors.Add(VisualizationColorMapper.ResolveMaterialColor(
                        element["material_color_hex"]?.ToString(),
                        VisualizationColorMapper.ConcreteMaterialColor));
            }
            else if (isAnalyticalSlab)
            {
                ResolveSlabAnalyticalData(element, colorBy, maxSlabBending, maxSlabMembrane,
                    maxSlabShear, maxSlabVonMises, maxSlabSurfaceStress,
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
                colors.Add(isVault
                    ? VisualizationColorMapper.EarthenMaterialColor
                    : VisualizationColorMapper.DefaultMaterialColor);
            }
        }
    }
}
