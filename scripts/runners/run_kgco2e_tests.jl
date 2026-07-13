# Focused test runner for the kgCO₂e Unitful refactor. Runs only the
# StructuralSizer test files that directly exercise material `.ecc` /
# `.fiber_ecc` fields, EC objectives, and composite stud carbon — i.e. the
# blast radius of typing material ECCs and EC results.
#
# Usage:
#     julia --project=StructuralSizer scripts/runners/run_kgco2e_tests.jl

using Test
using Unitful
using StructuralSizer
using Asap  # custom units (kip, ksi, ksf, ...)

const TEST_ROOT = joinpath(@__DIR__, "..", "..", "StructuralSizer", "test")

@testset "kgCO₂e refactor — focused" begin
    @testset "LWC materials" begin
        include(joinpath(TEST_ROOT, "test_lwc_materials.jl"))
    end

    @testset "Fire provisions" begin
        include(joinpath(TEST_ROOT, "test_fire_provisions.jl"))
    end

    @testset "PixelFrame capacities" begin
        include(joinpath(TEST_ROOT, "pixelframe", "test_pixelframe_capacities.jl"))
    end

    @testset "PixelFrame checker (MinCarbon / MinVolume MIP)" begin
        include(joinpath(TEST_ROOT, "pixelframe", "test_pixelframe_checker.jl"))
    end

    @testset "Composite beam (stud contribution)" begin
        include(joinpath(TEST_ROOT, "steel_member", "composite", "test_composite_beam.jl"))
    end

    @testset "Rebar volume / EC" begin
        include(joinpath(TEST_ROOT, "test_rebar_volume.jl"))
    end
end
