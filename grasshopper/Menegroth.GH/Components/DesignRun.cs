using System;
using System.Collections.Generic;
using System.Linq;
using System.Net.Http;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using System.Windows.Forms;
using Grasshopper.Kernel;
using Newtonsoft.Json.Linq;
using Menegroth.GH.Types;

namespace Menegroth.GH.Components
{
    /// <summary>
    /// Sends geometry + params to the Julia sizing API and returns a parsed
    /// <see cref="DesignResult"/> object plus the raw JSON and a streaming log.
    ///
    /// Key UX features:
    ///   - Pre-flight /health check with clear "server not running" message
    ///   - Async background request — Grasshopper UI stays responsive
    ///   - Message bar: Ready → Computing… → ✓ 2.3 s All Pass / ⚠ 3 failures
    ///   - Smart caching: unchanged inputs return instantly
    ///   - Server-side geometry cache: param-only changes skip skeleton rebuild
    ///   - Async submit-then-poll pattern for App Runner 120 s request timeout
    /// </summary>
    public class DesignRun : GH_Component
    {
        private const string DefaultServerUrl = "http://localhost:8080";
        private const int PollTimeoutSeconds = 3600;
        private const int HealthCheckTimeoutSeconds = 3;
        private const int ScheduleSolutionIntervalMs = 100;

        private static readonly HttpClient _client = new HttpClient
        {
            Timeout = TimeSpan.FromHours(1)
        };

        // ─── Persisted state ────────────────────────────────────────────
        private string _serverUrl = DefaultServerUrl;

        // ─── Cached results ─────────────────────────────────────────────
        private string _lastGeoHash = "";
        private string _lastParamsHash = "";
        private DesignResult _lastParsed;
        private double _lastComputeTime;

        // ─── Async state machine ────────────────────────────────────────
        private enum RunState { Idle, HealthCheck, Sending, Polling, Done, Error }
        private volatile int _stateInt;
        private RunState _state
        {
            get => (RunState)_stateInt;
            set => _stateInt = (int)value;
        }
        private DesignResult _pendingParsed;
        private string _pendingError = "";
        private string _pendingGeoHash = "";
        private string _pendingParamsHash = "";

        // ─── Status log ─────────────────────────────────────────────────
        private readonly object _logLock = new object();
        private readonly StringBuilder _statusLog = new StringBuilder();
        private string _waitStatusLine;
        private volatile bool _cancelRequested;

        public DesignRun()
            : base("Design Run",
                   "DesignRun",
                   "Send geometry and parameters to the Julia sizing server",
                   "Menegroth", "Analysis")
        { }

        public override Guid ComponentGuid =>
            new Guid("54C14B09-90A6-4F8C-BE47-6B5CAECC109F");

        // ─── Parameters ─────────────────────────────────────────────────

        protected override void RegisterInputParams(GH_InputParamManager pManager)
        {
            pManager.AddGenericParameter("Geometry", "Geometry",
                "BuildingGeometry from the GeometryInput component",
                GH_ParamAccess.item);

            pManager.AddGenericParameter("Params", "Params",
                "DesignParams from the DesignParams component",
                GH_ParamAccess.item);

            pManager.AddTextParameter("Server URL", "URL",
                "Julia API server URL (persisted in right-click menu)",
                GH_ParamAccess.item, DefaultServerUrl);

            pManager.AddBooleanParameter("Run", "Run",
                "Toggle to send the request (connect a Button)",
                GH_ParamAccess.item, false);
        }

        protected override void RegisterOutputParams(GH_OutputParamManager pManager)
        {
            pManager.AddGenericParameter("Result", "Result",
                "Parsed DesignResult object for downstream components",
                GH_ParamAccess.item);
            pManager.AddTextParameter("JSON", "JSON",
                "Raw JSON response from the server", GH_ParamAccess.item);
            pManager.AddTextParameter("Log", "Log",
                "Status log (wire to Panel to see progress)", GH_ParamAccess.item);
        }

