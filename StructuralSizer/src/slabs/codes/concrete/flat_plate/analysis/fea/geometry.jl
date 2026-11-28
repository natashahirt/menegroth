# =============================================================================
# FEA Geometry Helpers — Slab boundary, vertex positions, cell & column geometry
# =============================================================================

# =============================================================================
# Slab Boundary Extraction
# =============================================================================

"""
    _get_slab_face_boundary(struc, slab) -> (boundary_vis, all_vis, interior_edge_vis)

Ordered exterior boundary vertex indices, all vertex indices, and interior
cell-edge vertex pairs for a slab.

Single-cell slabs: boundary = face polygon, interior edges = empty.
Multi-cell slabs: edges used by one cell are the boundary. When a bay is
missing, that boundary is the exterior plus one loop per courtyard. The
exterior is the loop of largest area. Courtyard loops are
[`slab_void_loops`](@ref), not part of this polygon.
"""
function _get_slab_face_boundary(struc, slab)
    exterior, all_verts, interior_edge_vis, _ = _slab_boundary_topology(struc, slab)
    return (exterior, all_verts, interior_edge_vis)
end

"""
    slab_void_loops(struc, slab) -> Vector{Vector{NTuple{2,Float64}}}

Courtyard holes of `slab`, in plan metres. Each loop is clockwise (the
solid floor is to the left of a directed edge). A courtyard is a bay missing
from the slab, or a beam network nested inside one of its faces
(`skel.face_holes`). Empty when the slab has neither. These are framed voids,
not [`slab_opening_loops`](@ref).
"""
function slab_void_loops(struc, slab)
    skel = struc.skeleton
    _, _, _, holes = _slab_boundary_topology(struc, slab)
    out = [[_vertex_xy_m(skel, vi) for vi in loop] for loop in holes]
    hasproperty(skel, :face_holes) || return out
    nested = getfield(skel, :face_holes)
    for ci in slab.cell_indices, loop in get(nested, struc.cells[ci].face_idx, ())
        push!(out, reverse(loop))
    end
    return out
end

function _slab_boundary_topology(struc, slab)
    skel = struc.skeleton

    if length(slab.cell_indices) == 1
        face_idx = struc.cells[first(slab.cell_indices)].face_idx
        boundary = collect(skel.face_vertex_indices[face_idx])
        _ensure_ccw_vis!(boundary, skel)
        return (boundary, Set(boundary), Tuple{Int,Int}[], Vector{Int}[])
    end

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

    loops = _closed_boundary_loops(boundary_edge_vis)
    isempty(loops) && error("Could not close the slab boundary.")
    areas = [abs(_loop_area(skel, loop)) for loop in loops]
    k = argmax(areas)
    exterior = loops[k]
    _ensure_ccw_vis!(exterior, skel)
    holes = Vector{Int}[]
    for (i, loop) in enumerate(loops)
        i == k && continue
        _ensure_ccw_vis!(loop, skel)
        reverse!(loop)  # clockwise courtyard
        push!(holes, loop)
    end
    return (exterior, all_verts, interior_edge_vis, holes)
end

"""Closed loops of an undirected edge set. Each edge is used once."""
function _closed_boundary_loops(pairs::Vector{Tuple{Int,Int}})
    adj = Dict{Int, Vector{Int}}()
    for (a, b) in pairs
        push!(get!(adj, a, Int[]), b)
        push!(get!(adj, b, Int[]), a)
    end
    used = Set{NTuple{2,Int}}()
    loops = Vector{Int}[]
    for (a, bs) in adj
        for b0 in bs
            key0 = a < b0 ? (a, b0) : (b0, a)
            key0 in used && continue
            loop = Int[a]
            prev, cur = a, b0
            closed = false
            for _ in 1:(length(pairs) + 1)
                push!(used, prev < cur ? (prev, cur) : (cur, prev))
                if cur == a
                    closed = true
                    break
                end
                push!(loop, cur)
                nxt = 0
                found = false
                for n in adj[cur]
                    n == prev && continue
                    k2 = cur < n ? (cur, n) : (n, cur)
                    k2 in used && continue
                    nxt = n
                    found = true
                    break
                end
                found || break
                prev, cur = cur, nxt
            end
            closed && length(loop) >= 3 && push!(loops, loop)
        end
    end
    length(used) == length(pairs) ||
        error("slab boundary edges did not form closed loops")
    return loops
end

