#!/usr/bin/env julia
# Run the vault pipeline test.
# Usage: julia --project=StructuralSynthesizer scripts/runners/run_vault_pipeline_test.jl

using Pkg
Pkg.activate(joinpath(@__DIR__, "..", "..", "StructuralSynthesizer"))

using StructuralSynthesizer, StructuralSizer, Asap

include(joinpath(@__DIR__, "..", "..", "StructuralSynthesizer", "test", "sizing", "slabs", "test_vault_pipeline.jl"))