        // ─── Right-click menu ───────────────────────────────────────────

        protected override void AppendAdditionalComponentMenuItems(ToolStripDropDown menu)
        {
            base.AppendAdditionalComponentMenuItems(menu);
            Menu_AppendSeparator(menu);

            var resetItem = Menu_AppendItem(menu, "Reset Cache", OnResetCache);
            resetItem.ToolTipText = "Clear cached results and force a fresh analysis run";

            var cancelItem = Menu_AppendItem(menu, "Cancel", OnCancel);
            cancelItem.ToolTipText = "Cancel the current request (waiting for API or design)";
        }

        private void OnCancel(object sender, EventArgs e)
        {
            _cancelRequested = true;
            var doc = OnPingDocument();
            if (doc != null) ScheduleExpire(doc);
        }

        private void OnResetCache(object sender, EventArgs e)
        {
            _lastGeoHash = "";
            _lastParamsHash = "";
            _lastParsed = null;
            _lastComputeTime = 0;
            lock (_logLock) { _statusLog.Clear(); _waitStatusLine = null; }
            Message = "Cache cleared";
            ExpireSolution(true);
        }

        // ─── Persistence ────────────────────────────────────────────────

        public override bool Write(GH_IO.Serialization.GH_IWriter writer)
        {
            writer.SetString("ServerUrl", _serverUrl);
            return base.Write(writer);
        }

        public override bool Read(GH_IO.Serialization.GH_IReader reader)
        {
            if (reader.ItemExists("ServerUrl"))
                _serverUrl = reader.GetString("ServerUrl");
            return base.Read(reader);
        }

        // ─── Logging helpers ────────────────────────────────────────────

        private void AppendLog(GH_Document doc, string line)
        {
            lock (_logLock)
            {
                if (_statusLog.Length > 0) _statusLog.AppendLine();
                _statusLog.Append(line);
            }
            ScheduleExpire(doc);
        }

        private string GetLogSnapshot()
        {
            lock (_logLock)
            {
                var s = _statusLog.ToString();
                if (!string.IsNullOrEmpty(_waitStatusLine))
                    s += (s.Length > 0 ? "\n" : "") + _waitStatusLine;
                return s;
            }
        }

        private void UpdateWaitStatus(GH_Document doc, string message, int elapsedSec)
        {
            lock (_logLock) { _waitStatusLine = $"{message} ({elapsedSec} s)"; }
            ScheduleExpire(doc);
        }

        private void ClearWaitStatus()
        {
            lock (_logLock) { _waitStatusLine = null; }
        }

        // ─── Solve ──────────────────────────────────────────────────────

