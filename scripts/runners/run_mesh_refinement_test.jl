#!/usr/bin/env julia
# Run mesh refinement tests only.
# Usage: julia --project=StructuralSynthesizer scripts/runners/run_mesh_refinement_test.jl

using Pkg
Pkg.activate(joinpath(@__DIR__, "..", "..", "StructuralSynthesizer"))

ENV["SS_ENABLE_VISUALIZATION"] = "false"

include(joinpath(@__DIR__, "..", "..", "StructuralSynthesizer", "test", "analyze", "test_mesh_refinement.jl"))
