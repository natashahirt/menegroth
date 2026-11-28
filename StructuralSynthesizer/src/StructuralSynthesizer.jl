module StructuralSynthesizer

using Logging
using Printf
using Reexport

# StructuralSizer re-exports units from Asap, so we get everything via StructuralSizer
@reexport using StructuralSizer

# Extend StructuralSizer's floor-result interface functions for local wrapper types
# (e.g. `Slab`). In Julia, adding methods requires `import`, not `using`.
import StructuralSizer: self_weight, total_depth, structural_effects

import Meshes
import Graphs
import Asap
import LinearAlgebra: norm, normalize, diag, eigmin, Symmetric
import SparseArrays: sparse, spzeros, SparseMatrixCSC
using Unitful

function __init__()
    _ensure_asap_units!()
end

# Expected Asap custom-unit symbols. Used by the runtime sanity check.
# `:KgCO2e` is the embodied-carbon-equivalent ref-unit (Asap dimension `𝐗`),
# added alongside the existing US-customary units.
const _ASAP_UNIT_SYMS = (:Kip, :KipPerSquareInch, :PoundPerSquareFoot,
                          :KipPerSquareFoot, :PoundPerCubicFoot, :KgCO2e)

"""
    _ensure_asap_units!()

Force-register Asap custom units (kip, ksi, psf, …) into `Unitful.basefactors`.

Two strategies are tried:

1. `Unitful.register(Asap)` — the canonical Unitful mechanism (reads the hidden
   per-module basefactors dict that `@unit` populated at compile time).
2. `merge!(basefactors, Asap._localunits)` — snapshot captured at precompile time.

After both, a sanity check confirms every expected symbol is present and logs
an error for any that are missing.
"""
function _ensure_asap_units!()
    Unitful.register(Asap)

    if isdefined(Asap, :_localunits) && !isempty(Asap._localunits)
        merge!(Unitful.basefactors, Asap._localunits)
    end

    for sym in _ASAP_UNIT_SYMS
        haskey(Unitful.basefactors, sym) && continue
        @error "StructuralSynthesizer.__init__: Unitful.basefactors is missing :$sym — " *
               "unit conversions will fail. _localunits has $(length(get(Main, :_localunits, Dict()))) entries; " *
               "Asap._localunits has $(isdefined(Asap, :_localunits) ? length(Asap._localunits) : "N/A") entries"
    end
end

# =============================================================================
# File includes (order matters!)
# =============================================================================

# Loads (LoadCombination, GravityLoads, pattern loading) come from StructuralSizer
# via @reexport — no local include needed.

# Building types (includes TributaryCache, BuildingStructure, etc.)
include("building_types.jl")

# Wall-bridge geometry derivation (true plate geometry + per-story centre of mass
# for the reduced lateral evaluator). Included after building_types.jl so it can
# fully annotate BuildingSkeleton / Story / Cell / GeometryCache, which members.jl
# (loaded before skeleton.jl) cannot. The plate/CoM are derived from the skeleton
# vertex_coords datum; wall plan coords are NOT guaranteed to share it, so the
# helper VERIFIES walls ⊆ plate (assert_walls_enclosed) rather than assuming it.
include("walls_bridge.jl")

# Lateral design vocabulary, named by DesignParameters.lateral. Behavior is in
# analyze/lateral/approaches/.
include("analyze/lateral/approaches/types.jl")
include("analyze/lateral/ordinary_wall_inputs.jl")

# Design types (BuildingDesign, DesignParameters, result structs)
include("design_types.jl")

# Core functionality (includes tributary_accessors.jl)
include("core/_core.jl")

# Typed floor-design adapter and transactional installation boundary
include("floor_design_contracts.jl")

# Design graph scaffolding (node interface + container + executor). Included
# before design_workflow.jl so `build_design_graph` / `execute_graph!` and the
# node types are available to the workflow. Include order relative to
# building_types.jl / design_types.jl IS load-critical: executor.jl's
# `execute_graph!` method signature annotates `struc::BuildingStructure,
# params::DesignParameters`, and those type annotations are resolved at load
# time (method-definition time), not at call time — so `BuildingStructure` and
# `DesignParameters` must already be defined. This include MUST therefore come
# after building_types.jl and design_types.jl.
include("workflow/sizing_probe.jl")
include("design_graph/_design_graph.jl")

# Design workflow (uses both building_types and design_types)
include("design_workflow.jl")

