using System;
using System.Collections.Generic;
using System.Linq;
using System.Windows.Forms;
using Grasshopper.Kernel;
using Grasshopper.Kernel.Types;
using Newtonsoft.Json.Linq;
using Rhino.Geometry;

namespace StructuralSizer.GH.Components
{
    /// <summary>
    /// Visualizes structural design geometry with deflections.
    /// Supports two modes: "sized" (designed sections) and "deflected" (analysis model with displacements).
    /// </summary>
    public class SizerVisualization : GH_Component
    {
        // Menu state
        private string _mode = "deflected";
        private string _displacementMode = "global";
        
        public SizerVisualization()
            : base("Sizer Visualization",
                   "SizerViz",
                   "Visualize structural design with geometry and deflections",
                   "Menegroth", "Visualization")
        { }

        public override Guid ComponentGuid =>
            new Guid("A1B2C3D4-AAAA-BBBB-CCCC-DDDDEEEE0003");

        protected override void RegisterInputParams(GH_InputParamManager pManager)
        {
            pManager.AddTextParameter("JSON", "J",
                "Raw JSON response from SizerRun", GH_ParamAccess.item);
            // Mode and Displacement Mode are now menu-only (no text inputs)
            pManager.AddNumberParameter("Scale Factor", "S",
                "Deflection scale factor (only for deflected mode, 0 = auto)", GH_ParamAccess.item, 0.0);
            pManager.AddBooleanParameter("Show Original", "O",
                "Show original geometry as reference (only for deflected mode)", GH_ParamAccess.item, true);
        }

        protected override void RegisterOutputParams(GH_OutputParamManager pManager)
        {
            pManager.AddCurveParameter("Frame Curves", "FC",
                "Frame element curves (cubic interpolated if deflected)", GH_ParamAccess.list);
            pManager.AddGenericParameter("Frame Geometry", "FG",
                "Frame element 3D section geometry (Brep)", GH_ParamAccess.list);
            pManager.AddGenericParameter("Slab Geometry", "SG",
                "Slab geometry (Brep boxes for 'sized', Mesh for 'deflected')", GH_ParamAccess.list);
            pManager.AddCurveParameter("Original Curves", "OC",
                "Original frame curves (only if Show Original=true)", GH_ParamAccess.list);
            pManager.AddGenericParameter("Original Slabs", "OS",
                "Original slab geometry (only if Show Original=true)", GH_ParamAccess.list);
        }

