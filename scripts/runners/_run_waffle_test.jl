# Quick runner: waffle geometry unit tests
using Pkg
Pkg.activate(joinpath(@__DIR__, "..", ".."))

using Test, StructuralSizer

println("="^60)
println("  Waffle Slab Geometry Tests")
println("="^60)

include(joinpath(@__DIR__, "..", "..", "StructuralSizer", "test", "slabs", "test_waffle_geometry.jl"))

println("\nDone.")