# Geometry utilities (frame lines, slab validation)
include("geometry/_geometry.jl")

# Other modules
include("generate/_generate.jl")
include("analyze/_analyze.jl")
# Framing auto-generation (Phase 5): populate_levels! / derive_framing_level /
# materialize_level!. Included after analyze/_analyze.jl so it can use
# compute_member_tributaries! (analyze/members/utils.jl) and slab_face_edge_ids
# (analyze/asap/utils.jl); it also builds on the Phase-4 building_types.
include("analyze/framing/populate.jl")
include("postprocess/_postprocess.jl")

# API server (Oxygen routes, JSON serialization)
include("api/_api.jl")

# Binary scene packets for the web viewer (docs/src/reference/scene_format.md).
include("scene/_scene.jl")

# Finalized design file. The scene is rebuilt from this; the design is not re-run.
include("design/archive.jl")

# =============================================================================
# Exports
# =============================================================================

# --- Scene packets (web viewer) ---
export build_scene, write_scene, read_scene, export_scene, export_scene_meshes, ScenePacket
export append_variant!, write_design_variants, drop_variant!, compact_variants!
export read_variant_index, materialize_variant, variant_neighbors, variant_axes, variant_stored_hashes
export structure_geometry_hash, param_snapshot, PARAM_ANCHOR
export scene_buffer, scene_f32, scene_u32, scene_u16, scene_u8
export scene_station_displacement, hermite_local, demo_frame_model

# --- Geometry generation ---
export gen_medium_office, add_center_core!

# --- Building types ---
export BuildingSkeleton, BuildingStructure, Story
export SiteConditions, MaterialVolumes, VolumeType
export Cell, Slab, SlabGroup, thickness
export CellGroup
export Segment, MemberGroup
# Framing hierarchy (Phase 4). AbstractJoistPattern + joist_geometry come from
# StructuralSizer via @reexport; the concrete patterns + FramingLevel are local.
export LinearAxisPattern, IsoparametricPattern, ModularRibPattern, RadialPattern, CustomPattern
export FramingLevel, attach_framing_level!
# Framing auto-generation (Phase 5)
export populate_levels!, derive_framing_level, materialize_level!

# --- Tributary cache types ---
export TributaryCache, TributaryCacheKey
export CellTributaryResult, ColumnTributaryResult
export has_edge_tributaries, has_vertex_tributaries
export get_edge_tributaries, set_edge_tributaries!
export get_vertex_tributary, set_vertex_tributary!

# --- Tributary accessors (core/tributary_accessors.jl) ---
export tributary_cache_key
export get_cached_edge_tributaries, cache_edge_tributaries!
export get_cached_column_tributary, cache_column_tributary!
export column_tributary_area, column_tributary_by_cell, column_tributary_polygons
export split_cell_edges, split_cell_walls, cell_support_polygons, ColumnSupportShare, WallSupportShare, WallWidthPiece
export wall_edge_nodal_forces, wall_tributary_area
export cell_edge_tributaries, cell_strip_geometry, has_cell_tributaries
export clear_geometry_caches!

# --- Design types ---
export DesignParameters, ResolvedDesignContext, resolve_design_context
export MaterialOptions, FoundationParameters
export MemberGroupSizingOverride, resolve_member_group_override
export BuildingDesign, SlabDesignResult, ColumnDesignResult, BeamDesignResult, FoundationDesignResult
export PunchingDesignResult, StripReinforcementDesign, DesignSummary
export DisplayUnits, imperial, metric, fmt
export structure, skeleton  # BuildingDesign accessors
export slab_design, column_design, beam_design, foundation_design, all_ok, critical_ratio
export has_analysis_model, build_analysis_model!
export save_design, load_design

# --- Design workflow ---
export design_building, compare_designs, build_pipeline, PipelineStage, sync_asap!
export analyze_story_shell, ShellBeamDemand, story_shell_beam_demands, size_beams_with_story_shell!
export StoryShell, build_story_shell, solve_story_shell!
export prepare!, capture_design
export floor_design_request, design_floor, design_floor!, design_floors!, install_floor_design!

# --- Design graph (Run 1: node layer wrapping the pipeline) ---
export DesignNode, StageNode, NodeKey, DesignGraph
export build_design_graph, execute_graph!, topological_order
export node_key, dependencies, needs_sync
export PreSizingValidationError, run_pre_sizing_validation
export snapshot!, restore!, has_snapshot, delete_snapshot!, snapshot_keys
export DesignSnapshot, SlabSnapshot

