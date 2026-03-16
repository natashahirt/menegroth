using System;
using System.Collections.Generic;
using System.Linq;
using System.Windows.Forms;
using Grasshopper.Kernel;
using Rhino.Geometry;
using Menegroth.GH.Helpers;
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
                   "Menegroth", "   Input")
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

            pManager.AddGeometryParameter("Faces", "Slabs",
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

            pManager.AddTextParameter("Summary", "Summary",
                "Human-readable summary of geometry for debugging and agent context",
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
            var vertexMap = new Dictionary<(long, long, long), int>();

            static (long, long, long) QuantizePoint(Point3d pt)
            {
                return ((long)Math.Round(pt.X * 1e6),
                        (long)Math.Round(pt.Y * 1e6),
                        (long)Math.Round(pt.Z * 1e6));
            }

            int GetOrAddVertex(Point3d pt)
            {
                var key = QuantizePoint(pt);
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
                    var coords = GeometryExtraction.GetBoundaryPolylineCoords(geom);
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

            DA.SetData(0, new BuildingGeometryGoo(geo));
            DA.SetData(1, BuildGeometrySummary(geo));
        }

        /// <summary>
        /// Build a human-readable summary of building geometry for debugging and agent context.
        /// Thorough and informative: structure, connectivity, dimensions, and inferred topology.
        /// </summary>
        private static string BuildGeometrySummary(BuildingGeometry geo)
        {
            var sb = new System.Text.StringBuilder();
            sb.AppendLine("Geometry Summary");
            sb.AppendLine("────────────────");

            sb.Append("Units: ").Append(UnitLabelForValue(geo.Units));
            sb.Append(" | Mode: ").AppendLine(geo.GeometryIsCenterline ? "Centerline" : "Reference (columns offset)");

            int nV = geo.Vertices?.Count ?? 0;
            int nBeam = geo.BeamEdges?.Count ?? 0;
            int nCol = geo.ColumnEdges?.Count ?? 0;
            int nStrut = geo.StrutEdges?.Count ?? 0;
            int nSup = geo.Supports?.Count ?? 0;

            sb.AppendLine();
            sb.Append("Structure: ").Append(nV).Append(" vertices");
            sb.Append(", ").Append(nBeam).Append(" beams");
            sb.Append(", ").Append(nCol).Append(" columns");
            sb.Append(", ").Append(nStrut).Append(" struts");
            sb.Append(", ").Append(nSup).AppendLine(" supports");

            if (nV > 0 && geo.Vertices != null)
            {
                double minX = double.MaxValue, maxX = double.MinValue;
                double minY = double.MaxValue, maxY = double.MinValue;
                double minZ = double.MaxValue, maxZ = double.MinValue;
                foreach (var v in geo.Vertices)
                {
                    if (v == null || v.Length < 3) continue;
                    minX = Math.Min(minX, v[0]); maxX = Math.Max(maxX, v[0]);
                    minY = Math.Min(minY, v[1]); maxY = Math.Max(maxY, v[1]);
                    minZ = Math.Min(minZ, v[2]); maxZ = Math.Max(maxZ, v[2]);
                }
                sb.Append("Bounds: X [").Append(minX.ToString("F2")).Append(", ").Append(maxX.ToString("F2")).Append("]");
                sb.Append(" Y [").Append(minY.ToString("F2")).Append(", ").Append(maxY.ToString("F2")).Append("]");
                sb.Append(" Z [").Append(minZ.ToString("F2")).Append(", ").Append(maxZ.ToString("F2")).AppendLine("]");
            }

            if (nV > 0 && geo.Vertices != null)
            {
                var zVals = geo.Vertices
                    .Where(v => v != null && v.Length >= 3)
                    .Select(v => v[2])
                    .Distinct()
                    .OrderBy(z => z)
                    .ToList();
                if (zVals.Count > 0 && zVals.Count <= 20)
                {
                    sb.Append("Inferred Z levels: ");
                    sb.AppendLine(string.Join(", ", zVals.Select(z => z.ToString("F2"))));
                }
                else if (zVals.Count > 20)
                {
                    sb.Append("Inferred Z levels: ").Append(zVals.Count).Append(" distinct (first 5: ");
                    sb.Append(string.Join(", ", zVals.Take(5).Select(z => z.ToString("F2"))));
                    sb.AppendLine(" ...)");
                }
            }

            if (nBeam > 0 || nCol > 0 || nStrut > 0)
            {
                var lengths = new List<double>();
                foreach (var e in geo.BeamEdges ?? Enumerable.Empty<int[]>())
                {
                    if (e != null && e.Length >= 2)
                        lengths.Add(EdgeLength(geo, e[0], e[1]));
                }
                foreach (var e in geo.ColumnEdges ?? Enumerable.Empty<int[]>())
                {
                    if (e != null && e.Length >= 2)
                        lengths.Add(EdgeLength(geo, e[0], e[1]));
                }
                foreach (var e in geo.StrutEdges ?? Enumerable.Empty<int[]>())
                {
                    if (e != null && e.Length >= 2)
                        lengths.Add(EdgeLength(geo, e[0], e[1]));
                }
                if (lengths.Count > 0)
                {
                    double minL = lengths.Min(), maxL = lengths.Max(), avgL = lengths.Average();
                    sb.Append("Edge lengths: min ").Append(minL.ToString("F3"));
                    sb.Append(", max ").Append(maxL.ToString("F3"));
                    sb.Append(", avg ").Append(avgL.ToString("F3"));
                    sb.Append(" (").Append(geo.Units).AppendLine(")");
                }
            }

            if (geo.Faces != null && geo.Faces.Count > 0)
            {
                sb.Append("Faces: ");
                foreach (var kv in geo.Faces)
                {
                    int n = kv.Value?.Count ?? 0;
                    sb.Append(kv.Key).Append("=").Append(n).Append(" ");
                }
                sb.AppendLine();
            }

            if (nSup > 0 && geo.Supports != null)
            {
                var supportedSet = new HashSet<int>(geo.Supports);
                int beamEnds = 0, colEnds = 0, strutEnds = 0;
                foreach (var e in geo.BeamEdges ?? Enumerable.Empty<int[]>())
                {
                    if (e != null && e.Length >= 2 && (supportedSet.Contains(e[0]) || supportedSet.Contains(e[1])))
                        beamEnds++;
                }
                foreach (var e in geo.ColumnEdges ?? Enumerable.Empty<int[]>())
                {
                    if (e != null && e.Length >= 2 && (supportedSet.Contains(e[0]) || supportedSet.Contains(e[1])))
                        colEnds++;
                }
                foreach (var e in geo.StrutEdges ?? Enumerable.Empty<int[]>())
                {
                    if (e != null && e.Length >= 2 && (supportedSet.Contains(e[0]) || supportedSet.Contains(e[1])))
                        strutEnds++;
                }
                sb.Append("Supports at member ends: beams ").Append(beamEnds);
                sb.Append(", columns ").Append(colEnds);
                sb.Append(", struts ").Append(strutEnds).AppendLine();
            }

            return sb.ToString().TrimEnd();
        }

        private static double EdgeLength(BuildingGeometry geo, int v1, int v2)
        {
            if (geo?.Vertices == null || v1 < 1 || v2 < 1 ||
                v1 > geo.Vertices.Count || v2 > geo.Vertices.Count)
                return 0;
            var a = geo.Vertices[v1 - 1];
            var b = geo.Vertices[v2 - 1];
            if (a == null || b == null || a.Length < 3 || b.Length < 3)
                return 0;
            double dx = a[0] - b[0], dy = a[1] - b[1], dz = a[2] - b[2];
            return Math.Sqrt(dx * dx + dy * dy + dz * dz);
        }

        private static (long, long, long) QuantizePoint(Point3d pt)
        {
            return ((long)Math.Round(pt.X * 1e6),
                    (long)Math.Round(pt.Y * 1e6),
                    (long)Math.Round(pt.Z * 1e6));
        }

        /// <summary>
        /// For each line, find any intermediate vertices that lie on the segment
        /// (within tolerance) and split the edge accordingly. Uses a spatial hash
        /// grid so only nearby vertices are tested per line (O(L*k) instead of O(L*V)).
        /// </summary>
        private static void ShatterAndAdd(
            List<Line> lines,
            List<int[]> edgeList,
            BuildingGeometry geo,
            Dictionary<(long, long, long), int> vertexMap,
            double tol)
        {
            if (geo.Vertices.Count == 0 || lines.Count == 0) return;

            // Build spatial hash grid: cell size based on average edge length
            double totalLen = 0;
            foreach (var l in lines) totalLen += l.Length;
            double cellSize = Math.Max(tol * 10, totalLen / Math.Max(lines.Count, 1));

            var grid = new Dictionary<(long, long, long), List<int>>();
            for (int i = 0; i < geo.Vertices.Count; i++)
            {
                var v = geo.Vertices[i];
                var cell = ((long)Math.Floor(v[0] / cellSize),
                            (long)Math.Floor(v[1] / cellSize),
                            (long)Math.Floor(v[2] / cellSize));
                if (!grid.TryGetValue(cell, out var bucket))
                {
                    bucket = new List<int>();
                    grid[cell] = bucket;
                }
                bucket.Add(i);
            }

            foreach (var line in lines)
            {
                var key1 = QuantizePoint(line.From);
                var key2 = QuantizePoint(line.To);
                int v1 = vertexMap[key1];
                int v2 = vertexMap[key2];

                double segLen = line.From.DistanceTo(line.To);
                if (segLen < tol) continue;

                Vector3d dir = line.To - line.From;
                double dirLenSq = dir.X * dir.X + dir.Y * dir.Y + dir.Z * dir.Z;

                // Determine which grid cells the line's bounding box overlaps
                double minX = Math.Min(line.From.X, line.To.X) - tol;
                double maxX = Math.Max(line.From.X, line.To.X) + tol;
                double minY = Math.Min(line.From.Y, line.To.Y) - tol;
                double maxY = Math.Max(line.From.Y, line.To.Y) + tol;
                double minZ = Math.Min(line.From.Z, line.To.Z) - tol;
                double maxZ = Math.Max(line.From.Z, line.To.Z) + tol;
                long cx0 = (long)Math.Floor(minX / cellSize);
                long cx1 = (long)Math.Floor(maxX / cellSize);
                long cy0 = (long)Math.Floor(minY / cellSize);
                long cy1 = (long)Math.Floor(maxY / cellSize);
                long cz0 = (long)Math.Floor(minZ / cellSize);
                long cz1 = (long)Math.Floor(maxZ / cellSize);

                var intermediates = new List<(int idx, double t)>();
                for (long cx = cx0; cx <= cx1; cx++)
                for (long cy = cy0; cy <= cy1; cy++)
                for (long cz = cz0; cz <= cz1; cz++)
                {
                    if (!grid.TryGetValue((cx, cy, cz), out var bucket)) continue;
                    foreach (int i in bucket)
                    {
                        int vi = i + 1; // 1-based
                        if (vi == v1 || vi == v2) continue;

                        var vx = geo.Vertices[i];
                        var pt = new Point3d(vx[0], vx[1], vx[2]);
                        Vector3d toP = pt - line.From;
                        double t = (toP.X * dir.X + toP.Y * dir.Y + toP.Z * dir.Z) / dirLenSq;
                        if (t <= tol || t >= 1.0 - tol) continue;

                        Point3d closest = line.From + t * dir;
                        if (pt.DistanceTo(closest) > tol) continue;

                        intermediates.Add((vi, t));
                    }
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
