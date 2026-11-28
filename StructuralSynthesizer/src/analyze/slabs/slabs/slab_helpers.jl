# =============================================================================
# Slab group IDs, sizing spans, and vault edge effects
# =============================================================================

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

