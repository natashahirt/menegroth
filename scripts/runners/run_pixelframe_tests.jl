#!/usr/bin/env julia
"""
    run_pixelframe_tests.jl

Targeted runner for the PixelFrame test suite. Used to verify the
ASTM A416 Gr 270 LR tendon-yield change (`pf_flexural_capacity` and
`PixelFrameChecker` defaults harmonized to `f_py = 1674 MPa`).

Run via:

    SS_ENABLE_VISUALIZATION=false julia --project=StructuralSizer \\
        scripts/runners/run_pixelframe_tests.jl

Equivalent to `Pkg.test("StructuralSizer"; test_args=["pixelframe/..."])`
but skips the rest of the (slow) ~6-minute StructuralSizer test suite.
"""

using Test
using StructuralSizer
using Unitful
using Asap: CompoundSection
import JuMP
const MOI = JuMP.MOI

const _TEST_DIR = joinpath(dirname(@__DIR__), "..", "StructuralSizer", "test")

@testset "PixelFrame — targeted" begin
    include(joinpath(_TEST_DIR, "pixelframe", "test_pixelframe_checker.jl"))
    include(joinpath(_TEST_DIR, "pixelframe", "test_pixelframe_capacities.jl"))
end