function _loop_area(skel, loop::Vector{Int})
    vc = skel.geometry.vertex_coords
    area = 0.0
    n = length(loop)
    for i in 1:n
        j = mod1(i + 1, n)
        area += vc[loop[i], 1] * vc[loop[j], 2] - vc[loop[j], 1] * vc[loop[i], 2]
    end
    return 0.5 * area
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

"""
`(c1, c2)` of a column that has been sized, or `nothing`.

A stored `RCColumnSection` is the section that was designed. Otherwise the
column's own `c1` and `c2` are used when both are set. The caller supplies
the column below as a fallback.
"""
function _sized_column_section(col)
    if hasproperty(col, :base) && hasproperty(col.base, :section)
        section = col.base.section
        if section isa RCColumnSection
            return (section.b, section.h)
        end
    end
    hasproperty(col, :c1) || return nothing
    c1, c2 = col.c1, col.c2
    (c1 === nothing || c2 === nothing) && return nothing
    (c1 > zero(c1) && c2 > zero(c2)) || return nothing
    return (c1, c2)
end

"""
Build an Asap section for a column stub.

`fallback` is the section of the column below when `col` has not been sized.
"""
function _col_asap_sec(col, Ec, ν; I_factor=0.70, fallback=nothing)
    sec = _sized_column_section(col)
    c1, c2 = sec === nothing ? fallback : sec
    return column_asap_section(c1, c2, col_shape(col), Ec, ν; I_factor=I_factor)
end

# =============================================================================
# Edge-Beam Section (FEA perimeter line elements)
# =============================================================================

"""
    _edge_beam_dims(βt, h, c1_avg, l2) -> (b, h_eb)

Back-solve a rectangular edge-beam cross-section `(b, h_eb)` (width × depth)
that produces the user-specified torsional stiffness ratio `βt` per
ACI 318-11 §13.6.4.2:

    β_t = E_cb · C / (2 · E_cs · I_s)            ACI 318-11 Eq. (13-5)
    C   = (1 − 0.63 · x/y) · x³ · y / 3          ACI 318-11 Eq. (13-6),
                                                 with x = min(b, h_eb), y = max(b, h_eb)
    I_s = l2 · h³ / 12                           ACI 318-11 §13.6.4.2

Assumes E_cb = E_cs (monolithic construction, ACI 318-11 §13.7.5.1(b)).

The system has two unknowns (b, h_eb) and one equation.  We fix `b = c1_avg`
(the column dimension parallel to the edge — PCA Notes on ACI 318-11 §R13.7.5
torsional-member width when no transverse beam is present) and solve for `h_eb`.

For the typical case `h_eb ≥ b` (a deeper-than-wide edge beam below the slab),
the equation is linear in h_eb after expansion:

    h_eb · b³ − 0.63 · b⁴ = 3 · C_target   ⇒
    h_eb = (3 · C_target + 0.63 · b⁴) / b³,   where C_target = 2 · βt · I_s.

For low βt the trial h_eb falls below b (squat beam, h_eb < b → x = h_eb,
y = b); we then bisect Eq. (13-6) on (0, b) to recover a valid h_eb.

ENGINEERING JUDGMENT: the choice `b = c1_avg` is a default; users can override
via `edge_beam_βt` directly (the dimensions are then back-solved from the
requested βt).  This default mirrors PCA EB712 §R13.7.5 commentary.

# Reference
- ACI 318-11 §13.6.4.2 Eq. (13-5), Eq. (13-6) (page 250)
- ACI 318-11 §13.7.5 (torsional members, page 256)
"""
function _edge_beam_dims(βt::Float64, h::Length, c1_avg::Length, l2::Length)
    βt > 0 || error("_edge_beam_dims: βt must be > 0 (got $βt)")

    h_m  = ustrip(u"m", h)
    b_m  = ustrip(u"m", c1_avg)
    l2_m = ustrip(u"m", l2)

    Is_m4       = l2_m * h_m^3 / 12               # ACI Eq. (13-5) denominator
    C_target_m4 = 2 * βt * Is_m4                  # invert Eq. (13-5)

    # Trial assuming h_eb ≥ b (slender edge beam, x=b, y=h_eb)
    h_eb_trial = (3 * C_target_m4 + 0.63 * b_m^4) / b_m^3

    if h_eb_trial >= b_m
        return (uconvert(u"m", c1_avg), h_eb_trial * u"m")
    end

    # Squat beam (h_eb < b): bisect Eq. (13-6) with x=h_eb, y=b
    f(x) = (1 - 0.63 * x / b_m) * x^3 * b_m / 3 - C_target_m4
    lo, hi = 1e-9, b_m
    for _ in 1:100
        mid = (lo + hi) / 2
        if f(mid) > 0
            hi = mid
        else
            lo = mid
        end
    end
    return (uconvert(u"m", c1_avg), ((lo + hi) / 2) * u"m")