# --- Design graph (Run 2: incremental engine) ---
# Node provenance + canonical identities
export param_slice, struc_reads, struc_writes, code_version, node_provenance
export canonical_node_keys, pipeline_provenance
export NODE_INITIALIZE, NODE_POPULATE_FRAMING, NODE_ESTIMATE_COLUMNS, NODE_BUILD_ASAP
export NODE_SLAB_SIZING, NODE_MEMBERS, NODE_FOUNDATIONS, NODE_ORDINARY_WALLS, NODE_CAPTURE
# Graph queries
export transitive_dependencies, descendants
# Fingerprinting
export content_hash, hash_param_slice, input_hash, output_hash
# Per-node snapshots
export capture_node_state, restore_node_state, snapshot_node!, restore_node
# Scheduler / engine
export IncrementalEngine, NodeMemo, prepare_engine, run_target!
export capture_incremental_design, redesign_incremental!
export last_recomputed, last_restored, terminal_node
export changed_param_fields, dirty_frontier
# Stateful variation API (session) — dirty_frontier already exported above
export DesignSession, redesign, vary, base_design, base_params
export requires_new_engine, prepare_affecting_changes

# --- Design parameter helpers ---
export with, resolve_concrete, resolve_rebar, resolve_rc_material, resolve_floor_options

# --- Loads (re-exported from StructuralSizer via @reexport) ---
# GravityLoads, LoadCombination, factored_pressure, envelope_pressure, etc.
# are all available without additional exports here.
export governing_combo, validate_fire_rating, has_fire_rating  # defined locally in design_types.jl
export add_coating_loads!

# --- Member type hierarchy ---
export AbstractMember, MemberBase, Beam, Column, Strut, Wall
export wall_center, wall_length, wall_orientation, to_wall_line  # Shear-wall geometry + lateral-system bridge
# True plate geometry + per-story centre of mass for the reduced lateral evaluator
# (derived from the skeleton vertex_coords datum; assert_walls_enclosed VERIFIES
# walls ⊆ plate rather than assuming a shared frame; seismic weight per ASCE 7-22 §12.7.2)
export story_plate_geometry, story_floor_outline, projected_plan_width, story_center_of_mass, effective_seismic_weight, assert_walls_enclosed, walls_bridge_selfcheck
export all_members, segment_indices, member_length, unbraced_length
export group_id, section, volumes, set_group_id!, set_section!, set_volumes!
# Framing-hierarchy role / level helpers (Phase 1)
export is_girder, is_joist, is_beam, level_of, lateral_role_of
# Variable tributary profile (Phase 0)
export TributaryProfile, tributary_profile, tributary_width_scalar, tributary_width_envelope
export compute_member_tributaries!
# Building → composite check (AISC Ch. I): per-side §I3.1a profiles, scalar
# context, exact FEM demand field, and the per-station governing check.
export beam_side_profiles, composite_context_from_beam
export beam_interior_supports, beam_support_lookup
export beam_signed_moment_field, check_composite_beam, composite_deflection_scale
export apply_composite_element_stiffness!, refine_composite_stiffness!
export set_slab_openings!, SlabOpening, add_slab_opening!, frame_slab_openings!, face_openings, face_opening_loops, face_hole_loops, face_net_area
export WallOpening, WallOpeningSpec, add_wall_opening!
export composite_group_payload, composite_payloads_for_groups, composite_anchor_from_options
export classify_column_position, is_exterior_support  # Column position classification for DDM/EFM
export slab_material_angle, classify_corner_kind       # Corner refinement (convex vs re-entrant)
export update_structural_offsets!, structural_center_xy_m  # Architectural → structural centerline
export Support, Foundation, FoundationGroup, FoundationDemand

