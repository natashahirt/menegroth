#!/usr/bin/env julia
# Run full StructuralSizer test suite (loads StructuralSynthesizer as test dep).
# Usage: julia --project=StructuralSizer scripts/runners/run_full_test.jl

using Pkg
Pkg.activate(joinpath(@__DIR__, "..", "..", "StructuralSizer"))
Pkg.instantiate()
Pkg.test()
