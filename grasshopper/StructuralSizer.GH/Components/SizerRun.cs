using System;
using System.Diagnostics;
using System.Net.Http;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using System.Windows.Forms;
using Grasshopper.Kernel;
using Newtonsoft.Json.Linq;
using StructuralSizer.GH.Types;

namespace StructuralSizer.GH.Components
{
    /// <summary>
    /// Sends geometry + params to the Julia sizing API and returns the raw
    /// JSON response.
    ///
    /// Key UX features:
    ///   • Pre-flight /health check with clear "server not running" message
    ///   • Async background request — Grasshopper UI stays responsive
    ///   • Message bar shows current state: Ready, Computing…, ✓ 2.3 s, ✗ Error
    ///   • Smart caching: unchanged inputs return instantly
    ///   • Server-side geometry cache: param-only changes skip skeleton rebuild
    /// </summary>
    public class SizerRun : GH_Component
    {
        private static readonly HttpClient _client = new HttpClient
        {
            Timeout = TimeSpan.FromSeconds(300)
        };

        // ─── Cached results ──────────────────────────────────────────────
        private string _lastGeoHash = "";
        private string _lastParamsHash = "";
        private string _lastResult = "";
        private string _lastStatus = "";
        private double _lastComputeTime = 0;

        // ─── Async state machine ─────────────────────────────────────────
        private enum RunState { Idle, HealthCheck, Sending, Polling, Done, Error }
        private volatile int _stateInt = 0; // int-backed for volatile safety
        private RunState _state
        {
            get => (RunState)_stateInt;
            set => _stateInt = (int)value;
        }
        private string _pendingResult = "";
        private string _pendingStatus = "";
        private double _pendingTime = 0;
        private string _pendingError = "";
        private string _pendingGeoHash = "";
        private string _pendingParamsHash = "";

        // ─── Status log for streaming to Panel ─────────────────────────────
        private readonly object _logLock = new object();
        private readonly StringBuilder _statusLog = new StringBuilder();
        /// <summary>Current waiting line with timer (e.g. "Waiting for API ready... (12 s)"). Updated every second during poll.</summary>
        private string _waitStatusLine;
        /// <summary>Set by Cancel menu; when true the async task stops waiting and reports "Cancelled by user".</summary>
        private volatile bool _cancelRequested;

        public SizerRun()
            : base("Sizer Run",
                   "SizerRun",
                   "Send geometry and parameters to the Julia sizing server",
                   "Menegroth", "Analysis")
        { }

        public override Guid ComponentGuid =>
            new Guid("A1B2C3D4-AAAA-BBBB-CCCC-DDDDEEEE0001");

        // ─── Parameters ──────────────────────────────────────────────────

        protected override void RegisterInputParams(GH_InputParamManager pManager)
        {
            pManager.AddGenericParameter("Geometry", "Geometry",
                "SizerGeometry from the GeometryInput component",
                GH_ParamAccess.item);

            pManager.AddGenericParameter("Params", "Params",
                "SizerParams from the DesignParams component",
                GH_ParamAccess.item);

            // Default Server URL: for AWS deployment, ask the user for the AWS server URL and set it here.
            pManager.AddTextParameter("Server URL", "URL",
                "Julia API server URL",
                GH_ParamAccess.item, "http://localhost:8080");

            pManager.AddBooleanParameter("Run", "Run",
                "Toggle to send the request (connect a Button)",
                GH_ParamAccess.item, false);
        }

        protected override void RegisterOutputParams(GH_OutputParamManager pManager)
        {
            pManager.AddTextParameter("JSON", "JSON",
                "Raw JSON response from the server", GH_ParamAccess.item);
            pManager.AddTextParameter("Status", "Status",
                "Response status (ok, error, cached)", GH_ParamAccess.item);
            pManager.AddTextParameter("Log", "Log",
                "Status log (wire to Panel to see progress)", GH_ParamAccess.item);
        }

