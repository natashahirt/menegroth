# Main test runner for StructuralSynthesizer
# Run with: julia --project=. test/runtests.jl

using Test
using Unitful
using StructuralSynthesizer
using Asap  # ensures `u"kip"`, `u"ksi"`, etc resolve via Asap unit module

@testset "StructuralSynthesizer Tests" begin

    # ─── Core / Architecture ─────────────────────────────────────────────
    @testset "Core" begin
        include("core/test_core_structs.jl")
        include("core/test_design_architecture.jl")
        include("core/test_member_hierarchy.jl")
        include("core/test_design_api.jl")
    end

    # ─── Geometry & Utilities ────────────────────────────────────────────
    @testset "Geometry & Utilities" begin
        include("geometry/test_slab_geometry.jl")
        include("geometry/test_slab_coloring.jl")
    end

    # ─── Analysis ────────────────────────────────────────────────────────
    @testset "Analysis" begin
        include("analyze/test_drape.jl")
        include("analyze/test_pattern_loading.jl")
    end

    # ─── Visualization ───────────────────────────────────────────────────
    @testset "Visualization" begin
        include("visualization/test_voronoi_vis.jl")
    end

    # ─── Member Sizing ───────────────────────────────────────────────────
    @testset "Member Sizing" begin
        include("sizing/members/test_beam_sizing_report.jl")
        include("sizing/members/test_column_sizing_report.jl")
        include("sizing/members/test_aisc_column_examples.jl")
    end

    # ─── Slab Sizing ─────────────────────────────────────────────────────
    @testset "Slab Sizing" begin
        include("sizing/slabs/test_flat_plate_efm_integration.jl")
        include("sizing/slabs/test_flat_plate_methods_comparison.jl")
        include("sizing/slabs/test_vault_pipeline.jl")
    end

    # ─── Foundation Sizing ───────────────────────────────────────────────
    @testset "Foundation Sizing" begin
        include("sizing/foundations/test_foundation_integration.jl")
    end

    # ─── Optimization Convergence ────────────────────────────────────────
    @testset "Optimization" begin
        include("optimization/test_nlp_vs_catalog_convergence.jl")
    end

    # ─── Workflow Integration ────────────────────────────────────────────
    @testset "Workflow Integration" begin
        include("integration/test_structuralsizer_workflow_integration.jl")
    end

end