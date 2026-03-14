using System;
using System.Collections.Generic;
using System.Linq;
using System.Windows.Forms;
using Grasshopper.Kernel;
using Rhino.Geometry;
using Menegroth.GH.Types;

namespace Menegroth.GH.Components
{
    /// <summary>
    /// Extracts building geometry from Rhino objects and packages it for the
    /// structural sizing API.
    ///
    /// Beams, columns, and struts are provided as separate line inputs.
    /// Story elevations are inferred from vertex Z coordinates automatically.
    /// Lines are auto-shattered at intermediate vertex intersections.
    ///
    /// The coordinate unit is selected via the right-click menu (default: Feet).
    /// </summary>
    public class GeometryInput : GH_Component
    {
        // ─── Embedded dropdown state ─────────────────────────────────────
        private string _units = "feet";
        private bool _geometryIsCenterline = false;

        private static readonly (string Label, string Value)[] UnitChoices =
        {
            ("Feet",        "feet"),
            ("Inches",      "inches"),
            ("Meters",      "meters"),
            ("Millimeters", "mm"),
        };

        public GeometryInput()
            : base("Geometry Input",
                   "GeoInput",
                   "Extract building geometry for structural sizing",
                   "Menegroth", "Core")
        { }

        public override Guid ComponentGuid =>
            new Guid("06337717-7C60-47C6-97A5-0F2D8F9BC155");

        // ─── Parameters ──────────────────────────────────────────────────
        protected override void RegisterInputParams(GH_InputParamManager pManager)
        {
            pManager.AddLineParameter("Beams", "Beams",
                "Beam lines (horizontal frame members)",
                GH_ParamAccess.list);
            pManager[0].Optional = true;

            pManager.AddLineParameter("Columns", "Columns",
                "Column lines (vertical frame members)",
                GH_ParamAccess.list);
            pManager[1].Optional = true;

            pManager.AddLineParameter("Struts", "Struts",
                "Strut / brace lines (diagonal members)",
                GH_ParamAccess.list);
            pManager[2].Optional = true;

            pManager.AddGeometryParameter("Faces", "Frame",
                "Planar surfaces or closed curves (floor/roof/grade faces)",
                GH_ParamAccess.list);
            pManager[3].Optional = true;

            pManager.AddPointParameter("Supports", "Supports",
                "Support point locations", GH_ParamAccess.list);
        }

        protected override void RegisterOutputParams(GH_OutputParamManager pManager)
        {
            pManager.AddGenericParameter("Geometry", "Geometry",
                "BuildingGeometry object for the Design Run component",
                GH_ParamAccess.item);
        }

        // ─── Right-click menu for Units + Geometry Mode ──────────────────
        protected override void AppendAdditionalComponentMenuItems(ToolStripDropDown menu)
        {
            base.AppendAdditionalComponentMenuItems(menu);
            Menu_AppendSeparator(menu);

            var unitsMenu = Menu_AppendItem(menu, "Units");
            foreach (var (label, value) in UnitChoices)
            {
                var item = new ToolStripMenuItem(label)
                {
                    Checked = _units == value,
                    Tag = value
                };
                item.Click += (s, e) =>
                {
                    _units = (string)((ToolStripMenuItem)s).Tag;
                    Message = BuildMessage();
                    ExpireSolution(true);
                };
                unitsMenu.DropDownItems.Add(item);
            }

            Menu_AppendSeparator(menu);
            var centerlineItem = new ToolStripMenuItem("Input is Centerline")
            {
                Checked = _geometryIsCenterline,
                ToolTipText = "When checked, vertices are structural centerlines.\n" +
                    "When unchecked (default), vertices are architectural reference points\n" +
                    "and edge/corner columns are automatically offset inward."
            };
            centerlineItem.Click += (s, e) =>
            {
                _geometryIsCenterline = !_geometryIsCenterline;
                Message = BuildMessage();
                ExpireSolution(true);
            };
            menu.Items.Add(centerlineItem);
        }

        // ─── Persistence (save/load dropdown state) ──────────────────────
        public override bool Write(GH_IO.Serialization.GH_IWriter writer)
        {
            writer.SetString("Units", _units);
            writer.SetBoolean("GeometryIsCenterline", _geometryIsCenterline);
            return base.Write(writer);
        }

        public override bool Read(GH_IO.Serialization.GH_IReader reader)
        {
            if (reader.ItemExists("Units"))
                _units = reader.GetString("Units");
            if (reader.ItemExists("GeometryIsCenterline"))
                _geometryIsCenterline = reader.GetBoolean("GeometryIsCenterline");
            Message = BuildMessage();
            return base.Read(reader);
        }

        // ─── Display current selection under the component ───────────────
        public override void AddedToDocument(GH_Document document)
        {
            base.AddedToDocument(document);
            Message = BuildMessage();
        }