        protected override void SolveInstance(IGH_DataAccess DA)
        {
            // 1. Read inputs
            GH_BuildingGeometry geoGoo = null;
            GH_DesignParams paramsGoo = null;
            string urlInput = _serverUrl;
            bool run = false;

            if (!DA.GetData(0, ref geoGoo) || geoGoo?.Value == null) return;
            if (!DA.GetData(1, ref paramsGoo) || paramsGoo?.Value == null) return;
            DA.GetData(2, ref urlInput);
            DA.GetData(3, ref run);

            string url = string.IsNullOrWhiteSpace(urlInput) ? _serverUrl : urlInput;
            _serverUrl = url;

            // 2. Async work just finished
            if (_state == RunState.Done)
            {
                _lastGeoHash = _pendingGeoHash;
                _lastParamsHash = _pendingParamsHash;
                _lastParsed = _pendingParsed;
                _lastComputeTime = _lastParsed?.ComputeTime ?? 0;
                _state = RunState.Idle;

                EmitResult(DA, _lastParsed);
                Message = FormatDoneMessage(_lastParsed);
                return;
            }

            if (_state == RunState.Error)
            {
                AddRuntimeMessage(GH_RuntimeMessageLevel.Error, _pendingError);
                Message = "\u2717 Server error";
                _state = RunState.Idle;

                EmitResult(DA, _lastParsed);
                return;
            }

            // 3. Currently computing
            if (_state != RunState.Idle)
            {
                Message = _state == RunState.HealthCheck ? "Checking server..."
                        : _state == RunState.Sending     ? "Computing..."
                        : _state == RunState.Polling      ? "Waiting..."
                        : "Working...";
                AddRuntimeMessage(GH_RuntimeMessageLevel.Remark, Message);
                DA.SetData(2, GetLogSnapshot());
                if (_lastParsed != null)
                {
                    DA.SetData(0, new GH_DesignResult(_lastParsed));
                    DA.SetData(1, _lastParsed.RawJson);
                }
                return;
            }

            // 4. Run = false → cached or ready
            if (!run)
            {
                DA.SetData(2, GetLogSnapshot());
                if (_lastParsed != null)
                {
                    DA.SetData(0, new GH_DesignResult(_lastParsed));
                    DA.SetData(1, _lastParsed.RawJson);
                    Message = FormatDoneMessage(_lastParsed) + " (cached)";
                }
                else
                {
                    Message = "Ready";
                    AddRuntimeMessage(GH_RuntimeMessageLevel.Remark,
                        "Connect a Button to Run and click it to send the request.");
                }
                return;
            }

            // 5. Check for unchanged inputs
            var geo = geoGoo.Value;
            var prms = paramsGoo.Value;
            string geoHash = geo.ComputeHash();
            string paramsHash = prms.ComputeHash();

            if (geoHash == _lastGeoHash && paramsHash == _lastParamsHash && _lastParsed != null)
            {
                DA.SetData(0, new GH_DesignResult(_lastParsed));
                DA.SetData(1, _lastParsed.RawJson);
                DA.SetData(2, GetLogSnapshot());
                Message = FormatDoneMessage(_lastParsed) + " (cached)";
                AddRuntimeMessage(GH_RuntimeMessageLevel.Remark,
                    "No changes detected \u2014 returning cached result.");
                return;
            }

            // 6. Client-side validation (instant feedback, no network needed)
            var validationErrors = ValidateLocally(geo, prms);
            if (validationErrors.Count > 0)
            {
                foreach (var err in validationErrors)
                    AddRuntimeMessage(GH_RuntimeMessageLevel.Error, err);
                lock (_logLock) { _statusLog.Clear(); }
                AppendLog(OnPingDocument(), $"\u2717 Validation failed ({validationErrors.Count} error{(validationErrors.Count > 1 ? "s" : "")}):");
                foreach (var err in validationErrors)
                    AppendLog(OnPingDocument(), "  \u2022 " + err);
                DA.SetData(2, GetLogSnapshot());
                Message = $"\u2717 {validationErrors.Count} validation error{(validationErrors.Count > 1 ? "s" : "")}";
                return;
            }

            // 7. Build payload
            var payload = geo.ToJson();
            payload["params"] = prms.ToJson();
            if (geoHash == _lastGeoHash && paramsHash != _lastParamsHash)
                payload["geometry_hash"] = geoHash;
            string jsonBody = payload.ToString();

            // 8. Launch async
            _state = RunState.HealthCheck;
            _pendingGeoHash = geoHash;
            _pendingParamsHash = paramsHash;
            Message = "Checking server...";
            lock (_logLock) { _statusLog.Clear(); }
            _cancelRequested = false;

            var doc = OnPingDocument();
            AppendLog(doc, "Checking server...");

            Task.Run(async () =>
            {
                try
                {
                    if (!await CheckHealth(url))
                    {
                        AppendLog(doc, "\u2717 Health check failed.");
                        _pendingError = $"Julia server not running at {url}.\n" +
                            "Start it with:\n  julia --project=StructuralSynthesizer scripts/api/sizer_service.jl";
                        _state = RunState.Error;
                        ScheduleExpire(doc);
                        return;
                    }
                    AppendLog(doc, "Server reachable. Waiting for API ready (cold start may take up to ~10 min)...");

                    _state = RunState.Polling;
                    ScheduleExpire(doc);
                    UpdateWaitStatus(doc, "Waiting for API ready...", 0);
                    string readyBody = await PollUntilReady(url, PollTimeoutSeconds,
                        elapsed => UpdateWaitStatus(doc, "Waiting for API ready...", elapsed),
                        () => _cancelRequested);
                    ClearWaitStatus();

                    if (readyBody.Contains("Cancelled by user"))
                    {
                        AppendLog(doc, "\u2717 Cancelled by user.");
                        _pendingError = "Cancelled by user.";
                        _state = RunState.Error;
                        ScheduleExpire(doc);
                        return;
                    }
                    if (readyBody.Contains("Timeout waiting for server"))
                    {
                        AppendLog(doc, "\u2717 Timeout waiting for API (1 h).");
                        _pendingError = "Server did not become ready within 1 hour.";
                        _state = RunState.Error;
                        ScheduleExpire(doc);
                        return;
                    }
                    if (readyBody.Contains("\"status\":\"error\""))
                    {
                        AppendLog(doc, "\u2717 Server failed during startup. Check server logs.");
                        _pendingError = "Server reported an error during startup.";
                        _state = RunState.Error;
                        ScheduleExpire(doc);
                        return;
                    }

                    AppendLog(doc, "API ready. Sending design request...");
                    _state = RunState.Sending;
                    ScheduleExpire(doc);
                    UpdateWaitStatus(doc, "Waiting for design...", 0);

                    // Timer task shows elapsed seconds while waiting
                    var designCts = new CancellationTokenSource();
                    var designStart = DateTime.UtcNow;
                    var timerTask = Task.Run(async () =>
                    {
                        int lastTick = 0;
                        while (!designCts.Token.IsCancellationRequested)
                        {
                            try { await Task.Delay(1000, designCts.Token); }
                            catch (OperationCanceledException) { break; }
                            int elapsed = (int)(DateTime.UtcNow - designStart).TotalSeconds;
                            if (elapsed != lastTick)
                            {
                                lastTick = elapsed;
                                UpdateWaitStatus(doc, "Waiting for design...", elapsed);
                                ScheduleExpire(doc);
                            }
                        }
                    }, designCts.Token);

                    string responseJson;
                    try
                    {
                        responseJson = await PostDesign(url, jsonBody);
                    }
                    finally
                    {
                        designCts.Cancel();
                        try { await timerTask; }
                        catch (OperationCanceledException) { }
                        ClearWaitStatus();
                    }

                    // Check if server returned 202 Accepted (async pattern)
                    var jobj = JObject.Parse(responseJson);
                    string status = jobj["status"]?.ToString() ?? "unknown";

                    if (status == "queued" || status == "accepted")
                    {
                        AppendLog(doc, "Design accepted. Waiting for server to finish...");
                        _state = RunState.Polling;
                        ScheduleExpire(doc);
                        UpdateWaitStatus(doc, "Waiting for design to complete...", 0);
                        string idleBody = await PollUntilReady(url, PollTimeoutSeconds,
                            elapsed => UpdateWaitStatus(doc, "Waiting for design to complete...", elapsed),
                            () => _cancelRequested);
                        ClearWaitStatus();

                        if (idleBody.Contains("Cancelled by user"))
                        {
                            AppendLog(doc, "\u2717 Cancelled by user.");
                            _pendingError = "Cancelled by user.";
                            _state = RunState.Error;
                            ScheduleExpire(doc);
                            return;
                        }
                        if (idleBody.Contains("Timeout waiting for server"))
                        {
                            AppendLog(doc, "\u2717 Timeout waiting for design (1 h).");
                            _pendingError = "Design did not complete within 1 hour.";
                            _state = RunState.Error;
                            ScheduleExpire(doc);
                            return;
                        }

                        AppendLog(doc, "Server idle. Fetching design result...");
                        responseJson = await GetResultWithRetry(url);
                    }

                    // Parse the final response into a typed result
                    _pendingParsed = DesignResult.FromJson(responseJson);

                    if (_pendingParsed.IsError)
                        AppendLog(doc, $"\u2717 Server returned error: {_pendingParsed.ErrorMessage}");
                    else
                        AppendLog(doc, $"\u2713 Done in {_pendingParsed.ComputeTime:F1} s.");

                    _state = RunState.Done;
                }
                catch (TaskCanceledException)
                {
                    AppendLog(doc, "\u2717 Request timed out.");
                    _pendingError = $"Request timed out after {_client.Timeout.TotalSeconds:F0}s. " +
                        "The server may still be computing.";
                    _state = RunState.Error;
                }
                catch (HttpRequestException ex)
                {
                    AppendLog(doc, "\u2717 Connection failed: " + ex.Message);
                    _pendingError = $"Connection failed: {ex.Message}\n" +
                        $"Is the Julia server running at {url}?";
                    _state = RunState.Error;
                }
                catch (Exception ex)
                {
                    AppendLog(doc, "\u2717 Error: " + ex.Message);
                    _pendingError = $"Error: {ex.Message}";
                    _state = RunState.Error;
                }

                ScheduleExpire(doc);
            });

            DA.SetData(2, GetLogSnapshot());
            if (_lastParsed != null)
            {
                DA.SetData(0, new GH_DesignResult(_lastParsed));
                DA.SetData(1, _lastParsed.RawJson);
            }
        }

