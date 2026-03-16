using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Net.Http;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using System.Windows.Forms;
using Grasshopper.Kernel;
using Newtonsoft.Json.Linq;
using Menegroth.GH.Config;
using Menegroth.GH.Helpers;
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
        // ─── Persisted state ────────────────────────────────────────────
        private string _serverUrl = MenegrothConfig.DefaultServerUrl;
        private bool _enableVisualization = true;
        /// <summary>Report units override: null = use DesignParams, "imperial" or "metric" = force.</summary>
        private string _reportUnitsOverride = null;

        // ─── Cached results ─────────────────────────────────────────────
        private string _lastGeoHash = "";
        private string _lastParamsHash = "";
        private DesignResult _lastParsed;
        private string _lastReport = "";
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
        private string _pendingReport = "";
        private string _lastReportUnitsOverride = null;  // units used when _lastReport was fetched
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
                   "Menegroth", "  Analysis")
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

            pManager.AddTextParameter("Server URL", "ServerUrl",
                "Julia API server URL (persisted in right-click menu)",
                GH_ParamAccess.item, MenegrothConfig.DefaultServerUrl);

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
            pManager.AddIntegerParameter("Failure Count", "FailureCount",
                "Number of failing elements in the latest result", GH_ParamAccess.item);
            pManager.AddTextParameter("Failure Messages", "FailureMessages",
                "Per-element failure messages from the latest result", GH_ParamAccess.list);
            pManager.AddTextParameter("Report", "Report",
                "Engineering report for design review (wire to Panel)", GH_ParamAccess.item);
        }

        // ─── Right-click menu ───────────────────────────────────────────

        protected override void AppendAdditionalComponentMenuItems(ToolStripDropDown menu)
        {
            base.AppendAdditionalComponentMenuItems(menu);
            Menu_AppendSeparator(menu);

            var resetItem = Menu_AppendItem(menu, "Reset Cache", OnResetCache);
            resetItem.ToolTipText = "Clear cached results and force a fresh analysis run";

            var vizItem = Menu_AppendItem(menu, "Enable Visualization", OnToggleVisualization, true, _enableVisualization);
            vizItem.ToolTipText = "When off, skip shell mesh build and visualization (faster response, no deflected slabs)";

            var reportUnitsMenu = new ToolStripMenuItem("Report Units");
            reportUnitsMenu.ToolTipText = "Override units for the engineering report; default uses DesignParams";
            var useParamsItem = Menu_AppendItem(reportUnitsMenu.DropDown, "Use DesignParams", (s, e) => OnReportUnits(null), true, _reportUnitsOverride == null);
            var imperialItem = Menu_AppendItem(reportUnitsMenu.DropDown, "Imperial", (s, e) => OnReportUnits("imperial"), true, _reportUnitsOverride == "imperial");
            var metricItem = Menu_AppendItem(reportUnitsMenu.DropDown, "Metric", (s, e) => OnReportUnits("metric"), true, _reportUnitsOverride == "metric");
            menu.Items.Add(reportUnitsMenu);

            var cancelItem = Menu_AppendItem(menu, "Cancel", OnCancel);
            cancelItem.ToolTipText = "Cancel the current request (waiting for API or design)";
        }

        private void OnToggleVisualization(object sender, EventArgs e)
        {
            var item = sender as ToolStripMenuItem;
            if (item != null)
            {
                _enableVisualization = !_enableVisualization;
                item.Checked = _enableVisualization;
                Message = _enableVisualization ? "" : "Viz off";
                ExpireSolution(true);
            }
        }

        private void OnReportUnits(string overrideValue)
        {
            _reportUnitsOverride = overrideValue;
            Message = string.IsNullOrEmpty(overrideValue) ? "" : $"Report: {overrideValue}";
            ExpireSolution(true);
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
            _lastReport = "";
            _lastReportUnitsOverride = null;
            _lastComputeTime = 0;
            lock (_logLock) { _statusLog.Clear(); _waitStatusLine = null; }
            Message = "Cache cleared";
            ExpireSolution(true);
        }

        // ─── Persistence ────────────────────────────────────────────────

        public override bool Write(GH_IO.Serialization.GH_IWriter writer)
        {
            writer.SetString("ServerUrl", _serverUrl);
            writer.SetBoolean("EnableVisualization", _enableVisualization);
            if (!string.IsNullOrEmpty(_reportUnitsOverride))
                writer.SetString("ReportUnitsOverride", _reportUnitsOverride);
            return base.Write(writer);
        }

        public override bool Read(GH_IO.Serialization.GH_IReader reader)
        {
            if (reader.ItemExists("ServerUrl"))
                _serverUrl = reader.GetString("ServerUrl");
            if (reader.ItemExists("EnableVisualization"))
                _enableVisualization = reader.GetBoolean("EnableVisualization");
            if (reader.ItemExists("ReportUnitsOverride"))
                _reportUnitsOverride = reader.GetString("ReportUnitsOverride");
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

        /// <summary>
        /// Appends the current wait line (including final elapsed time) to the log, then clears it.
        /// Keeps lines like "Waiting for API ready... (107 s)" in the log after the wait finishes.
        /// </summary>
        private void CommitWaitStatus(GH_Document doc)
        {
            lock (_logLock)
            {
                if (!string.IsNullOrEmpty(_waitStatusLine))
                {
                    if (_statusLog.Length > 0) _statusLog.AppendLine();
                    _statusLog.Append(_waitStatusLine);
                    _waitStatusLine = null;
                }
            }
            ScheduleExpire(doc);
        }

        private void ClearWaitStatus()
        {
            lock (_logLock) { _waitStatusLine = null; }
        }

        /// <summary>
        /// Appends a stage completion line with elapsed time, e.g. "✓ Health check (0.3 s)".
        /// </summary>
        private void AppendStageDone(GH_Document doc, string stageName, Stopwatch sw)
        {
            sw.Stop();
            AppendLog(doc, $"\u2713 {stageName} ({sw.Elapsed.TotalSeconds:F1} s)");
        }

        /// <summary>
        /// Appends server phase timings to the log (prepare, pipeline, capture, etc.).
        /// </summary>
        private void AppendPhaseTimings(GH_Document doc, DesignResult result)
        {
            if (result?.PhaseTimings == null || result.PhaseTimings.Count == 0)
                return;
            var order = new[] { "prepare", "pipeline", "capture", "analysis_model", "restore", "serialize_visualization" };
            foreach (var phase in order)
            {
                if (result.PhaseTimings.TryGetValue(phase, out var sec))
                    AppendLog(doc, $"  {phase}: {sec:F1} s");
            }
        }

        // ─── Solve ──────────────────────────────────────────────────────

        protected override void SolveInstance(IGH_DataAccess DA)
        {
            // 1. Read inputs
            BuildingGeometryGoo geoGoo = null;
            DesignParamsDataGoo paramsGoo = null;
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
                _lastReport = _pendingReport;
                _lastReportUnitsOverride = _reportUnitsOverride;
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
                SetFailureOutputs(DA, _lastParsed);
                if (_lastParsed != null)
                {
                    DA.SetData(0, new DesignResultGoo(_lastParsed));
                    DA.SetData(1, _lastParsed.RawJson);
                }
                if (!string.IsNullOrEmpty(_lastReport))
                    DA.SetData(5, _lastReport);
                return;
            }

            // 4. Run = false → cached or ready
            if (!run)
            {
                DA.SetData(2, GetLogSnapshot());
                SetFailureOutputs(DA, _lastParsed);
                if (_lastParsed != null)
                {
                    DA.SetData(0, new DesignResultGoo(_lastParsed));
                    DA.SetData(1, _lastParsed.RawJson);
                    Message = FormatDoneMessage(_lastParsed) + " (cached)";
                }
                else
                {
                    Message = "Ready";
                    AddRuntimeMessage(GH_RuntimeMessageLevel.Remark,
                        "Connect a Button to Run and click it to send the request.");
                }
                if (!string.IsNullOrEmpty(_lastReport))
                    DA.SetData(5, _lastReport);
                return;
            }

            // 5. Check for unchanged inputs
            var geo = geoGoo.Value;
            var prms = paramsGoo.Value;
            string geoHash = geo.ComputeHash();
            string paramsHash = prms.ComputeHash() + (_enableVisualization ? "" : "|noviz");

            if (geoHash == _lastGeoHash && paramsHash == _lastParamsHash && _lastParsed != null)
            {
                // If report units changed, re-fetch report in background
                if (_reportUnitsOverride != _lastReportUnitsOverride)
                {
                    var urlForReport = string.IsNullOrWhiteSpace(urlInput) ? _serverUrl : urlInput;
                    var unitsToFetch = _reportUnitsOverride;
                    var docForReport = OnPingDocument();
                    Task.Run(async () =>
                    {
                        try
                        {
                            var report = await DesignRunHttpClient.GetReportAsync(urlForReport, default, unitsToFetch);
                            _lastReport = report;
                            _lastReportUnitsOverride = unitsToFetch;
                            ScheduleExpire(docForReport);
                        }
                        catch { /* Non-critical */ }
                    });
                }

                DA.SetData(0, new DesignResultGoo(_lastParsed));
                DA.SetData(1, _lastParsed.RawJson);
                DA.SetData(2, GetLogSnapshot());
                SetFailureOutputs(DA, _lastParsed);
                if (!string.IsNullOrEmpty(_lastReport))
                    DA.SetData(5, _lastReport);
                Message = FormatDoneMessage(_lastParsed) + " (cached)";
                AddRuntimeMessage(GH_RuntimeMessageLevel.Remark,
                    "No changes detected \u2014 returning cached result.");
                return;
            }

            // 6. Client-side validation (instant feedback, no network needed)
            var validationErrors = DesignRunValidator.Validate(geo, prms);
            if (validationErrors.Count > 0)
            {
                foreach (var err in validationErrors)
                    AddRuntimeMessage(GH_RuntimeMessageLevel.Error, err);
                lock (_logLock) { _statusLog.Clear(); }
                AppendLog(OnPingDocument(), $"\u2717 Geometry/params validation failed ({validationErrors.Count} error{(validationErrors.Count > 1 ? "s" : "")}) — not calling API:");
                foreach (var err in validationErrors)
                    AppendLog(OnPingDocument(), "  \u2022 " + err);
                DA.SetData(2, GetLogSnapshot());
                DA.SetData(3, validationErrors.Count);
                DA.SetDataList(4, validationErrors);
                Message = $"\u2717 {validationErrors.Count} validation error{(validationErrors.Count > 1 ? "s" : "")}";
                return;
            }

            // 7. Build payload
            var payload = geo.ToJson();
            var paramsJson = prms.ToJson();
            paramsJson["geometry_is_centerline"] = geo.GeometryIsCenterline;
            paramsJson["skip_visualization"] = !_enableVisualization;
            payload["params"] = paramsJson;
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

            var reportUnits = _reportUnitsOverride;
            Task.Run(async () =>
            {
                var runSw = Stopwatch.StartNew();
                var logPollCts = new CancellationTokenSource();
                var logPollTask = Task.Run(async () =>
                {
                    int since = 0;
                    while (!logPollCts.Token.IsCancellationRequested)
                    {
                        try
                        {
                            var (nextSince, lines) = await DesignRunHttpClient.GetServerLogsAsync(url, since, logPollCts.Token);
                            since = nextSince;
                            foreach (var line in lines)
                                AppendLog(doc, $"[server] {line}");
                        }
                        catch
                        {
                            // Keep polling; transient log endpoint failures should not fail design runs.
                        }

                        try { await Task.Delay(1000, logPollCts.Token); }
                        catch (OperationCanceledException) { break; }
                    }
                }, logPollCts.Token);

                try
                {
                    var healthSw = Stopwatch.StartNew();
                    if (!await DesignRunHttpClient.CheckHealthAsync(url, logPollCts.Token))
                    {
                        AppendLog(doc, "\u2717 Health check failed.");
                        _pendingError = $"Julia server not running at {url}.\n" +
                            "Start it with:\n  julia --project=StructuralSynthesizer scripts/api/sizer_service.jl";
                        _state = RunState.Error;
                        ScheduleExpire(doc);
                        return;
                    }
                    AppendStageDone(doc, "Health check", healthSw);
                    AppendLog(doc, "Waiting for API ready (cold start may take up to ~10 min)...");

                    _state = RunState.Polling;
                    ScheduleExpire(doc);
                    UpdateWaitStatus(doc, "Waiting for API ready...", 0);
                    string readyBody = await DesignRunHttpClient.PollUntilReadyAsync(url, MenegrothConfig.PollTimeoutSeconds,
                        elapsed => UpdateWaitStatus(doc, "Waiting for API ready...", elapsed),
                        () => _cancelRequested, logPollCts.Token);
                    CommitWaitStatus(doc);

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
                    if (readyBody.Contains("\"state\":\"error\"") || readyBody.Contains("\"status\":\"error\""))
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
                    var sendSw = Stopwatch.StartNew();
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
                        responseJson = await DesignRunHttpClient.PostDesignAsync(url, jsonBody, designCts.Token);
                    }
                    finally
                    {
                        designCts.Cancel();
                        try { await timerTask; }
                        catch (OperationCanceledException) { }
                        CommitWaitStatus(doc);
                        AppendStageDone(doc, "Design request sent", sendSw);
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
                        string idleBody = await DesignRunHttpClient.PollUntilReadyAsync(url, MenegrothConfig.PollTimeoutSeconds,
                            elapsed => UpdateWaitStatus(doc, "Waiting for design to complete...", elapsed),
                            () => _cancelRequested, logPollCts.Token);
                        CommitWaitStatus(doc);

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

                        AppendLog(doc, "Server idle. Waiting for result cache...");
                        var cacheSw = Stopwatch.StartNew();
                        await DesignRunHttpClient.WaitForResultReadyAsync(url, logPollCts.Token);
                        AppendStageDone(doc, "Result cache ready", cacheSw);
                        AppendLog(doc, "Fetching design result...");
                        var fetchSw = Stopwatch.StartNew();
                        responseJson = await DesignRunHttpClient.GetResultWithRetryAsync(url, logPollCts.Token);
                        AppendStageDone(doc, "Result fetched", fetchSw);
                    }

                    // Parse the final response into a typed result
                    _pendingParsed = DesignResult.FromJson(responseJson);

                    if (_pendingParsed.IsError)
                        AppendLog(doc, $"\u2717 Server returned error: {_pendingParsed.ErrorMessage}");
                    else
                    {
                        AppendLog(doc, $"\u2713 Server compute: {_pendingParsed.ComputeTime:F1} s.");
                        runSw.Stop();
                        AppendLog(doc, $"\u2713 Total client time: {runSw.Elapsed.TotalSeconds:F1} s.");
                        AppendPhaseTimings(doc, _pendingParsed);
                    }

                    // Fetch engineering report (non-blocking; empty string on failure)
                    _pendingReport = "";
                    if (!_pendingParsed.IsError)
                    {
                        try
                        {
                            _pendingReport = await DesignRunHttpClient.GetReportAsync(url, logPollCts.Token, reportUnits);
                            if (!string.IsNullOrEmpty(_pendingReport))
                                AppendLog(doc, "\u2713 Engineering report fetched.");
                        }
                        catch { /* Report is non-critical; proceed without it. */ }
                    }

                    _state = RunState.Done;
                }
                catch (OperationCanceledException)
                {
                    AppendLog(doc, "\u2717 Cancelled by user.");
                    _pendingError = "Cancelled by user.";
                    _state = RunState.Error;
                }
                catch (DesignRunHttpException ex)
                {
                    AppendLog(doc, "\u2717 " + ex.Message);
                    _pendingError = ex.Message;
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
                finally
                {
                    logPollCts.Cancel();
                    try { await logPollTask; }
                    catch (OperationCanceledException) { }
                }

                ScheduleExpire(doc);
            });

            DA.SetData(2, GetLogSnapshot());
            SetFailureOutputs(DA, _lastParsed);
            if (_lastParsed != null)
            {
                DA.SetData(0, new DesignResultGoo(_lastParsed));
                DA.SetData(1, _lastParsed.RawJson);
            }
            if (!string.IsNullOrEmpty(_lastReport))
                DA.SetData(5, _lastReport);
        }

        // ─── Output helper ──────────────────────────────────────────────

        private void EmitResult(IGH_DataAccess DA, DesignResult result)
        {
            DA.SetData(2, GetLogSnapshot());
            SetFailureOutputs(DA, result);
            if (result != null)
            {
                DA.SetData(0, new DesignResultGoo(result));
                DA.SetData(1, result.RawJson);
                if (result.IsError)
                    AddRuntimeMessage(GH_RuntimeMessageLevel.Error, result.ErrorMessage);
            }
            if (!string.IsNullOrEmpty(_lastReport))
                DA.SetData(5, _lastReport);
        }

        private static void SetFailureOutputs(IGH_DataAccess DA, DesignResult result)
        {
            if (result == null || result.IsError)
            {
                DA.SetData(3, 0);
                DA.SetDataList(4, new List<string>());
                return;
            }

            var failures = CollectFailureMessages(result);
            DA.SetData(3, failures.Count);
            DA.SetDataList(4, failures);
        }

        private static List<string> CollectFailureMessages(DesignResult result)
        {
            var failures = new List<string>();

            foreach (var s in result.Slabs)
            {
                if (s.Ok) continue;
                failures.Add(string.IsNullOrWhiteSpace(s.FailureReason)
                    ? $"Slab {s.Id}: deflection={s.DeflectionRatio:F2}, punching={s.PunchingMaxRatio:F2}"
                    : $"Slab {s.Id}: {s.FailureReason}");
            }

            foreach (var c in result.Columns)
                if (!c.Ok) failures.Add($"Column {c.Id}: interaction={c.InteractionRatio:F2}, axial={c.AxialRatio:F2}");
            foreach (var b in result.Beams)
                if (!b.Ok) failures.Add($"Beam {b.Id}: flexure={b.FlexureRatio:F2}, shear={b.ShearRatio:F2}");
            foreach (var f in result.Foundations)
                if (!f.Ok) failures.Add($"Foundation {f.Id}: bearing={f.BearingRatio:F2}");

            return failures;
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
            doc.ScheduleSolution(MenegrothConfig.ScheduleSolutionIntervalMs, _ => ExpireSolution(false));
        }
    }
}
