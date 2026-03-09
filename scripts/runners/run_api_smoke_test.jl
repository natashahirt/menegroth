# =============================================================================
# API smoke test — hit deployed or local Sizer API
# Usage: julia scripts/runners/run_api_smoke_test.jl [BASE_URL]
#   e.g. julia scripts/runners/run_api_smoke_test.jl https://xxx.us-east-1.awsapprunner.com
#   Or:  APP_URL=https://... julia scripts/runners/run_api_smoke_test.jl
#   Or:  julia scripts/runners/run_api_smoke_test.jl  (defaults to http://127.0.0.1:8080)
# =============================================================================

using Pkg
Pkg.activate(joinpath(@__DIR__, "..", "..", "StructuralSynthesizer"))
using HTTP

const BASE = length(ARGS) >= 1 ? rstrip(ARGS[1], '/') : get(ENV, "APP_URL", "http://127.0.0.1:8080")

function get(path)
    url = "$(BASE)$(path)"
    r = HTTP.get(url; readtimeout=30)
    @assert r.status == 200 "GET $path: status $(r.status)"
    String(r.body)
end

println("Testing API at $BASE")
println("  GET /health ... ", get("/health"))
println("  GET /status ... ", get("/status"))
println("  GET /schema ... ", (s = get("/schema"); length(s) > 100 ? "$(length(s)) bytes" : s))
println("✓ Smoke test passed")