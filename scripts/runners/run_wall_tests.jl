# ==============================================================================
# Focused runner: StructuralSizer wall testsets only
# ==============================================================================
# Runs StructuralSizer/test/walls/test_walls.jl against the COMPILED package
# (real harness — `using StructuralSizer` / `using Asap`), NOT include-into-Main
# of the raw source (which previously produced `UndefVarError: Asap not defined
# in Main`). This exercises the Phase 1 wall-hardening regression tests without
# the slow / Gurobi-dependent full suite.
#
# Usage:
#   SS_ENABLE_VISUALIZATION=false julia --project=StructuralSizer \
#       scripts/runners/run_wall_tests.jl

using Test
using Unitful
using StructuralSizer
using Asap  # custom units (kip, ksi, ksf, psf, …) used by the wall tests

const _TESTFILE = joinpath(@__DIR__, "..", "..",
                           "StructuralSizer", "test", "walls", "test_walls.jl")

@testset "StructuralSizer Walls (Phase 1 verification)" begin
    include(_TESTFILE)
end
