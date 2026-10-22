# Targeted StructuralSynthesizer analyze + sizing tests for pattern-loading
# and foundation-demand oracles. Invoked from the repo root:
#   SS_ENABLE_VISUALIZATION=false julia --project=StructuralSynthesizer \
#       scripts/runners/run_analyze_sizing_oracles.jl

ENV["SS_ENABLE_VISUALIZATION"] = get(ENV, "SS_ENABLE_VISUALIZATION", "false")
ENV["SS_ENABLE_HEAVY_PRECOMPILE_WORKLOAD"] =
    get(ENV, "SS_ENABLE_HEAVY_PRECOMPILE_WORKLOAD", "false")

using Test
using Unitful
using StructuralSynthesizer
using Asap

const TEST_DIR = joinpath(@__DIR__, "..", "..", "StructuralSynthesizer", "test")

@testset "analyze + sizing oracles" begin
    @testset "Analysis" begin
        include(joinpath(TEST_DIR, "analyze", "test_drape.jl"))
        include(joinpath(TEST_DIR, "analyze", "test_pattern_loading.jl"))
        include(joinpath(TEST_DIR, "analyze", "test_structural_offset.jl"))
        include(joinpath(TEST_DIR, "analyze", "test_mesh_refinement.jl"))
        include(joinpath(TEST_DIR, "analyze", "test_member_group_demands.jl"))
        include(joinpath(TEST_DIR, "analyze", "test_foundation_demands.jl"))
    end
    @testset "Slab Sizing" begin
        include(joinpath(TEST_DIR, "sizing", "slabs", "test_vault_pipeline.jl"))
    end
    @testset "Member Sizing" begin
        include(joinpath(TEST_DIR, "sizing", "members", "test_aisc_column_examples.jl"))
    end
end
