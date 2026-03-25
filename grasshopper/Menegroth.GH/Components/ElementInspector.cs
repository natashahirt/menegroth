using System;
using System.Collections.Generic;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;
using System.Windows.Forms;
using Grasshopper.Kernel;
using Rhino;
using Rhino.Display;
using Rhino.UI;
using Rhino.Geometry;
using Rhino.Geometry.Intersect;
using Menegroth.GH.Config;
using Menegroth.GH.Helpers;
using Newtonsoft.Json.Linq;
using System.Drawing;

namespace Menegroth.GH.Components
{
    /// <summary>
    /// Element Inspector: click a structural element in the Rhino viewport to
    /// highlight it cyan and fetch a natural-language narration via the
    /// <c>narrate_element</c> agent tool.
    ///
    /// No wire inputs — the Visualization component is auto-discovered on the
    /// canvas.  Audience and element selection are controlled through right-click
    /// menus.
    /// </summary>
    public class ElementInspector : GH_Component
    {
        // ─── Persisted state ─────────────────────────────────────────────
        private string _audience = "architect";
        private int _selectedElementId = -1;
        private string _selectedElementType = "";
        private string _lastNarration = "";

        // ─── Pick mode ───────────────────────────────────────────────────
        private volatile bool _pickModeActive;
        private InspectorMouseCallback? _mouseCallback;

        // ─── Async narration ─────────────────────────────────────────────
        private enum NarrationState { Idle, Fetching, Done, Error }
        private volatile int _narrationStateInt;
        private NarrationState _narrationState
        {
            get => (NarrationState)_narrationStateInt;
            set => _narrationStateInt = (int)value;
        }
        private string _pendingNarration = "";
        private string _pendingError = "";
        private CancellationTokenSource? _narrationCts;

        // ─── Highlight rendering ─────────────────────────────────────────
        private static readonly Color CyanHighlight = Color.FromArgb(200, 0, 255, 255);
        private static readonly DisplayMaterial CyanMaterial = new DisplayMaterial(CyanHighlight);

        public ElementInspector()
            : base("Element Inspector",
                   "Inspector",
                   "Click a structural element to highlight it and get a narration",
                   "Menegroth", MenegrothSubcategories.Assistant)
        { }

        public override Guid ComponentGuid =>
            new Guid("F8A12D3E-5B67-4C9A-8E01-D2F3A4B5C6D7");

        // ─── Parameters ──────────────────────────────────────────────────

        protected override void RegisterInputParams(GH_InputParamManager pManager)
        {
        }

        protected override void RegisterOutputParams(GH_OutputParamManager pManager)
        {
            pManager.AddTextParameter("ElementType", "Type",
                "Selected element type (column, beam, slab, foundation)", GH_ParamAccess.item);
            pManager.AddIntegerParameter("ElementId", "Id",
                "Selected element ID from the structural model", GH_ParamAccess.item);
            pManager.AddTextParameter("Narration", "Narration",
                "Natural-language narration of the selected element", GH_ParamAccess.item);
        }

        // ─── Right-click menu ────────────────────────────────────────────

        protected override void AppendAdditionalComponentMenuItems(ToolStripDropDown menu)
        {
            base.AppendAdditionalComponentMenuItems(menu);
            Menu_AppendSeparator(menu);

            var selectItem = Menu_AppendItem(menu, "Select Element", OnSelectElement);
            selectItem.ToolTipText = "Click an element in the Rhino viewport to inspect it";

            var clearItem = Menu_AppendItem(menu, "Clear Selection", OnClearSelection);
            clearItem.ToolTipText = "Clear the current element selection";
            clearItem.Enabled = _selectedElementId >= 0;

            Menu_AppendSeparator(menu);

            var audienceMenu = Menu_AppendItem(menu, "Audience");
            foreach (var (label, value) in new[]
            {
                ("Architect", "architect"),
                ("Engineer", "engineer"),
            })
            {
                var item = new ToolStripMenuItem(label)
                {
                    Checked = _audience == value,
                    Tag = value
                };
                item.Click += (s, _) =>
                {
                    _audience = (string)((ToolStripMenuItem)s!).Tag!;
                    if (_selectedElementId >= 0)
                        FetchNarrationAsync();
                    ExpireSolution(true);
                };
                audienceMenu.DropDownItems.Add(item);
            }

            var customItem = new ToolStripMenuItem("Custom...");
            customItem.Click += (s, _) =>
            {
                if (Rhino.UI.Dialogs.ShowEditBox(
                    "Custom Audience",
                    "Describe who you are and what you're interested in.\nExample: \"sustainability consultant focused on embodied carbon\"",
                    _audience,
                    false,
                    out string result))
                {
                    if (!string.IsNullOrWhiteSpace(result))
                    {
                        _audience = result.Trim();
                        if (_selectedElementId >= 0)
                            FetchNarrationAsync();
                        ExpireSolution(true);
                    }
                }
            };
            audienceMenu.DropDownItems.Add(customItem);
        }

