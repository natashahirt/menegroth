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

println(stdout, "[bootstrap] starting (JULIA_DEPOT_PATH=$(get(ENV, "JULIA_DEPOT_PATH", "unset")))")
flush(stdout)

# ── Force unbuffered logging to stdout for Docker/App Runner ──────────────────
# Julia's default ConsoleLogger writes to stderr, which AWS App Runner may not
# surface in Application Logs (only stdout appears reliably).  Additionally,
# non-interactive containers block-buffer stderr.  This wrapper sends all
# @info/@warn/@error to stdout and flushes after every message.
using Logging
struct FlushLogger <: AbstractLogger
    inner::ConsoleLogger
end
FlushLogger(io::IO=stdout; kw...) = FlushLogger(ConsoleLogger(io; kw...))
Logging.min_enabled_level(l::FlushLogger) = Logging.min_enabled_level(l.inner)
Logging.shouldlog(l::FlushLogger, args...) = Logging.shouldlog(l.inner, args...)
Logging.catch_exceptions(l::FlushLogger) = Logging.catch_exceptions(l.inner)
function Logging.handle_message(l::FlushLogger, args...; kw...)
    Logging.handle_message(l.inner, args...; kw...)
    flush(stdout)
end
global_logger(FlushLogger(stdout; meta_formatter=Logging.default_metafmt))
println(stdout, "[bootstrap] installed FlushLogger (stdout, auto-flush)")
flush(stdout)

ENV["SS_ENABLE_VISUALIZATION"] = get(ENV, "SS_ENABLE_VISUALIZATION", "false")
ENV["SS_ENABLE_HEAVY_PRECOMPILE_WORKLOAD"] = get(ENV, "SS_ENABLE_HEAVY_PRECOMPILE_WORKLOAD", "false")

using JSON3
include(joinpath(@__DIR__, "..", "..", "StructuralSynthesizer", "src", "api", "llm_secrets.jl"))

# ── LLM chat configuration ───────────────────────────────────────────────────
# Load the OpenAI API key from secrets/openai_api_key if not already set via ENV.
# Prefer a single raw `sk-...` line; `normalize_llm_api_key_secret` also accepts
# `CHAT_LLM_API_KEY=...` or one-line JSON (see llm_secrets.jl).
let key_file = joinpath(@__DIR__, "..", "..", "secrets", "openai_api_key")
    if haskey(ENV, "CHAT_LLM_API_KEY")
        k0 = get(ENV, "CHAT_LLM_API_KEY", "")
        k = normalize_llm_api_key_secret(k0)
        if k != k0
            ENV["CHAT_LLM_API_KEY"] = k
            println(stdout, "[bootstrap] CHAT_LLM_API_KEY normalized (was env assignment / JSON style)")
        else
            println(stdout, "[bootstrap] CHAT_LLM_API_KEY set via environment")
        end
    elseif isfile(key_file)
        api_key = normalize_llm_api_key_secret(read(key_file, String))
        if !isempty(api_key)
            ENV["CHAT_LLM_API_KEY"] = api_key
            println(stdout, "[bootstrap] CHAT_LLM_API_KEY loaded from secrets/openai_api_key")
        end
    else
        println(stdout, "[bootstrap] WARNING: CHAT_LLM_API_KEY not set — /chat will return 503")
    end
end
# Base URL and model default to OpenAI gpt-4o; override via ENV if needed.
if !haskey(ENV, "CHAT_LLM_BASE_URL")
    ENV["CHAT_LLM_BASE_URL"] = "https://api.openai.com"
end
if !haskey(ENV, "CHAT_LLM_MODEL")
    ENV["CHAT_LLM_MODEL"] = "gpt-4o"
end
println(stdout, "[bootstrap] LLM: base=$(ENV["CHAT_LLM_BASE_URL"]) model=$(ENV["CHAT_LLM_MODEL"])")
flush(stdout)

println(stdout, "[bootstrap] loading Oxygen...")
flush(stdout)
using Oxygen
println(stdout, "[bootstrap] loading HTTP...")
flush(stdout)
using HTTP
using Unitful

const PORT = parse(Int, get(ENV, "PORT", get(ENV, "SIZER_PORT", "8080")))
const HOST = get(ENV, "SIZER_HOST", "0.0.0.0")
println(stdout, "[bootstrap] host=$HOST port=$PORT")
flush(stdout)