        // ─── Output helper ──────────────────────────────────────────────

        private void EmitResult(IGH_DataAccess DA, DesignResult result)
        {
            DA.SetData(2, GetLogSnapshot());
            if (result != null)
            {
                DA.SetData(0, new GH_DesignResult(result));
                DA.SetData(1, result.RawJson);
                if (result.IsError)
                    AddRuntimeMessage(GH_RuntimeMessageLevel.Error, result.ErrorMessage);
            }
        }

        private static string FormatDoneMessage(DesignResult r)
        {
            if (r == null) return "Ready";
            if (r.IsError) return "\u2717 Error";
            int failures = r.FailureCount;
            return failures == 0
                ? $"\u2713 {r.ComputeTime:F1} s \u2014 All Pass"
                : $"\u26A0 {r.ComputeTime:F1} s \u2014 {failures} failure{(failures > 1 ? "s" : "")}";
        }

        // ─── Thread-safe solution expiry ────────────────────────────────

        private void ScheduleExpire(GH_Document doc)
        {
            if (doc == null) return;
            doc.ScheduleSolution(ScheduleSolutionIntervalMs, _ => ExpireSolution(false));
        }

        // ─── HTTP helpers ───────────────────────────────────────────────

        private static async Task<bool> CheckHealth(string baseUrl)
        {
            try
            {
                using var cts = new CancellationTokenSource(TimeSpan.FromSeconds(HealthCheckTimeoutSeconds));
                var resp = await _client.GetAsync($"{baseUrl.TrimEnd('/')}/health", cts.Token);
                return resp.IsSuccessStatusCode;
            }
            catch { return false; }
        }

