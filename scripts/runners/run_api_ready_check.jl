using Pkg
Pkg.activate(joinpath(@__DIR__, "..", "..", "StructuralSynthesizer"))
using HTTP
using JSON3

const BASE = length(ARGS) >= 1 ? rstrip(ARGS[1], '/') : "http://127.0.0.1:8080"
const MAX_SECONDS = length(ARGS) >= 2 ? parse(Int, ARGS[2]) : 240

println("Polling $(BASE)/status for up to $(MAX_SECONDS)s...")
for i in 1:MAX_SECONDS
    try
        resp = HTTP.get("$(BASE)/status"; readtimeout=10)
        if resp.status == 200
            status_obj = JSON3.read(String(resp.body))
            state_str = haskey(status_obj, :state) ? String(status_obj.state) : "unknown"
            println("  [$i] state=$state_str")
            if state_str != "warming"
                println("Ready: state=$state_str")
                exit(0)
            end
        else
            println("  [$i] HTTP $(resp.status)")
        end
    catch e
        println("  [$i] waiting ($(typeof(e)))")
    end
    sleep(1.0)
end

error("API did not leave warming state within $(MAX_SECONDS)s")
