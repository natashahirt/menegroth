# Main test runner for StructuralSizer
# Run with: julia --project=../.. runtests.jl  (from test/ directory)
#
# Not included here (standalone scripts, not @testset):
#   - flat_plate_full_pipeline_validation.jl  (cross-project, uses StructuralSynthesizer)
#   - test_rebar_volume.jl                    (cross-project, uses StructuralSynthesizer)
#   - test_fea_flat_plate.jl                  (cross-project, uses StructuralSynthesizer
#                                              fixtures like `gen_medium_office`; the
#                                              `using StructuralSynthesizer` import only
#                                              resolves under StructuralSynthesizer's test env)
#   - concrete_column/test_catalog_gen.jl     (smoke test, println-based)
#   - concrete_column/test_biaxial_fix.jl     (debug script, println-based)
#   - slabs/test_ddm_multispan.jl             (assert-based, not @testset)
#   - concrete_column/run_biaxial_slenderness_tests.jl (runner script, println-based)

using Test
using Unitful
using StructuralSizer
using Asap  # custom units (kip, ksi, ksf, psf, etc.)

@testset "StructuralSizer Tests" begin

    # ─── Loads ───────────────────────────────────────────────────────────
    @testset "Loads" begin
        include("loads/test_seismic_elf.jl")
        include("loads/test_seismic_nehrp_examples.jl")
        include("loads/test_wind_chapter27.jl")
        include("loads/test_wind_gust.jl")
    end

    # ─── Vault ───────────────────────────────────────────────────────────
    @testset "Vault" begin
        include("haile_vault/test_vault.jl")
    end

    # ─── Steel Members ───────────────────────────────────────────────────
    @testset "Steel Members" begin
        # W-section beams
        include("steel_member/test_aisc_beam_examples.jl")
        include("steel_member/test_handcalc_beam.jl")
        include("steel_member/test_phi_v_provision.jl")
        # HSS sections
        include("steel_member/test_hss_sections.jl")
        include("steel_member/test_hss_e7.jl")
        include("steel_member/test_hss_round_shear.jl")
        include("steel_member/test_hss_torsion.jl")
        # W-section torsion
        include("steel_member/test_w_torsion.jl")
        # Slenderness / local buckling
        include("steel_member/test_qa_slender_web.jl")
        include("steel_member/test_qa_slender_flange.jl")
        # AISC reference examples
        include("steel_member/test_aisc_companion_manual_1.jl")
        include("steel_member/test_aisc_360_reference.jl")
        # Moment amplification (B1/B2)
        include("steel_member/test_b1_b2_amplification.jl")
        include("steel_member/test_b1_checker_integration.jl")
        # Composite beams
        include("steel_member/composite/test_composite_beam.jl")
        include("steel_member/composite/test_composite_per_station.jl")
        # Pure axial members (braces / truss chords / struts / ties)
        include("steel_member/test_axial_members.jl")
    end

    # ─── Members: connection defaults ────────────────────────────────────
    @testset "Member Defaults" begin
        include("members/test_defaults.jl")
        include("members/test_up_eccentricity.jl")
        include("members/test_shared_column_moments.jl")
    end

    # ─── Concrete Beams ──────────────────────────────────────────────────
    @testset "Concrete Beams" begin
        include("concrete_beam/test_beam_section.jl")
        include("concrete_beam/test_rc_rebar_objective.jl")
        include("concrete_beam/test_beam_flexure.jl")
        include("concrete_beam/test_beam_shear.jl")
        include("concrete_beam/test_joist_construction.jl")
        include("concrete_beam/test_joist_ribs.jl")
        include("concrete_beam/test_rib_sets.jl")
        include("concrete_beam/test_beam_design.jl")
        include("concrete_beam/test_beam_deflection.jl")
        include("concrete_beam/test_deflection.jl")
        include("concrete_beam/test_cantilever_beam.jl")
        include("concrete_beam/test_doubly_reinforced.jl")
        include("concrete_beam/test_rc_beam_reference.jl")
        # Torsion
        include("concrete_beam/test_torsion.jl")
        # T-beams
        include("concrete_beam/test_tbeam.jl")
        include("concrete_beam/test_tbeam_optimization.jl")
        include("concrete_beam/test_tbeam_tributary_flange.jl")
        include("concrete_beam/test_tbeam_per_station.jl")
        include("concrete_beam/test_signed_demands.jl")
        include("concrete_beam/test_beam_catalog_growth.jl")
        include("concrete_column/test_column_catalog_growth.jl")
    end

    # ─── Concrete Columns ────────────────────────────────────────────────
    @testset "Concrete Columns" begin
        include("concrete_column/test_rc_column_section.jl")
        include("concrete_column/test_bar_detailing.jl")
        include("concrete_column/test_column_pm.jl")
        include("concrete_column/test_circular_column_pm.jl")
        include("concrete_column/test_biaxial.jl")
        include("concrete_column/test_slenderness.jl")
        include("concrete_column/test_column_shear.jl")
        include("concrete_column/test_floor_transmission.jl")
    end

    # ─── Bar placement ───────────────────────────────────────────────────
    @testset "Detailing" begin
        include("detailing/test_member_detailing.jl")
    end

    # ─── Slabs ───────────────────────────────────────────────────────────
    @testset "Slabs" begin
        # Geometry & tributary
        include("slabs/test_strip_geometry.jl")
        include("slabs/test_spanning_behavior.jl")
        include("slabs/test_panel_analysis.jl")
        include("slabs/test_two_way_thickness.jl")
        include("slabs/test_tributary_workflow.jl")
        # One-way
        include("slabs/test_one_way_slab_reference.jl")
        # Flat plate
        include("slabs/test_flat_plate.jl")
        include("slabs/test_flat_plate_methods.jl")
        include("slabs/test_size_flat_plate.jl")
        include("slabs/test_thickness_jump.jl")
        include("slabs/test_joint_search.jl")
        include("slabs/test_flat_plate_safety_regressions.jl")
        include("slabs/test_aci318_19_slab_provisions.jl")
        include("slabs/test_method_comparison.jl")
        include("slabs/test_efm_frame_lines.jl")
        # DDM / EFM analysis
        include("slabs/test_frameline_ddm.jl")
        include("slabs/test_hardy_cross_larger.jl")
        include("slabs/test_efm_stiffness.jl")
        include("slabs/test_efm_pipeline.jl")
        include("slabs/test_raw_asap_frame.jl")
        # Flat slab (drop panels)
        include("slabs/test_flat_slab.jl")
        # Pipeline provisions (edge beam, ρ', integrity, transfer, face-of-support)
        include("slabs/test_pipeline_provisions.jl")
        # ACI 318-11 audit — Tier 1 correctness gaps (encodes correct behaviour;
        # currently fails / @test_broken on main until fixes land)
        include("slabs/test_aci_audit_tier1.jl")
        include("slabs/test_ddm_edge_mub.jl")
        include("slabs/test_eq_13_7_adjoining.jl")
        include("slabs/test_corner_punching.jl")
        include("slabs/test_moment_transfer_13_5_3_3.jl")
        include("slabs/test_opening_punching.jl")
        include("slabs/test_panel_shell_beams.jl")
        include("slabs/test_slab_edge.jl")
        include("slabs/test_story_shell.jl")
        # General-shape critical sections (ACI 421.1R-99 App. B): non-orthogonal,
        # re-entrant, circular, I-/odd supports via true principal axes
        include("slabs/test_general_critical_section.jl")
        include("slabs/test_wall_punching.jl")
        include("slabs/test_wall_supports.jl")
        include("slabs/test_fea_combo_envelope.jl")
        include("slabs/test_fea_mesh_key.jl")
        # Punching / shear
        include("slabs/test_shear_transfer.jl")
        include("slabs/test_shear_studs.jl")
        include("slabs/test_punching_reinforcement.jl")
        # Torsion discount (ACI concrete torsion capacity for Wood–Armer)
        include("slabs/test_torsion_discount.jl")
        # Column growth
        include("slabs/test_column_growth.jl")
        include("slabs/test_span_clause.jl")
        # Pattern loading
        include("slabs/test_pattern_loading_sizing.jl")
        include("slabs/test_fea_one_way_shear_cut.jl")
        # Stud catalogs
        include("slabs/test_stud_catalog.jl")
        include("slabs/test_composite_deck_shear.jl")
        include("slabs/test_deck_form.jl")
        include("slabs/test_deck_hogging.jl")
        include("slabs/test_deck_floor.jl")
        # Waffle geometry
        include("slabs/test_waffle_geometry.jl")
        include("slabs/test_rib_arrangement.jl")
        include("slabs/test_solid_head_modules.jl")
        include("slabs/test_solid_head_punching.jl")
        include("slabs/test_rib_deflection.jl")
        # Optimizer
        include("slabs/test_flat_plate_optimizer.jl")
        # `test_fea_flat_plate.jl` is intentionally NOT included here — it
        # uses `StructuralSynthesizer` fixtures (`gen_medium_office`, etc.)
        # and only resolves under that project's test env. Run it via
        # `julia --project=StructuralSynthesizer` instead.
    end

    # ─── Foundations ──────────────────────────────────────────────────────
    @testset "Foundations" begin
        include("foundations/test_spread_footing.jl")
        include("foundations/test_spread_aci.jl")
        include("foundations/test_foundation_combinations.jl")
        include("foundations/test_strip_aci.jl")
        include("foundations/test_wall_footing.jl")
        include("foundations/test_mat_walls.jl")
        include("foundations/test_strip_unequal_c_across.jl")
        include("foundations/test_mat_aci.jl")
        include("foundations/test_mat_rigid_statics.jl")
        include("foundations/test_foundation_stiffness.jl")
        include("foundations/test_wall_strip.jl")
        include("foundations/test_corner_punching.jl")
        include("foundations/test_rebar_quantity.jl")
        include("foundations/test_no_tension_springs.jl")
        include("foundations/test_types_load.jl")
        include("foundations/test_foundation_safety_9_15.jl")
    end

    # ─── Optimization ────────────────────────────────────────────────────
    @testset "Optimization" begin
        include("optimize/test_column_optimization.jl")
        include("optimize/test_column_full.jl")
        include("optimize/test_column_nlp.jl")
        include("optimize/test_column_nlp_adapter.jl")
        include("optimize/test_hss_column_nlp.jl")
        include("optimize/test_w_column_nlp.jl")
        include("optimize/test_multi_material_mip.jl")
        include("optimize/test_binary_search_depth.jl")
        include("optimize/test_sizing_strategy_contract.jl")
        include("optimize/test_explain_agreement.jl")
        include("optimize/test_section_relaxation.jl")
        include("optimize/test_coupled_warm_start.jl")
        include("optimize/test_pareto_scalarization.jl")
        include("optimize/test_epsilon_pareto.jl")
        include("optimize/test_drift_optimality.jl")
        include("optimize/test_drift_governor.jl")
    end

    # ─── Structural Walls (lateral system) ───────────────────────────────
    @testset "Walls" begin
        include("walls/test_walls.jl")
        include("walls/test_special_boundary.jl")
        include("walls/test_boundary_bars.jl")
        include("walls/test_coupling_beams.jl")
        include("walls/test_special_wall.jl")
        include("walls/test_flanged_section.jl")
        include("walls/test_fem_rigid_diaphragm.jl")
    end

    # ─── PixelFrame ──────────────────────────────────────────────────────
    @testset "PixelFrame" begin
        include("pixelframe/test_pixelframe_capacities.jl")
        include("pixelframe/test_pixelframe_checker.jl")
    end

    # ─── VCmaster Reference ──────────────────────────────────────────────
    @testset "VCmaster Reference" begin
        include("test_vcmaster_reference.jl")
    end

    # ─── Fire Provisions ──────────────────────────────────────────────────
    @testset "Fire Provisions" begin
        include("test_fire_provisions.jl")
    end

    # ─── Material Presets (LWC) ───────────────────────────────────────────
    @testset "Material Presets" begin
        include("test_lwc_materials.jl")
    end

    # ─── Element Rebar ────────────────────────────────────────────────────
    @testset "Element Rebar" begin
        include("test_element_rebar.jl")
    end

    # ─── Solver Trace ────────────────────────────────────────────────────
    @testset "Solver Trace" begin
        include("trace/test_trace.jl")
    end

end
