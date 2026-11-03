# =============================================================================
# Tributary Area Computation
# =============================================================================

"""
    compute_cell_tributaries!(struc; floor_opts, tributary_axis=nothing)

Compute parametric tributary polygons for each cell and store in TributaryCache.

Uses one-way directed partitioning for one-way floor types (along span axis),
isotropic straight skeleton for two-way systems. The `tributary_axis` argument
can override the default behavior. It defaults to the override already stored on
`struc._tributary_caches` and is stored there, so a later call without it
(`to_asap!`) and every [`cell_edge_tributaries`](@ref) lookup use the same axis.

Results stored in `struc._tributary_caches.edge[key][cell_idx]` where key is derived
from (spanning_behavior, axis). Access via:
- `cell_edge_tributaries(struc, cell_idx)` → Vector{TributaryPolygon}
- `get_cached_edge_tributaries(struc, behavior, axis, cell_idx)` → CellTributaryResult

Note: Tributaries are computed per-cell (not shared via groups) because the
parametric `local_edge_idx` must match each cell's specific vertex order.
"""
function compute_cell_tributaries!(struc::BuildingStructure; 
                                    floor_opts::StructuralSizer.AbstractFloorOptions=StructuralSizer.FlatPlateOptions(),
                                    tributary_axis=struc._tributary_caches.axis_override)
    struc._tributary_caches.axis_override = _stored_tributary_axis(tributary_axis)
    skel = struc.skeleton
    for (cell_idx, cell) in enumerate(struc.cells)
        if cell.floor_type == :unknown || cell.floor_type == :grade
            continue
        end
        
        verts = [skel.vertices[i] for i in skel.face_vertex_indices[cell.face_idx]]
        
        ft = StructuralSizer.floor_type(cell.floor_type)
        behavior = StructuralSizer.spanning_behavior(ft)
        axis = _cell_partition_axis(struc, cell_idx, tributary_axis)
        
        if has_cell_tributaries(struc, cell_idx, behavior, axis)
            continue
        end
        
        trib = if isnothing(axis)
            StructuralSizer.get_tributary_polygons_isotropic(verts)
        else
            StructuralSizer.get_tributary_polygons(verts; axis=collect(axis))
        end
        
        strips = nothing
        if behavior isa TwoWaySpanning || behavior isa BeamlessSpanning
            strips = StructuralSizer.compute_panel_strips(trib)
        end
        
        cache_edge_tributaries!(struc, behavior, axis, cell_idx, trib; strip_geometry=strips)
    end
end

"""
Partition axis for one cell.

An explicit per-cell direction (`ScopedFloorOverride.span_axis`, or a
direction `tributary_axis` applied to every cell) wins. Otherwise the
building override, then the floor type's own rule.
"""
function _cell_partition_axis(struc::BuildingStructure, cell_idx::Int, tributary_axis)
    explicit = get(struc._tributary_caches.cell_axes, cell_idx, nothing)
    explicit !== nothing && return explicit
    cell = struc.cells[cell_idx]
    ft = StructuralSizer.floor_type(cell.floor_type)
    return StructuralSizer.resolve_tributary_axis(ft, cell.spans, tributary_axis)
end

"""`tributary_axis` in the form `TributaryCache.axis_override` stores."""
_stored_tributary_axis(::Nothing) = nothing
_stored_tributary_axis(tax::Symbol) = tax
_stored_tributary_axis(tax::NTuple{2, <:Real}) = (Float64(tax[1]), Float64(tax[2]))
_stored_tributary_axis(tax::AbstractVector{<:Real}) =
    length(tax) == 2 ? (Float64(tax[1]), Float64(tax[2])) :
    throw(ArgumentError("tributary_axis must have two components; got $(length(tax))."))

"""Resolve a user-provided slab group ID at `idx`, returning `nothing` or `UInt64`."""
function _resolve_slab_group_id(slab_group_ids, idx::Int; tag::Symbol)
    isnothing(slab_group_ids) && return nothing
    length(slab_group_ids) >= idx || throw(ArgumentError("slab_group_ids too short: need at least $idx entries for $tag indexing"))
    v = slab_group_ids[idx]
    v === nothing && return nothing
    return UInt64(v)
end