# --- Building operations ---
export add_vertex!, add_element!, find_faces!, rebuild_stories!, to_asap!
export require_diaphragm_node_stiffness
export classify_diaphragm_idealization, deck_floor_diaphragm, stricter_diaphragm_idealization
export diaphragm_inertial_force, diaphragm_bay_actions
export FlexibleDiaphragmLayout, DiaphragmLine, flexible_diaphragm_layout!
export SemirigidDiaphragmLayout, SemirigidFloor, semirigid_shells, set_semirigid_stiffness!, semirigid_sfrs!
export elf_story_analysis
export SeismicEffectCase, seismic_effect_cases, seismic_effect_loads
export orthogonal_combination_required, nonparallel_system_elements
export unit_plan_axis, plan_axes
export wind_story_analysis
export check_seismic_story_drift, wind_story_drift_report
export factored_wind_cases, factored_seismic_cases
export WallMesh, WallPierMesh, WallAssembly, WallCut, StoryCutEquilibrium
export wall_assemblies, wall_pier_cut, check_story_cut_equilibrium
export check_opening_row_equilibrium
export SpandrelEndAction, PierSegmentActions, SpandrelSegmentActions
export VerticalSegmentForces, HorizontalSegmentForces, SegmentForceReport, OpeningRowGate
export pier_segment_actions, spandrel_segment_actions
export segment_opening_forces, opening_row_equilibria
export segment_end_strength, check_pier_segment, column_one_way_shear_capacity
export WALL_MESH_DIV, WALL_MESH_ROWS, wall_panel_quads
export wall_self_weight_loads
export GravityBasicCases, solve_gravity_basic_cases
export WallAction, PierGravityActions, CombinedWallAction
export wall_action_from_global, pier_wall_action, pier_gravity_actions
export assembly_wall_action, combine_wall_action, wall_strength_actions
export wind_pier_actions, seismic_strength_pier_actions
export WallCheckRecord, check_ordinary_wall
export OrdinaryWallInputs, OrdinaryWallResult, design_ordinary_walls!
export DualSystemResult, design_dual_system!
export WallThicknessTrial, propose_wall_thickness, scale_wall_action
export shared_wall_thickness, wall_thickness_groups, WALL_THICKNESS_GROUPINGS,
       propose_wall_thicknesses, wall_thickness_candidates, wall_thickness_passes
export pier_self_weight_N, wall_thickness_scale_applies, apply_wall_thickness!
export split_tee_junctions!, joined_clear_length, assembly_corners, WallCorner
export joint_vertical_shear, corner_vertical_shear, joined_assembly_cuts
export select_corner_ratio
export require_seismic_wall_demand_provisions
export LateralDesign, LateralSystem, DemandAssignment
export WallsSeismicSystem, InteractiveShearWallFrameSystem, DualSystem
export OutriggerSystem, BuildingUnit, IsolatedWallShare
export prepare_lateral_model!, seismic_members, system_checks, assign_lateral_demands
export SeismicStoryDriftCheck, WindStoryDriftReport, FactoredLateralCase
export initialize!, size!
export create_slab_diaphragm_shells

# --- Lookup utilities ---
export SkeletonLookup, enable_lookup!, build_lookup!, disable_lookup!
export find_vertex, find_edge, find_face, validate_lookup

# --- Geometry cache + query helpers ---
export GeometryCache, rebuild_geometry_cache!
export edge_length, face_area, vertex_coords, edge_vertices, face_vertices
export edge_face_count, edge_story
export is_convex_face

# --- Frame lines ---
export FrameLine, perpendicular, direction_vector
export n_spans, n_joints, is_end_span, get_span_supports
export initialize_cells!, initialize_slabs!
export initialize_segments!, initialize_members!, update_bracing!
export build_slab_groups!, build_cell_groups!, compute_cell_tributaries!
# update_slab_loads! / update_all_slab_loads! removed — use sync_asap!(struc; params)
export update_slab_volumes!
export slab_conflict_coloring, compute_slab_parallel_batches!

# --- Member sizing ---
export build_member_groups!, member_group_demands
export group_collinear_members!
export size_steel_members!, size_member_group!
export size_beams!, size_columns!, size_members!
export estimate_column_sizes!
export compute_story_properties!, p_delta_iterate!

# --- Slab summary ---
export slab_summary, flat_plate_moment_comparison

# --- Foundation sizing ---
export initialize_supports!, initialize_foundations!, size_foundations!
export support_demands, foundation_summary, build_foundation_groups!
export group_foundations_by_reaction!, size_foundations_grouped!, foundation_group_summary

# --- Postprocessing (Embodied Carbon + Engineering Report) ---
export element_ec, material_ec, material_ec_total, material_takeoff, takeoff_by_element, compute_building_ec, ec_summary
export BuildingDetail, detail_building, building_detail_mass
export ElementECResult, BuildingECResult, MaterialTakeoff
export to_dict
export engineering_report