        private static string UnitLabelForValue(string value)
        {
            foreach (var (label, val) in UnitChoices)
                if (val == value) return label;
            return value;
        }

        private string BuildMessage()
        {
            var msg = UnitLabelForValue(_units);
            if (_geometryIsCenterline)
                msg += " | CL";
            return msg;
        }

        // ─── Solve ───────────────────────────────────────────────────────
        protected override void SolveInstance(IGH_DataAccess DA)
        {
            var beamLines = new List<Line>();
            var columnLines = new List<Line>();
            var strutLines = new List<Line>();
            var supportPts = new List<Point3d>();

            DA.GetDataList(0, beamLines);    // optional
            DA.GetDataList(1, columnLines);  // optional
            DA.GetDataList(2, strutLines);   // optional
            if (!DA.GetDataList(4, supportPts)) return;

            if (beamLines.Count == 0 && columnLines.Count == 0 && strutLines.Count == 0)
            {
                AddRuntimeMessage(GH_RuntimeMessageLevel.Error,
                    "Provide at least one of: Beams, Columns, or Struts.");
                return;
            }

            var geo = new BuildingGeometry
            {
                Units = _units,
                GeometryIsCenterline = _geometryIsCenterline
            };

            // ─── Vertex extraction with deduplication ────────────────────
            const double TOL = 1e-6;
            var vertexMap = new Dictionary<string, int>();

            int GetOrAddVertex(Point3d pt)
            {
                var key = $"{Math.Round(pt.X, 6)}_{Math.Round(pt.Y, 6)}_{Math.Round(pt.Z, 6)}";
                if (vertexMap.TryGetValue(key, out int idx))
                    return idx;
                geo.Vertices.Add(new[] { pt.X, pt.Y, pt.Z });
                int newIdx = geo.Vertices.Count; // 1-based for Julia
                vertexMap[key] = newIdx;
                return newIdx;
            }

            // First pass: register all vertices from all line endpoints
            foreach (var line in beamLines)
            {
                GetOrAddVertex(line.From);
                GetOrAddVertex(line.To);
            }
            foreach (var line in columnLines)
            {
                GetOrAddVertex(line.From);
                GetOrAddVertex(line.To);
            }
            foreach (var line in strutLines)
            {
                GetOrAddVertex(line.From);
                GetOrAddVertex(line.To);
            }
            foreach (var sp in supportPts)
            {
                GetOrAddVertex(sp);
            }

            // ─── Auto-shatter + edge classification ──────────────────────
            ShatterAndAdd(beamLines, geo.BeamEdges, geo, vertexMap, TOL);
            ShatterAndAdd(columnLines, geo.ColumnEdges, geo, vertexMap, TOL);
            ShatterAndAdd(strutLines, geo.StrutEdges, geo, vertexMap, TOL);

            // ─── Support matching ────────────────────────────────────────
            foreach (var sp in supportPts)
            {
                int idx = GetOrAddVertex(sp);
                if (!geo.Supports.Contains(idx))
                    geo.Supports.Add(idx);
            }

            // ─── Face extraction (optional): curves or planar surfaces ───
            var faceInputs = new List<GeometryBase>();
            if (DA.GetDataList(3, faceInputs) && faceInputs.Count > 0)
            {
                foreach (var geom in faceInputs)
                {
                    if (geom == null) continue;
                    var coords = GetBoundaryPolylineCoords(geom);
                    if (coords == null || coords.Count < 3) continue;

                    // Snap face boundary points to the same rounded vertex map used by edges.
                    // This ensures explicit faces reference the same geometric graph as beams/columns.
                    var snapped = new List<double[]>();
                    foreach (var c in coords)
                    {
                        int vi = GetOrAddVertex(new Point3d(c[0], c[1], c[2]));
                        var v = geo.Vertices[vi - 1];
                        var hasPrev = snapped.Count > 0;
                        var prev = hasPrev ? snapped[snapped.Count - 1] : null;
                        if (snapped.Count == 0 ||
                            Math.Abs(prev[0] - v[0]) > TOL ||
                            Math.Abs(prev[1] - v[1]) > TOL ||
                            Math.Abs(prev[2] - v[2]) > TOL)
                        {
                            snapped.Add(new[] { v[0], v[1], v[2] });
                        }
                    }
                    if (snapped.Count < 3) continue;

                    string category = "floor";
                    if (!geo.Faces.ContainsKey(category))
                        geo.Faces[category] = new List<List<double[]>>();
                    geo.Faces[category].Add(snapped);
                }
            }

            DA.SetData(0, new GH_BuildingGeometry(geo));
        }

