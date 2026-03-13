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
                   "Menegroth", "Input")
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

            pManager.AddCurveParameter("Faces", "Faces",
                "Closed polylines defining floor/roof/grade faces (optional)",
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

        // ─── Right-click menu for Units ──────────────────────────────────
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
                    Message = LabelForValue(_units);
                    ExpireSolution(true);
                };
                unitsMenu.DropDownItems.Add(item);
            }
        }

        // ─── Persistence (save/load dropdown state) ──────────────────────
        public override bool Write(GH_IO.Serialization.GH_IWriter writer)
        {
            writer.SetString("Units", _units);
            return base.Write(writer);
        }

        public override bool Read(GH_IO.Serialization.GH_IReader reader)
        {
            if (reader.ItemExists("Units"))
                _units = reader.GetString("Units");
            Message = LabelForValue(_units);
            return base.Read(reader);
        }

        // ─── Display current selection under the component ───────────────
        public override void AddedToDocument(GH_Document document)
        {
            base.AddedToDocument(document);
            Message = LabelForValue(_units);
        }

        private static string LabelForValue(string value)
        {
            foreach (var (label, val) in UnitChoices)
                if (val == value) return label;
            return value;
        }

        // ─── Solve ───────────────────────────────────────────────────────
        protected override void SolveInstance(IGH_DataAccess DA)
        {
            var beamLines = new List<Line>();
            var columnLines = new List<Line>();
            var strutLines = new List<Line>();
            var faceCurves = new List<Rhino.Geometry.Curve>();
            var supportPts = new List<Point3d>();

            DA.GetDataList(0, beamLines);    // optional
            DA.GetDataList(1, columnLines);  // optional
            DA.GetDataList(2, strutLines);   // optional
            DA.GetDataList(3, faceCurves);   // optional
            if (!DA.GetDataList(4, supportPts)) return;

            if (beamLines.Count == 0 && columnLines.Count == 0 && strutLines.Count == 0)
            {
                AddRuntimeMessage(GH_RuntimeMessageLevel.Error,
                    "Provide at least one of: Beams, Columns, or Struts.");
                return;
            }

            var geo = new BuildingGeometry { Units = _units };

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

            // ─── Face extraction (optional) ──────────────────────────────
            if (faceCurves.Count > 0)
            {
                foreach (var crv in faceCurves)
                {
                    if (crv == null || !crv.IsClosed) continue;
                    if (!crv.TryGetPolyline(out Polyline pl)) continue;

                    var coords = new List<double[]>();
                    for (int i = 0; i < pl.Count - 1; i++)
                        coords.Add(new[] { pl[i].X, pl[i].Y, pl[i].Z });

                    if (coords.Count < 3) continue;

                    // Faces are auto-categorised by Julia (rebuild_stories! + _auto_categorize_faces!)
                    string category = "floor";

                    if (!geo.Faces.ContainsKey(category))
                        geo.Faces[category] = new List<List<double[]>>();
                    geo.Faces[category].Add(coords);
                }
            }

            DA.SetData(0, new GH_BuildingGeometry(geo));
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
