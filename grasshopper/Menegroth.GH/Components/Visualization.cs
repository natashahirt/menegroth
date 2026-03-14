using System;
using System.Collections.Generic;
using System.Drawing;
using System.Linq;
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

        public Visualization()
            : base("Visualization",
                   "Viz",
                   "Visualize structural design with geometry, deflections, and color mapping",
                   "Menegroth", "Visualization")
        { }

        public override Guid ComponentGuid =>
            new Guid("E7D94B2A-6C31-4D89-AF1E-2B8A3C5D7E9F");

        protected override void RegisterInputParams(GH_InputParamManager pManager)
        {
            pManager.AddGenericParameter("Result", "R",
                "DesignResult from the DesignRun component", GH_ParamAccess.item);

            var modeParam = new Param_Integer();
            modeParam.AddNamedValue("Sized", MODE_SIZED);
            modeParam.AddNamedValue("Deflected (Global)", MODE_DEFLECTED_GLOBAL);
            modeParam.AddNamedValue("Deflected (Local)", MODE_DEFLECTED_LOCAL);
            modeParam.AddNamedValue("Original", MODE_ORIGINAL);
            pManager.AddParameter(modeParam, "Mode", "M",
                "Visualization mode: Sized shows as-designed geometry, " +
                "Deflected Global/Local shows displaced shapes",
                GH_ParamAccess.item);
            pManager[1].Optional = true;

            pManager.AddNumberParameter("Scale", "S",
                "Deflection scale multiplier (0 = no deflection, 1 = auto-suggested, >1 = exaggerated)",
                GH_ParamAccess.item, 1.0);

            pManager.AddBooleanParameter("Show Original", "O",
                "Show undeflected geometry as reference", GH_ParamAccess.item, true);

            var colorParam = new Param_Integer();
            colorParam.AddNamedValue("None", COLOR_NONE);
            colorParam.AddNamedValue("Utilization", COLOR_UTILIZATION);
            colorParam.AddNamedValue("Deflection", COLOR_DEFLECTION);
            pManager.AddParameter(colorParam, "Color By", "C",
                "Color mapping: None, Utilization (green→red by demand/capacity), " +
                "Deflection (blue→red by displacement magnitude)",
                GH_ParamAccess.item);
            pManager[4].Optional = true;
        }

        protected override void RegisterOutputParams(GH_OutputParamManager pManager)
        {
            pManager.AddCurveParameter("Frame Curves", "FC",
                "Frame element curves (cubic interpolated if deflected)", GH_ParamAccess.list);
            pManager.AddGenericParameter("Frame Geometry", "FG",
                "Frame element 3D section geometry (Brep)", GH_ParamAccess.list);
            pManager.AddGenericParameter("Slab Geometry", "SG",
                "Slab + foundation geometry (Brep for Sized, Mesh for Deflected)", GH_ParamAccess.list);
            pManager.AddCurveParameter("Original Curves", "OC",
                "Original frame curves (only if Show Original = true and Mode is Deflected)",
                GH_ParamAccess.list);
            pManager.AddGenericParameter("Original Slabs", "OS",
                "Original slab geometry (only if Show Original = true and Mode is Deflected)",
                GH_ParamAccess.list);
            pManager.AddColourParameter("Frame Colors", "FClr",
                "Colors for frame elements (parallel to FC/FG). Wire to Custom Preview.",
                GH_ParamAccess.list);
            pManager.AddColourParameter("Slab Colors", "SClr",
                "Colors for slabs (parallel to SG). Wire to Custom Preview.",
                GH_ParamAccess.list);
            pManager.AddCurveParameter("Column Curves", "CC",
                "Column curves (subset of FC) for dedicated line preview", GH_ParamAccess.list);
            pManager.AddCurveParameter("Beam Curves", "BC",
                "Beam curves (subset of FC) for dedicated line preview", GH_ParamAccess.list);
            pManager.AddColourParameter("Column Colors", "CClr",
                "Colors parallel to CC", GH_ParamAccess.list);
            pManager.AddColourParameter("Beam Colors", "BClr",
                "Colors parallel to BC", GH_ParamAccess.list);
            pManager.AddGenericParameter("Column Geometry", "CG",
                "Column section geometry as Breps", GH_ParamAccess.list);
            pManager.AddGenericParameter("Beam Geometry", "BG",
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

            bool showOriginal = true;
            DA.GetData(3, ref showOriginal);

            int colorByInt = COLOR_UTILIZATION;
            DA.GetData(4, ref colorByInt);

            bool isDeflected = modeInt == MODE_DEFLECTED_GLOBAL || modeInt == MODE_DEFLECTED_LOCAL;
            bool isLocal = modeInt == MODE_DEFLECTED_LOCAL;
            bool isOriginalMode = modeInt == MODE_ORIGINAL;

            // Extract nodes
            var nodes = new Dictionary<int, (Point3d pos, Vector3d disp)>();
            var nodesArray = viz["nodes"] as JArray ?? new JArray();
            foreach (var n in nodesArray)
            {
                int nodeId = n["node_id"]?.ToObject<int>() ?? 0;
                var posArr = n["position_ft"]?.ToObject<double[]>() ?? new double[3];
                var dispArr = n["displacement_ft"]?.ToObject<double[]>() ?? new double[3];
                nodes[nodeId] = (
                    new Point3d(posArr[0], posArr[1], posArr[2]),
                    new Vector3d(dispArr[0], dispArr[1], dispArr[2])
                );
            }

            double finalScale = scaleMult * result.SuggestedScaleFactor;
            double maxDisp = result.MaxDisplacementFt;

            // Frame elements
            var frameCurves = new List<Curve>();
            var frameGeometry = new List<IGH_GeometricGoo>();
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

                Curve elementCurve;
                List<Point3d> origCurvePoints = null;

                if (origPts.Length == 0 || dispVecs.Length == 0)
                {
                    int ns = elem["node_start"]?.ToObject<int>() ?? 0;
                    int ne = elem["node_end"]?.ToObject<int>() ?? 0;
                    if (!nodes.ContainsKey(ns) || !nodes.ContainsKey(ne)) continue;

                    var p1 = nodes[ns].pos;
                    var p2 = nodes[ne].pos;

                    if (showOriginal && isDeflected && finalScale > 0)
                        originalCurves.Add(new Line(p1, p2).ToNurbsCurve());

                    if (isDeflected && finalScale > 0)
                    {
                        p1 += nodes[ns].disp * finalScale;
                        p2 += nodes[ne].disp * finalScale;
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

                            if (isLocal && dispVecs.Length >= 2)
                            {
                                var uStart = new Vector3d(dispVecs[0][0], dispVecs[0][1], dispVecs[0][2]);
                                int last = dispVecs.Length - 1;
                                var uEnd = new Vector3d(dispVecs[last][0], dispVecs[last][1], dispVecs[last][2]);
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

                    elementCurve = pts.Count > 1 ? new PolylineCurve(pts) : null;

                    if (showOriginal && isDeflected && finalScale > 0 && origCurvePoints.Count > 1)
                        originalCurves.Add(new PolylineCurve(origCurvePoints));
                }

                if (elementCurve == null) continue;
                frameCurves.Add(elementCurve);
                string elemType = elem["element_type"]?.ToString() ?? "";

                var brep = SweepSection(elementCurve, elem);
                if (brep != null)
                {
                    frameGeometry.Add(new GH_Brep(brep));
                    if (elemType == "column")
                        columnGeometry.Add(new GH_Brep(brep));
                    else if (elemType == "beam")
                        beamGeometry.Add(new GH_Brep(brep));
                }

                Color elementColor = Color.Empty;
                bool hasColor = false;
                if (colorByInt == COLOR_UTILIZATION)
                {
                    double ratio = elem["utilization_ratio"]?.ToObject<double>() ?? 0;
                    bool ok = elem["ok"]?.ToObject<bool>() ?? true;
                    elementColor = UtilizationColor(ratio, ok);
                    hasColor = true;
                }
                else if (colorByInt == COLOR_DEFLECTION)
                {
                    double disp = ComputeElementDisplacement(elem, nodes, dispVecs);
                    elementColor = DeflectionColor(disp, maxDisp);
                    hasColor = true;
                }

                if (hasColor)
                    frameColors.Add(elementColor);

                if (elemType == "column")
                {
                    columnCurves.Add(elementCurve);
                    if (hasColor) columnColors.Add(elementColor);
                }
                else if (elemType == "beam")
                {
                    beamCurves.Add(elementCurve);
                    if (hasColor) beamColors.Add(elementColor);
                }
            }

            // Slab geometry + colors
            var slabGeometry = new List<IGH_GeometricGoo>();
            var slabColors = new List<Color>();
            var originalSlabs = new List<IGH_GeometricGoo>();

            if (isOriginalMode)
                BuildOriginalSlabs(viz, slabGeometry, slabColors, colorByInt, maxDisp);
            else if (!isDeflected || finalScale <= 0)
                BuildSizedSlabs(viz, slabGeometry, slabColors, colorByInt, maxDisp);
            else
                BuildDeflectedSlabs(viz, finalScale, showOriginal, slabGeometry, originalSlabs,
                    slabColors, colorByInt, maxDisp, isLocal);

            if (!isDeflected)
                BuildFoundations(viz, slabGeometry, slabColors, colorByInt);

            // Set outputs
            DA.SetDataList(0, frameCurves);
            DA.SetDataList(1, frameGeometry);
            DA.SetDataList(2, slabGeometry);
            DA.SetDataList(3, originalCurves);
            DA.SetDataList(4, originalSlabs);
            DA.SetDataList(5, frameColors);
            DA.SetDataList(6, slabColors);
            DA.SetDataList(7, columnCurves);
            DA.SetDataList(8, beamCurves);
            DA.SetDataList(9, columnColors);
            DA.SetDataList(10, beamColors);
            DA.SetDataList(11, columnGeometry);
            DA.SetDataList(12, beamGeometry);

            // Update message bar
            string modeName = modeInt == MODE_SIZED ? "Sized"
                : modeInt == MODE_DEFLECTED_LOCAL ? "Deflected (Local)"
                : modeInt == MODE_ORIGINAL ? "Original"
                : "Deflected (Global)";
            string colorName = colorByInt == COLOR_UTILIZATION ? "Utilization"
                : colorByInt == COLOR_DEFLECTION ? "Deflection" : "";
            Message = colorName.Length > 0 ? $"{modeName} | {colorName}" : modeName;
        }

        // ─── Displacement magnitude for a frame element ──────────────────

        private static double ComputeElementDisplacement(JToken elem,
            Dictionary<int, (Point3d pos, Vector3d disp)> nodes,
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
            double depth = elem["section_depth_ft"]?.ToObject<double>() ?? 0;
            double width = elem["section_width_ft"]?.ToObject<double>() ?? 0;

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
        private static Color UtilizationColor(double ratio, bool ok)
        {
            if (!ok || ratio > 1.0)
                return Color.FromArgb(200, 0, 120);

            ratio = Math.Max(0.0, Math.Min(ratio, 1.0));

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
        private static Color DeflectionColor(double displacement, double maxDisplacement)
        {
            if (maxDisplacement < 1e-12)
                return Color.FromArgb(40, 80, 200);

            double t = Math.Max(0.0, Math.Min(displacement / maxDisplacement, 1.0));

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

        // ─── Slab helpers ───────────────────────────────────────────────

        private static void BuildSizedSlabs(JToken viz, List<IGH_GeometricGoo> output,
            List<Color> colors, int colorBy, double maxDisp)
        {
            var slabs = viz["sized_slabs"] as JArray ?? new JArray();
            foreach (var slab in slabs)
            {
                var boundary = slab["boundary_vertices"]?.ToObject<double[][]>() ?? new double[0][];
                double thickness = slab["thickness_ft"]?.ToObject<double>() ?? 0;
                double zTop = slab["z_top_ft"]?.ToObject<double>() ?? 0;
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

                    AppendSlabColor(colors, slab, colorBy, maxDisp);
                }
            }
        }

        private static void BuildDeflectedSlabs(JToken viz, double scale, bool showOriginal,
            List<IGH_GeometricGoo> output, List<IGH_GeometricGoo> origOutput,
            List<Color> colors, int colorBy, double maxDisp, bool isLocal)
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

                // Per-vertex coloring for deflection mode on meshes
                if (colorBy == COLOR_DEFLECTION && disps.Length > 0)
                {
                    for (int i = 0; i < rhinoMesh.Vertices.Count; i++)
                    {
                        double mag = 0;
                        if (i < disps.Length && disps[i].Length >= 3)
                            mag = Math.Sqrt(disps[i][0] * disps[i][0] +
                                            disps[i][1] * disps[i][1] +
                                            disps[i][2] * disps[i][2]);
                        rhinoMesh.VertexColors.Add(DeflectionColor(mag, maxDisp));
                    }
                }

                if (rhinoMesh.Vertices.Count > 0 && rhinoMesh.Faces.Count > 0)
                {
                    rhinoMesh.Normals.ComputeNormals();
                    rhinoMesh.Compact();
                    output.Add(new GH_Mesh(rhinoMesh));

                    if (origMesh?.Vertices.Count > 0 && origMesh.Faces.Count > 0)
                    {
                        origMesh.Normals.ComputeNormals();
                        origMesh.Compact();
                        origOutput.Add(new GH_Mesh(origMesh));
                    }

                    string dispField = isLocal && dispsLocal.Length > 0
                        ? "vertex_displacements_local"
                        : "vertex_displacements";
                    AppendSlabColor(colors, m, colorBy, maxDisp, dispField);
                }
            }
        }

        /// <summary>
        /// Build undeformed slab meshes from the deflected slab payload.
        /// This is used by "Original" mode so users can color original geometry
        /// by utilization/deflection without drawing displaced geometry.
        /// </summary>
        private static void BuildOriginalSlabs(JToken viz, List<IGH_GeometricGoo> output,
            List<Color> colors, int colorBy, double maxDisp)
        {
            var meshes = viz["deflected_slab_meshes"] as JArray ?? new JArray();
            if (meshes.Count == 0)
            {
                BuildSizedSlabs(viz, output, colors, colorBy, maxDisp);
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
                    AppendSlabColor(colors, m, colorBy, maxDisp);
                }
            }
        }

        private static void BuildFoundations(JToken viz, List<IGH_GeometricGoo> output,
            List<Color> colors, int colorBy)
        {
            var foundations = viz["foundations"] as JArray ?? new JArray();
            foreach (var f in foundations)
            {
                var c = f["center_ft"]?.ToObject<double[]>() ?? new double[3];
                if (c.Length < 3) continue;
                double length = f["length_ft"]?.ToObject<double>() ?? 0;
                double width = f["width_ft"]?.ToObject<double>() ?? 0;
                double depth = f["depth_ft"]?.ToObject<double>() ?? 0;
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
                    colors.Add(UtilizationColor(ratio, ok));
                }
                else if (colorBy == COLOR_DEFLECTION)
                {
                    colors.Add(DeflectionColor(0.0, 1.0));
                }
            }
        }

        /// <summary>
        /// Append one color per slab/mesh element to the parallel color list.
        /// For deflection mode on meshes, per-vertex coloring is handled above;
        /// this still outputs one representative color for the Custom Preview pipeline.
        /// </summary>
        private static void AppendSlabColor(List<Color> colors, JToken element,
            int colorBy, double maxDisp, string displacementField = "vertex_displacements")
        {
            if (colorBy == COLOR_UTILIZATION)
            {
                double ratio = element["utilization_ratio"]?.ToObject<double>() ?? 0;
                bool ok = element["ok"]?.ToObject<bool>() ?? true;
                colors.Add(UtilizationColor(ratio, ok));
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
                colors.Add(DeflectionColor(maxVertDisp, maxDisp));
            }
        }
    }
}
