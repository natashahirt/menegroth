using Pkg
Pkg.activate(joinpath(@__DIR__, "..", "..", "StructuralSynthesizer"))
using HTTP

const BASE = length(ARGS) >= 1 ? rstrip(ARGS[1], '/') : "http://127.0.0.1:8080"
const PAYLOAD_PATH = joinpath(@__DIR__, "..", "..", "scripts", "api", "test_payload.json")

@assert isfile(PAYLOAD_PATH) "Missing test payload at $(PAYLOAD_PATH)"
payload = read(PAYLOAD_PATH, String)
headers = ["Content-Type" => "application/json"]

r = HTTP.post("$(BASE)/design", headers, payload; readtimeout=120)
@assert r.status in (200, 202) "POST /design failed with status $(r.status): $(String(r.body))"
println("Submitted test design to $(BASE): status $(r.status)")
