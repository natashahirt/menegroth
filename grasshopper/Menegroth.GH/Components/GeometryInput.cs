using System;
using System.Collections.Generic;
using System.Linq;
using System.Windows.Forms;
using Grasshopper.Kernel;
using Rhino.Geometry;
using Menegroth.GH.Config;
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
                   "Menegroth", MenegrothSubcategories.Inputs)
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
                "Planar surfaces or closed curves (defaults to floor category)",
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

                    AddFacePolygon(geo, "floor", snapped);
                }
            }

            var summary = BuildGeometrySummary(geo);
            MenegrothConfig.UpdateBuildingGeometry(geo, summary);

            DA.SetData(0, new BuildingGeometryGoo(geo));
            DA.SetData(1, summary);
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

            // ── Bounding box ────────────────────────────────────────────
            double minX = double.MaxValue, maxX = double.MinValue;
            double minY = double.MaxValue, maxY = double.MinValue;
            double minZ = double.MaxValue, maxZ = double.MinValue;
            if (nV > 0 && geo.Vertices != null)
            {
                foreach (var v in geo.Vertices)
                {
                    if (v == null || v.Length < 3) continue;
                    minX = Math.Min(minX, v[0]); maxX = Math.Max(maxX, v[0]);
                    minY = Math.Min(minY, v[1]); maxY = Math.Max(maxY, v[1]);
                    minZ = Math.Min(minZ, v[2]); maxZ = Math.Max(maxZ, v[2]);
                }
                sb.Append("Bounding box: X [").Append(minX.ToString("F2")).Append(", ").Append(maxX.ToString("F2")).Append("]");
                sb.Append(" Y [").Append(minY.ToString("F2")).Append(", ").Append(maxY.ToString("F2")).Append("]");
                sb.Append(" Z [").Append(minZ.ToString("F2")).Append(", ").Append(maxZ.ToString("F2")).AppendLine("]");
                sb.Append("Bounding box extents: ").Append((maxX - minX).ToString("F2"))
                  .Append(" x ").Append((maxY - minY).ToString("F2"))
                  .Append(" ").Append(geo.Units)
                  .AppendLine(" (NOTE: actual plan may be smaller if geometry is non-rectangular)");
            }

            // ── Z levels and story heights ──────────────────────────────
            var zVals = new List<double>();
            if (nV > 0 && geo.Vertices != null)
            {
                zVals = geo.Vertices
                    .Where(v => v != null && v.Length >= 3)
                    .Select(v => Math.Round(v[2], 6))
                    .Distinct()
                    .OrderBy(z => z)
                    .ToList();
                if (zVals.Count > 0 && zVals.Count <= 20)
                {
                    sb.Append("Z levels (").Append(zVals.Count).Append("): ");
                    sb.AppendLine(string.Join(", ", zVals.Select(z => z.ToString("F2"))));
                }
                else if (zVals.Count > 20)
                {
                    sb.Append("Z levels: ").Append(zVals.Count).Append(" distinct (first 5: ");
                    sb.Append(string.Join(", ", zVals.Take(5).Select(z => z.ToString("F2"))));
                    sb.AppendLine(" ...)");
                }

                if (zVals.Count >= 2)
                {
                    var storyHeights = new List<double>();
                    for (int i = 1; i < zVals.Count; i++)
                        storyHeights.Add(zVals[i] - zVals[i - 1]);

                    bool uniformHeight = storyHeights.Distinct().Count() == 1;
                    if (uniformHeight)
                    {
                        sb.Append("Story heights: uniform ").Append(storyHeights[0].ToString("F2"))
                          .Append(" (").Append(zVals.Count - 1).Append(" stories)").AppendLine();
                    }
                    else
                    {
                        sb.Append("Story heights: ").AppendLine(string.Join(", ", storyHeights.Select(h => h.ToString("F2"))));
                        sb.Append("  min ").Append(storyHeights.Min().ToString("F2"));
                        sb.Append(", max ").Append(storyHeights.Max().ToString("F2"));
                        sb.Append(", typical ").Append(storyHeights.GroupBy(h => Math.Round(h, 2)).OrderByDescending(g => g.Count()).First().Key.ToString("F2"));
                        sb.Append(" (").Append(zVals.Count - 1).Append(" stories, VARYING heights)").AppendLine();
                    }
                }
            }

            // ── Per-level plan analysis (handles irregular/setback plans) ─
            if (nV > 0 && geo.Vertices != null && zVals.Count >= 2)
            {
                var vertsByLevel = zVals.Select(z =>
                    geo.Vertices.Where(v => v != null && v.Length >= 3 && Math.Abs(v[2] - z) < 0.01).ToList()
                ).ToList();

                var countsByLevel = vertsByLevel.Select(vl => vl.Count).ToList();
                bool sameVertCount = countsByLevel.Distinct().Count() == 1;

                // Check plan extents per level to detect setbacks even with same vertex count
                var levelExtents = vertsByLevel.Select(vl =>
                {
                    if (vl.Count == 0) return (0.0, 0.0, 0.0, 0.0, 0.0, 0.0);
                    double lMinX = vl.Min(v => v[0]), lMaxX = vl.Max(v => v[0]);
                    double lMinY = vl.Min(v => v[1]), lMaxY = vl.Max(v => v[1]);
                    return (lMinX, lMaxX, lMinY, lMaxY, lMaxX - lMinX, lMaxY - lMinY);
                }).ToList();

                bool samePlanExtents = levelExtents.Select(e => (Math.Round(e.Item5, 2), Math.Round(e.Item6, 2))).Distinct().Count() == 1;
                bool samePlanOrigin = levelExtents.Select(e => (Math.Round(e.Item1, 2), Math.Round(e.Item3, 2))).Distinct().Count() == 1;

                bool verticallyRegular = sameVertCount && samePlanExtents && samePlanOrigin;

                if (verticallyRegular)
                {
                    sb.Append("Vertical regularity: REGULAR (").Append(countsByLevel[0]).Append(" vertices per level, ")
                      .Append(levelExtents[0].Item5.ToString("F2")).Append(" x ").Append(levelExtents[0].Item6.ToString("F2"))
                      .Append(" plan at all levels)").AppendLine();
                }
                else
                {
                    sb.AppendLine("Vertical regularity: IRREGULAR");
                    var irregularityReasons = new List<string>();
                    if (!sameVertCount) irregularityReasons.Add("varying vertex count per level");
                    if (!samePlanExtents) irregularityReasons.Add("varying plan dimensions (setbacks or step-backs)");
                    if (sameVertCount && samePlanExtents && !samePlanOrigin) irregularityReasons.Add("plan offset shifts between levels");
                    sb.Append("  Irregularity: ").AppendLine(string.Join("; ", irregularityReasons));

                    for (int i = 0; i < vertsByLevel.Count; i++)
                    {
                        var vl = vertsByLevel[i];
                        if (vl.Count == 0) continue;
                        var ext = levelExtents[i];
                        sb.Append("  Level z=").Append(zVals[i].ToString("F2"))
                          .Append(": ").Append(vl.Count).Append(" vertices, plan ")
                          .Append(ext.Item5.ToString("F2")).Append(" x ").Append(ext.Item6.ToString("F2"));
                        if (ext.Item1 != minX || ext.Item3 != minY)
                            sb.Append(" offset=(").Append((ext.Item1 - minX).ToString("F2")).Append(", ").Append((ext.Item3 - minY).ToString("F2")).Append(")");
                        sb.AppendLine();
                    }
                }

                // Per-level member counts (detect levels where beams/columns drop off)
                var beamCountByLevel = new Dictionary<double, int>();
                var colCountByLevel = new Dictionary<double, int>();
                foreach (var e in geo.BeamEdges ?? Enumerable.Empty<int[]>())
                {
                    if (e == null || e.Length < 2) continue;
                    double z = GetEdgeMidZ(geo, e[0], e[1]);
                    double closest = zVals.OrderBy(zl => Math.Abs(zl - z)).First();
                    if (!beamCountByLevel.TryGetValue(closest, out int beamCount))
                        beamCount = 0;
                    beamCountByLevel[closest] = beamCount + 1;
                }
                foreach (var e in geo.ColumnEdges ?? Enumerable.Empty<int[]>())
                {
                    if (e == null || e.Length < 2) continue;
                    double z = GetEdgeMidZ(geo, e[0], e[1]);
                    double closest = zVals.OrderBy(zl => Math.Abs(zl - z)).First();
                    if (!colCountByLevel.TryGetValue(closest, out int colCount))
                        colCount = 0;
                    colCountByLevel[closest] = colCount + 1;
                }

                bool uniformBeams = beamCountByLevel.Values.Distinct().Count() <= 1;
                bool uniformCols = colCountByLevel.Values.Distinct().Count() <= 1;
                if (!uniformBeams || !uniformCols)
                {
                    sb.AppendLine("  Member counts vary by level:");
                    foreach (var z in zVals)
                    {
                        beamCountByLevel.TryGetValue(z, out int bCount);
                        colCountByLevel.TryGetValue(z, out int cCount);
                        if (bCount > 0 || cCount > 0)
                            sb.Append("    z=").Append(z.ToString("F2")).Append(": ").Append(bCount).Append(" beams, ").Append(cCount).AppendLine(" columns");
                    }
                }
            }

            // ── Beam span analysis ──────────────────────────────────────
            if (nBeam > 0 && geo.BeamEdges != null)
            {
                var beamLengths = new List<double>();
                foreach (var e in geo.BeamEdges)
                {
                    if (e != null && e.Length >= 2)
                    {
                        double len = EdgeLength(geo, e[0], e[1]);
                        if (len > 0) beamLengths.Add(len);
                    }
                }
                if (beamLengths.Count > 0)
                {
                    beamLengths.Sort();
                    sb.Append("Beam spans: min ").Append(beamLengths.First().ToString("F2"));
                    sb.Append(", max ").Append(beamLengths.Last().ToString("F2"));
                    sb.Append(", median ").Append(beamLengths[beamLengths.Count / 2].ToString("F2"));
                    sb.Append(", avg ").Append(beamLengths.Average().ToString("F2"));
                    sb.Append(" (").Append(geo.Units).AppendLine(")");

                    int nDistinct = beamLengths.Select(l => Math.Round(l, 1)).Distinct().Count();
                    if (nDistinct == 1)
                    {
                        sb.AppendLine("  Span uniformity: all beams same length (regular grid)");
                    }
                    else
                    {
                        double spanRange = beamLengths.Last() - beamLengths.First();
                        double cv = StdDev(beamLengths) / beamLengths.Average();
                        sb.Append("  Span uniformity: ").Append(nDistinct).Append(" distinct lengths, range ")
                          .Append(spanRange.ToString("F2")).Append(", CV=").Append(cv.ToString("F2"));
                        if (cv > 0.3) sb.Append(" [high diversity]");
                        else if (cv > 0.15) sb.Append(" [moderate diversity]");
                        sb.AppendLine();
                        sb.AppendLine("  NOTE: CV is over ALL beam edge lengths (every direction). Different bay sizes in X vs Y naturally increase CV — that is not, by itself, evidence of a non-rectangular plan or \"irregular\" framing. Use the grid-pattern / column-line section below and face shapes for plan regularity.");

                        // Show span histogram (buckets)
                        if (beamLengths.Count >= 4)
                        {
                            var groups = beamLengths.GroupBy(l => Math.Round(l, 1)).OrderByDescending(g => g.Count()).Take(5);
                            sb.Append("  Most common spans: ");
                            sb.AppendLine(string.Join(", ", groups.Select(g => $"{g.Key:F1} ({g.Count()}x)")));
                        }
                    }
                }
            }

            // ── Column heights ──────────────────────────────────────────
            if (nCol > 0 && geo.ColumnEdges != null)
            {
                var colLengths = new List<double>();
                foreach (var e in geo.ColumnEdges)
                {
                    if (e != null && e.Length >= 2)
                    {
                        double len = EdgeLength(geo, e[0], e[1]);
                        if (len > 0) colLengths.Add(len);
                    }
                }
                if (colLengths.Count > 0)
                {
                    sb.Append("Column heights: min ").Append(colLengths.Min().ToString("F2"));
                    sb.Append(", max ").Append(colLengths.Max().ToString("F2"));
                    sb.Append(", avg ").Append(colLengths.Average().ToString("F2"));
                    sb.Append(" (").Append(geo.Units).Append(")");
                    if (colLengths.Min() < colLengths.Max() * 0.8)
                        sb.Append(" [VARYING — check for mixed story heights or mezzanines]");
                    sb.AppendLine();
                }
            }

            // ── Column position analysis ────────────────────────────────
            // Reports nearest-neighbor spacings instead of assuming an orthogonal grid.
            if (nCol > 0 && geo.ColumnEdges != null && geo.Vertices != null && zVals.Count >= 1)
            {
                var baseLevel = zVals[0];
                var baseColPositions = new List<(double x, double y)>();
                foreach (var e in geo.ColumnEdges ?? Enumerable.Empty<int[]>())
                {
                    if (e == null || e.Length < 2) continue;
                    foreach (int vi in new[] { e[0], e[1] })
                    {
                        if (vi < 1 || vi > nV) continue;
                        var v = geo.Vertices[vi - 1];
                        if (v == null || v.Length < 3) continue;
                        if (Math.Abs(v[2] - baseLevel) < 0.01)
                            baseColPositions.Add((v[0], v[1]));
                    }
                }
                var uniquePositions = baseColPositions.Distinct().ToList();

                if (uniquePositions.Count >= 2)
                {
                    sb.Append("Base level column positions: ").Append(uniquePositions.Count).AppendLine(" unique");

                    // Nearest-neighbor distances (works for any layout)
                    var nnDists = new List<double>();
                    for (int i = 0; i < uniquePositions.Count; i++)
                    {
                        double nearest = double.MaxValue;
                        for (int j = 0; j < uniquePositions.Count; j++)
                        {
                            if (i == j) continue;
                            double dx = uniquePositions[i].x - uniquePositions[j].x;
                            double dy = uniquePositions[i].y - uniquePositions[j].y;
                            double d = Math.Sqrt(dx * dx + dy * dy);
                            if (d < nearest) nearest = d;
                        }
                        if (nearest < double.MaxValue) nnDists.Add(nearest);
                    }
                    if (nnDists.Count > 0)
                    {
                        sb.Append("  Column-to-column nearest spacing: min ").Append(nnDists.Min().ToString("F2"));
                        sb.Append(", max ").Append(nnDists.Max().ToString("F2"));
                        sb.Append(", avg ").Append(nnDists.Average().ToString("F2"));
                        sb.Append(" ").AppendLine(geo.Units);
                    }

                    // Check if columns form a recognizable orthogonal grid
                    var xCoords = uniquePositions.Select(p => Math.Round(p.x, 2)).Distinct().OrderBy(x => x).ToList();
                    var yCoords = uniquePositions.Select(p => Math.Round(p.y, 2)).Distinct().OrderBy(y => y).ToList();
                    int gridCount = xCoords.Count * yCoords.Count;
                    double gridFill = (double)uniquePositions.Count / gridCount;

                    if (gridFill > 0.85 && xCoords.Count >= 2 && yCoords.Count >= 2)
                    {
                        sb.AppendLine("  Grid pattern: approximately rectangular");
                        var xSpacings = new List<double>();
                        for (int i = 1; i < xCoords.Count; i++) xSpacings.Add(xCoords[i] - xCoords[i - 1]);
                        var ySpacings = new List<double>();
                        for (int i = 1; i < yCoords.Count; i++) ySpacings.Add(yCoords[i] - yCoords[i - 1]);

                        bool uniformX = xSpacings.Select(s => Math.Round(s, 1)).Distinct().Count() == 1;
                        bool uniformY = ySpacings.Select(s => Math.Round(s, 1)).Distinct().Count() == 1;

                        sb.Append("  X gridlines (").Append(xCoords.Count).Append("): spacings ");
                        sb.Append(uniformX ? $"uniform {xSpacings[0]:F2}" : string.Join(", ", xSpacings.Select(s => s.ToString("F2"))));
                        sb.AppendLine();

                        sb.Append("  Y gridlines (").Append(yCoords.Count).Append("): spacings ");
                        sb.Append(uniformY ? $"uniform {ySpacings[0]:F2}" : string.Join(", ", ySpacings.Select(s => s.ToString("F2"))));
                        sb.AppendLine();
                    }
                    else if (gridFill > 0.5)
                    {
                        sb.Append("  Grid pattern: partially rectangular (").Append((gridFill * 100).ToString("F0")).AppendLine("% fill of bounding grid)");
                        sb.AppendLine("  NOTE: some grid positions are empty — L-shape, T-shape, or other non-rectangular plan");
                    }
                    else
                    {
                        sb.AppendLine("  Grid pattern: non-rectangular or free-form column layout");
                    }
                }
            }

            // ── Face / slab panel counts ────────────────────────────────
            if (geo.Faces != null && geo.Faces.Count > 0)
            {
                sb.Append("Faces: ");
                foreach (var kv in geo.Faces)
                {
                    int n = kv.Value?.Count ?? 0;
                    sb.Append(kv.Key).Append("=").Append(n).Append(" ");
                }
                sb.AppendLine();

                // Analyze face shapes for irregularity
                if (geo.Faces.TryGetValue("floor", out var floorFaces) && floorFaces != null)
                {
                    int quadCount = 0, triCount = 0, otherCount = 0;
                    foreach (var face in floorFaces)
                    {
                        if (face == null) continue;
                        int nPts = face.Count;
                        if (nPts == 4) quadCount++;
                        else if (nPts == 3) triCount++;
                        else otherCount++;
                    }
                    sb.Append("  Floor panels: ").Append(quadCount).Append(" quads");
                    if (triCount > 0) sb.Append(", ").Append(triCount).Append(" triangles");
                    if (otherCount > 0) sb.Append(", ").Append(otherCount).Append(" other polygons");
                    if (triCount > 0 || otherCount > 0)
                        sb.Append(" [non-rectangular panels present — irregular plan]");
                    sb.AppendLine();
                }
            }

            // ── Support connectivity ────────────────────────────────────
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

        private static double GetEdgeMidZ(BuildingGeometry geo, int v1, int v2)
        {
            if (geo?.Vertices == null || v1 < 1 || v2 < 1 ||
                v1 > geo.Vertices.Count || v2 > geo.Vertices.Count)
                return 0;
            var a = geo.Vertices[v1 - 1];
            var b = geo.Vertices[v2 - 1];
            if (a == null || b == null || a.Length < 3 || b.Length < 3) return 0;
            return (a[2] + b[2]) / 2.0;
        }

        private static double StdDev(List<double> values)
        {
            if (values.Count <= 1) return 0;
            double avg = values.Average();
            double sumSq = values.Sum(v => (v - avg) * (v - avg));
            return Math.Sqrt(sumSq / (values.Count - 1));
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

        private static void AddFacePolygon(BuildingGeometry geo, string category, List<double[]> polygon)
        {
            if (geo == null || polygon == null || polygon.Count < 3) return;
            if (string.IsNullOrWhiteSpace(category)) category = "floor";
            if (!geo.Faces.ContainsKey(category))
                geo.Faces[category] = new List<List<double[]>>();
            geo.Faces[category].Add(polygon);
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
