using Pkg
Pkg.activate(joinpath(@__DIR__, "..", "..", "StructuralSynthesizer"))

using HTTP
using JSON3

const BASE = length(ARGS) >= 1 ? rstrip(ARGS[1], '/') : "http://127.0.0.1:8080"
const MAX_WAIT_S = 120

function get_json(path::String)
    url = "$(BASE)$(path)"
    r = HTTP.get(url; readtimeout=30)
    @assert r.status == 200 "GET $path failed with status $(r.status), body=$(String(r.body))"
    return JSON3.read(String(r.body))
end

println("Schema smoke against $BASE")

# Health should always be immediate.
health = get_json("/health")
@assert haskey(health, :status)
@assert health.status == "ok"
println("  /health ok")

# Wait for bootstrap readiness (full routes loaded).
ready = Ref(false)
for i in 1:MAX_WAIT_S
    st = get_json("/status")
    if haskey(st, :ready) && st.ready == true
        ready[] = true
        println("  /status ready after $(i)s")
        break
    end
    sleep(1.0)
end
@assert ready[] "Server did not become ready within $(MAX_WAIT_S)s"

schema = get_json("/schema")
@assert haskey(schema, :diagnose_schema) "Expected diagnose_schema in /schema response"
println("  /schema includes diagnose_schema")

diag_schema = get_json("/schema/diagnose")
@assert haskey(diag_schema, :version)
@assert haskey(diag_schema, :endpoint)
@assert diag_schema.version == "v1"
@assert diag_schema.endpoint == "GET /diagnose"
println("  /schema/diagnose contract validated")

println("✓ Local schema integration smoke passed")
