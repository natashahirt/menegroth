#!/usr/bin/env julia
# Smoke-test chat tool dispatch (no HTTP, no LLM).
# From repo root: julia --project=StructuralSynthesizer scripts/runners/smoke_chat_tools.jl
using StructuralSynthesizer

const dispatch = StructuralSynthesizer._dispatch_chat_tool

r1 = dispatch("validate_params", Dict("params" => Dict("punching_strategy" => "reinforce_last")))
println("validate_params (patch): ", r1)

r2 = dispatch("validate_params", Dict("params" => Dict()))
println("validate_params (empty): ", r2)

r3 = dispatch("get_applicability", Dict())
ks = collect(keys(r3))
println("get_applicability nkeys: ", length(ks))

r4 = dispatch("get_situation_card", Dict())
println("get_situation_card has_geometry: ", get(r4, "has_geometry", missing))

r5 = dispatch("run_design", Dict("params" => Dict("punching_strategy" => "reinforce_last")))
println("run_design (no geometry): ", haskey(r5, "error") ? r5["error"] : "ok")

println("smoke_chat_tools: done")
