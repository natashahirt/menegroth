# Run the full foundation testset in isolation (mat, strip, spread, rebar
# quantity audit, and the type/load smoke test).  Use during development to
# iterate on foundation-side fixes — e.g. the mat rigid-scaling fix, strip
# inter-band T&S steel fix, and the punching edge/corner detection fix —
# without paying the cost of the full StructuralSizer test suite.
#
# Usage:
#     julia --project=StructuralSizer scripts/runners/run_foundation_rebar_tests.jl

using Pkg
Pkg.activate(joinpath(@__DIR__, "..", "..", "StructuralSizer"))

using StructuralSizer
using Test
using Unitful
using Asap  # custom units (kip, ksi, ksf, psf, etc.) used inside test files

const _FOUND_TEST_DIR =
    joinpath(@__DIR__, "..", "..", "StructuralSizer", "test", "foundations")

@testset "Foundations" begin
    include(joinpath(_FOUND_TEST_DIR, "test_spread_footing.jl"))
    include(joinpath(_FOUND_TEST_DIR, "test_spread_aci.jl"))
    include(joinpath(_FOUND_TEST_DIR, "test_strip_aci.jl"))
    include(joinpath(_FOUND_TEST_DIR, "test_mat_aci.jl"))
    include(joinpath(_FOUND_TEST_DIR, "test_rebar_quantity.jl"))
    include(joinpath(_FOUND_TEST_DIR, "test_no_tension_springs.jl"))
    include(joinpath(_FOUND_TEST_DIR, "test_types_load.jl"))
end
