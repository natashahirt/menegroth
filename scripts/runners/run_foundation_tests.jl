# Run foundation-related tests (StructuralSizer + foundation integration in StructuralSynthesizer)
# Usage: julia --project=StructuralSizer scripts/runners/run_foundation_tests.jl

ENV["SS_ENABLE_VISUALIZATION"] = "false"
using Pkg
Pkg.activate("StructuralSizer")
using Test
using StructuralSizer
include(joinpath(@__DIR__, "..", "..", "StructuralSizer", "test", "foundations", "test_spread_aci.jl"))
