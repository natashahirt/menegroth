using System;
using System.Collections.Generic;
using System.Net;
using System.Net.Http;
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

        public static async Task<bool> CheckHealthAsync(string baseUrl, CancellationToken cancellationToken = default)
        {
            try
            {
                using var cts = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
                cts.CancelAfter(TimeSpan.FromSeconds(MenegrothConfig.HealthCheckTimeoutSeconds));
                var resp = await Client.GetAsync(NormalizeUrl(baseUrl, "health"), cts.Token);
                return resp.IsSuccessStatusCode;
            }
            catch (OperationCanceledException)
            {
                throw;
            }
            catch
            {
                return false;
            }
        }

        public static async Task<string> PostDesignAsync(string baseUrl, string jsonBody, CancellationToken cancellationToken = default)
        {
            var content = new StringContent(jsonBody, Encoding.UTF8, "application/json");
            var response = await Client.PostAsync(NormalizeUrl(baseUrl, "design"), content, cancellationToken);
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

                var response = await Client.GetAsync(NormalizeUrl(baseUrl, "result"), cancellationToken);
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

                var resp = await Client.GetAsync(NormalizeUrl(baseUrl, "status"), cancellationToken);
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
                    var resp = await Client.GetAsync(NormalizeUrl(baseUrl, "status"), cancellationToken);
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
            var response = await Client.GetAsync($"{baseUrl.TrimEnd('/')}/logs?since={since}", cancellationToken);
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
                var response = await Client.GetAsync(NormalizeUrl(baseUrl, path), cancellationToken);
                if (!response.IsSuccessStatusCode)
                    return "";
                return await response.Content.ReadAsStringAsync();
            }
            catch
            {
                return "";
            }
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