        protected override void SolveInstance(IGH_DataAccess DA)
        {
            string json = "";
            if (!DA.GetData(0, ref json) || string.IsNullOrWhiteSpace(json)) return;

            // Use menu values instead of reading from inputs
            string mode = _mode;
            string dispMode = _displacementMode;

            double scaleFactor = 0.0;
            DA.GetData(1, ref scaleFactor);

            bool showOriginal = true;
            DA.GetData(2, ref showOriginal);

            JObject root;
            try
            {
                root = JObject.Parse(json);
            }
            catch (Exception ex)
            {
                AddRuntimeMessage(GH_RuntimeMessageLevel.Error,
                    $"Failed to parse JSON: {ex.Message}");
                return;
            }

            string status = root["status"]?.ToString() ?? "unknown";
            if (status == "error")
            {
                string msg = root["message"]?.ToString() ?? "Unknown error";
                AddRuntimeMessage(GH_RuntimeMessageLevel.Error, msg);
                return;
            }

            var viz = root["visualization"];
            if (viz == null)
            {
                AddRuntimeMessage(GH_RuntimeMessageLevel.Warning,
                    "No visualization data available. Analysis model may not be built.");
                return;
            }

            // Extract nodes for displacement mapping
            var nodes = new Dictionary<int, (Point3d pos, Vector3d disp)>();
            var nodesArray = viz["nodes"] as JArray ?? new JArray();
            foreach (var n in nodesArray)
            {
                int nodeId = n["node_id"]?.ToObject<int>() ?? 0;
                var posArray = n["position_ft"]?.ToObject<double[]>() ?? new double[3];
                var dispArray = n["displacement_ft"]?.ToObject<double[]>() ?? new double[3];
                nodes[nodeId] = (
                    new Point3d(posArray[0], posArray[1], posArray[2]),
                    new Vector3d(dispArray[0], dispArray[1], dispArray[2])
                );
            }

            // Extract frame elements with cubic interpolation
            var frameCurves = new List<Curve>();
            var frameGeometry = new List<IGH_GeometricGoo>();
            var originalCurves = new List<Curve>();
            var frameElementsArray = viz["frame_elements"] as JArray ?? new JArray();
            
            double finalScale = scaleFactor > 0 ? scaleFactor : (viz["suggested_scale_factor"]?.ToObject<double>() ?? 1.0);

            foreach (var elem in frameElementsArray)
            {
                var originalPoints = elem["original_points"]?.ToObject<double[][]>() ?? new double[0][];
                var displacementVectors = elem["displacement_vectors"]?.ToObject<double[][]>() ?? new double[0][];
                
                if (originalPoints.Length == 0 || displacementVectors.Length == 0)
                {
                    // Fallback to node-to-node if no interpolation data
                    int nodeStart = elem["node_start"]?.ToObject<int>() ?? 0;
                    int nodeEnd = elem["node_end"]?.ToObject<int>() ?? 0;
                    if (nodes.ContainsKey(nodeStart) && nodes.ContainsKey(nodeEnd))
                    {
                        var p1 = nodes[nodeStart].pos;
                        var p2 = nodes[nodeEnd].pos;
                        
                        // Store original positions
                        if (showOriginal && mode == "deflected")
                        {
                            originalCurves.Add(new Line(p1, p2).ToNurbsCurve());
                        }
                        
                        // Apply deflections if in deflected mode
                        if (mode == "deflected")
                        {
                            p1 += nodes[nodeStart].disp * finalScale;
                            p2 += nodes[nodeEnd].disp * finalScale;
                        }
                        
                        var lineCurve = new Line(p1, p2).ToNurbsCurve();
                        frameCurves.Add(lineCurve);
                        
                        // Create 3D section geometry if section_polygon is available
                        var sectionPolygon = elem["section_polygon"]?.ToObject<double[][]>() ?? new double[0][];
                        
                        // If section_polygon is empty, create default based on section dimensions
                        if (sectionPolygon.Length < 3)
                        {
                            double depth = elem["section_depth_ft"]?.ToObject<double>() ?? 0.0;
                            double width = elem["section_width_ft"]?.ToObject<double>() ?? 0.0;
                            
                            if (depth > 0 && width > 0)
                            {
                                // Create default rectangular section polygon
                                sectionPolygon = new double[][]
                                {
                                    new double[] { -width / 2, -depth / 2 },
                                    new double[] { width / 2, -depth / 2 },
                                    new double[] { width / 2, depth / 2 },
                                    new double[] { -width / 2, depth / 2 }
                                };
                            }
                        }
                        
                        if (sectionPolygon.Length >= 3)
                        {
                            var brep = CreateSectionGeometry(lineCurve, sectionPolygon);
                            if (brep != null)
                            {
                                frameGeometry.Add(new GH_Brep(brep));
                            }
                        }
                    }
                    continue;
                }

                // Build cubic-interpolated curve
                var curvePoints = new List<Point3d>();
                var originalCurvePoints = new List<Point3d>();

                for (int i = 0; i < originalPoints.Length; i++)
                {
                    var origPt = new Point3d(originalPoints[i][0], originalPoints[i][1], originalPoints[i][2]);
                    originalCurvePoints.Add(origPt);

                    if (mode == "deflected")
                    {
                        var dispVec = new Vector3d(
                            displacementVectors[i][0],
                            displacementVectors[i][1],
                            displacementVectors[i][2]);

                        if (dispMode == "local")
                        {
                            // Local mode: compute chord-relative displacement
                            // This shows the element's own deflection without rigid body motion
                            var uStart = new Vector3d(
                                displacementVectors[0][0],
                                displacementVectors[0][1],
                                displacementVectors[0][2]);
                            var uEnd = new Vector3d(
                                displacementVectors[displacementVectors.Length - 1][0],
                                displacementVectors[displacementVectors.Length - 1][1],
                                displacementVectors[displacementVectors.Length - 1][2]);
                            
                            double t = originalPoints.Length > 1 ? (double)i / (originalPoints.Length - 1) : 0.0;
                            var uChord = uStart + t * (uEnd - uStart);
                            var uLocal = dispVec - uChord;
                            
                            curvePoints.Add(origPt + uLocal * finalScale);
                        }
                        else
                        {
                            // Global mode: full displacement
                            curvePoints.Add(origPt + dispVec * finalScale);
                        }
                    }
                    else
                    {
                        curvePoints.Add(origPt);
                    }
                }

                if (curvePoints.Count > 1)
                {
                    var elementCurve = new PolylineCurve(curvePoints);
                    frameCurves.Add(elementCurve);
                    
                    // Create 3D section geometry if section_polygon is available
                    var sectionPolygon = elem["section_polygon"]?.ToObject<double[][]>() ?? new double[0][];
                    
                    // If section_polygon is empty, create default based on section dimensions
                    if (sectionPolygon.Length < 3)
                    {
                        double depth = elem["section_depth_ft"]?.ToObject<double>() ?? 0.0;
                        double width = elem["section_width_ft"]?.ToObject<double>() ?? 0.0;
                        
                        if (depth > 0 && width > 0)
                        {
                            // Create default rectangular section polygon
                            sectionPolygon = new double[][]
                            {
                                new double[] { -width / 2, -depth / 2 },
                                new double[] { width / 2, -depth / 2 },
                                new double[] { width / 2, depth / 2 },
                                new double[] { -width / 2, depth / 2 }
                            };
                        }
                        else
                        {
                            // If no dimensions, skip geometry creation
                            sectionPolygon = new double[0][];
                        }
                    }
                    
                    if (sectionPolygon.Length >= 3)
                    {
                        var brep = CreateSectionGeometry(elementCurve, sectionPolygon);
                        if (brep != null)
                        {
                            frameGeometry.Add(new GH_Brep(brep));
                        }
                    }
                }

                if (showOriginal && mode == "deflected" && originalCurvePoints.Count > 1)
                {
                    originalCurves.Add(new PolylineCurve(originalCurvePoints));
                }
            }

            // Extract slabs
            var slabGeometry = new List<IGH_GeometricGoo>();
            var originalSlabs = new List<IGH_GeometricGoo>();

            if (mode == "sized")
            {
                var sizedSlabs = viz["sized_slabs"] as JArray ?? new JArray();
                foreach (var slab in sizedSlabs)
                {
                    var boundary = slab["boundary_vertices"]?.ToObject<double[][]>() ?? new double[0][];
                    double thickness = slab["thickness_ft"]?.ToObject<double>() ?? 0.0;
                    double zTop = slab["z_top_ft"]?.ToObject<double>() ?? 0.0;

                    if (boundary.Length < 3) continue;

                    var boundaryPts = boundary.Select(v => new Point3d(v[0], v[1], zTop)).ToList();
                    boundaryPts.Add(boundaryPts[0]);

                    var bottomPts = boundaryPts.Select(p => new Point3d(p.X, p.Y, p.Z - thickness)).ToList();
                    
                    var brep = Brep.CreateFromLoft(
                        new[] { new PolylineCurve(boundaryPts), new PolylineCurve(bottomPts) },
                        Point3d.Unset, Point3d.Unset, LoftType.Normal, false)[0];
                    
                    if (brep != null)
                    {
                        slabGeometry.Add(new GH_Brep(brep));
                    }
                }
            }
            else // deflected mode
            {
                var deflectedMeshes = viz["deflected_slab_meshes"] as JArray ?? new JArray();

                foreach (var mesh in deflectedMeshes)
                {
                    var vertices = mesh["vertices"]?.ToObject<double[][]>() ?? new double[0][];
                    var vertexDisplacements = mesh["vertex_displacements"]?.ToObject<double[][]>() ?? new double[0][];
                    var faces = mesh["faces"]?.ToObject<int[][]>() ?? new int[0][];

                    if (vertices.Length == 0) continue;

                    var rhinoMesh = new Mesh();
                    var originalMesh = new Mesh();

                    // Ensure vertex_displacements array matches vertices array
                    if (vertexDisplacements.Length != vertices.Length)
                    {
                        // If mismatch, create zero displacements for missing vertices
                        var fixedDisplacements = new double[vertices.Length][];
                        for (int i = 0; i < vertices.Length; i++)
                        {
                            if (i < vertexDisplacements.Length)
                            {
                                fixedDisplacements[i] = vertexDisplacements[i];
                            }
                            else
                            {
                                fixedDisplacements[i] = new double[] { 0.0, 0.0, 0.0 };
                            }
                        }
                        vertexDisplacements = fixedDisplacements;
                    }

                    // Add vertices with deflections applied
                    for (int i = 0; i < vertices.Length; i++)
                    {
                        var origPt = new Point3d(vertices[i][0], vertices[i][1], vertices[i][2]);
                        originalMesh.Vertices.Add(origPt);

                        var dispVec = new Vector3d(
                            vertexDisplacements[i][0],
                            vertexDisplacements[i][1],
                            vertexDisplacements[i][2]);

                        // Apply displacement scaled by finalScale
                        var deflectedPt = origPt + dispVec * finalScale;
                        rhinoMesh.Vertices.Add(deflectedPt);
                    }

                    // Add faces (triangles from FEA mesh)
                    foreach (var face in faces)
                    {
                        if (face.Length >= 3)
                        {
                            // Convert from 1-based to 0-based indices
                            int i0 = face[0] - 1;
                            int i1 = face[1] - 1;
                            int i2 = face[2] - 1;
                            
                            // Validate indices
                            if (i0 >= 0 && i0 < rhinoMesh.Vertices.Count &&
                                i1 >= 0 && i1 < rhinoMesh.Vertices.Count &&
                                i2 >= 0 && i2 < rhinoMesh.Vertices.Count)
                            {
                                rhinoMesh.Faces.AddFace(i0, i1, i2);
                                originalMesh.Faces.AddFace(i0, i1, i2);
                            }
                        }
                    }

                    // Rebuild mesh normals for proper rendering
                    if (rhinoMesh.Vertices.Count > 0 && rhinoMesh.Faces.Count > 0)
                    {
                        rhinoMesh.Normals.ComputeNormals();
                        rhinoMesh.Compact(); // Remove unused vertices
                        
                        if (showOriginal && originalMesh.Vertices.Count > 0 && originalMesh.Faces.Count > 0)
                        {
                            originalMesh.Normals.ComputeNormals();
                            originalMesh.Compact();
                            originalSlabs.Add(new GH_Mesh(originalMesh));
                        }
                        
                        slabGeometry.Add(new GH_Mesh(rhinoMesh));
                    }
                }
            }

            // Set outputs
            DA.SetDataList(0, frameCurves);
            DA.SetDataList(1, frameGeometry);
            DA.SetDataList(2, slabGeometry);
            DA.SetDataList(3, originalCurves);
            DA.SetDataList(4, originalSlabs);
        }
        
