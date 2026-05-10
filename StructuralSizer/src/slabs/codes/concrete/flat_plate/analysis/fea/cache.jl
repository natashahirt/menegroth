# =============================================================================
# FEA Model Cache — Persistent state for slab FEA mesh
# =============================================================================

"""Per-element precomputed data: extracted once after each solve."""
mutable struct FEAElementData
    cx::Float64;  cy::Float64      # centroid (m)
    area::Float64                  # m²
    Mxx::Float64; Myy::Float64; Mxy::Float64  # bending moments (N·m/m)
    Qxz::Float64; Qyz::Float64    # transverse shear forces (N/m)
    ex::NTuple{2,Float64}         # local x̂ projected to 2D
    ey::NTuple{2,Float64}         # local ŷ projected to 2D
end

"""Per-element moment triplet for a single load case (D or L)."""
struct ElementMoments
    Mxx::Float64
    Myy::Float64
    Mxy::Float64
end

"""Column stub half: `(element, base_node, slab_node)` for one side of a column."""
const ColStubHalf = NamedTuple{(:element, :base_node, :slab_node)}

"""Per-column stub data: `(below, above)` where `above` is `nothing` at roof level."""
const ColStubData = NamedTuple{(:below, :above),
                               Tuple{ColStubHalf, Union{Nothing, ColStubHalf}}}

"""
    FEAModelCache

Persistent cache for a slab's FEA mesh.  Stored in
`struc._analysis_caches[slab_idx][:fea]`.

- On **first call**: `_build_fea_slab_model` creates the mesh + column stubs;
  the cache stores the model, stub data, and topology.
- On **subsequent calls**: `_update_and_resolve!` updates section props,
  column stub sections, and load, then re-processes and re-solves.
- After each solve: `_precompute_element_data!` fills `element_data`
  and `cell_tri_indices` for O(1) strip integration.

## D/L Split Solve

When `split_dl = true`, the model is solved twice (once for dead load, once
for live load) and the per-element moments are stored separately in
`element_data_D` and `element_data_L`.  The combined factored moments
(governing load combination) are written back into `element_data.Mxx/Myy/Mxy`
for backward compatibility with all downstream extraction functions.

This enables:
- Proper post-solve load combination (ASCE 7 §2.3.1)
- FEA-native pattern loading (checkerboard, adjacent spans)
"""
mutable struct FEAModelCache
    initialized::Bool

    # Asap model + column stubs (persistent across iterations)
    model::Union{Nothing, Asap.Model}
    col_stubs::Dict{Int, ColStubData}   # i => (below=..., above=...)
    shells::Union{Nothing, Vector{<:Asap.ShellElement}}  # shell elements from mesher

    # Per-element precomputed data (rebuilt after each solve)
    element_data::Vector{FEAElementData}
    cell_tri_indices::Dict{Int, Vector{Int}}   # cell_idx → indices into element_data

    # D/L split: per-element moments for each unfactored load case.
    # Empty when split_dl = false (legacy single-solve path).
    element_data_D::Vector{ElementMoments}
    element_data_L::Vector{ElementMoments}

    # Per-cell live load moments (for FEA-native pattern loading).
    # Maps cell_idx → per-element moments from live load on THAT cell only.
    # Populated by `_solve_per_cell_live!` when `pattern_mode == :fea_resolve`.
    cell_live_moments::Dict{Int, Vector{ElementMoments}}

    # Per-cell live load displacement fields (for pattern loading column forces
    # and deflection).  Maps cell_idx → full DOF displacement vector (Float64).
    # Populated alongside cell_live_moments by `_solve_per_cell_live!`.
    cell_live_displacements::Dict{Int, Vector{Float64}}

    # Dead-load displacement field (full DOF vector, Float64).
    # Stored during `_solve_dl_cases!` for pattern loading superposition.
    U_D::Vector{Float64}

    # Cell geometry cache (mesh-invariant — polygon, centroid, bbox)
    cell_geometries::Dict{Int, NamedTuple}

    # Characteristic mesh edge length (m) — median of √(2·A) over all
    # triangles, computed once on first pass.  Used for section-cut bandwidth.
    mesh_edge_length::Float64

    # Drop panel geometry (for strip width adjustment per Pacoste §4.2.1 Fig 4.4).
    # Stored here so all extraction functions can access it without threading
    # through every call site.  Set by `_build_or_update_fea!`.
    drop_panel::Union{Nothing, DropPanelGeometry}

    # Edge-beam frame elements (ACI 318-11 §13.6.4.2 / §13.7.5).  Empty when
    # `has_edge_beam=false` and `edge_beam_βt=0`.  When configured, holds one
    # `Asap.Element` per skeleton boundary edge connecting consecutive
    # `boundary_vis` nodes (generalizes to non-rectangular polygons).
    edge_beam_elements::Vector{Any}

    # Active edge-beam βt (for `_update_and_resolve!` to refresh sections when
    # the user changes βt or h between iterations).  0.0 when no edge beam.
    edge_beam_βt::Float64

    FEAModelCache() = new(
        false, nothing, Dict{Int,ColStubData}(), nothing,
        FEAElementData[], Dict{Int,Vector{Int}}(),
        ElementMoments[], ElementMoments[],
        Dict{Int,Vector{ElementMoments}}(),
        Dict{Int,Vector{Float64}}(),
        Float64[],
        Dict{Int,NamedTuple}(),
        0.0,
        nothing,
        Any[],
        0.0,
    )
end
