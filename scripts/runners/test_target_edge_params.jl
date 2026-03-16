#!/usr/bin/env julia
# Quick test of target_edge and visualization_target_edge_m API params.
using StructuralSynthesizer
using StructuralSizer

# Test FEA target_edge_m
p = json_to_params(APIParams(floor_options=APIFloorOptions(method="FEA", target_edge_m=0.5)), "meters")
@assert p.floor isa StructuralSizer.FlatPlateOptions
@assert p.floor.method isa StructuralSizer.FEA
@assert p.floor.method.target_edge == 0.5u"m"
println("FEA target_edge: OK")

# Test visualization_target_edge_m
p2 = json_to_params(APIParams(visualization_target_edge_m=0.6), "meters")
@assert p2.visualization_target_edge_m == 0.6
println("visualization_target_edge_m: OK")

# Test default (nothing)
p3 = json_to_params(APIParams(), "meters")
@assert isnothing(p3.visualization_target_edge_m)
println("defaults: OK")

println("All API param tests passed.")