        // ─── Menu handlers ───────────────────────────────────────────────

        private void OnSelectElement(object sender, EventArgs e)
        {
            var viz = FindVisualization();
            if (viz == null || !viz.HasLoadedDesign)
            {
                RhinoApp.WriteLine("ElementInspector: no Visualization component with a loaded design found.");
                return;
            }

            _pickModeActive = true;
            Message = "Click an element\u2026";

            if (_mouseCallback == null)
            {
                _mouseCallback = new InspectorMouseCallback(this);
            }
            _mouseCallback.Enabled = true;

            RhinoDoc.ActiveDoc?.Views?.Redraw();
        }

        private void OnClearSelection(object sender, EventArgs e)
        {
            _selectedElementId = -1;
            _selectedElementType = "";
            _lastNarration = "";
            _pickModeActive = false;
            if (_mouseCallback != null)
                _mouseCallback.Enabled = false;
            Message = "";
            ExpireSolution(true);
        }

        // ─── Auto-discover Visualization ─────────────────────────────────

        private Visualization? FindVisualization()
        {
            var doc = OnPingDocument();
            if (doc == null) return null;
            foreach (var obj in doc.Objects)
            {
                if (obj is Visualization viz)
                    return viz;
            }
            return null;
        }

        // ─── SolveInstance ───────────────────────────────────────────────

        protected override void SolveInstance(IGH_DataAccess DA)
        {
            // Check for completed async narration
            if (_narrationState == NarrationState.Done)
            {
                _lastNarration = _pendingNarration;
                _narrationState = NarrationState.Idle;
            }
            else if (_narrationState == NarrationState.Error)
            {
                AddRuntimeMessage(GH_RuntimeMessageLevel.Warning, _pendingError);
                _narrationState = NarrationState.Idle;
            }

            var viz = FindVisualization();
            if (viz == null || !viz.HasLoadedDesign)
            {
                AddRuntimeMessage(GH_RuntimeMessageLevel.Error,
                    "No Visualization component with a loaded design found on this canvas.");
                return;
            }

            if (_selectedElementId >= 0)
            {
                DA.SetData(0, _selectedElementType);
                DA.SetData(1, _selectedElementId);
                DA.SetData(2, _lastNarration);
            }
        }

        // ─── Narration fetch ─────────────────────────────────────────────

        private void FetchNarrationAsync()
        {
            _narrationCts?.Cancel();
            _narrationCts = new CancellationTokenSource();
            _narrationState = NarrationState.Fetching;
            Message = $"{Capitalize(_selectedElementType)} {_selectedElementId} \u2014 loading\u2026";

            var ct = _narrationCts.Token;
            var elemType = _selectedElementType;
            var elemId = _selectedElementId;
            var audience = _audience;
            var doc = OnPingDocument();

            Task.Run(async () =>
            {
                try
                {
                    var args = new JObject
                    {
                        ["element_type"] = elemType,
                        ["element_id"] = elemId,
                        ["audience"] = audience
                    };
                    var result = await DesignRunHttpClient.PostChatActionAsync(
                        MenegrothConfig.LastServerUrl, "narrate_element", args, ct);

                    if (ct.IsCancellationRequested) return;

                    if (result != null)
                    {
                        _pendingNarration = result["narration"]?.ToString()
                            ?? result["narrative"]?.ToString()
                            ?? result.ToString(Newtonsoft.Json.Formatting.Indented);
                        _narrationState = NarrationState.Done;
                    }
                    else
                    {
                        _pendingError = "narrate_element returned null";
                        _narrationState = NarrationState.Error;
                    }
                }
                catch (Exception ex)
                {
                    if (!ct.IsCancellationRequested)
                    {
                        _pendingError = $"Narration failed: {ex.Message}";
                        _narrationState = NarrationState.Error;
                    }
                }
                finally
                {
                    RhinoApp.InvokeOnUiThread((Action)(() =>
                    {
                        Message = _selectedElementId >= 0
                            ? $"{Capitalize(_selectedElementType)} {_selectedElementId}"
                            : "";
                        doc?.ScheduleSolution(10, _ => ExpireSolution(false));
                    }));
                }
            }, ct);
        }

