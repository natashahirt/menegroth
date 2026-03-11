# =============================================================================
# FEA Geometry Helpers — Slab boundary, vertex positions, cell & column geometry
# =============================================================================

# =============================================================================
# Slab Boundary Extraction
# =============================================================================

"""
    _get_slab_face_boundary(struc, slab) -> (boundary_vis, all_vis, interior_edge_vis)

Ordered boundary vertex indices, all vertex indices, and interior cell-edge
vertex pairs for a slab.

Single-cell slabs: boundary = face polygon, interior edges = empty.
Multi-cell slabs: boundary edges (count=1) chained into polygon; interior
edges (count≥2) returned as vertex pairs.
"""
function _get_slab_face_boundary(struc, slab)
    skel = struc.skeleton

    if length(slab.cell_indices) == 1
        face_idx = struc.cells[first(slab.cell_indices)].face_idx
        boundary = collect(skel.face_vertex_indices[face_idx])
        return (boundary, Set(boundary), Tuple{Int,Int}[])
    end

    # Count how many slab cells reference each skeleton edge
    edge_count = Dict{Int, Int}()
    all_verts = Set{Int}()

    for ci in slab.cell_indices
        face_idx = struc.cells[ci].face_idx
        union!(all_verts, skel.face_vertex_indices[face_idx])
        for ei in skel.face_edge_indices[face_idx]
            edge_count[ei] = get(edge_count, ei, 0) + 1
        end
    end

    boundary_edge_vis = Tuple{Int,Int}[skel.edge_indices[ei] for (ei, c) in edge_count if c == 1]
    interior_edge_vis = Tuple{Int,Int}[skel.edge_indices[ei] for (ei, c) in edge_count if c >= 2]

    isempty(boundary_edge_vis) && error("Could not find slab boundary — all edges are shared.")

    # Chain boundary edges into an ordered polygon
    adj = Dict{Int, Vector{Int}}()
    for (a, b) in boundary_edge_vis
        push!(get!(adj, a, Int[]), b)
        push!(get!(adj, b, Int[]), a)
    end

    start = boundary_edge_vis[1][1]
    boundary = [start]
    prev = 0
    current = start
    for _ in 1:length(boundary_edge_vis)
        neighbors = adj[current]
        next = first(n for n in neighbors if n != prev)
        next == start && break
        push!(boundary, next)
        prev = current
        current = next
    end

    # Ensure CCW (Delaunay triangulator requires positive orientation)
    _ensure_ccw_vis!(boundary, skel)

    return (boundary, all_verts, interior_edge_vis)
end

"""
    _ensure_ccw_vis!(vis, skel)

Reverse `vis` in-place if the polygon formed by the skeleton vertices is CW.
Uses the signed-area (shoelace) sign test.
"""
function _ensure_ccw_vis!(vis::Vector{Int}, skel)
    n = length(vis)
    vc = skel.geometry.vertex_coords
    signed_area = 0.0
    for i in 1:n
        j = mod1(i + 1, n)
        signed_area += vc[vis[i], 1] * vc[vis[j], 2] -
                       vc[vis[j], 1] * vc[vis[i], 2]
    end
    signed_area < 0 && reverse!(vis)
    return vis
end

"""Build an Asap section for a column stub, delegating to `column_asap_section`."""
_col_asap_sec(col, Ec, ν; I_factor=0.70) =
    column_asap_section(col.c1, col.c2, col_shape(col), Ec, ν; I_factor=I_factor)

# =============================================================================
# Skeleton Vertex → (x, y) Cache
# =============================================================================

"""
    _vertex_xy_m(skel, vi) -> NTuple{2,Float64}

XY position of a skeleton vertex in meters.
"""
function _vertex_xy_m(skel, vi::Int)
    vc = skel.geometry.vertex_coords
    return (vc[vi, 1], vc[vi, 2])
end

# =============================================================================
# Cell Geometry Helpers
# =============================================================================

"""
    _cell_geometry_m(struc, cell_idx) -> (poly, centroid)

Polygon vertices and centroid of a cell, both in meters (bare Float64).
Reads directly from skeleton face data — no redundant lookups.
"""
function _cell_geometry_m(struc, cell_idx::Int; _cache::Union{Nothing, Dict} = nothing)
    if !isnothing(_cache)
        cached = get(_cache, cell_idx, nothing)
        !isnothing(cached) && return cached
    end

    skel = struc.skeleton
    cell = struc.cells[cell_idx]
    vis = skel.face_vertex_indices[cell.face_idx]
    poly = NTuple{2,Float64}[_vertex_xy_m(skel, vi) for vi in vis]

    face = skel.faces[cell.face_idx]
    c = coords(Meshes.centroid(face))
    centroid = (Float64(ustrip(u"m", c.x)), Float64(ustrip(u"m", c.y)))

    result = (poly=poly, centroid=centroid)
    !isnothing(_cache) && (_cache[cell_idx] = result)
    return result
end

"""
    _build_cell_to_columns(columns) -> Dict{Int, Vector}

Invert column.tributary_cell_indices into a cell_idx → columns mapping.
O(n_cols) construction, O(1) lookup per cell — replaces O(n_cols) scan per cell.
"""
function _build_cell_to_columns(columns)
    cell_to_cols = Dict{Int, Vector{eltype(columns)}}()
    for col in columns
        for ci in col.tributary_cell_indices
            push!(get!(cell_to_cols, ci, eltype(columns)[]), col)
        end
    end
    return cell_to_cols
end

# =============================================================================
# Column Face Geometry
# =============================================================================

"""
    _column_face_offset_m(col, d::NTuple{2,Float64}) -> Float64

Distance (meters) from column center to column face in direction `d` (global).

For circular columns, the offset is simply D/2 (isotropic).
For rectangular columns, rotates `d` into the column's local frame
(using `col_orientation`) and projects onto the axis-aligned bounding box
of the cross-section (c1 along local-x, c2 along local-y).
"""
function _column_face_offset_m(col, d::NTuple{2,Float64})
    cshape = col_shape(col)
    if cshape == :circular
        return ustrip(u"m", col.c1) / 2   # D/2 in any direction
    end

    # Rotate d from global frame into the column's local frame.
    # Column local-x is at angle θ from global X.
    θ = col_orientation(col)
    cosθ = cos(θ)
    sinθ = sin(θ)
    # d_local = Rᵀ · d  (inverse rotation)
    dl_x = cosθ * d[1] + sinθ * d[2]
    dl_y = -sinθ * d[1] + cosθ * d[2]

    c1_m = ustrip(u"m", col.c1)
    c2_m = ustrip(u"m", col.c2)
    tx = abs(dl_x) > 1e-9 ? c1_m / (2 * abs(dl_x)) : Inf
    ty = abs(dl_y) > 1e-9 ? c2_m / (2 * abs(dl_y)) : Inf
    return min(tx, ty)
end
