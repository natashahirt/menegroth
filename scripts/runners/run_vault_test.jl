#!/usr/bin/env julia
# Run vault pipeline test to verify _generate_mesh_points_with_supports fix.
ENV["SS_ENABLE_VISUALIZATION"] = "false"
include(joinpath(@__DIR__, "..", "..", "StructuralSynthesizer", "test", "sizing", "slabs", "test_vault_pipeline.jl"))