        // ─── Right-click menu ────────────────────────────────────────────────

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
            _lastResult = "";
            _lastStatus = "";
            _lastComputeTime = 0;
            lock (_logLock) { _statusLog.Clear(); _waitStatusLine = null; }
            Message = "Cache cleared";
            ExpireSolution(true);
        }

        /// <summary>Append a line to the status log and schedule a canvas refresh so the Panel updates.</summary>
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

        /// <summary>Set the live wait line (e.g. "Waiting... (12 s)") and refresh the Panel.</summary>
        private void UpdateWaitStatus(GH_Document doc, string message, int elapsedSec)
        {
            lock (_logLock) { _waitStatusLine = message + " (" + elapsedSec + " s)"; }
            ScheduleExpire(doc);
        }

        private void ClearWaitStatus()
        {
            lock (_logLock) { _waitStatusLine = null; }
        }

        // ─── Solve ───────────────────────────────────────────────────────

        protected override void SolveInstance(IGH_DataAccess DA)
        {
            // ── 1. Read inputs ──
            GH_SizerGeometry? geoGoo = null;
            GH_SizerParams? paramsGoo = null;
            string url = "http://localhost:8080";
            bool run = false;

            if (!DA.GetData(0, ref geoGoo) || geoGoo?.Value == null) return;
            if (!DA.GetData(1, ref paramsGoo) || paramsGoo?.Value == null) return;
            DA.GetData(2, ref url);
            DA.GetData(3, ref run);

            if (string.IsNullOrWhiteSpace(url))
                url = "http://localhost:8080";

            // ── 2. If async work just finished, harvest the result ──
            if (_state == RunState.Done)
            {
                _lastGeoHash = _pendingGeoHash;
                _lastParamsHash = _pendingParamsHash;
                _lastResult = _pendingResult;
                _lastStatus = _pendingStatus;
                _lastComputeTime = _pendingTime;
                _state = RunState.Idle;

                DA.SetData(0, _lastResult);
                DA.SetData(1, _lastStatus);
                DA.SetData(2, GetLogSnapshot());

                if (_lastStatus == "error")
                    AddRuntimeMessage(GH_RuntimeMessageLevel.Error, ExtractErrorMessage(_lastResult));

                Message = _lastStatus == "error"
                    ? $"\u2717 Error"
                    : $"\u2713 {_lastComputeTime:F1} s";
                return;
            }

            if (_state == RunState.Error)
            {
                AddRuntimeMessage(GH_RuntimeMessageLevel.Error, _pendingError);
                Message = "\u2717 Server error";
                _state = RunState.Idle;

                DA.SetData(0, _lastResult);
                DA.SetData(1, "error");
                DA.SetData(2, GetLogSnapshot());
                return;
            }

            // ── 3. If currently computing, show progress ──
            if (_state != RunState.Idle)
            {
                Message = _state == RunState.HealthCheck ? "Checking server..."
                        : _state == RunState.Sending     ? "Computing..."
                        : _state == RunState.Polling      ? "Queued..."
                        : "Working...";

                AddRuntimeMessage(GH_RuntimeMessageLevel.Remark, Message);

                DA.SetData(2, GetLogSnapshot());
                if (!string.IsNullOrEmpty(_lastResult))
                {
                    DA.SetData(0, _lastResult);
                    DA.SetData(1, _lastStatus);
                }
                return;
            }

            // ── 4. Run = false → show cached or "ready" ──
            if (!run)
            {
                DA.SetData(2, GetLogSnapshot());
                if (!string.IsNullOrEmpty(_lastResult))
                {
                    DA.SetData(0, _lastResult);
                    DA.SetData(1, _lastStatus);
                    Message = $"\u2713 {_lastComputeTime:F1} s (cached)";
                }
                else
                {
                    Message = "Ready";
                    AddRuntimeMessage(GH_RuntimeMessageLevel.Remark,
                        "Connect a Button to Run and click it to send the request.");
                }
                return;
            }

            // ── 5. Check for unchanged inputs ──
            var geo = geoGoo.Value;
            var prms = paramsGoo.Value;
            string geoHash = geo.ComputeHash();
            string paramsHash = prms.ComputeHash();

            if (geoHash == _lastGeoHash && paramsHash == _lastParamsHash
                && !string.IsNullOrEmpty(_lastResult))
            {
                DA.SetData(0, _lastResult);
                DA.SetData(1, "cached");
                DA.SetData(2, GetLogSnapshot());
                Message = $"\u2713 {_lastComputeTime:F1} s (cached)";
                AddRuntimeMessage(GH_RuntimeMessageLevel.Remark,
                    "No changes detected \u2014 returning cached result.");
                return;
            }

            // ── 6. Build payload ──
            var payload = geo.ToJson();
            payload["params"] = prms.ToJson();

            if (geoHash == _lastGeoHash && paramsHash != _lastParamsHash)
                payload["geometry_hash"] = geoHash;

            string jsonBody = payload.ToString();

            // ── 7. Launch async: health check → wait for API → POST /design → poll if queued ──
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
                        AppendLog(doc, "✗ Health check failed.");
                        _pendingError = $"Julia server not running at {url}.\n" +
                            "Start it with:\n  julia --project=StructuralSynthesizer scripts/api/sizer_service.jl";
                        _state = RunState.Error;
                        ScheduleExpire(doc);
                        return;
                    }
                    AppendLog(doc, "Server reachable. Waiting for API ready (cold start may take ~1 min)...");