const STATUS_FN = Ref{Function}(() -> "warming")
const LOAD_ERROR = Ref{String}("")

@get "/health" function (_)
    return HTTP.Response(200, ["Content-Type" => "application/json"], "{\"status\":\"ok\"}")
end

@get "/status" function (_)
    s = STATUS_FN[]()
    # Keep response shape stable with the full API /status payload.
    # - warming: full API not ready yet
    # - error: background load failed
    # - otherwise: s is the StructuralSynthesizer server state (idle/running/queued)
    payload = if s == "warming"
        Dict(
            "status" => "ok",
            "mode" => "bootstrap",
            "ready" => false,
            "state" => s,
            "has_result" => false,
            "message" => "Full API not ready yet",
            "error" => nothing,
        )
    elseif s == "error"
        Dict(
            "status" => "ok",
            "mode" => "bootstrap",
            "ready" => false,
            "state" => s,
            "has_result" => false,
            "message" => "Failed to load full API",
            "error" => (isempty(LOAD_ERROR[]) ? nothing : LOAD_ERROR[]),
        )
    else
        Dict(
            "status" => "ok",
            "mode" => "bootstrap",
            "ready" => true,
            "state" => s,
            "has_result" => false,
            "message" => nothing,
            "error" => nothing,
        )
    end
    return HTTP.Response(200, ["Content-Type" => "application/json"], JSON3.write(payload))
end

@get "/debug" function (_)
    err = LOAD_ERROR[]
    s = STATUS_FN[]()
    body = "{\"status\":\"$(s)\",\"error\":$(repr(err))}"
    return HTTP.Response(200, ["Content-Type" => "application/json"], body)
end

# Load StructuralSynthesizer in background via require (no "using" inside block).
const SS_PKGID = Base.PkgId(Base.UUID("fc54e8a9-dab1-4bea-a64f-f8e9b3ce8a89"), "StructuralSynthesizer")
@async begin
    try
        println(stdout, "[bootstrap] @async: starting background load...")
        flush(stdout)
        @info "Loading StructuralSynthesizer (first request may be slow)..."
        mod = Base.require(SS_PKGID)

        # Belt-and-suspenders: ensure Asap units are in Unitful.basefactors.
        # The __init__ chain should have done this, but log the state for debugging.
        n_bf = length(Unitful.basefactors)
        has_ksi = haskey(Unitful.basefactors, :KipPerSquareInch)
        println(stdout, "[bootstrap] basefactors: $n_bf entries, has :KipPerSquareInch = $has_ksi")
        flush(stdout)
        if !has_ksi
            println(stdout, "[bootstrap] __init__ did NOT register Asap units — calling _ensure_asap_units! explicitly")
            flush(stdout)
            Base.invokelatest(mod._ensure_asap_units!)
            has_ksi2 = haskey(Unitful.basefactors, :KipPerSquareInch)
            println(stdout, "[bootstrap] after explicit fix: has :KipPerSquareInch = $has_ksi2")
            flush(stdout)
        end

        println(stdout, "[bootstrap] @async: require done, calling register_routes!...")
        flush(stdout)
        Base.invokelatest(mod.register_routes!)
        STATUS_FN[] = () -> Base.invokelatest(mod.status_string, mod.SERVER_STATUS)
        println(stdout, "[bootstrap] @async: fully loaded")
        flush(stdout)
        @info "StructuralSynthesizer loaded; POST /design, /validate, GET /schema ready"
    catch e
        err_msg = sprint(showerror, e, catch_backtrace())
        LOAD_ERROR[] = err_msg
        println(stderr, "[bootstrap] @async FAILED: ", err_msg)
        flush(stderr)
        @error "Failed to load StructuralSynthesizer" exception=(e, catch_backtrace())
        STATUS_FN[] = () -> "error"
    end
end

@info "Sizer API bootstrap listening on http://$HOST:$PORT (GET /health, /status ready)"
println(stdout, "[bootstrap] calling serve()...")
flush(stdout)
try
    serve(; host=HOST, port=PORT)
catch e
    msg = sprint(showerror, e, catch_backtrace())
    println(stderr, "[bootstrap] FATAL: ", msg)
    @error "Bootstrap serve failed" exception=(e, catch_backtrace())
    flush(stdout)
    flush(stderr)
    exit(1)
end
