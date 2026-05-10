#!/usr/bin/env julia
# =============================================================================
# Runner: focused mat-foundation test (post-Tier-1 fix verification)
# =============================================================================
# Re-runs only `test_mat_aci.jl` to isolate the lone Foundations failure
# observed in the full Pkg.test() suite, since Scenario B uses hard-coded
# column demands and cannot be affected by the slab-pipeline fixes.
#
# Usage (from repo root):
#   julia --project=StructuralSizer scripts/runners/run_mat_aci_smoke.jl
# =============================================================================

using Pkg
Pkg.activate(joinpath(@__DIR__, "..", "..", "StructuralSizer"))

using Test, Unitful
using StructuralSizer

@testset "Mat ACI smoke" begin
    include(joinpath(@__DIR__, "..", "..", "StructuralSizer", "test",
                     "foundations", "test_mat_aci.jl"))
end
