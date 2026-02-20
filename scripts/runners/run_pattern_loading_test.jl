# Runner script for pattern loading diagnostic tests
# Usage: julia --project=. scripts/runners/run_pattern_loading_test.jl

using Pkg
Pkg.activate(joinpath(@__DIR__, "..", "..", "StructuralSizer"))

include(joinpath(@__DIR__, "..", "..", "StructuralSizer", "test", "slabs", "test_pattern_loading_sizing.jl"))