        private static async Task<string> PostDesign(string baseUrl, string jsonBody)
        {
            var content = new StringContent(jsonBody, Encoding.UTF8, "application/json");
            var response = await _client.PostAsync($"{baseUrl.TrimEnd('/')}/design", content);
            var body = await response.Content.ReadAsStringAsync();
            if (!response.IsSuccessStatusCode)
                throw new InvalidOperationException(
                    $"Server returned {(int)response.StatusCode} {response.ReasonPhrase}. {body}");
            if (string.IsNullOrWhiteSpace(body))
                throw new InvalidOperationException("Server returned empty response.");
            return body;
        }

        private static async Task<string> GetResultWithRetry(string baseUrl)
        {
            const int maxRetries = 10;
            const int retryDelayMs = 1000;

            for (int attempt = 1; attempt <= maxRetries; attempt++)
            {
                var response = await _client.GetAsync($"{baseUrl.TrimEnd('/')}/result");
                var body = await response.Content.ReadAsStringAsync();

                if (response.IsSuccessStatusCode)
                {
                    if (string.IsNullOrWhiteSpace(body))
                        throw new InvalidOperationException("Server returned empty result from GET /result.");
                    return body;
                }

                if ((int)response.StatusCode == 503 && attempt < maxRetries)
                {
                    await Task.Delay(retryDelayMs);
                    continue;
                }

                throw new InvalidOperationException(
                    $"GET /result failed: {(int)response.StatusCode} {response.ReasonPhrase}. {body}");
            }

            throw new InvalidOperationException("GET /result failed after retries.");
        }