        // ─── Right-click menu ────────────────────────────────────────────────
        
        protected override void AppendAdditionalComponentMenuItems(ToolStripDropDown menu)
        {
            base.AppendAdditionalComponentMenuItems(menu);
            Menu_AppendSeparator(menu);
            
            // Visualization Mode menu
            var modeMenu = Menu_AppendItem(menu, "Visualization Mode");
            var sizedItem = new ToolStripMenuItem("Sized")
            {
                Checked = _mode == "sized",
                Tag = "sized"
            };
            sizedItem.Click += (s, e) =>
            {
                _mode = (string)((ToolStripMenuItem)s).Tag;
                UpdateMessage();
                ExpireSolution(true);
            };
            modeMenu.DropDownItems.Add(sizedItem);
            
            var deflectedItem = new ToolStripMenuItem("Deflected")
            {
                Checked = _mode == "deflected",
                Tag = "deflected"
            };
            deflectedItem.Click += (s, e) =>
            {
                _mode = (string)((ToolStripMenuItem)s).Tag;
                UpdateMessage();
                ExpireSolution(true);
            };
            modeMenu.DropDownItems.Add(deflectedItem);
            
            Menu_AppendSeparator(menu);
            
            // Displacement Mode menu (only relevant for deflected mode)
            var dispMenu = Menu_AppendItem(menu, "Displacement Mode");
            var globalItem = new ToolStripMenuItem("Global")
            {
                Checked = _displacementMode == "global",
                Tag = "global"
            };
            globalItem.Click += (s, e) =>
            {
                _displacementMode = (string)((ToolStripMenuItem)s).Tag;
                UpdateMessage();
                ExpireSolution(true);
            };
            dispMenu.DropDownItems.Add(globalItem);
            
            var localItem = new ToolStripMenuItem("Local")
            {
                Checked = _displacementMode == "local",
                Tag = "local"
            };
            localItem.Click += (s, e) =>
            {
                _displacementMode = (string)((ToolStripMenuItem)s).Tag;
                UpdateMessage();
                ExpireSolution(true);
            };
            dispMenu.DropDownItems.Add(localItem);
        }
        
