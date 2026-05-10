#!/usr/bin/env julia
# Run only the ACI 318-11 beam torsion tests (a fast subset of the
# StructuralSizer suite). Used to regression-test the §11.5 audit fixes,
# in particular the corrected Eq. (11-24) implementation in
# `min_torsion_longitudinal` and the §11.5.3.6 θ bounds.

using Pkg
Pkg.activate(joinpath(@__DIR__, "..", "..", "StructuralSizer"))

using Test
using Unitful
using StructuralSizer
using Asap: ksi

# Match the headless test environment used by Pkg.test.
ENV["SS_ENABLE_VISUALIZATION"] = "false"

@testset "ACI 318-11 beam torsion regression" begin
    test_dir = joinpath(@__DIR__, "..", "..", "StructuralSizer", "test", "concrete_beam")
    include(joinpath(test_dir, "test_torsion.jl"))
end
