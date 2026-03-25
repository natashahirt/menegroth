using System;
using System.Collections.Generic;
using System.Net;
using System.Net.Http;
using System.Net.Http.Headers;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using Menegroth.GH.Config;
using Newtonsoft.Json.Linq;

namespace Menegroth.GH.Helpers
{
    /// <summary>
    /// HTTP client for the Menegroth Julia sizing API.
    /// Handles health checks, design submission, result retrieval, and status polling.
    /// Supports gzip/deflate decompression when the server sends compressed responses.
    /// </summary>
    public static class DesignRunHttpClient
    {
        private static readonly HttpClient Client = new HttpClient(
            new HttpClientHandler { AutomaticDecompression = DecompressionMethods.GZip | DecompressionMethods.Deflate })
        {
            Timeout = MenegrothConfig.HttpClientTimeout
        };

        /// <summary>
        /// Adds Authorization: Bearer when MENEGROTH_API_KEY is set on the server.
        /// Uses MenegrothConfig.LastApiKey (set by DesignRun).
        /// </summary>
        private static void AddAuthHeader(HttpRequestMessage request)
        {
            var key = MenegrothConfig.LastApiKey;
            if (!string.IsNullOrEmpty(key))
                request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", key);
        }

        public static async Task<bool> CheckHealthAsync(string baseUrl, CancellationToken cancellationToken = default)
        {
            const int maxRetries = 5;
            const int retryDelayMs = 500;

            for (int attempt = 0; attempt <= maxRetries; attempt++)
            {
                cancellationToken.ThrowIfCancellationRequested();
                try
                {
                    using var cts = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
                    cts.CancelAfter(TimeSpan.FromSeconds(MenegrothConfig.HealthCheckTimeoutSeconds));
                    using var req = new HttpRequestMessage(HttpMethod.Get, NormalizeUrl(baseUrl, "health"));
                    AddAuthHeader(req);
                    var resp = await Client.SendAsync(req, cts.Token);
                    if (resp.IsSuccessStatusCode)
                        return true;
                }
                catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested)
                {
                    // Local per-attempt timeout: retry up to maxRetries.
                }
                catch (OperationCanceledException)
                {
                    throw;
                }
                catch
                {
                    // Transient network errors: retry up to maxRetries.
                }

                if (attempt < maxRetries)
                    await Task.Delay(retryDelayMs, cancellationToken);
            }

            return false;
        }

        public static async Task<string> PostDesignAsync(string baseUrl, string jsonBody, CancellationToken cancellationToken = default)
        {
            var content = new StringContent(jsonBody, Encoding.UTF8, "application/json");
            using var req = new HttpRequestMessage(HttpMethod.Post, NormalizeUrl(baseUrl, "design")) { Content = content };
            AddAuthHeader(req);
            var response = await Client.SendAsync(req, cancellationToken);
            var body = await response.Content.ReadAsStringAsync();
            if (!response.IsSuccessStatusCode)
                throw new DesignRunHttpException(
                    $"Server returned {(int)response.StatusCode} {response.ReasonPhrase}. {body}");
            if (string.IsNullOrWhiteSpace(body))
                throw new DesignRunHttpException("Server returned empty response.");
            return body;
        }

        /// <summary>
        /// Fetches the design result with retries. Retries on 503 (design still running) and 404
        /// (result not yet cached — race between idle state and last_result visibility).
        /// </summary>
        public static async Task<string> GetResultWithRetryAsync(string baseUrl, CancellationToken cancellationToken = default)
        {
            const int maxRetries = 15;
            const int retryDelayMs = 1000;

            for (int attempt = 1; attempt <= maxRetries; attempt++)
            {
                cancellationToken.ThrowIfCancellationRequested();

                using var req = new HttpRequestMessage(HttpMethod.Get, NormalizeUrl(baseUrl, "result"));
                AddAuthHeader(req);
                var response = await Client.SendAsync(req, cancellationToken);
                var body = await response.Content.ReadAsStringAsync();

                if (response.IsSuccessStatusCode)
                {
                    if (string.IsNullOrWhiteSpace(body))
                        throw new DesignRunHttpException("Server returned empty result from GET /result.");
                    return body;
                }

                // 503: design still in progress — retry
                // 404: idle but result not yet cached (race) — retry to allow cache write to complete
                if (((int)response.StatusCode == 503 || (int)response.StatusCode == 404) && attempt < maxRetries)
                {
                    await Task.Delay(retryDelayMs, cancellationToken);
                    continue;
                }

                throw new DesignRunHttpException(
                    $"GET /result failed: {(int)response.StatusCode} {response.ReasonPhrase}. {body}");
            }

            throw new DesignRunHttpException("GET /result failed after retries.");
        }

