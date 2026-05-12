#!/usr/bin/env julia
# scripts/runners/run_steel_audit_smoke.jl
#
# Smoke-test runner for the AISC steel beam/column audit fixes
# (F-1, F-2, F-3, G-1, G-2, E-1, E-3, H-1, I-1, I-2, I-3, I-4, I-5, I-6, I-7
# and the tension Ae_ratio engineering-judgment marker).
#
# Runs only the steel-member test files that exercise the patched code paths,
# avoiding the full (~6 min) StructuralSizer test suite.

using Pkg
Pkg.activate(joinpath(@__DIR__, "..", "..", "StructuralSizer"))

using Test
using Unitful
using StructuralSizer
using Asap

const TESTDIR = joinpath(@__DIR__, "..", "..", "StructuralSizer", "test")

@testset "Steel Audit Patch Smoke" begin
    @testset "Flexure (F2/F3, web-class guard)" begin
        include(joinpath(TESTDIR, "steel_member", "test_aisc_beam_examples.jl"))
        include(joinpath(TESTDIR, "steel_member", "test_handcalc_beam.jl"))
    end

    @testset "Shear (G2 / G6) and slender Q" begin
        include(joinpath(TESTDIR, "steel_member", "test_qa_slender_web.jl"))
        include(joinpath(TESTDIR, "steel_member", "test_qa_slender_flange.jl"))
    end

    @testset "Moment amplification (Cm, B1, B2)" begin
        include(joinpath(TESTDIR, "steel_member", "test_b1_b2_amplification.jl"))
        include(joinpath(TESTDIR, "steel_member", "test_b1_checker_integration.jl"))
    end

    @testset "AISC reference examples" begin
        include(joinpath(TESTDIR, "steel_member", "test_aisc_360_reference.jl"))
        include(joinpath(TESTDIR, "steel_member", "test_aisc_companion_manual_1.jl"))
    end

    @testset "Composite beam (I3, I8)" begin
        include(joinpath(TESTDIR, "steel_member", "composite", "test_composite_beam.jl"))
    end
end