# --- API server ---
export register_routes!, json_to_skeleton, json_to_params, design_to_json, design_to_diagnose
export validate_input, compute_geometry_hash
# --- Harness Phase 1: unified design-state projection + corpus grounding ---
export design_to_design_state, ground_check, citation_id
export design_state_content_bytes, design_state_generated_at
export APIInput, APIOutput, APIError, APIParams
export status_string, SERVER_STATUS  # for lightweight bootstrap /status delegation
export DESIGN_CACHE
# --- API schema ---
export api_input_schema, api_params_schema_structured, api_applicability_schema, api_diagnose_schema, api_tool_schema
# --- Report / summary ---
export report_summary_json, condense_result
# --- Chat (public-facing) ---
export register_chat_routes!

# =============================================================================
# Precompilation Workload
# =============================================================================
# Comprehensive workload that exercises every hot code path:
#   1. Full design_building DDM (initialize → estimate columns → to_asap →
#      size_slabs [DDM moments, column P-M MIP, punching, deflection,
#      one-way shear, rebar design] → result building)
#   2. Full design_building EFM (Asap FrameModel build + solve for EFM)
#   3. Steel member sizing (member_group_demands + AISC MIP from Asap model)
#
# Opt-in: it adds ~10 min to every rebuild. Enable it per environment with
#   [StructuralSynthesizer]
#   heavy_precompile_workload = true
# in the LocalPreferences.toml next to the active Project.toml. A preference
# (unlike an ENV var) is part of the precompile cache key, so toggling it
# triggers a rebuild instead of silently reusing a cache built the other way.
# `precompile_workload = false` (PrecompileTools) disables all workloads.

using PrecompileTools

# Same calls Preferences.@load_preference makes, without adding a dependency.
Base.record_compiletime_preference(Base.PkgId(@__MODULE__).uuid, "heavy_precompile_workload")
const ENABLE_HEAVY_PRECOMPILE_WORKLOAD =
    get(Base.get_preferences(Base.PkgId(@__MODULE__).uuid), "heavy_precompile_workload", false)::Bool

if ENABLE_HEAVY_PRECOMPILE_WORKLOAD
    @setup_workload begin
        @compile_workload begin
            redirect_stdio(; stdout=devnull, stderr=devnull) do
                # =================================================================
                # 2. Full DDM pipeline via design_building
                #    Cascades through: initialize! → estimate_column_sizes! →
                #    to_asap! → size_slabs!(DDM) → column P-M MIP → punching →
                #    deflection → one-way shear → rebar design → results
                #    NOTE: Use realistic spans (~18ft) so column sizing succeeds.
                #    40m/3 = 13.3m spans were infeasible for RC column catalog.
                # =================================================================
                try
                    _skel_ddm = gen_medium_office(54.0u"ft", 42.0u"ft", 10.0u"ft", 3, 3, 1)
                    _struc_ddm = BuildingStructure(_skel_ddm)
                    design_building(_struc_ddm, DesignParameters(
                        name = "precompile_ddm",
                        floor = StructuralSizer.FlatPlateOptions(method = StructuralSizer.DDM()),
                        max_iterations = 2,
                    ))
                catch; end

                # =================================================================
                # 3. Full EFM pipeline via design_building
                #    Exercises Asap FrameModel build + solve for equivalent frame
                # =================================================================
                try
                    _skel_efm = gen_medium_office(54.0u"ft", 42.0u"ft", 10.0u"ft", 2, 2, 1)
                    _struc_efm = BuildingStructure(_skel_efm)
                    design_building(_struc_efm, DesignParameters(
                        name = "precompile_efm",
                        floor = StructuralSizer.FlatPlateOptions(method = StructuralSizer.EFM()),
                        max_iterations = 2,
                    ))
                catch; end

                # =================================================================
                # 4. Steel member sizing (Asap ElementInternalForces + AISC MIP)
                # =================================================================
                try
                    _skel_st = gen_medium_office(54.0u"ft", 42.0u"ft", 10.0u"ft", 2, 2, 1)
                    _struc_st = BuildingStructure(_skel_st)
                    initialize!(_struc_st; floor_type = :flat_plate)
                    to_asap!(_struc_st)
                    Asap.solve!(_struc_st.asap_model)
                    size_steel_members!(_struc_st;
                        member_edge_group = :beams,
                        resolution = 20,
                    )
                catch; end
            end
        end
    end
end

end # module StructuralSynthesizer
