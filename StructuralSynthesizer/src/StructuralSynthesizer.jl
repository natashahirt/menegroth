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
import LinearAlgebra: norm, normalize
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

# Design types (BuildingDesign, DesignParameters, result structs)
include("design_types.jl")

# Core functionality (includes tributary_accessors.jl)
include("core/_core.jl")

# Design graph scaffolding (node interface + container + executor). Included
# before design_workflow.jl so `build_design_graph` / `execute_graph!` and the
# node types are available to the workflow. Include order relative to
# building_types.jl / design_types.jl IS load-critical: executor.jl's
# `execute_graph!` method signature annotates `struc::BuildingStructure,
# params::DesignParameters`, and those type annotations are resolved at load
# time (method-definition time), not at call time — so `BuildingStructure` and
# `DesignParameters` must already be defined. This include MUST therefore come
# after building_types.jl and design_types.jl.
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

# =============================================================================
# Exports
# =============================================================================

# --- Geometry generation ---
export gen_medium_office

# --- Building types ---
export BuildingSkeleton, BuildingStructure, Story
export SiteConditions, MaterialVolumes, VolumeType
export Cell, Slab, SlabGroup, thickness
export CellGroup
export Segment, MemberGroup
# Framing hierarchy (Phase 4). AbstractJoistPattern + joist_geometry come from
# StructuralSizer via @reexport; the concrete patterns + FramingLevel are local.
export LinearAxisPattern, IsoparametricPattern, RadialPattern, CustomPattern
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
export cell_edge_tributaries, cell_strip_geometry, has_cell_tributaries
export clear_geometry_caches!

# --- Design types ---
export DesignParameters, MaterialOptions, FoundationParameters
export MemberGroupSizingOverride, resolve_member_group_override
export BuildingDesign, SlabDesignResult, ColumnDesignResult, BeamDesignResult, FoundationDesignResult
export PunchingDesignResult, StripReinforcementDesign, DesignSummary
export DisplayUnits, imperial, metric, fmt
export structure, skeleton  # BuildingDesign accessors
export slab_design, column_design, beam_design, foundation_design, all_ok, critical_ratio
export has_analysis_model, build_analysis_model!

# --- Design workflow ---
export design_building, compare_designs, build_pipeline, PipelineStage, sync_asap!
export prepare!, capture_design

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
export NODE_SLAB_SIZING, NODE_MEMBERS, NODE_FOUNDATIONS, NODE_CAPTURE
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
export all_members, segment_indices, member_length, unbraced_length
export group_id, section, volumes, set_group_id!, set_section!, set_volumes!
# Framing-hierarchy role / level helpers (Phase 1)
export is_girder, is_joist, is_beam, level_of, lateral_role_of
# Variable tributary profile (Phase 0)
export TributaryProfile, tributary_profile, tributary_width_scalar, tributary_width_envelope
export compute_member_tributaries!
export classify_column_position, is_exterior_support  # Column position classification for DDM/EFM
export update_structural_offsets!, structural_center_xy_m  # Architectural → structural centerline
export Support, Foundation, FoundationGroup, FoundationDemand

# --- Building operations ---
export add_vertex!, add_element!, find_faces!, rebuild_stories!, to_asap!
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

# --- Frame lines and slab geometry ---
export FrameLine, perpendicular, direction_vector
export n_spans, n_joints, is_end_span, get_span_supports
export decompose_to_rectangles, group_by_connectivity
export validate_and_split_slab, build_cell_grid, CellGrid
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
export element_ec, compute_building_ec, ec_summary
export ElementECResult, BuildingECResult
export to_dict
export engineering_report

# --- API server ---
export register_routes!, json_to_skeleton, json_to_params, design_to_json, design_to_diagnose
export validate_input, compute_geometry_hash
# --- Harness Phase 1: unified design-state projection + corpus grounding ---
export design_to_design_state, ground_check, citation_id
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

using PrecompileTools

const ENABLE_HEAVY_PRECOMPILE_WORKLOAD = lowercase(get(ENV, "SS_ENABLE_HEAVY_PRECOMPILE_WORKLOAD", "true")) == "true"

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
