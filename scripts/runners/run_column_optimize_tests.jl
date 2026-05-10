#!/usr/bin/env julia
# Run the column optimization tests after the per-axis kx/ky migration.

using Pkg
Pkg.activate(joinpath(@__DIR__, "..", "..", "StructuralSizer"))
ENV["SS_ENABLE_VISUALIZATION"] = "false"

using Test
using Unitful
using StructuralSizer
using Asap

@testset "Column optimization (per-axis kx/ky migration)" begin
    test_dir = joinpath(@__DIR__, "..", "..", "StructuralSizer", "test", "optimize")
    for f in (
        "test_column_optimization.jl",
        "test_column_nlp.jl",
        "test_column_nlp_adapter.jl",
        # Heavy: test_column_full.jl, test_w_column_nlp.jl, test_hss_column_nlp.jl,
        # test_multi_material_mip.jl all run the full size_columns pipeline.
        # Run them when validating the synthesizer-side PR-3 changes too.
    )
        include(joinpath(test_dir, f))
    end
end