        // ─── Viewport highlight ──────────────────────────────────────────

        public override void DrawViewportMeshes(IGH_PreviewArgs args)
        {
            base.DrawViewportMeshes(args);
            if (_selectedElementId < 0) return;

            var viz = FindVisualization();
            if (viz == null) return;

            var meshes = viz.PreviewMeshes;
            var ids = viz.PreviewMeshElementIds;
            var types = viz.PreviewMeshElementTypes;

            int n = Math.Min(meshes.Count, Math.Min(ids.Count, types.Count));
            for (int i = 0; i < n; i++)
            {
                if (ids[i] == _selectedElementId && types[i] == _selectedElementType)
                {
                    var m = meshes[i];
                    if (m != null)
                        args.Display.DrawMeshShaded(m, CyanMaterial);
                }
            }
        }

        public override void DrawViewportWires(IGH_PreviewArgs args)
        {
            base.DrawViewportWires(args);
            if (_selectedElementId < 0) return;

            var viz = FindVisualization();
            if (viz == null) return;

            BoundingBox labelBox = BoundingBox.Empty;

            if (_selectedElementType == "column")
            {
                var curves = viz.PreviewColumnCurves;
                var curveIds = viz.PreviewColumnIds;
                int nc = Math.Min(curves.Count, curveIds.Count);
                for (int i = 0; i < nc; i++)
                {
                    if (curveIds[i] == _selectedElementId && curves[i] != null)
                    {
                        args.Display.DrawCurve(curves[i], CyanHighlight, 4);
                        labelBox.Union(curves[i].GetBoundingBox(false));
                    }
                }
            }
            else if (_selectedElementType == "beam")
            {
                var curves = viz.PreviewBeamCurves;
                var curveIds = viz.PreviewBeamIds;
                int nc = Math.Min(curves.Count, curveIds.Count);
                for (int i = 0; i < nc; i++)
                {
                    if (curveIds[i] == _selectedElementId && curves[i] != null)
                    {
                        args.Display.DrawCurve(curves[i], CyanHighlight, 4);
                        labelBox.Union(curves[i].GetBoundingBox(false));
                    }
                }
            }

            // Gather bounding box from meshes for the label
            var meshes = viz.PreviewMeshes;
            var ids = viz.PreviewMeshElementIds;
            var types = viz.PreviewMeshElementTypes;
            int nm = Math.Min(meshes.Count, Math.Min(ids.Count, types.Count));
            for (int i = 0; i < nm; i++)
            {
                if (ids[i] == _selectedElementId && types[i] == _selectedElementType && meshes[i] != null)
                    labelBox.Union(meshes[i].GetBoundingBox(false));
            }

            if (labelBox.IsValid)
            {
                var center = labelBox.Center;
                var dot = new TextDot($"{Capitalize(_selectedElementType)} {_selectedElementId}", center);
                args.Display.DrawDot(dot, CyanHighlight, Color.Black, Color.Black);
            }
        }

        public override BoundingBox ClippingBox
        {
            get
            {
                var box = base.ClippingBox;
                if (_selectedElementId < 0) return box;
                var viz = FindVisualization();
                if (viz == null) return box;

                var meshes = viz.PreviewMeshes;
                var ids = viz.PreviewMeshElementIds;
                var types = viz.PreviewMeshElementTypes;
                int n = Math.Min(meshes.Count, Math.Min(ids.Count, types.Count));
                for (int i = 0; i < n; i++)
                {
                    if (ids[i] == _selectedElementId && types[i] == _selectedElementType && meshes[i] != null)
                        box.Union(meshes[i].GetBoundingBox(false));
                }
                return box;
            }
        }

        // ─── State serialization ─────────────────────────────────────────

        public override bool Write(GH_IO.Serialization.GH_IWriter writer)
        {
            writer.SetString("Audience", _audience);
            writer.SetInt32("SelectedElementId", _selectedElementId);
            writer.SetString("SelectedElementType", _selectedElementType);
            return base.Write(writer);
        }

        public override bool Read(GH_IO.Serialization.GH_IReader reader)
        {
            if (reader.ItemExists("Audience"))
                _audience = reader.GetString("Audience");
            if (reader.ItemExists("SelectedElementId"))
                _selectedElementId = reader.GetInt32("SelectedElementId");
            if (reader.ItemExists("SelectedElementType"))
                _selectedElementType = reader.GetString("SelectedElementType");
            return base.Read(reader);
        }

        // ─── Cleanup ─────────────────────────────────────────────────────