"""Resolve the common group ID for a set of cells (errors if they disagree)."""
function _resolve_group_id_for_cell_set(slab_group_ids, cell_indices::Vector{Int})
    isnothing(slab_group_ids) && return nothing
    gids = UInt64[]
    for c_idx in cell_indices
        g = _resolve_slab_group_id(slab_group_ids, c_idx; tag=:cell)
        g === nothing && continue
        push!(gids, g)
    end
    isempty(gids) && return nothing
    all(g -> g == first(gids), gids) || throw(ArgumentError("Cells in a physical slab have inconsistent slab_group_ids: $(unique(gids))"))
    return first(gids)
end

# =============================================================================
# Sizing span conventions
# =============================================================================

"""
Pick the `span` passed into `_size_span_floor(ft, span, ...)`.

Uses SpanInfo to select the appropriate span for each floor system type:
- One-way systems: primary (short) span
- Two-way systems: isotropic span or max(primary, secondary)
"""
_sizing_span(::AbstractFloorSystem, si::SpanInfo) = si.primary

# ACI two-way / plate / waffle / PT thickness rules are based on the long span.
# For TwoWay that is the longer chord along the two reinforcement axes
# (ACI 318-11 §9.5.3.3, corpus: aci-318-11, page 135). The polygon diameter
# is not along either axis.
_sizing_span(::TwoWay, si::SpanInfo) = max(si.primary, si.secondary)
_sizing_span(::FlatPlate, si::SpanInfo) = max(si.primary, si.secondary)
_sizing_span(::FlatSlab, si::SpanInfo) = max(si.primary, si.secondary)
_sizing_span(::PTBanded, si::SpanInfo) = max(si.primary, si.secondary)
_sizing_span(::Waffle, si::SpanInfo) = max(si.primary, si.secondary)

# =============================================================================
# Structural Effects Application
# =============================================================================

"""
Apply vault thrust effects to the building structure model.
Identifies support edges and applies outward horizontal LineLoads to ASAP members.
"""
function StructuralSizer.apply_effects!(::Vault, struc::BuildingStructure, slab::Slab)
    # Keep this method for compatibility, but delegate to the unified edge-load interface.
    _assert_rectangular_slab_face(struc, struc.cells[first(slab.cell_indices)].face_idx)

    for ll in slab_edge_line_loads(struc, slab)
        el = struc.asap_model.frame_elements[ll.edge_idx]
        push!(struc.asap_model.loads, Asap.LineLoad(el, collect(ll.w)))
    end
end

"""Assert that `face_idx` is a 4-vertex orthogonal rectangle (required for vaults)."""
function _assert_rectangular_slab_face(struc::BuildingStructure, face_idx::Int; tol=1e-8)
    skel = struc.skeleton
    vc = skel.geometry.vertex_coords
    v_idx = skel.face_vertex_indices[face_idx]

    length(v_idx) == 4 || throw(ArgumentError("Vault requires a rectangular face (4 vertices); face $face_idx has $(length(v_idx)) vertices."))

    # Edge vectors in meters (Float64)
    vs = [(vc[v_idx[2], 1] - vc[v_idx[1], 1], vc[v_idx[2], 2] - vc[v_idx[1], 2]),
          (vc[v_idx[3], 1] - vc[v_idx[2], 1], vc[v_idx[3], 2] - vc[v_idx[2], 2]),
          (vc[v_idx[4], 1] - vc[v_idx[3], 1], vc[v_idx[4], 2] - vc[v_idx[3], 2]),
          (vc[v_idx[1], 1] - vc[v_idx[4], 1], vc[v_idx[1], 2] - vc[v_idx[4], 2])]

    norms = [hypot(v[1], v[2]) for v in vs]
    all(n -> n > tol, norms) || throw(ArgumentError("Vault face $face_idx is degenerate (zero-length edge)."))

    dot12 = abs((vs[1][1]*vs[2][1] + vs[1][2]*vs[2][2]) / (norms[1]*norms[2]))
    dot23 = abs((vs[2][1]*vs[3][1] + vs[2][2]*vs[3][2]) / (norms[2]*norms[3]))
    dot34 = abs((vs[3][1]*vs[4][1] + vs[3][2]*vs[4][2]) / (norms[3]*norms[4]))
    dot41 = abs((vs[4][1]*vs[1][1] + vs[4][2]*vs[1][2]) / (norms[4]*norms[1]))

    (dot12 < 1e-6 && dot23 < 1e-6 && dot34 < 1e-6 && dot41 < 1e-6) ||
        throw(ArgumentError("Vault requires an orthogonal rectangular face; face $face_idx is not orthogonal within tolerance."))
end

