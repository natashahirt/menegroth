# Runner script for fire provision tests
using Pkg
Pkg.activate(joinpath(@__DIR__, "..", "..", "StructuralSizer"))
include(joinpath(@__DIR__, "..", "..", "StructuralSizer", "test", "test_fire_provisions.jl"))