        /// <summary>
        /// After seeing idle, polls /status until has_result is true (handles race where
        /// state becomes idle before last_result is cached). Max wait ~5 s.
        /// </summary>
        public static async Task WaitForResultReadyAsync(string baseUrl, CancellationToken cancellationToken = default)
        {
            const int maxAttempts = 10;
            const int delayMs = 500;

            for (int i = 0; i < maxAttempts; i++)
            {
                cancellationToken.ThrowIfCancellationRequested();

                using (var req = new HttpRequestMessage(HttpMethod.Get, NormalizeUrl(baseUrl, "status")))
                {
                    AddAuthHeader(req);
                    var resp = await Client.SendAsync(req, cancellationToken);
                    var body = await resp.Content.ReadAsStringAsync();
                    if (string.IsNullOrWhiteSpace(body))
                    {
                        await Task.Delay(delayMs, cancellationToken);
                        continue;
                    }
                    try
                    {
                        var jobj = JObject.Parse(body);
                        bool hasResult = jobj["has_result"]?.ToObject<bool>() ?? false;
                        if (hasResult)
                            return;
                    }
                    catch
                    {
                        // Invalid JSON (e.g. proxy error page) — retry
                    }
                }

                await Task.Delay(delayMs, cancellationToken);
            }
        }

