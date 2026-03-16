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
        include("core/test_api_units_faces.jl")
        include("core/test_api_scoped_overrides_payload.jl")
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
        include("analyze/test_structural_offset.jl")
        include("analyze/test_mesh_refinement.jl")
    end

    # ─── Visualization ───────────────────────────────────────────────────
    # Requires StructuralVisualization (and GLMakie); skip when not in project or headless.
    @testset "Visualization" begin
        try
            using StructuralVisualization
            include("visualization/test_voronoi_vis.jl")
        catch
            @test_skip "StructuralVisualization not available (optional dep; expected in headless/CI)"
        end
    end

    # ─── Report Generators (hybrid: report + @test assertions) ───────────
    @testset "Report Generators" begin
        include("report_generators/test_beam_sizing_report.jl")
        include("report_generators/test_column_sizing_report.jl")
        include("report_generators/test_composite_beam_report.jl")
        include("report_generators/test_flat_plate_efm_integration.jl")
        include("report_generators/test_flat_plate_methods_comparison.jl")
        include("report_generators/test_foundation_integration.jl")
        include("report_generators/test_fire_rating_report.jl")
    end

    # ─── Slab Sizing (non-report tests) ──────────────────────────────────
    @testset "Slab Sizing" begin
        include("sizing/slabs/test_vault_pipeline.jl")
    end

    # ─── Member Sizing (non-report tests) ────────────────────────────────
    @testset "Member Sizing" begin
        include("sizing/members/test_aisc_column_examples.jl")
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
