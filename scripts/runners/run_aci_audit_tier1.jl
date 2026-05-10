#!/usr/bin/env julia
# =============================================================================
# Runner: ACI 318-11 Tier 1 audit tests for the flat-plate slab pipeline.
# =============================================================================
# Smoke runner intended for fast iteration on the Tier 1 audit suite added in
# `StructuralSizer/test/slabs/test_aci_audit_tier1.jl`.
#
# Usage (from repo root):
#   julia --project=StructuralSizer scripts/runners/run_aci_audit_tier1.jl
# =============================================================================

using Pkg
Pkg.activate(joinpath(@__DIR__, "..", "..", "StructuralSizer"))

using Test
using StructuralSizer  # ensure compiled

@testset "ACI Tier 1 audit (smoke)" begin
    include(joinpath(@__DIR__, "..", "..", "StructuralSizer", "test",
                     "slabs", "test_aci_audit_tier1.jl"))
end
