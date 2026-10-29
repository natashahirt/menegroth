# Targeted verification runner (test agent).
#
# Runs the two oracle suites relevant to:
#   1. DEFECT 4 — corner/edge biaxial punching shear (ACI 318-11 §11.11.7.1)
#      → test/slabs/test_corner_punching.jl
#   2. The §13.5.3 transfer-reinforcement consolidation refactor
#      (_transfer_reinforcement_pass shared by _rot_transfer_reinforcement!
#       and _pipeline_transfer_reinforcement)
#      → test/slabs/test_eq_13_7_adjoining.jl
#
# Activates the StructuralSizer environment and includes both files under a
# top-level @testset so the aggregate pass/fail/broken counts are printed.
#
# Run from repo root:
#   SS_ENABLE_VISUALIZATION=false SS_ENABLE_HEAVY_PRECOMPILE_WORKLOAD=false \
#     julia --project=StructuralSizer scripts/runners/test_defect4_and_transfer_refactor.jl

using Test
using Unitful
using Asap
using StructuralSizer

const SS = StructuralSizer

const TESTDIR = joinpath(@__DIR__, "..", "..", "StructuralSizer", "test")

@testset "Defect 4 + transfer-reinforcement refactor" begin
    include(joinpath(TESTDIR, "slabs", "test_eq_13_7_adjoining.jl"))
    include(joinpath(TESTDIR, "slabs", "test_corner_punching.jl"))
end
