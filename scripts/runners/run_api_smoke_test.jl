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
using JSON3

const BASE = length(ARGS) >= 1 ? rstrip(ARGS[1], '/') : get(ENV, "APP_URL", "http://127.0.0.1:8080")
const RUN_DESIGN = get(ENV, "RUN_DESIGN_E2E", "1") == "1"
const PAYLOAD_PATH = joinpath(@__DIR__, "..", "..", "scripts", "api", "test_payload.json")

function get(path)
    url = "$(BASE)$(path)"
    r = HTTP.get(url; readtimeout=30)
    @assert r.status == 200 "GET $path: status $(r.status)"
    String(r.body)
end

function run_design_e2e()
    @assert isfile(PAYLOAD_PATH) "Missing test payload at $(PAYLOAD_PATH)"
    payload = read(PAYLOAD_PATH, String)
    headers = ["Content-Type" => "application/json"]

    r = HTTP.post("$(BASE)/design", headers, payload; readtimeout=120)
    @assert r.status in (200, 202) "POST /design: status $(r.status), body=$(String(r.body))"
    println("  POST /design ... status $(r.status)")

    # Poll until the background design loop returns to idle.
    idle = false
    for i in 1:180
        status_obj = JSON3.read(get("/status"))
        if haskey(status_obj, :state) && status_obj.state == "idle"
            println("  GET /status ... idle after $(i)s")
            idle = true
            break
        end
        sleep(1.0)
    end
    @assert idle "Design did not return to idle within timeout"

    result_resp = HTTP.get("$(BASE)/result"; readtimeout=60)
    @assert result_resp.status == 200 "GET /result: status $(result_resp.status)"
    result_obj = JSON3.read(String(result_resp.body))
    err = haskey(result_obj, :error) ? result_obj.error : nothing
    @assert isnothing(err) "Design result contained error: $(err)"
    println("  GET /result ... ok")
end

println("Testing API at $BASE")
println("  GET /health ... ", get("/health"))
println("  GET /status ... ", get("/status"))
println("  GET /schema ... ", (s = get("/schema"); length(s) > 100 ? "$(length(s)) bytes" : s))
RUN_DESIGN && run_design_e2e()
println("✓ Smoke test passed")