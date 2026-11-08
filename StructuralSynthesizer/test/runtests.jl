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
        include("core/test_walls_bridge.jl")
        include("core/test_design_api.jl")
        include("core/test_api_units_faces.jl")
        include("core/test_courtyard_void.jl")
        include("core/test_slab_openings.jl")
        include("core/test_api_scoped_overrides_payload.jl")
        include("core/test_api_sizing_strategy_contract.jl")
        include("core/test_chat_api.jl")
        include("core/test_diagnose_api.jl")
        include("core/test_design_state.jl")
        include("core/test_micro_experiments.jl")
        include("core/test_postprocess_ec.jl")
    end

    # ─── Geometry & Utilities ────────────────────────────────────────────
    @testset "Geometry & Utilities" begin
        include("geometry/test_slab_geometry.jl")
        include("geometry/test_slab_coloring.jl")
    end

    # ─── Design Graph (Incremental Design DAG — Run 1 gate + Run 2 engine) ─
    @testset "Design Graph" begin
        include("design_graph/test_design_graph_topology.jl")
        include("design_graph/test_design_graph_equivalence.jl")
        include("design_graph/test_design_graph_incremental.jl")
    end

    # ─── Analysis ────────────────────────────────────────────────────────
    @testset "Analysis" begin
        include("analyze/test_drape.jl")
        include("analyze/test_pattern_loading.jl")
        include("analyze/test_pattern_live_three_quarter.jl")
        include("analyze/test_structural_offset.jl")
        include("analyze/test_corner_kind.jl")
        include("analyze/test_mesh_refinement.jl")
        include("analyze/test_member_group_demands.jl")
        include("analyze/test_section_floor.jl")
        include("analyze/test_foundation_demands.jl")
        include("analyze/test_column_populate_ltb.jl")
        include("analyze/test_wall_phase5_assembly.jl")
        include("analyze/test_wall_cuts.jl")
        include("analyze/test_wall_joints.jl")
        include("analyze/test_wall_openings.jl")
        include("analyze/test_wall_pier_checks.jl")
        include("analyze/test_support_regions.jl")
        include("analyze/test_seismic_wall_gates.jl")
        include("analyze/test_wall_story_cuts.jl")
        include("analyze/test_story_pdelta.jl")
        include("analyze/test_wall_combinations.jl")
        include("analyze/test_wall_ordinary.jl")
        include("analyze/test_ordinary_wall_stage.jl")
        include("analyze/test_wall_detailing.jl")
        include("analyze/test_skew_plan_walls.jl")
        include("analyze/test_lateral_approaches.jl")
        include("analyze/test_node_rotations.jl")
        include("analyze/test_diaphragm_idealization.jl")
        include("analyze/test_elf_story_cases.jl")
        include("analyze/test_wind_story_cases.jl")
        include("analyze/test_composite_context.jl")
        include("analyze/test_story_shell.jl")
        include("analyze/test_story_shell_beams.jl")
    end

    # ─── Scene packets (web viewer) ──────────────────────────────────────
    @testset "Scene" begin
        include("visualization/test_scene.jl")
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
        include("report_generators/test_walls_report.jl")
    end

    # ─── Slab Sizing (non-report tests) ──────────────────────────────────
    @testset "Slab Sizing" begin
        include("sizing/slabs/test_floor_design_contracts.jl")
        include("sizing/slabs/test_panel_classification.jl")
        include("sizing/slabs/test_flat_plate_pure_methods.jl")
        include("sizing/slabs/test_vault_pipeline.jl")
        include("sizing/slabs/test_fea_remesh.jl")
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
        include("integration/test_deck_floor_building.jl")
        include("integration/test_building_detailing.jl")
    end

end
