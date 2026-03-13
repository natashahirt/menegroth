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

println(stdout, "[bootstrap] starting")
flush(stdout)

ENV["SS_ENABLE_VISUALIZATION"] = get(ENV, "SS_ENABLE_VISUALIZATION", "false")
ENV["SS_ENABLE_HEAVY_PRECOMPILE_WORKLOAD"] = get(ENV, "SS_ENABLE_HEAVY_PRECOMPILE_WORKLOAD", "false")

println(stdout, "[bootstrap] loading Oxygen...")
flush(stdout)
using Oxygen
println(stdout, "[bootstrap] loading HTTP...")
flush(stdout)
using HTTP

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
    msg = s == "warming" ? "Full API not ready yet" : "ready"
    body = "{\"status\":\"$(s)\",\"message\":\"$(msg)\"}"
    return HTTP.Response(200, ["Content-Type" => "application/json"], body)
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
        using Unitful
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