end

"""
    _edge_beam_asap_sec(βt, h, c1_avg, l2, Ecs, ν) -> Asap.Section

Build an `Asap.Section` for the perimeter edge-beam frame elements.

Cross-section is rectangular `b × h_eb` with dimensions back-solved from
`βt` via [`_edge_beam_dims`](@ref).  Section properties use the gross
rectangular section (no cracking reduction) — flat-plate edge beams are
governed by serviceability and torsional stiffness rather than ultimate
capacity, and ACI 318-11 §13.7 stiffness conventions use gross properties.

Generalizes to non-rectangular slab layouts: a single cross-section is
applied uniformly along every consecutive boundary-vertex pair returned
by `_get_slab_face_boundary`.  Frame-element local axes are derived from
endpoint geometry, so slanted, kinked, or polygonal boundaries are
handled automatically.

# Reference
- ACI 318-11 §13.6.4.2 Eq. (13-6) for J (= C of Eq. 13-6)
- ACI 318-11 §13.7.5.1 / §13.2.4 (effective beam section)
"""
function _edge_beam_asap_sec(
    βt::Float64, h::Length, c1_avg::Length, l2::Length,
    Ecs::Pressure, ν::Float64,
)
    b, h_eb = _edge_beam_dims(βt, h, c1_avg, l2)
    G = Ecs / (2 * (1 + ν))

    # Rectangular b × h_eb beam — gross section (matches column convention
    # in `column_asap_section`: A=c1*c2, Ix=c1*c2³/12, Iy=c2*c1³/12).
    A  = b * h_eb
    Ix = b * h_eb^3 / 12
    Iy = h_eb * b^3 / 12

    # Torsional constant — ACI 318-11 §13.6.4.2 Eq. (13-6), reproduced verbatim
    # via `torsional_constant_C(x, y)`.  By construction this matches the user's
    # requested βt because `_edge_beam_dims` solved the inverse problem.
    J = torsional_constant_C(min(b, h_eb), max(b, h_eb))

    return Asap.Section(
        uconvert(u"m^2", A),
        uconvert(u"Pa", Ecs),
        uconvert(u"Pa", G),
        uconvert(u"m^4", Ix),
        uconvert(u"m^4", Iy),
        uconvert(u"m^4", J),
    )
end

# =============================================================================
# Skeleton Vertex → (x, y) Cache
# =============================================================================

"""
    _vertex_xy_m(skel, vi) -> NTuple{2,Float64}

XY position of a skeleton vertex in meters (architectural / raw position).
"""
function _vertex_xy_m(skel, vi::Int)
    vc = skel.geometry.vertex_coords
    return (vc[vi, 1], vc[vi, 2])
end

"""
    _column_xy_m(skel, col) -> NTuple{2,Float64}

XY position (meters) of a column's **structural centerline**.

Applies `col.structural_offset` (populated by `update_structural_offsets!`)
to shift edge/corner columns inward from their architectural vertex.
Falls back to the raw vertex position if the column has no offset field
(e.g., lightweight NamedTuple stubs in standalone tests).
"""
function _column_xy_m(skel, col)
    xy = _vertex_xy_m(skel, col.vertex_idx)
    off = hasproperty(col, :structural_offset) ? col.structural_offset : (0.0, 0.0)
    return (xy[1] + off[1], xy[2] + off[2])
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
        return _edge_m(col.c1) / 2   # D/2 in any direction
    end

    # Rotate d from global frame into the column's local frame.
    # Column local-x is at angle θ from global X.
    θ = col_orientation(col)
    cosθ = cos(θ)
    sinθ = sin(θ)
    # d_local = Rᵀ · d  (inverse rotation)
    dl_x = cosθ * d[1] + sinθ * d[2]
    dl_y = -sinθ * d[1] + cosθ * d[2]

    c1_m = _edge_m(col.c1)
    c2_m = _edge_m(col.c2)
    tx = abs(dl_x) > 1e-9 ? c1_m / (2 * abs(dl_x)) : Inf
    ty = abs(dl_y) > 1e-9 ? c2_m / (2 * abs(dl_y)) : Inf
    return min(tx, ty)
end