        public override void RemovedFromDocument(GH_Document document)
        {
            _narrationCts?.Cancel();
            if (_mouseCallback != null)
            {
                _mouseCallback.Enabled = false;
                _mouseCallback = null;
            }
            base.RemovedFromDocument(document);
        }

        // ─── Helpers ─────────────────────────────────────────────────────

        private static string Capitalize(string s) =>
            string.IsNullOrEmpty(s) ? s : char.ToUpperInvariant(s[0]) + s.Substring(1);

        // ─── Mouse callback for viewport element picking ─────────────────

        internal void HandleViewportClick(System.Drawing.Point screenPoint, RhinoViewport viewport)
        {
            if (!_pickModeActive) return;

            var viz = FindVisualization();
            if (viz == null || !viz.HasLoadedDesign) return;

            viewport.GetFrustumLine(screenPoint.X, screenPoint.Y, out Line frustumLine);
            var ray = new Ray3d(frustumLine.From, frustumLine.Direction);

            int bestIndex = -1;
            double bestT = double.MaxValue;
            string bestType = "";
            int bestId = -1;

            // Test shaded meshes
            var meshes = viz.PreviewMeshes;
            var meshIds = viz.PreviewMeshElementIds;
            var meshTypes = viz.PreviewMeshElementTypes;
            int nm = Math.Min(meshes.Count, Math.Min(meshIds.Count, meshTypes.Count));
            for (int i = 0; i < nm; i++)
            {
                var m = meshes[i];
                if (m == null) continue;
                double t = Intersection.MeshRay(m, ray);
                if (t >= 0 && t < bestT)
                {
                    bestT = t;
                    bestIndex = i;
                    bestType = meshTypes[i];
                    bestId = meshIds[i];
                }
            }

            // Test column curves
            TestCurveHit(viz.PreviewColumnCurves, viz.PreviewColumnIds, "column",
                frustumLine, viewport, ref bestT, ref bestId, ref bestType);

            // Test beam curves
            TestCurveHit(viz.PreviewBeamCurves, viz.PreviewBeamIds, "beam",
                frustumLine, viewport, ref bestT, ref bestId, ref bestType);

            if (bestId >= 0)
            {
                _selectedElementId = bestId;
                _selectedElementType = bestType;
                _pickModeActive = false;
                if (_mouseCallback != null)
                    _mouseCallback.Enabled = false;

                FetchNarrationAsync();
                RhinoDoc.ActiveDoc?.Views?.Redraw();
                var doc = OnPingDocument();
                doc?.ScheduleSolution(10, _ => ExpireSolution(false));
            }
            else
            {
                RhinoApp.WriteLine("ElementInspector: no element found at click location.");
            }
        }

        private static void TestCurveHit(
            IReadOnlyList<Curve> curves, IReadOnlyList<int> curveIds, string elementType,
            Line frustumLine, RhinoViewport viewport,
            ref double bestT, ref int bestId, ref string bestType)
        {
            int nc = Math.Min(curves.Count, curveIds.Count);
            for (int i = 0; i < nc; i++)
            {
                var crv = curves[i];
                if (crv == null) continue;
                if (!crv.ClosestPoints(new LineCurve(frustumLine), out Point3d ptOnCurve, out Point3d ptOnLine))
                    continue;

                var screenCurve = viewport.WorldToClient(ptOnCurve);
                var screenLine = viewport.WorldToClient(ptOnLine);

                double pixelDist = Math.Sqrt(
                    Math.Pow(screenCurve.X - screenLine.X, 2) +
                    Math.Pow(screenCurve.Y - screenLine.Y, 2));

                if (pixelDist < 8.0)
                {
                    double dist = ptOnCurve.DistanceTo(frustumLine.From);
                    if (dist < bestT)
                    {
                        bestT = dist;
                        bestId = curveIds[i];
                        bestType = elementType;
                    }
                }
            }
        }

        // ─── MouseCallback implementation ────────────────────────────────

        private class InspectorMouseCallback : Rhino.UI.MouseCallback
        {
            private readonly ElementInspector _owner;

            public InspectorMouseCallback(ElementInspector owner)
            {
                _owner = owner;
            }

            protected override void OnMouseDown(MouseCallbackEventArgs e)
            {
                if (!_owner._pickModeActive) return;
                if (e.MouseButton != MouseButton.Left) return;
                if (e.View?.ActiveViewport == null) return;

                _owner.HandleViewportClick(e.ViewportPoint, e.View.ActiveViewport);

                e.Cancel = true;
            }
        }
    }
}