        /// <summary>
        /// Poll /status until state is "idle" or timeout/cancel.
        /// Returns the response body; check for "Cancelled by user" or "Timeout waiting for server" in the message.
        /// </summary>
        public static async Task<string> PollUntilReadyAsync(
            string baseUrl,
            int timeoutSeconds,
            Action<int> onTick,
            Func<bool> cancelRequested,
            CancellationToken cancellationToken = default)
        {
            var start = DateTime.UtcNow;
            var deadline = start.AddSeconds(timeoutSeconds);
            int lastTick = 0;

            while (DateTime.UtcNow < deadline)
            {
                try
                {
                    await Task.Delay(1000, cancellationToken);
                }
                catch (OperationCanceledException)
                {
                    return "{\"status\":\"error\",\"message\":\"Cancelled by user\"}";
                }

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
                    using var req = new HttpRequestMessage(HttpMethod.Get, NormalizeUrl(baseUrl, "status"));
                    AddAuthHeader(req);
                    var resp = await Client.SendAsync(req, cancellationToken);
                    var body = await resp.Content.ReadAsStringAsync();
                    if (!string.IsNullOrWhiteSpace(body))
                    {
                        var jobj = JObject.Parse(body);
                        string st = jobj["state"]?.ToString() ?? "";
                        if (st == "idle")
                            return body;
                        if (st == "error")
                            return "{\"state\":\"error\",\"message\":\"Server reported an error during startup. Check server logs.\"}";
                    }
                }
                catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested)
                {
                    // Request-level timeout (or similar) without explicit cancel: retry until overall deadline.
                }
                catch (OperationCanceledException)
                {
                    return "{\"status\":\"error\",\"message\":\"Cancelled by user\"}";
                }
                catch
                {
                    /* retry on transient network errors or invalid JSON */
                }
            }

            return "{\"state\":\"error\",\"message\":\"Timeout waiting for server\"}";
        }

        public static async Task<(int nextSince, List<string> lines)> GetServerLogsAsync(string baseUrl, int since, CancellationToken cancellationToken = default)
        {
            using var req = new HttpRequestMessage(HttpMethod.Get, $"{baseUrl.TrimEnd('/')}/logs?since={since}");
            AddAuthHeader(req);
            var response = await Client.SendAsync(req, cancellationToken);
            if (!response.IsSuccessStatusCode)
                return (since, new List<string>());

            var body = await response.Content.ReadAsStringAsync();
            if (string.IsNullOrWhiteSpace(body))
                return (since, new List<string>());

            try
            {
                var obj = JObject.Parse(body);
                int next = obj["next_since"]?.ToObject<int>() ?? since;
                var lines = new List<string>();
                if (obj["lines"] is JArray arr)
                {
                    foreach (var token in arr)
                    {
                        var line = token?.ToString();
                        if (!string.IsNullOrWhiteSpace(line))
                            lines.Add(line);
                    }
                }
                return (next, lines);
            }
            catch
            {
                return (since, new List<string>());
            }
        }

        /// <summary>
        /// Asks the server to rebuild the visualization mesh at a new target edge length.
        /// Returns the raw JSON response containing only the new visualization payload.
        /// </summary>
        public static async Task<string> PostRebuildVisualizationAsync(
            string baseUrl, double targetEdgeM, CancellationToken cancellationToken = default)
        {
            var body = $"{{\"target_edge_m\":{targetEdgeM}}}";
            var content = new StringContent(body, Encoding.UTF8, "application/json");
            using var req = new HttpRequestMessage(HttpMethod.Post, NormalizeUrl(baseUrl, "rebuild_visualization")) { Content = content };
            AddAuthHeader(req);
            var response = await Client.SendAsync(req, cancellationToken);
            var respBody = await response.Content.ReadAsStringAsync();
            if (!response.IsSuccessStatusCode)
                throw new DesignRunHttpException(
                    $"POST /rebuild_visualization returned {(int)response.StatusCode}: {respBody}");
            return respBody;
        }

        /// <summary>
        /// Fetches the engineering report as plain text from GET /report.
        /// When unitsOverride is "imperial" or "metric", appends ?units= to override DesignParams display units.
        /// Returns the report string, or an empty string if unavailable.
        /// </summary>
        public static async Task<string> GetReportAsync(string baseUrl, CancellationToken cancellationToken = default, string unitsOverride = null)
        {
            try
            {
                var path = "report";
                if (!string.IsNullOrWhiteSpace(unitsOverride) &&
                    (unitsOverride.Equals("imperial", StringComparison.OrdinalIgnoreCase) ||
                     unitsOverride.Equals("metric", StringComparison.OrdinalIgnoreCase)))
                {
                    path = $"report?units={unitsOverride.ToLowerInvariant()}";
                }
                using var req = new HttpRequestMessage(HttpMethod.Get, NormalizeUrl(baseUrl, path));
                AddAuthHeader(req);
                var response = await Client.SendAsync(req, cancellationToken);
                if (!response.IsSuccessStatusCode)
                    return "";
                return await response.Content.ReadAsStringAsync();
            }
            catch
            {
                return "";
            }
        }

        /// <summary>
        /// POST to /chat and read the SSE stream. Invokes <paramref name="onToken"/> for each
        /// content token, <paramref name="onSummary"/> when the <c>agent_turn_summary</c> event
        /// arrives, and <paramref name="onError"/> if the server returns a non-200 or an error
        /// event. The stream ends when the server sends <c>data: [DONE]</c>.
        /// </summary>
        public static async Task PostChatStreamAsync(
            string baseUrl,
            string jsonBody,
            Action<string> onToken,
            Action<string> onError,
            CancellationToken ct,
            Action<JObject>? onSummary = null)
        {
            var content = new StringContent(jsonBody, Encoding.UTF8, "application/json");
            using var req = new HttpRequestMessage(HttpMethod.Post, NormalizeUrl(baseUrl, "chat")) { Content = content };
            AddAuthHeader(req);

            HttpResponseMessage response;
            try
            {
                response = await Client.SendAsync(req, HttpCompletionOption.ResponseHeadersRead, ct);
            }
            catch (Exception ex)
            {
                onError?.Invoke($"Connection failed: {ex.Message}");
                return;
            }

            if (!response.IsSuccessStatusCode)
            {
                var errBody = await response.Content.ReadAsStringAsync();
                onError?.Invoke($"Server returned {(int)response.StatusCode}: {errBody}");
                return;
            }

            using var stream = await response.Content.ReadAsStreamAsync();
            using var reader = new System.IO.StreamReader(stream, Encoding.UTF8);

            while (!reader.EndOfStream)
            {
                ct.ThrowIfCancellationRequested();
                var line = await reader.ReadLineAsync();
                if (string.IsNullOrEmpty(line)) continue;
                if (!line.StartsWith("data: ")) continue;

                var data = line.Substring(6);
                if (data == "[DONE]") break;

                try
                {
                    var obj = JObject.Parse(data);
                    if (obj.TryGetValue("error", out var errToken))
                    {
                        var msg = obj["message"]?.ToString() ?? errToken.ToString();
                        var hint = obj["recovery_hint"]?.ToString();
                        if (!string.IsNullOrWhiteSpace(hint))
                            msg += $"\n  Hint: {hint}";
                        onError?.Invoke(msg);
                        continue;
                    }
                    // Structured summary event emitted by the server after streaming finishes.
                    if (obj["type"]?.ToString() == "agent_turn_summary")
                    {
                        onSummary?.Invoke(obj);
                        continue;
                    }
                    var token = obj["token"]?.ToString();
                    if (token != null) onToken?.Invoke(token);
                }
                catch
                {
                    // Skip unparseable SSE data lines
                }
            }
        }

        /// <summary>
        /// Fetches the compact applicability and compatibility schema from GET /schema/applicability.
        /// Returns null on failure.
        /// </summary>
        public static async Task<JObject?> GetApplicabilitySchemaAsync(string baseUrl, CancellationToken ct = default)
        {
            try
            {
                using var req = new HttpRequestMessage(HttpMethod.Get, NormalizeUrl(baseUrl, "schema/applicability"));
                AddAuthHeader(req);
                var resp = await Client.SendAsync(req, ct);
                if (!resp.IsSuccessStatusCode) return null;
                var body = await resp.Content.ReadAsStringAsync();
                return string.IsNullOrWhiteSpace(body) ? null : JObject.Parse(body);
            }
            catch { return null; }
        }

        /// <summary>
        /// Retrieves stored conversation history for a session from GET /chat/history.
        /// Returns an empty list on failure or when no history exists.
        /// </summary>
        public static async Task<List<JObject>> GetChatHistoryAsync(string baseUrl, string sessionId, CancellationToken ct = default)
        {
            var result = new List<JObject>();
            if (string.IsNullOrWhiteSpace(sessionId)) return result;
            try
            {
                using var req = new HttpRequestMessage(HttpMethod.Get,
                    NormalizeUrl(baseUrl, $"chat/history?session_id={Uri.EscapeDataString(sessionId)}"));
                AddAuthHeader(req);
                var resp = await Client.SendAsync(req, ct);
                if (!resp.IsSuccessStatusCode) return result;
                var body = await resp.Content.ReadAsStringAsync();
                if (string.IsNullOrWhiteSpace(body)) return result;
                var obj = JObject.Parse(body);
                if (obj["messages"] is JArray arr)
                {
                    foreach (var item in arr)
                    {
                        if (item is JObject msg)
                            result.Add(msg);
                    }
                }
            }
            catch { /* return empty on any error */ }
            return result;
        }

        /// <summary>
        /// Clears stored conversation history via DELETE /chat/history.
        /// Pass null or empty to clear all sessions.
        /// </summary>
        public static async Task DeleteChatHistoryAsync(string baseUrl, string? sessionId = null, CancellationToken ct = default)
        {
            try
            {
                var path = string.IsNullOrWhiteSpace(sessionId)
                    ? "chat/history"
                    : $"chat/history?session_id={Uri.EscapeDataString(sessionId!)}";
                using var req = new HttpRequestMessage(HttpMethod.Delete, NormalizeUrl(baseUrl, path));
                AddAuthHeader(req);
                await Client.SendAsync(req, ct);
            }
            catch { /* fire and forget — non-critical */ }
        }

        /// <summary>
        /// POST to /chat/action to invoke a structural tool from the agent.
        /// Returns the parsed JSON response, or null on failure.
        /// </summary>
        public static async Task<JObject?> PostChatActionAsync(
            string baseUrl, string tool, JObject? args = null, CancellationToken ct = default)
        {
            try
            {
                var body = new JObject { ["tool"] = tool };
                if (args != null) body["args"] = args;
                var content = new StringContent(body.ToString(Newtonsoft.Json.Formatting.None), Encoding.UTF8, "application/json");
                using var req = new HttpRequestMessage(HttpMethod.Post, NormalizeUrl(baseUrl, "chat/action")) { Content = content };
                AddAuthHeader(req);
                var resp = await Client.SendAsync(req, ct);
                var respBody = await resp.Content.ReadAsStringAsync();
                return string.IsNullOrWhiteSpace(respBody) ? null : JObject.Parse(respBody);
            }
            catch { return null; }
        }

        private static string NormalizeUrl(string baseUrl, string path)
        {
            return $"{baseUrl.TrimEnd('/')}/{path}";
        }
    }

    /// <summary>
    /// Exception thrown when an API HTTP request fails.
    /// </summary>
    public class DesignRunHttpException : Exception
    {
        public DesignRunHttpException(string message) : base(message) { }
        public DesignRunHttpException(string message, Exception inner) : base(message, inner) { }
    }
}
