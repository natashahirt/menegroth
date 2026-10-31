
"""
A complete design solution for a BuildingStructure.

Holds a reference to the source `BuildingStructure` for geometry access,
enabling a clean API: `visualize(design)` works without passing structure separately.

Multiple BuildingDesign instances can reference the same BuildingStructure,
enabling comparison of different material choices or optimization targets.

`walls` is keyed by index into `structure.walls`. Each entry holds one
[`WallCheckRecord`](@ref) per check of that wall, story, direction, and
combination. `seismic_story_drift` holds one comparison per ELF drift story.

# Example
```julia
building = BuildingStructure(skeleton)
# ... initialize cells, members ...

design1 = BuildingDesign(building, DesignParameters(
    name = "Concrete 4ksi",
    materials = MaterialOptions(concrete = NWC_4000),
))

design2 = BuildingDesign(building, DesignParameters(
    name = "Concrete 6ksi",
    materials = MaterialOptions(concrete = NWC_6000),
))

visualize(design1)  # Self-contained: accesses geometry via design.structure
compare_designs(design1, design2)
```
"""
mutable struct BuildingDesign{T, A, P}
    # Reference to source building (pointer, not copy)
    structure::BuildingStructure{T, A, P}
    
    # Design configuration
    params::DesignParameters
    
    # Design results (keyed by member index)
    slabs::Dict{Int, SlabDesignResult}
    columns::Dict{Int, ColumnDesignResult}
    beams::Dict{Int, BeamDesignResult}
    # Sidecar keyed by index into `structure.walls`. One record per check.
    walls::Dict{Int, Vector{WallCheckRecord}}
    # One [`SeismicStoryDriftCheck`](@ref) per ELF drift story. `Any` because
    # that type is defined after this struct.
    seismic_story_drift::Vector{Any}
    foundations::Dict{Int, FoundationDesignResult}
    
    # Summary
    summary::DesignSummary
    
    # ─── Analysis Model ───
    # Frame+shell model for global deflection analysis (built after design)
    # Separate from struc.asap_model to preserve the design-phase frame model
    asap_model::Union{Asap.Model, Nothing}
    # Skeleton edge index for each frame element in asap_model (when built via build_analysis_model!).
    # Enables correct element→design mapping for visualization; empty when using struc.asap_model.
    asap_model_frame_edge_indices::Vector{Int}
    
    # Structural offsets captured at design time (vertex_idx → (dx_m, dy_m)).
    # Persists edge/corner column offsets so serialization can reconstruct
    # centerline positions after restore! wipes them from the structure.
    structural_offsets::Dict{Int, NTuple{2, Float64}}
    
    # Wall-clock time for each design phase (prepare, pipeline, capture, etc.)
    phase_timings::Dict{String, Float64}

    # Solver decision trace (populated when TraceCollector is passed to design_building)
    solver_trace::Vector{StructuralSizer.TraceEvent}

    # Finalization contract. Published designs own their structure and parameter
    # snapshots; callers may inspect them but must not treat them as a workspace.
    finalized::Bool
    converged::Bool
    diagnostics::Vector{String}
    context_hash::String
    
    # Metadata
    created::DateTime
    compute_time_s::Float64
end

"""
    BuildingDesign(struc, params=DesignParameters()) -> BuildingDesign

Construct an empty `BuildingDesign` with empty result dictionaries and a fresh timestamp.
"""
function BuildingDesign(struc::BuildingStructure{T, A, P}, params::DesignParameters=DesignParameters()) where {T, A, P}
    # Fail-loud guard (Run 4) — STRUCTURAL choke point. This constructor is the
    # single universal path through which every BuildingDesign is materialized
    # (design_building, redesign, vary, redesign_incremental!, and the primitive
    # build_design_graph -> execute_graph! -> capture_design and run_target! +
    # capture_incremental_design paths all route here). Phase B HONORS effective
    # steel-beam-group overrides; this struc-aware guard is the backstop that
    # refuses the un-honorable targets (flat-plate/flat-slab floors, non-steel or
    # coupled beam sizing, and column/strut groups — the last decidable only with
    # prepared members) so no materialization path silently drops one. Empty /
    # all-unset (vacuous) overrides pass unchanged (byte-identical happy path).
    # See _assert_member_group_overrides_unsupported.
    _assert_member_group_overrides_unsupported(params, struc)
    BuildingDesign{T, A, P}(
        struc,
        params,
        Dict{Int, SlabDesignResult}(),
        Dict{Int, ColumnDesignResult}(),
        Dict{Int, BeamDesignResult}(),
        Dict{Int, Vector{WallCheckRecord}}(),
        Any[],
        Dict{Int, FoundationDesignResult}(),
        DesignSummary(),
        nothing,  # asap_model (built via build_analysis_model!)
        Int[],    # asap_model_frame_edge_indices (populated by build_analysis_model!)
        Dict{Int, NTuple{2, Float64}}(),  # structural_offsets (captured by capture_design)
        Dict{String, Float64}(),          # phase_timings (populated by design_building)
        StructuralSizer.TraceEvent[],     # solver_trace (populated when tc is passed)
        false,                            # finalized
        false,                            # converged
        String[],                         # diagnostics
        "",                               # context_hash
        now(),
        0.0
    )
end

# =============================================================================
# BuildingDesign Accessors
# =============================================================================

"""Get the source BuildingStructure."""
structure(d::BuildingDesign) = d.structure

"""Get the source BuildingSkeleton (shorthand for d.structure.skeleton)."""
skeleton(d::BuildingDesign) = d.structure.skeleton

"""Get slab design result by index."""
slab_design(d::BuildingDesign, idx::Int) = get(d.slabs, idx, nothing)

"""Get column design result by index."""
column_design(d::BuildingDesign, idx::Int) = get(d.columns, idx, nothing)

"""Get beam design result by index."""
beam_design(d::BuildingDesign, idx::Int) = get(d.beams, idx, nothing)

"""Get foundation design result by index."""
foundation_design(d::BuildingDesign, idx::Int) = get(d.foundations, idx, nothing)

"""Check if all design checks pass."""
all_ok(d::BuildingDesign) = d.summary.all_checks_pass

"""Get the governing (critical) design ratio."""
critical_ratio(d::BuildingDesign) = d.summary.critical_ratio

"""Check if the analysis model (frame+shell) has been built."""
has_analysis_model(d::BuildingDesign) = !isnothing(d.asap_model)
