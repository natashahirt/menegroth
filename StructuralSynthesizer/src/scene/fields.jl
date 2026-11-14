# Analysis fields beyond deflection: axial force and tributary polygons.
# Shell surface stress is written with the shell faces in build.jl.

"""
Signed axial-force extremum of each frame element, newtons.

Positive is tension, the sign `ElementInternalForces` already uses. The value
is the station whose absolute force is largest, the same choice as the JSON
frame view.
"""
function _element_axial(model::Asap.Model, elements)
    axial = Float32[]
    sizehint!(axial, length(elements))
    peak = 0.0
    for elem in elements
        force, _, _ = _compute_frame_analytical(elem, model)
        push!(axial, Float32(force))
        peak = max(peak, abs(force))
    end
    return axial, peak
end

const _TRIBUTARY_COLUMN = 0x00
const _TRIBUTARY_BEAM = 0x01
const _TRIBUTARY_WALL = 0x02
const _TRIBUTARY_NONE = 0xffffffff

"""0-based frame element of a skeleton edge, or a sentinel when the edge is not in the analysis model."""
function _element_for_edge(edges, edge_idx::Int)
    i = findfirst(isequal(edge_idx), edges)
    return isnothing(i) ? _TRIBUTARY_NONE : UInt32(i - 1)
end

"""Frame element of a member's first segment."""
function _member_element(struc::BuildingStructure, edges, member)
    segs = segment_indices(member)
    isempty(segs) && return _TRIBUTARY_NONE
    seg = first(segs)
    seg > length(struc.segments) && return _TRIBUTARY_NONE
    return _element_for_edge(edges, struc.segments[seg].edge_idx)
end

_scene_meters(x::Unitful.Length) = ustrip(u"m", x)
_scene_meters(x::Real) = Float64(x)

"""Append one plan polygon. Returns false when the loop has fewer than three vertices."""
function _push_plan!(pos::Vector{Float32}, counts::Vector{UInt32}, xy, z::Float64, origin)
    start = length(pos)
    n = 0
    for (x, y) in xy
        push!(pos, Float32(_scene_meters(x) - origin[1]),
                   Float32(_scene_meters(y) - origin[2]),
                   Float32(z - origin[3]))
        n += 1
    end
    if n < 3
        resize!(pos, start)
        return false
    end
    push!(counts, UInt32(n))
    return true
end

"""
True when wall piers cover this plan edge and their height includes `z`.

A pier runs from its story elevation through `base.L`, the same span
`_wall_pier_geometry` meshes, so a roof edge is included when the pier below
reaches it. Several collinear piers may share one edge; the edge is a wall
when their union covers it.
"""
function _edge_on_wall(struc::BuildingStructure, edge_idx::Int, z::Float64)
    skel = struc.skeleton
    v1, v2 = skel.edge_indices[edge_idx]
    vc = skel.geometry.vertex_coords
    P = (_scene_meters(vc[v1, 1]), _scene_meters(vc[v1, 2]))
    Q = (_scene_meters(vc[v2, 1]), _scene_meters(vc[v2, 2]))
    dx = Q[1] - P[1]
    dy = Q[2] - P[2]
    span = hypot(dx, dy)
    span < 1e-6 && return false
    ux, uy = dx / span, dy / span
    nx, ny = -uy, ux
    covered = Tuple{Float64, Float64}[]
    for wall in struc.walls
        haskey(skel.stories, wall.story) || continue
        z0 = _scene_meters(skel.stories[wall.story].elevation)
        height = _scene_meters(wall.base.L)
        height > 0 || continue
        z0 - 0.05 <= z <= z0 + height + 0.05 || continue
        A = (wall.x1 - P[1], wall.y1 - P[2])
        B = (wall.x2 - P[1], wall.y2 - P[2])
        max(abs(A[1] * nx + A[2] * ny), abs(B[1] * nx + B[2] * ny)) > 1e-3 && continue
        sA = A[1] * ux + A[2] * uy
        sB = B[1] * ux + B[2] * uy
        lo, hi = min(sA, sB), max(sA, sB)
        (hi < -1e-3 || lo > span + 1e-3) && continue
        push!(covered, (max(lo, 0.0), min(hi, span)))
    end
    isempty(covered) && return false
    sort!(covered)
    at = 0.0
    for (lo, hi) in covered
        lo > at + 1e-3 && return false
        at = max(at, hi)
    end
    return at >= span - 1e-3
end

