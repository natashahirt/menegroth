# =============================================================================
# Runner for mat foundation tests (all three methods)
#   julia scripts/runners/run_mat_test.jl
# =============================================================================

using Pkg
Pkg.activate(joinpath(@__DIR__, "..", ".."))
Pkg.resolve()

include(joinpath(@__DIR__, "..", "..", "StructuralSizer", "test", "foundations", "test_mat_aci.jl"))
