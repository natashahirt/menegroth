# =============================================================================
# Edge polygons of each cell
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

The same polygons load the beams ([`compute_member_tributaries!`](@ref)) and
split each cell between its columns and walls
([`compute_column_tributaries!`](@ref)).

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
        holes, hole_supports = _face_partition_holes(skel, cell.face_idx)

        ft = StructuralSizer.floor_type(cell.floor_type)
        behavior = StructuralSizer.spanning_behavior(ft)
        axis = _cell_partition_axis(struc, cell_idx, tributary_axis)

        if has_cell_tributaries(struc, cell_idx, behavior, axis)
            continue
        end

        trib = _edge_polygons(verts, axis, holes;
                              weights = _partition_weights(cell, axis, skel),
                              hole_supports = hole_supports)
        _assert_cell_tributaries_cover(trib, cell, cell_idx)
        
        strips = nothing
        if behavior isa TwoWaySpanning || behavior isa BeamlessSpanning
            strips = StructuralSizer.compute_panel_strips(trib)
        end
        
        cache_edge_tributaries!(struc, behavior, axis, cell_idx, trib; strip_geometry=strips)
    end
end

"""
Free openings, then beam-ring holes, and a support flag for each.

A ring edge carries the slab. An opening edge does not. Both stay voids, so
neither is floor area. The straight skeleton (no axis) has no ring edges yet;
that partition still treats a ring as a free hole.
"""
function _face_partition_holes(skel, face_idx)
    free = [skel.openings[k].loop for k in face_openings(skel, face_idx)]
    rings = face_hole_loops(skel, face_idx)
    return vcat(free, rings), vcat(falses(length(free)), trues(length(rings)))
end

"""
Edge polygons of a plan outline: the straight skeleton when `axis` is
`nothing`, otherwise the partition along `axis`. `holes` are void loops.
`hole_supports` marks the beam rings among them. A ring edge carries slab
in both the one-way partition and the straight skeleton.
"""
function _edge_polygons(verts, axis, holes; weights=nothing, hole_supports=nothing)
    return StructuralSizer.get_tributary_polygons(
        verts; axis = axis === nothing ? nothing : collect(axis), holes = holes,
        weights = weights, hole_supports = hole_supports)
end

"""
Edge weights for a one-way partition. A beam, wall, joist, or secondary member
is a support (weight 1). Any other outline edge is not (weight 0), so its
stretch lands on the support at the other end instead of on a free edge.

Two-way partitions do not use these weights. Only `:one_way` and
`:composite_deck` span onto line supports this way.
"""
function _partition_weights(cell, axis, skel)
    axis === nothing && return nothing
    cell.floor_type in (:one_way, :composite_deck) || return nothing
    support = Set{Int}()
    for g in (:beams, :walls, :joists, :secondary)
        union!(support, get(skel.groups_edges, g, Int[]))
    end
    return Float64[e in support ? 1.0 : 0.0 for e in skel.face_edge_indices[cell.face_idx]]
end

"""
Throw unless a cell's tributaries add up to the cell's net area, the area its
floor load is applied over. Asap checks the partition against its own net
area; this ties that to `face_net_area`.
"""
function _assert_cell_tributaries_cover(tribs, cell, cell_idx::Int)
    net = ustrip(u"m^2", cell.area)
    got = sum(t.area for t in tribs; init = 0.0)
    abs(got - net) <= 1e-6 * max(net, 1.0) || error(
        "Cell $cell_idx tributaries cover $got m² of its $net m² net floor area.")
    return nothing
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

"""
    cell_support_polygons(struc, cell_idx) -> (tribs, axis)

Edge polygons the column and wall split uses for one cell, and the axis they
were partitioned along (`nothing` for two-way). A cell
[`compute_cell_tributaries!`](@ref) has cached reads the cache. A cell it
skips (no floor type, or grade) is partitioned here with the straight
skeleton.
"""
function cell_support_polygons(struc::BuildingStructure, cell_idx::Int)
    cell = struc.cells[cell_idx]
    skel = struc.skeleton
    if cell.floor_type != :unknown && cell.floor_type != :grade
        axis = _cell_partition_axis(struc, cell_idx, struc._tributary_caches.axis_override)
        cached = cell_edge_tributaries(struc, cell_idx)
        cached === nothing || return (cached, axis)
    else
        axis = nothing
    end
    verts = [skel.vertices[i] for i in skel.face_vertex_indices[cell.face_idx]]
    holes, hole_supports = _face_partition_holes(skel, cell.face_idx)
    return (_edge_polygons(verts, axis, holes; weights = _partition_weights(cell, axis, skel),
                           hole_supports = hole_supports),
            axis)
end