                    _state = RunState.Polling;
                    ScheduleExpire(doc);
                    UpdateWaitStatus(doc, "Waiting for API ready...", 0);
                    // No practical timeout (1 h cap); user can Cancel from the component menu if needed
                    string readyBody = await PollUntilReady(url, 3600, elapsed => UpdateWaitStatus(doc, "Waiting for API ready...", elapsed), () => _cancelRequested);
                    ClearWaitStatus();
                    if (readyBody.Contains("Cancelled by user"))
                    {
                        AppendLog(doc, "✗ Cancelled by user.");
                        _pendingError = "Cancelled by user.";
                        _state = RunState.Error;
                        ScheduleExpire(doc);
                        return;
                    }
                    if (readyBody.Contains("Timeout waiting for server"))
                    {
                        AppendLog(doc, "✗ Timeout waiting for API (1 h).");
                        _pendingError = "Server did not become ready within 1 hour. Check server logs or try Cancel and run again.";
                        _state = RunState.Error;
                        ScheduleExpire(doc);
                        return;
                    }
                    AppendLog(doc, "API ready. Sending design request...");

                    _state = RunState.Sending;
                    ScheduleExpire(doc);

                    string responseJson = await PostDesign(url, jsonBody);

                    string status = "ok";
                    double computeTime = 0;

                    try
                    {
                        var jobj = JObject.Parse(responseJson);
                        status = jobj["status"]?.ToString() ?? "unknown";
                        computeTime = jobj["compute_time_s"]?.ToObject<double>() ?? 0;

                        if (status == "queued")
                        {
                            AppendLog(doc, "Design queued. Waiting for server to become idle...");
                            _state = RunState.Polling;
                            ScheduleExpire(doc);
                            UpdateWaitStatus(doc, "Waiting for server idle...", 0);
                            string idleBody = await PollUntilReady(url, 3600, elapsed => UpdateWaitStatus(doc, "Waiting for server idle...", elapsed), () => _cancelRequested);
                            ClearWaitStatus();
                            if (idleBody.Contains("Cancelled by user"))
                            {
                                AppendLog(doc, "✗ Cancelled by user.");
                                _pendingError = "Cancelled by user.";
                                _state = RunState.Error;
                                ScheduleExpire(doc);
                                return;
                            }
                            AppendLog(doc, "Resubmitting to get design result...");
                            responseJson = await PostDesign(url, jsonBody);
                            var result = JObject.Parse(responseJson);
                            status = result["status"]?.ToString() ?? "unknown";
                            computeTime = result["compute_time_s"]?.ToObject<double>() ?? 0;
                        }
                    }
                    catch { /* parse errors are surfaced via status */ }

