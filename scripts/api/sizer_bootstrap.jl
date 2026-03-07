# =============================================================================
# Sizer API — Lightweight bootstrap server
# =============================================================================
#
# Binds to the port immediately with minimal routes (/health, /status) so
# health checks pass quickly. Loads StructuralSynthesizer and full API in the
# background; /design, /validate, /schema become available when ready.
#
# Usage: julia --project=StructuralSynthesizer scripts/api/sizer_bootstrap.jl
#
# Env: PORT or SIZER_PORT, SIZER_HOST (default 0.0.0.0)
# =============================================================================

ENV["SS_ENABLE_VISUALIZATION"] = get(ENV, "SS_ENABLE_VISUALIZATION", "false")
ENV["SS_ENABLE_HEAVY_PRECOMPILE_WORKLOAD"] = get(ENV, "SS_ENABLE_HEAVY_PRECOMPILE_WORKLOAD", "false")

using Oxygen
using HTTP

const PORT = parse(Int, get(ENV, "PORT", get(ENV, "SIZER_PORT", "8080")))
const HOST = get(ENV, "SIZER_HOST", "0.0.0.0")

# Status callback: "warming" until full app is loaded, then delegates to API.
const STATUS_FN = Ref{Function}(() -> "warming")

@get "/health" function (_)
    # Health check only: always 200 so load balancers see "up".
    return HTTP.Response(200, ["Content-Type" => "application/json"], "{\"status\":\"ok\"}")
end

@get "/status" function (_)
    # "warming" → still loading; then "idle" / "running" / "queued" or "error".
    s = STATUS_FN[]()
    msg = s == "warming" ? "Full API not ready yet" : "ready"
    body = "{\"status\":\"$(s)\",\"message\":\"$(msg)\"}"
    return HTTP.Response(200, ["Content-Type" => "application/json"], body)
end

# Load full app in background so first connection is fast.
@async begin
    try
        @info "Loading StructuralSynthesizer (first request may be slow)..."
        using StructuralSynthesizer
        register_routes!()
        STATUS_FN[] = () -> StructuralSynthesizer.status_string(StructuralSynthesizer.SERVER_STATUS)
        @info "StructuralSynthesizer loaded; POST /design, /validate, GET /schema ready"
    catch e
        @error "Failed to load StructuralSynthesizer" exception=(e, catch_backtrace())
        STATUS_FN[] = () -> "error"
    end
end

@info "Sizer API bootstrap listening on http://$HOST:$PORT (GET /health, /status ready)"
serve(; host=HOST, port=PORT)
