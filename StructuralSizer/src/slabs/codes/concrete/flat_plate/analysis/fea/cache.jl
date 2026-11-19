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

"""
    FEASlabView(shell_elements, nodes, u)

One slab's triangles in a larger solved model. `shell_elements[k]` is the
triangle of `element_data[k]`. `nodes` is the whole model's node list, so a
triangle's `nodeID` indexes it, and `u` is the displacement those triangles
are read at. Readers that only need the slab's own shells (nodal smoothing,
element precompute) take this in place of an `Asap.Model`.
"""
struct FEASlabView
    shell_elements::Vector{Asap.ShellTri3}
    nodes::Vector{Asap.Node}
    u::Vector{Float64}
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

    # Asap model + column stubs (persistent across iterations). A slab read
    # from the building model holds an `FEASlabView` of its own triangles.
    model::Union{Nothing, Asap.Model, FEASlabView}
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

    # Unfactored drop-projection self-weight (Pa), `h_drop × γ × g`. It acts on
    # the `:drop_panel` shells only, as dead load ([`_set_fea_area_loads!`](@ref)).
    q_drop::Float64

    # Edge-beam frame elements (ACI 318-11 §13.6.4.2 / §13.7.5).  Empty when
    # `has_edge_beam=false` and `edge_beam_βt=0`.  When configured, holds one
    # `Asap.Element` per skeleton boundary edge connecting consecutive
    # `boundary_vis` nodes (generalizes to non-rectangular polygons).
    edge_beam_elements::Vector{Any}

    # Active edge-beam βt (for `_update_and_resolve!` to refresh sections when
    # the user changes βt or h between iterations).  0.0 when no edge beam.
    edge_beam_βt::Float64

    # Geometry this mesh was acquired for. `nothing` until
    # [`acquire_fea_cache!`](@ref) stamps it. A different key replaces the
    # cache instead of updating a mesh built for another slab.
    mesh_key::Any

    # Column-face transverse averaging width ÷ column dimension across the
    # span. `nothing` integrates the whole strip. Copied from
    # `FEA.averaging_width_factor` before moment extraction.
    averaging_width_factor::Union{Nothing, Float64}

    # How many times this cache built a mesh, and how many times it kept
    # the mesh and only updated sections and loads. A reset keeps both,
    # so a column that grows and forces a remesh still adds to the count.
    n_rebuilds::Int
    n_updates::Int

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
        0.0,
        Any[],
        0.0,
        nothing,
        nothing,
        0,
        0,
    )
end

"""
    fea_mesh_key(struc, slab, columns; target_edge=nothing, drop_panel=nothing) -> Tuple

Topology inputs of the shell mesh: slab vertices, column centers, sizes,
shape, position and orientation, the span axis, target edge, and drop-panel
plan. A circle is meshed as the equivalent-area square, so shape is part of
the key even when `c1` and `c2` are unchanged.
The drop patch is clipped from those, so a change in any of them rebuilds
the mesh. Thickness and modulus are not included;
those take the update path. [`_build_or_update_fea!`](@ref) recomputes the key
on every analysis, so a column that grows between iterations rebuilds the mesh
and its patch matches the new column.
"""
function fea_mesh_key(struc, slab, columns;
                      target_edge::Union{Nothing, Length} = nothing,
                      drop_panel::Union{Nothing, DropPanelGeometry} = nothing)
    boundary, all_vis, interior_edges = _get_slab_face_boundary(struc, slab)
    skel = struc.skeleton
    _m(x) = Float64(ustrip(u"m", x))
    bxy = Tuple(_vertex_xy_m(skel, vi) for vi in boundary)
    verts = Tuple(sort!(collect(Int, all_vis)))
    edges = Tuple(sort!(collect(interior_edges)))
    cols = Tuple(
        let xy = _column_xy_m(skel, col)
            pos = hasproperty(col, :position) ? col.position : :interior
            (xy[1], xy[2], _m(col.c1), _m(col.c2), col_shape(col), pos, col_orientation(col))
        end
        for col in columns
    )
    spans = Tuple(
        (_m(struc.cells[ci].spans.primary), _m(struc.cells[ci].spans.secondary))
        for ci in slab.cell_indices
    )
    te = target_edge === nothing ? nothing : _m(target_edge)
    dp = drop_panel === nothing ? nothing :
        (_m(drop_panel.h_drop), _m(drop_panel.a_drop_1), _m(drop_panel.a_drop_2))
    # The drop patch is clipped at free edges and aligned to the span, so both
    # belong in the key.
    return (bxy, verts, edges, cols, spans, te, dp, _get_span_axis(slab))
end

"""
    acquire_fea_cache!(slab_caches, key) -> FEAModelCache

Return the slab's FEA cache when `key` is the one it was built for.
Any other key, including a cache that was never keyed, is replaced with a
fresh cache. The replacement is what stops a mesh from a previous geometry
being updated in place.
"""
function acquire_fea_cache!(slab_caches::AbstractDict, key)
    cache = get(slab_caches, :fea, nothing)
    if !(cache isa FEAModelCache) || cache.mesh_key != key
        cache = FEAModelCache()
        slab_caches[:fea] = cache
    end
    cache.mesh_key = key
    return cache
end

"""
    _reset_fea_cache!(cache) -> FEAModelCache

Return every field of `cache` to the state of a fresh `FEAModelCache()`.
Element data, per-cell live-load fields, the dead-load displacement and the
median edge length all belong to one mesh, so none of them survive a remesh.
"""
function _reset_fea_cache!(cache::FEAModelCache)
    fresh = FEAModelCache()
    kept = (:n_rebuilds, :n_updates)
    for f in fieldnames(FEAModelCache)
        f in kept && continue
        setfield!(cache, f, getfield(fresh, f))
    end
    return cache
end