                    _pendingResult = responseJson;
                    _pendingStatus = status;
                    _pendingTime = computeTime;
                    if (status == "ok")
                        AppendLog(doc, $"✓ Done in {computeTime:F1} s.");
                    else
                        AppendLog(doc, $"Response status: {status}");
                    _state = RunState.Done;
                }
                catch (TaskCanceledException)
                {
                    AppendLog(doc, "✗ Request timed out.");
                    _pendingError = $"Request timed out after {_client.Timeout.TotalSeconds:F0}s. " +
                        "The server may still be computing — check its terminal.";
                    _state = RunState.Error;
                }
                catch (HttpRequestException ex)
                {
                    AppendLog(doc, "✗ Connection failed: " + ex.Message);
                    _pendingError = $"Connection failed: {ex.Message}\n" +
                        $"Is the Julia server running at {url}?\n" +
                        "Start it with:\n  julia --project=StructuralSynthesizer scripts/api/sizer_service.jl";
                    _state = RunState.Error;
                }
                catch (Exception ex)
                {
                    AppendLog(doc, "✗ Error: " + ex.Message);
                    _pendingError = $"Unexpected error: {ex.Message}";
                    _state = RunState.Error;
                }

                ScheduleExpire(doc);
            });

            DA.SetData(2, GetLogSnapshot());
            if (!string.IsNullOrEmpty(_lastResult))
            {
                DA.SetData(0, _lastResult);
                DA.SetData(1, _lastStatus);
            }
        }

        // ─── Thread-safe solution expiry ─────────────────────────────────

        private void ScheduleExpire(GH_Document? doc)
        {
            if (doc == null) return;
            doc.ScheduleSolution(100, d =>
            {
                ExpireSolution(false);
            });
        }

        // ─── HTTP helpers ────────────────────────────────────────────────

        /// <summary>
        /// Quick health check — returns true if the server responds to GET /health
        /// within 3 seconds.
        /// </summary>
        private static async Task<bool> CheckHealth(string baseUrl)
        {
            try
            {
                using var cts = new CancellationTokenSource(TimeSpan.FromSeconds(3));
                var resp = await _client.GetAsync(
                    $"{baseUrl.TrimEnd('/')}/health", cts.Token);
                return resp.IsSuccessStatusCode;
            }
            catch
            {
                return false;
            }
        }

        /// <summary>
        /// POST /design. Throws if response is not success (e.g. 404 during warming, 400 validation).
        /// </summary>
        private static async Task<string> PostDesign(string baseUrl, string jsonBody)
        {
            var content = new StringContent(jsonBody, Encoding.UTF8, "application/json");
            var response = await _client.PostAsync($"{baseUrl.TrimEnd('/')}/design", content);
            var body = await response.Content.ReadAsStringAsync();
            if (!response.IsSuccessStatusCode)
            {
                throw new InvalidOperationException(
                    $"Server returned {(int)response.StatusCode} {response.ReasonPhrase}. {body}");
            }
            if (string.IsNullOrWhiteSpace(body))
                throw new InvalidOperationException("Server returned empty response.");
            return body;
        }

        /// <param name="onTick">Optional: called each second with elapsed seconds (1, 2, 3, ...) so the UI can show a timer.</param>
        /// <param name="cancelRequested">Optional: when true, stop waiting and return a "Cancelled by user" body.</param>
        private static async Task<string> PollUntilReady(string baseUrl, int timeoutSeconds, Action<int> onTick = null, Func<bool> cancelRequested = null)
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
                }
                catch { /* retry */ }
            }
            return "{\"status\":\"error\",\"message\":\"Timeout waiting for server\"}";
        }

        // ─── Helpers ─────────────────────────────────────────────────────

        private static string ExtractErrorMessage(string json)
        {
            try
            {
                var jobj = JObject.Parse(json);
                return jobj["message"]?.ToString() ?? "Unknown server error";
            }
            catch
            {
                return "Server returned an error.";
            }
        }
    }
}