"""
Who owns one cell-edge polygon.

A wall that covers the edge owns it, including the roof edge a pier reaches.
On a beamless floor the remaining edges belong to the columns. On a beam floor
a beam edge stays a beam, and any other edge belongs to the columns.
"""
function _tributary_kind_for_edge(struc, cell, edge_idx::Int, z::Float64, beam_edges)
    _edge_on_wall(struc, edge_idx, z) && return _TRIBUTARY_WALL
    if edge_idx in beam_edges && !_cell_is_beamless(cell)
        return _TRIBUTARY_BEAM
    end
    return _TRIBUTARY_COLUMN
end

"""
Tributary polygons on the slab plane, copied from `slab.tributary_polygons`.

Those loops are the column and wall shares, parabolic edges already sampled.
A beam-supported cell that has no such share keeps the straight-skeleton edge
polygons the beam design uses. `tributary_cell` is the 0-based cell index.
"""
function _with_tributaries(packet::ScenePacket, design::BuildingDesign)
    struc = design.structure
    skel = struc.skeleton
    vc = skel.geometry.vertex_coords
    origin = packet.origin
    edges = design.asap_model_frame_edge_indices
    pos = Float32[]
    counts = UInt32[]
    owners = UInt32[]
    kinds = UInt8[]
    cells = UInt32[]
    covered = Set{Int}()

    for slab in struc.slabs
        for region in slab.tributary_polygons
            1 <= region.cell_idx <= length(struc.cells) || continue
            face_verts = skel.face_vertex_indices[struc.cells[region.cell_idx].face_idx]
            isempty(face_verts) && continue
            z = _scene_meters(vc[face_verts[1], 3])
            _push_plan!(pos, counts, region.xy, z, origin) || continue
            push!(owners, _tributary_owner(struc, edges, region))
            push!(kinds, region.kind === :wall ? _TRIBUTARY_WALL : _TRIBUTARY_COLUMN)
            push!(cells, UInt32(region.cell_idx - 1))
            push!(covered, region.cell_idx)
        end
    end

    beam_edges = Set{Int}()
    for beam in struc.beams
        for seg_idx in segment_indices(beam)
            seg_idx > length(struc.segments) && continue
            push!(beam_edges, struc.segments[seg_idx].edge_idx)
        end
    end

    for (cell_idx, cell) in enumerate(struc.cells)
        cell_idx in covered && continue
        _cell_is_beamless(cell) && continue
        tribs = cell_edge_tributaries(struc, cell_idx)
        isnothing(tribs) && continue
        face_edges = skel.face_edge_indices[cell.face_idx]
        face_verts = skel.face_vertex_indices[cell.face_idx]
        n_verts = length(face_verts)
        n_verts < 2 && continue
        z = _scene_meters(vc[face_verts[1], 3])
        for trib in tribs
            trib.area < 1e-8 && continue
            local_idx = trib.local_edge_idx
            (1 <= local_idx <= length(face_edges) && local_idx <= n_verts) || continue
            global_edge = face_edges[local_idx]
            a = face_verts[local_idx]
            b = face_verts[mod1(local_idx + 1, n_verts)]
            xy = Asap.vertices(trib, (vc[a, 1], vc[a, 2]), (vc[b, 1], vc[b, 2]))
            _push_plan!(pos, counts, xy, z, origin) || continue
            push!(owners, _element_for_edge(edges, global_edge))
            push!(kinds, _tributary_kind_for_edge(struc, cell, global_edge, z, beam_edges))
            push!(cells, UInt32(cell_idx - 1))
        end
    end

    isempty(counts) && return packet
    meta = copy(packet.meta)
    tally = copy(meta["counts"])
    tally["tributary_polygons"] = length(counts)
    meta["counts"] = tally
    extra = SceneBuffer[
        SceneBuffer("tributary_position", pos),
        SceneBuffer("tributary_count", counts),
        SceneBuffer("tributary_element", owners),
        SceneBuffer("tributary_kind", kinds),
        SceneBuffer("tributary_cell", cells),
    ]
    return ScenePacket(packet.stages, origin, meta, vcat(packet.buffers, extra))
end

"""Frame element of a stored slab share. A wall has no frame element."""
function _tributary_owner(struc, edges, region)
    if region.kind === :column && 1 <= region.owner <= length(struc.columns)
        return _member_element(struc, edges, struc.columns[region.owner])
    end
    return _TRIBUTARY_NONE
end