        /// <summary>
        /// Get boundary as a closed polyline in [x,y,z] coords. Supports closed curves
        /// (polyline or NURBS) and planar surfaces / single-face Breps.
        /// </summary>
        private static List<double[]> GetBoundaryPolylineCoords(GeometryBase geom)
        {
            if (geom is Curve crv)
                return CurveToPolylineCoords(crv);
            if (geom is Brep brep && brep.Faces.Count == 1)
                return BrepFaceToPolylineCoords(brep.Faces[0]);
            if (geom is Surface srf)
            {
                var brepFromSrf = Brep.CreateFromSurface(srf);
                if (brepFromSrf?.Faces.Count == 1)
                    return BrepFaceToPolylineCoords(brepFromSrf.Faces[0]);
            }
            return null;
        }

        private static List<double[]> CurveToPolylineCoords(Curve crv)
        {
            if (crv == null || !crv.IsClosed) return null;
            if (crv.TryGetPolyline(out Polyline pl))
            {
                var coords = new List<double[]>();
                for (int i = 0; i < pl.Count - 1; i++)
                    coords.Add(new[] { pl[i].X, pl[i].Y, pl[i].Z });
                return coords;
            }
            const double tol = 1e-6;
            const double angleTol = 0.1;
            var plCurve = crv.ToPolyline(tol, angleTol, 0.001, 1000.0);
            if (plCurve == null || !plCurve.TryGetPolyline(out Polyline plApprox) || plApprox.Count < 4)
                return null;
            var list = new List<double[]>();
            for (int i = 0; i < plApprox.Count - 1; i++)
                list.Add(new[] { plApprox[i].X, plApprox[i].Y, plApprox[i].Z });
            return list;
        }

        private static List<double[]> BrepFaceToPolylineCoords(BrepFace face)
        {
            var loop = face.OuterLoop;
            if (loop == null) return null;
            var coords = new List<double[]>();
            foreach (var trim in loop.Trims)
            {
                var edge = trim.Edge;
                if (edge?.EdgeCurve == null) return null;
                var edgeCrv = edge.EdgeCurve;
                if (edgeCrv.TryGetPolyline(out Polyline pl))
                {
                    int n = pl.Count - 1;
                    for (int i = 0; i < n; i++)
                        coords.Add(new[] { pl[i].X, pl[i].Y, pl[i].Z });
                }
                else
                {
                    const double tol = 1e-6;
                    const double angleTol = 0.1;
                    var plCurve = edgeCrv.ToPolyline(tol, angleTol, 0.001, 1000.0);
                    if (plCurve == null || !plCurve.TryGetPolyline(out Polyline plApprox)) return null;
                    for (int i = 0; i < plApprox.Count - 1; i++)
                        coords.Add(new[] { plApprox[i].X, plApprox[i].Y, plApprox[i].Z });
                }
            }
            return coords.Count >= 3 ? coords : null;
        }

        // ─── Auto-shatter helper ─────────────────────────────────────────
        private static void ShatterAndAdd(
            List<Line> lines,
            List<int[]> edgeList,
            BuildingGeometry geo,
            Dictionary<string, int> vertexMap,
            double tol)
        {
            foreach (var line in lines)
            {
                var key1 = $"{Math.Round(line.From.X, 6)}_{Math.Round(line.From.Y, 6)}_{Math.Round(line.From.Z, 6)}";
                var key2 = $"{Math.Round(line.To.X, 6)}_{Math.Round(line.To.Y, 6)}_{Math.Round(line.To.Z, 6)}";
                int v1 = vertexMap[key1];
                int v2 = vertexMap[key2];

                var intermediates = new List<(int idx, double t)>();
                double segLenSq = line.From.DistanceTo(line.To);
                segLenSq *= segLenSq;

                if (segLenSq < tol * tol) continue;

                Vector3d dir = line.To - line.From;

                for (int i = 0; i < geo.Vertices.Count; i++)
                {
                    int vi = i + 1; // 1-based
                    if (vi == v1 || vi == v2) continue;

                    var pt = new Point3d(geo.Vertices[i][0], geo.Vertices[i][1], geo.Vertices[i][2]);
                    Vector3d toP = pt - line.From;

                    double t = (toP.X * dir.X + toP.Y * dir.Y + toP.Z * dir.Z) /
                               (dir.X * dir.X + dir.Y * dir.Y + dir.Z * dir.Z);

                    if (t <= tol || t >= 1.0 - tol) continue;

                    Point3d closest = line.From + t * dir;
                    double dist = pt.DistanceTo(closest);
                    if (dist > tol) continue;

                    intermediates.Add((vi, t));
                }

                if (intermediates.Count == 0)
                {
                    edgeList.Add(new[] { v1, v2 });
                }
                else
                {
                    intermediates.Sort((a, b) => a.t.CompareTo(b.t));
                    int prev = v1;
                    foreach (var (vi, _) in intermediates)
                    {
                        edgeList.Add(new[] { prev, vi });
                        prev = vi;
                    }
                    edgeList.Add(new[] { prev, v2 });
                }
            }
        }
    }
}