        private static async Task<string> PollUntilReady(string baseUrl, int timeoutSeconds,
            Action<int> onTick = null, Func<bool> cancelRequested = null)
        {
            var start = DateTime.UtcNow;
            var deadline = start.AddSeconds(timeoutSeconds);
            int lastTick = 0;
            while (DateTime.UtcNow < deadline)
            {
                await Task.Delay(1000);
                if (cancelRequested?.Invoke() == true)
                    return "{\"status\":\"error\",\"message\":\"Cancelled by user\"}";
                int elapsed = (int)(DateTime.UtcNow - start).TotalSeconds;
                if (elapsed != lastTick)
                {
                    lastTick = elapsed;
                    onTick?.Invoke(elapsed);
                }
                try
                {
                    var resp = await _client.GetAsync($"{baseUrl.TrimEnd('/')}/status");
                    var body = await resp.Content.ReadAsStringAsync();
                    var jobj = JObject.Parse(body);
                    string st = jobj["status"]?.ToString() ?? "";
                    if (st == "idle")
                        return body;
                    if (st == "error")
                        return "{\"status\":\"error\",\"message\":\"Server reported an error during startup. Check server logs.\"}";
                }
                catch { /* retry on transient network errors */ }
            }
            return "{\"status\":\"error\",\"message\":\"Timeout waiting for server\"}";
        }

        // ─── Client-side validation ──────────────────────────────────────
        // Mirrors StructuralSynthesizer/src/api/validation.jl so that obvious
        // errors are caught instantly without a network round-trip.

        private static readonly HashSet<string> ValidFloorTypes =
            new HashSet<string> { "flat_plate", "flat_slab", "one_way", "vault" };
        private static readonly HashSet<string> ValidColumnTypes =
            new HashSet<string> { "rc_rect", "rc_circular", "steel_w", "steel_hss", "steel_pipe" };
        private static readonly HashSet<string> ValidBeamTypes =
            new HashSet<string> { "steel_w", "steel_hss", "rc_rect", "rc_tbeam" };
        private static readonly HashSet<string> ValidConcretes =
            new HashSet<string> { "NWC_3000", "NWC_4000", "NWC_5000", "NWC_6000" };
        private static readonly HashSet<string> ValidRebars =
            new HashSet<string> { "Rebar_40", "Rebar_60", "Rebar_75", "Rebar_80" };
        private static readonly HashSet<string> ValidSteels =
            new HashSet<string> { "A992" };
        private static readonly HashSet<string> ValidSoils =
            new HashSet<string> { "loose_sand", "medium_sand", "dense_sand", "soft_clay", "stiff_clay", "hard_clay" };
        private static readonly HashSet<double> ValidFireRatings =
            new HashSet<double> { 0, 1, 1.5, 2, 3, 4 };
        private static readonly HashSet<string> ValidOptimize =
            new HashSet<string> { "weight", "carbon", "cost" };
        private static readonly HashSet<string> ValidUnitSystems =
            new HashSet<string> { "imperial", "metric" };