        // ─── Persistence ──────────────────────────────────────────────────────
        
        public override bool Write(GH_IO.Serialization.GH_IWriter writer)
        {
            writer.SetString("Mode", _mode);
            writer.SetString("DisplacementMode", _displacementMode);
            return base.Write(writer);
        }

        public override bool Read(GH_IO.Serialization.GH_IReader reader)
        {
            if (reader.ItemExists("Mode"))
                _mode = reader.GetString("Mode");
            if (reader.ItemExists("DisplacementMode"))
                _displacementMode = reader.GetString("DisplacementMode");
            UpdateMessage();
            return base.Read(reader);
        }
        
        public override void AddedToDocument(GH_Document document)
        {
            base.AddedToDocument(document);
            UpdateMessage();
        }
        
        private void UpdateMessage()
        {
            Message = $"Mode: {_mode}, Disp: {_displacementMode}";
        }
        
        /// <summary>
        /// Create 3D Brep geometry from section polygon and element curve.
        /// Section polygon is in local y-z coordinates (centroid at origin).
        /// </summary>
        private Brep CreateSectionGeometry(Curve elementCurve, double[][] sectionPolygon)
        {
            if (sectionPolygon.Length < 3) return null;
            
            try
            {
                // Get start point and tangent at start
                elementCurve.Domain = new Interval(0.0, 1.0);
                var startPt = elementCurve.PointAtStart;
                var startTangent = elementCurve.TangentAtStart;
                startTangent.Unitize();
                
                // Compute local coordinate system
                // x = element direction (along length)
                // y = width direction (from section polygon)
                // z = depth direction (from section polygon)
                
                // Choose an "up" vector that isn't parallel to element direction
                Vector3d up = Math.Abs(startTangent.Z) < 0.9 
                    ? new Vector3d(0, 0, 1) 
                    : new Vector3d(1, 0, 0);
                
                // Local Y = up × elementDir (perpendicular to element, roughly horizontal)
                var localY = Vector3d.CrossProduct(up, startTangent);
                localY.Unitize();
                
                // Local Z = elementDir × localY (perpendicular to both)
                var localZ = Vector3d.CrossProduct(startTangent, localY);
                localZ.Unitize();
                
                // Create section polygon in 3D space at start point
                var sectionPts = new List<Point3d>();
                foreach (var pt2d in sectionPolygon)
                {
                    // pt2d is [y, z] in local coordinates
                    double y = pt2d[0];  // width direction
                    double z = pt2d[1];  // depth direction
                    
                    // Transform to global coordinates
                    var pt3d = startPt + localY * y + localZ * z;
                    sectionPts.Add(pt3d);
                }
                
                // Close the polygon if needed
                if (sectionPts.Count > 0 && sectionPts[0].DistanceTo(sectionPts[sectionPts.Count - 1]) > 1e-6)
                {
                    sectionPts.Add(sectionPts[0]);
                }
                
                // Create closed section curve (use Curve so we can assign NurbsCurve when closing)
                Curve sectionCurve = new PolylineCurve(sectionPts);
                if (!sectionCurve.IsClosed)
                {
                    sectionCurve = sectionCurve.ToNurbsCurve();
                }
                
                // Sweep section along element curve
                var sweep = Brep.CreateFromSweep(elementCurve, sectionCurve, true, 0.01);
                if (sweep != null && sweep.Length > 0)
                {
                    return sweep[0];
                }
            }
            catch
            {
                // Silently fail - return null if geometry creation fails
            }
            
            return null;
        }
    }
}
