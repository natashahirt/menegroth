#!/usr/bin/env julia
# Run only the column P-M and slenderness tests (fast subset of the
# StructuralSizer suite). Intended for verifying the ACI 318 column
# correctness PRs without paying the cost of the full Pkg.test run.

using Pkg
Pkg.activate(joinpath(@__DIR__, "..", "..", "StructuralSizer"))

using Test
using Unitful
using StructuralSizer
using Asap: ksi

# Match the headless test environment used by Pkg.test.
ENV["SS_ENABLE_VISUALIZATION"] = "false"

@testset "ACI Column suite (concrete_column/)" begin
    test_dir = joinpath(@__DIR__, "..", "..", "StructuralSizer", "test", "concrete_column")
    for f in (
        "test_column_pm.jl",
        "test_circular_column_pm.jl",
        "test_biaxial.jl",
        "test_slenderness.jl",
        "test_rc_column_section.jl",
        # `test_biaxial_fix.jl` is a debug script (println-based) and is
        # explicitly excluded from runtests.jl. We skip it here too.
        # `test_catalog_gen.jl` is intentionally excluded — slow (~minutes)
        # and not the focus of the PM-cap regression.
    )
        include(joinpath(test_dir, f))
    end
end