        private static List<string> ValidateLocally(BuildingGeometry geo, DesignParams prms)
        {
            var errors = new List<string>();

            // Vertices
            int nVerts = geo.Vertices.Count;
            if (nVerts < 4)
                errors.Add($"Need at least 4 vertices (got {nVerts}).");
            for (int i = 0; i < nVerts; i++)
                if (geo.Vertices[i].Length != 3)
                    errors.Add($"Vertex {i + 1} has {geo.Vertices[i].Length} coordinates (expected 3).");

            // Edges
            var allEdges = geo.BeamEdges.Concat(geo.ColumnEdges).Concat(geo.StrutEdges).ToList();
            if (allEdges.Count == 0)
                errors.Add("No edges provided (need at least beams, columns, or braces).");
            for (int i = 0; i < allEdges.Count; i++)
            {
                var e = allEdges[i];
                if (e.Length != 2) { errors.Add($"Edge {i + 1} has {e.Length} indices (expected 2)."); continue; }
                if (e[0] < 1 || e[0] > nVerts) errors.Add($"Edge {i + 1}: vertex index {e[0]} out of range [1, {nVerts}].");
                if (e[1] < 1 || e[1] > nVerts) errors.Add($"Edge {i + 1}: vertex index {e[1]} out of range [1, {nVerts}].");
                if (e[0] == e[1]) errors.Add($"Edge {i + 1}: degenerate edge (both indices = {e[0]}).");
            }

            // Supports
            if (geo.Supports.Count == 0)
                errors.Add("No support vertices specified.");
            for (int i = 0; i < geo.Supports.Count; i++)
            {
                int si = geo.Supports[i];
                if (si < 1 || si > nVerts) errors.Add($"Support {i + 1}: vertex index {si} out of range [1, {nVerts}].");
            }

            // Parameters
            if (!ValidFloorTypes.Contains(prms.FloorType))
                errors.Add($"Invalid floor type \"{prms.FloorType}\". Options: {string.Join(", ", ValidFloorTypes)}");
            if (!ValidColumnTypes.Contains(prms.ColumnType))
                errors.Add($"Invalid column type \"{prms.ColumnType}\". Options: {string.Join(", ", ValidColumnTypes)}");
            if (!ValidBeamTypes.Contains(prms.BeamType))
                errors.Add($"Invalid beam type \"{prms.BeamType}\". Options: {string.Join(", ", ValidBeamTypes)}");
            if (!ValidConcretes.Contains(prms.Concrete))
                errors.Add($"Unknown concrete \"{prms.Concrete}\". Options: {string.Join(", ", ValidConcretes)}");
            if (!ValidRebars.Contains(prms.Rebar))
                errors.Add($"Unknown rebar \"{prms.Rebar}\". Options: {string.Join(", ", ValidRebars)}");
            if (!ValidSteels.Contains(prms.Steel))
                errors.Add($"Unknown steel \"{prms.Steel}\". Options: {string.Join(", ", ValidSteels)}");
            if (!ValidFireRatings.Contains(prms.FireRating))
                errors.Add($"Invalid fire rating {prms.FireRating}. Options: 0, 1, 1.5, 2, 3, 4");
            if (!ValidOptimize.Contains(prms.OptimizeFor))
                errors.Add($"Invalid optimize_for \"{prms.OptimizeFor}\". Options: weight, carbon, cost");
            if (!ValidUnitSystems.Contains(prms.UnitSystem?.ToLowerInvariant() ?? ""))
                errors.Add($"Invalid unit system \"{prms.UnitSystem}\". Options: imperial, metric");

            // Foundation soil (only if foundations requested)
            if (prms.SizeFoundations && !ValidSoils.Contains(prms.FoundationSoil))
                errors.Add($"Unknown foundation soil \"{prms.FoundationSoil}\". Options: {string.Join(", ", ValidSoils)}");

            return errors;
        }
    }
}
