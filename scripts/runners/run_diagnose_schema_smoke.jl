using StructuralSynthesizer
using JSON3

s = api_diagnose_schema()
@assert s["version"] == "v1"
@assert s["endpoint"] == "GET /diagnose"
@assert haskey(s, "top_level")
@assert haskey(s["top_level"], "constraints")
@assert haskey(s["top_level"], "columns")

println("diagnose schema smoke: ok")
println(JSON3.write(Dict(
    "version" => s["version"],
    "endpoint" => s["endpoint"],
    "has_top_level" => haskey(s, "top_level"),
)))
