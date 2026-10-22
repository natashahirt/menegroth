# =============================================================================
# Runner: corner punching Muy production-caller tests
# =============================================================================
#
# Usage (from repo root):
#   SS_ENABLE_VISUALIZATION=false julia --project=StructuralSizer \
#       scripts/runners/run_corner_punching_tests.jl
# =============================================================================

using Pkg
Pkg.activate(joinpath(@__DIR__, "..", "..", "StructuralSizer"))

include(joinpath(@__DIR__, "..", "..", "StructuralSizer", "test", "slabs",
                 "test_corner_punching.jl"))
