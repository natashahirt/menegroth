#!/usr/bin/env julia
# =============================================================================
# Runner: mat-foundation tests covering the in-place section update refactor
# =============================================================================
# Verifies the WinklerFEA mat pipeline after hoisting mesh / springs / loads /
# Asap.Model out of the thickness loop and switching to per-element
# `elem.thickness = h_m` mutation + `Asap.update!(model; values_only=true)`.
#
# Two suites:
#   1. test_mat_aci.jl            — Scenarios A/B/C/D, all three methods
#   2. test_no_tension_springs.jl — compression-only iteration semantics
#
# Usage (from repo root):
#   julia --project=StructuralSizer scripts/runners/run_mat_winkler_inplace.jl
# =============================================================================

using Pkg
Pkg.activate(joinpath(@__DIR__, "..", "..", "StructuralSizer"))

using Test, Unitful
using StructuralSizer

const TEST_DIR = joinpath(@__DIR__, "..", "..", "StructuralSizer", "test", "foundations")

@testset "WinklerFEA mat — in-place section update refactor" begin
    @testset "test_mat_aci.jl" begin
        include(joinpath(TEST_DIR, "test_mat_aci.jl"))
    end

    @testset "test_no_tension_springs.jl" begin
        include(joinpath(TEST_DIR, "test_no_tension_springs.jl"))
    end
end
