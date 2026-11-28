# =============================================================================
# Column Demands from Per-Span Moments
# =============================================================================

# =============================================================================
# Eq. (13-7) adjoining spans — ACI 318-11 §13.6.9.2
# =============================================================================
#
# Spans come from the column layout, not from slab-face corners: faces are
# mesh pieces, not panels.  The far support is the nearest column on the
# frame line that the slab is shown to reach (`_eq137_far_support`).  ℓ_cc
# is the distance between structural centerlines of the two columns (vertex
# plus `structural_offset`).  ℓn is face to face along that same line
# (ACI 318-11 §13.6.2.5, corpus: aci-318-11, page 253).  ℓ2 is the sum of
# transverse widths to the panel centerlines, fixed by the adjacent column
# lines and measured from the architectural frame line (the vertex line),
# not from the structural center (§13.6.2.1, §13.6.2.3, §13.6.2.4, page 253;
# `_eq137_side_width`).  The Eq. (13-7) terms are the line loads Σ q·ℓ2.

# ENGINEERING JUDGMENT: a face that overlaps another same-storey face (not
# a piece of one tessellation of the slab) and whose centroid lies this
# close to the column line normal to the analysis direction is a
# perpendicular neighbour and does not enter the Eq. (13-7) widths
# (`_eq137_side_width`).  Floor 0.05 m, or 2% of the centroid distance.  A
# face of a proper tessellation always enters, clipped to the span, however
# close its centroid is to that line.
const _EQ137_PERP_ALONG_MIN_M = 0.05
const _EQ137_PERP_ALONG_FRAC = 0.02

# One on-line predicate (`_eq137_on_line`).  A vertex is on this frame line
# when its perpendicular distance is at most
# max(0.35 m, 10% of its along-axis distance from the column).
#
# The 10% is ACI 318-11 §13.6.1.4 (corpus: aci-318-11, page 252): "Offset of
# columns by a maximum of 10 percent of the span (in direction of offset)
# from either axis between centerlines of successive columns shall be
# permitted."  The span is taken along the frame line, as the §13.6.1.4
# check in `check_ddm_applicability` does.  It covers a 5° skew
# (tan 5° < 0.10).  The next column line is at least ℓ1/2 away (§13.6.1.2,
# page 252), so it is never on the line.
#
# ENGINEERING JUDGMENT: the 0.35 m floor covers 0.1 ft of vertex noise and a
# 1 mm survey error next to the column, where 10% of the distance is tiny.
#
# Membership, frame-line depth, the far support, the straddle cutoff, and
# the next-column-line cap on tributary width all use this predicate.
const _EQ137_FRAME_BAND_M = 0.35
const _EQ137_FRAME_BAND_FRAC = 0.10

# ENGINEERING JUDGMENT: two skeleton vertices are on the same storey when
# their z agree within 0.05 m.  Storey heights are metres apart, so this is
# a float tolerance on one level.
const _EQ137_STOREY_DZ_M = 0.05

# ENGINEERING JUDGMENT: a far support lies at least 0.15 m along the frame
# line from the column under analysis.  A closer column vertex is the same
# support (a duplicated or nudged vertex), not the next column line.
const _EQ137_FAR_MIN_ALONG_M = 0.15

# ENGINEERING JUDGMENT: two plan points within 5 mm are the same point of
# the slab mesh, whatever their vertex indices.  Continuity at a column is
# read from coordinates, not from shared vertex indices, so a mesh whose
# faces carry their own copies of a vertex (no deduplication, or float noise
# across the StructuralSynthesizer `COORD_DIGITS = 6` rounding, 1e-6 m)
# classifies exactly like the merged mesh.  5 mm covers that noise and a
# 1–3 mm survey offset with margin, and is far below any column or panel
# dimension, so two distinct mesh points are never taken as one.
const _EQ137_COINCIDE_M = 0.005

# ENGINEERING JUDGMENT: the column neighbourhood is the on-line floor
# `_EQ137_FRAME_BAND_M` (0.35 m) around the column point.  A same-storey face
# that comes this close to the column without adjoining it (no corner at the
# column point) and is not explained by the adjoining faces
# (`_eq137_neighbourhood_explained`) may be a hidden panel or a separate
# slab; the geometry cannot tell which, so the column is ambiguous and takes
# the envelope (`_eq137_support_class`).  No structural joint is ever
# inferred from mesh topology: the skeleton has no joint flag.
const _EQ137_NEIGHBOURHOOD_M = _EQ137_FRAME_BAND_M

# ENGINEERING JUDGMENT: a cell vertex within 0.05 m along the frame line of
# the column is at the column and does not give the cell a depth.
const _EQ137_DEPTH_MIN_ALONG_M = 0.05

# ENGINEERING JUDGMENT: two columns recorded at one support point agree when their
# face half-widths along the axis differ by at most 1/8 in (1/4 in on the
# full dimension).  A larger difference changes ℓn (§13.6.2.5) and is a
# data conflict, not float noise.  The comparison allows a further 1e-6 in
# of float error from the unit conversions, so exactly 1/4 in agrees.
const _EQ137_FACE_ATOL_IN = 0.125
const _EQ137_FACE_FLOAT_IN = 1e-6

# ENGINEERING JUDGMENT: a cell at the column puts the slab on one side of
# it along the frame line when it covers at least 0.01 m (twice
# `_EQ137_COINCIDE_M`) of the frame line within `_EQ137_NEIGHBOURHOOD_M`
# of the column point on that side (`_eq137_cell_sides`).  A shorter run is
# the coincidence tolerance at the column point (a face on the other side,
# or across the column's transverse line), not slab.  The frame line is
# probed on its axis and on the two rays `_EQ137_FRAME_BAND_FRAC` (the
# §13.6.1.4 10%, page 252) off it, so a slab edge skewed within that offset
# still continues the frame line.
const _EQ137_SIDE_MIN_M = 2 * _EQ137_COINCIDE_M

# ENGINEERING JUDGMENT: a cell occupies a quadrant around a column when at
# least 5% of its area lies in that quadrant.  A 2° skew sliver across a
# column line is well below that; a panel that genuinely crosses the line
# puts a large share on each side.
const _EQ137_QUADRANT_AREA_FRAC = 0.05

# Spatial-hash bucket (meters) for the column neighbourhood index.  Only an
# accelerator: a cell is tested against every column vertex in the buckets
# its tolerance-expanded bounding box touches, and a point against the
# column points in its own and the eight adjacent buckets (both tolerances
# are far below the bucket), so the size does not change any result.
const _EQ137_PARTWAY_BUCKET_M = 3.0

"""Spatial-hash bucket of a coordinate (meters)."""
_eq137_bucket(x::Float64) = floor(Int, x / _EQ137_PARTWAY_BUCKET_M)

"""True when plan points `a` and `b` are the same mesh point (`_EQ137_COINCIDE_M`)."""
_eq137_coincide(a, b)::Bool = hypot(a[1] - b[1], a[2] - b[2]) <= _EQ137_COINCIDE_M

"""True when segments AB and CD meet, including a shared endpoint."""
function _eq137_segs_cross(A, B, C, D)::Bool
    orient(P, Q, R) = (Q[1] - P[1]) * (R[2] - P[2]) - (Q[2] - P[2]) * (R[1] - P[1])
    o1, o2 = orient(A, B, C), orient(A, B, D)
    o3, o4 = orient(C, D, A), orient(C, D, B)
    tol = 1e-14
    if abs(o1) <= tol && abs(o2) <= tol && abs(o3) <= tol && abs(o4) <= tol
        return !(max(A[1], B[1]) < min(C[1], D[1]) - 1e-12 ||
                 max(C[1], D[1]) < min(A[1], B[1]) - 1e-12 ||
                 max(A[2], B[2]) < min(C[2], D[2]) - 1e-12 ||
                 max(C[2], D[2]) < min(A[2], B[2]) - 1e-12)
    end
    return o1 * o2 <= 0 && o3 * o4 <= 0
end

"""True when polygons `a` and `b` intersect, including a shared boundary."""
function _eq137_poly_hits(a, b)::Bool
    any(p -> _ddm_point_in_or_on(p, b), a) && return true
    any(p -> _ddm_point_in_or_on(p, a), b) && return true
    na, nb = length(a), length(b)
    for i in 1:na
        A, B = a[i], a[mod1(i + 1, na)]
        for j in 1:nb
            _eq137_segs_cross(A, B, b[j], b[mod1(j + 1, nb)]) && return true
        end
    end
    return false
end

"""
Plan rectangle of `col` at `xy` (meters), expanded by `_EQ137_COINCIDE_M`.

ACI 318-11 §13.6.2.5 (corpus: aci-318-11, page 253): a circular support is
the equivalent square of the same area.  Rectangular supports use `c1` and
`c2` in the column's local axes (`col_orientation`).  `nothing` when the
column has no section size.
"""
function _eq137_column_outline(col, xy)::Union{Nothing,Vector{NTuple{2,Float64}}}
    hasproperty(col, :c1) || return nothing
    c1 = col.c1
    (c1 === nothing || !isfinite(ustrip(u"m", c1))) && return nothing
    tol = _EQ137_COINCIDE_M
    if col_shape(col) == :circular
        side = ustrip(u"m", equivalent_square_column(c1))
        hx = side / 2 + tol
        hy = hx
    else
        c2 = hasproperty(col, :c2) && col.c2 !== nothing ? col.c2 : c1
        isfinite(ustrip(u"m", c2)) || return nothing
        hx = ustrip(u"m", c1) / 2 + tol
        hy = ustrip(u"m", c2) / 2 + tol
    end
    (hx > tol && hy > tol) || return nothing
    θ = col_orientation(col)
    cθ, sθ = cos(θ), sin(θ)
    corners = NTuple{2,Float64}[]
    for (dx, dy) in ((-hx, -hy), (hx, -hy), (hx, hy), (-hx, hy))
        push!(corners, (xy[1] + cθ * dx - sθ * dy, xy[2] + sθ * dx + cθ * dy))
    end
    return corners
end

"""
True when the slab `polys` meets a column of the far-support group `far`.

The test is the column cross-section (`_eq137_column_outline`) against the
slab polygons.  With no section size, a polygon within
`_EQ137_NEIGHBOURHOOD_M` of the column point counts: the slab cannot be
shown to miss the support.

ACI 318-11 §13.6.2.5 (corpus: aci-318-11, page 253): ℓn is measured to the
face of a column the slab reaches.  A slot on the frame line does not
remove that column when the slab beside the slot still meets its face.
"""
function _eq137_slab_meets_support(far, polys)::Bool
    sized = false
    for col in far.columns
        outline = _eq137_column_outline(col, far.xy)
        outline === nothing && continue
        sized = true
        any(poly -> _eq137_poly_hits(outline, poly), polys) && return true
    end
    sized && return false
    # ENGINEERING JUDGMENT: no section size is on the column.  A slab within
    # the column neighbourhood cannot be shown to miss the support, so the
    # column stays a candidate and Eq. (13-7) is enveloped up to the
    # column-to-column clear span rather than cut at the slot.
    R = _EQ137_NEIGHBOURHOOD_M
    return any(poly -> _eq137_poly_dist(far.xy, poly) <= R, polys)
end

"""
True when two vertex elevations (meters, `nothing` for a 2-D skeleton) are
on the same storey (`_EQ137_STOREY_DZ_M`).  An unknown or non-finite
elevation cannot exclude the vertex.  A non-finite z on a slab-face corner
or column vertex is rejected before any geometry is read: it flags every
column (`_eq137_partway_index` `nonfinite`), so the transfer moment is NaN
with a `:failure` trace event (`non_finite_vertex`).
"""
function _eq137_z_agree(za, zb)::Bool
    (za === nothing || zb === nothing) && return true
    (isfinite(za) && isfinite(zb)) || return true
    return abs(za - zb) <= _EQ137_STOREY_DZ_M
end

"""On-line tolerance (meters) at an along-axis distance (§13.6.1.4 and a floor)."""
function _eq137_online_tol(along_m::Float64)
    return max(_EQ137_FRAME_BAND_M, _EQ137_FRAME_BAND_FRAC * abs(along_m))
end

"""
True when a point `along` meters along the frame line and `perp` meters off
it lies on the frame line (`_eq137_online_tol`).
"""
_eq137_on_line(along::Float64, perp::Float64)::Bool =
    abs(perp) <= _eq137_online_tol(along)

const _EQ137_WARNED = Set{Symbol}()
# NLP grid search calls `evaluate` on many threads, so the check-and-insert
# on `_EQ137_WARNED` is taken under this lock.
const _EQ137_WARNED_LOCK = ReentrantLock()

"""Warn at most once per process for a given Eq. (13-7) fallback (thread-safe)."""
function _eq137_warn_once(key::Symbol, msg::String)
    first_time = lock(_EQ137_WARNED_LOCK) do
        key in _EQ137_WARNED && return false
        push!(_EQ137_WARNED, key)
        return true
    end
    first_time && @warn msg
    return nothing
end

"""Skeleton geometry is present and readable for adjoining-panel lookup."""
function _eq137_geometry_available(struc)::Bool
    isnothing(struc) && return false
    hasproperty(struc, :skeleton) || return false
    hasproperty(struc, :cells) || return false
    skel = struc.skeleton
    hasproperty(skel, :geometry) || return false
    hasproperty(skel, :face_vertex_indices) || return false
    hasproperty(skel.geometry, :vertex_coords) || return false
    return true
end

"""Bare XY (meters) of skeleton vertex `vi`."""
function _eq137_vertex_xy_m(skel, vi::Int)::NTuple{2,Float64}
    vc = skel.geometry.vertex_coords
    x, y = vc[vi, 1], vc[vi, 2]
    if x isa Length
        return (ustrip(u"m", x), ustrip(u"m", y))
    end
    return (Float64(x), Float64(y))
end

"""Structural centerline (meters): vertex plus `structural_offset`."""
function _eq137_structural_xy(struc, col)::NTuple{2,Float64}
    vi = col_vertex_idx(col)
    vi <= 0 && return (0.0, 0.0)
    x, y = _eq137_vertex_xy_m(struc.skeleton, vi)
    if hasproperty(col, :structural_offset)
        o = col.structural_offset
        x += Float64(o[1])
        y += Float64(o[2])
    end
    return (x, y)
end

"""Unit span axis and the left-pointing perpendicular."""
function _eq137_unit_axes(span_axis::NTuple{2,Float64})
    ax_len = hypot(span_axis...)
    ax_len < 1e-9 && return nothing
    ax = (span_axis[1] / ax_len, span_axis[2] / ax_len)
    return ax, (-ax[2], ax[1])
end

"""
Half-width of `col` along `axis` (center to face).

ACI 318-11 §13.6.2.5 and R13.6.2.5 (corpus: aci-318-11, page 253): circular
supports, and rectangular supports whose sides are not parallel to the span,
are the square of the same area.  A rectangle with sides parallel to `axis`
(θ a multiple of 90°) uses its face, `c1/2` or `c2/2`.

`c_override` replaces the full dimension of columns on the slab under design
(the NLP trial size).
"""
function _eq137_face_half(col, axis::NTuple{2,Float64};
                          c_override=nothing, design_verts=nothing)
    vi = col_vertex_idx(col)
    if c_override !== nothing && design_verts !== nothing && vi in design_verts
        return c_override / 2
    end
    c1 = hasproperty(col, :c1) ? col.c1 : nothing
    isnothing(c1) && return 0.0u"inch"
    if col_shape(col) == :circular
        return equivalent_square_column(c1) / 2
    end
    if !hasproperty(col, :c2) || isnothing(col.c2)
        return c1 / 2
    end
    axes = _eq137_unit_axes(axis)
    ax = axes === nothing ? (1.0, 0.0) : axes[1]
    θ = col_orientation(col)
    # Span axis in the column's local frame; aligned iff one component is zero.
    dl_x = cos(θ) * ax[1] + sin(θ) * ax[2]
    dl_y = -sin(θ) * ax[1] + cos(θ) * ax[2]
    if abs(dl_x * dl_y) > 1e-6
        return sqrt(c1 * col.c2) / 2
    end
    return _column_face_offset_m(col, ax) * u"m"
end

"""
Mean full support width along `axis`, for the Eq. (13-4) clear span.

Same face projection as Eq. (13-7).  ACI 318-11 §13.6.2.5
(corpus: aci-318-11, page 253).
"""
function _mean_support_width(columns, axis)
    widths = Length[]
    for col in columns
        push!(widths, 2 * _eq137_face_half(col, axis))
    end
    isempty(widths) && return 0.0u"inch"
    return sum(widths) / length(widths)
end

"""
Vertex indices of the slab under design: its face corners, and every column
vertex of the neighbourhood index `partway` whose point coincides with one
of those corners (`_eq137_columns_at`), so a column on a duplicated vertex
still takes the NLP trial size.
"""
function _eq137_design_vertices(struc, slab, partway = nothing)::Set{Int}
    ids = Set{Int}()
    _eq137_geometry_available(struc) || return ids
    (isnothing(slab) || !hasproperty(slab, :cell_indices)) && return ids
    for ci in slab.cell_indices
        for vi in _eq137_cell_vis(struc, ci)
            push!(ids, vi)
            partway === nothing || union!(ids, _eq137_columns_at(struc, partway, vi))
        end
    end
    return ids
end

"""Cells of every slab, including the slab under design if it is not listed."""
function _eq137_slab_cells(struc, design_slab)
    seen = Set{Int}()
    cells = Int[]
    function _add(sl)
        isnothing(sl) && return
        hasproperty(sl, :cell_indices) || return
        for ci in sl.cell_indices
            ci in seen && continue
            push!(seen, ci)
            push!(cells, ci)
        end
    end
    if hasproperty(struc, :slabs)
        for sl in struc.slabs
            _add(sl)
        end
    end
    _add(design_slab)
    return cells
end

"""Column vertices of `struc.columns` plus the vertex indices in `extra_verts`."""
function _eq137_column_vertices(struc, extra_verts = ())::Set{Int}
    query = Set{Int}(Int(v) for v in extra_verts)
    if hasproperty(struc, :columns)
        for col in struc.columns
            push!(query, col_vertex_idx(col))
        end
    end
    return query
end

"""
Vertex → cells at that vertex.

Built once per analysis.  Eq. (13-7) then touches only the cells at the
column, not every cell in the building.

At a column vertex (one of `struc.columns`, or listed in `extra_verts`;
or every vertex indexed by a supplied `partway`) the entry is the
geometric adjoining set of the neighbourhood index
(`_eq137_partway_index`): every same-storey cell with a corner that
coincides with the column point (`_EQ137_COINCIDE_M`), whatever its vertex
indices.  Other vertices list the cells that use that vertex index.
"""
function _eq137_vertex_cell_index(struc, extra_verts = (); partway = nothing)
    idx = Dict{Int,Vector{Int}}()
    _eq137_geometry_available(struc) || return idx
    for ci in _eq137_slab_cells(struc, nothing), vi in _eq137_cell_vis(struc, ci)
        push!(get!(idx, vi, Int[]), ci)
    end
    pw = partway === nothing ?
         _eq137_partway_index(struc, _eq137_column_vertices(struc, extra_verts)) : partway
    for (v, cells) in pw.adjoin
        idx[v] = copy(cells)
    end
    return idx
end

"""Throw for a cell listed by two slabs (`k1`, `k2` index `struc.slabs`)."""
function _eq137_shared_cell_error(ci::Int, k1::Int, k2::Int)
    throw(ArgumentError(
        "Eq. (13-7) neighbour lookup: cell $ci is listed by slab $k1 and slab $k2 " *
        "(indices in struc.slabs).  A cell must belong to one slab; its self-weight " *
        "and drop panel cannot be chosen between two owners."
    ))
end

"""
Cell index → owning slab.  Built once per analysis call.

A cell listed by two different slabs has no single owner, so its neighbour
thickness and drop are undefined.  That throws `ArgumentError` naming both
slabs and the cell; no slab wins by list order.
"""
function _eq137_cell_slab_map(struc)
    m = Dict{Int,Any}()
    owner = Dict{Int,Int}()
    (isnothing(struc) || !hasproperty(struc, :slabs)) && return m
    for (k, sl) in enumerate(struc.slabs)
        hasproperty(sl, :cell_indices) || continue
        for ci in sl.cell_indices
            c = Int(ci)
            if haskey(m, c)
                m[c] === sl && continue
                _eq137_shared_cell_error(c, owner[c], k)
            end
            m[c] = sl
            owner[c] = k
        end
    end
    return m
end

"""
Vertex → every distinct column recorded at that vertex.

Storeys that share an XY location use different vertex indices, so the map
does not confuse a ground-storey column with the slab under design.  Two
columns at one vertex are both kept; `_eq137_resolved_sides` rejects them
when their sizes disagree.
"""
function _eq137_vertex_column_map(struc, extra)
    m = Dict{Int,Vector{Any}}()
    function add(col)
        vi = col_vertex_idx(col)
        vi > 0 || return
        at = get!(m, vi, Any[])
        any(c -> c === col, at) || push!(at, col)
    end
    if !isnothing(struc) && hasproperty(struc, :columns)
        for col in struc.columns
            add(col)
        end
    end
    for col in extra
        add(col)
    end
    return m
end

"""
Index, cell→slab, vertex→column, and the column neighbourhood index
(`_eq137_partway_index`), built once and reused.  The vertex index takes
its column entries from the neighbourhood index, so both read the same
geometry.
"""
function _eq137_context(struc, extra = ())
    vertex_column = _eq137_vertex_column_map(struc, extra)
    partway = _eq137_partway_index(struc, keys(vertex_column))
    return (
        index = _eq137_geometry_available(struc) ?
                _eq137_vertex_cell_index(struc; partway = partway) : nothing,
        cell_slab = _eq137_cell_slab_map(struc),
        vertex_column = vertex_column,
        partway = partway,
    )
end

"""
Owning slab of a cell.  A precomputed map is not scanned again.  The scan
rejects a cell listed by two slabs, as `_eq137_cell_slab_map` does.
"""
function _eq137_owning_slab(cell_slab, struc, ci::Int)
    cell_slab !== nothing && return get(cell_slab, ci, nothing)
    (isnothing(struc) || !hasproperty(struc, :slabs)) && return nothing
    found = nothing
    found_k = 0
    for (k, sl) in enumerate(struc.slabs)
        hasproperty(sl, :cell_indices) || continue
        ci in sl.cell_indices || continue
        if found !== nothing && found !== sl
            _eq137_shared_cell_error(ci, found_k, k)
        end
        found === nothing && (found = sl; found_k = k)
    end
    return found
end

"""Polygon vertices (meters) of one cell, or `nothing`."""
function _eq137_cell_poly_m(struc, cell_index::Int)
    cell = struc.cells[cell_index]
    hasproperty(cell, :face_idx) || return nothing
    fi = cell.face_idx
    (fi isa Integer && fi >= 1) || return nothing
    skel = struc.skeleton
    vis = skel.face_vertex_indices[fi]
    return [_eq137_vertex_xy_m(skel, Int(vi)) for vi in vis]
end

"""Vertex indices of one cell, or an empty vector."""
function _eq137_cell_vis(struc, cell_index::Int)
    cell = struc.cells[cell_index]
    hasproperty(cell, :face_idx) || return Int[]
    fi = cell.face_idx
    (fi isa Integer && fi >= 1) || return Int[]
    return [Int(vi) for vi in struc.skeleton.face_vertex_indices[fi]]
end

"""Point of segment AB nearest to P, and its distance (meters)."""
function _eq137_seg_nearest(P, A, B)
    abx = B[1] - A[1]
    aby = B[2] - A[2]
    apx = P[1] - A[1]
    apy = P[2] - A[2]
    ab2 = abx * abx + aby * aby
    t = ab2 < 1e-18 ? 0.0 : clamp((apx * abx + apy * aby) / ab2, 0.0, 1.0)
    Q = (A[1] + t * abx, A[2] + t * aby)
    return Q, hypot(P[1] - Q[1], P[2] - Q[2])
end

"""True when P lies within `tol` meters of an edge of `poly`."""
function _eq137_on_boundary(P, poly; tol::Float64 = 1e-3)::Bool
    n = length(poly)
    n < 2 && return false
    for i in 1:n
        _, d = _eq137_seg_nearest(P, poly[i], poly[mod1(i + 1, n)])
        d <= tol && return true
    end
    return false
end

"""True when P lies strictly inside polygon `poly` (crossing-number test)."""
function _eq137_point_in_poly(P, poly)::Bool
    inside = false
    n = length(poly)
    for i in 1:n
        A = poly[i]
        B = poly[mod1(i + 1, n)]
        if (A[2] > P[2]) != (B[2] > P[2])
            x = A[1] + (P[2] - A[2]) * (B[1] - A[1]) / (B[2] - A[2])
            x > P[1] && (inside = !inside)
        end
    end
    return inside
end

"""Plan distance (meters) from P to polygon `poly`; 0 when P is inside it."""
function _eq137_poly_dist(P, poly)::Float64
    _eq137_point_in_poly(P, poly) && return 0.0
    n = length(poly)
    return minimum(_eq137_seg_nearest(P, poly[i], poly[mod1(i + 1, n)])[2] for i in 1:n)
end

"""
Along-axis depth (meters) to the far frame-line vertex of the cell.

Only vertices inside the on-line tolerance are candidates.  Among those,
the depth is the farthest vertex that actually sits on the line (smallest
perpendicular distance).  An off-line corner, even one inside the
tolerance, does not change the depth.  Returns `nothing` when the cell
has no positive on-line extent.

ENGINEERING JUDGMENT: vertices within 1 mm of the closest perpendicular
distance are the same frame line.  Vertices within
`_EQ137_DEPTH_MIN_ALONG_M` along the line are at the column itself.
"""
function _eq137_frame_depth_m(poly, frame, dir)
    cands = Tuple{Float64,Float64}[]
    for p in poly
        dx = p[1] - frame[1]
        dy = p[2] - frame[2]
        along = dx * dir[1] + dy * dir[2]
        along <= _EQ137_DEPTH_MIN_ALONG_M && continue
        perp = abs(-dx * dir[2] + dy * dir[1])
        _eq137_on_line(along, perp) || continue
        push!(cands, (perp, along))
    end
    isempty(cands) && return nothing
    best_perp = minimum(c[1] for c in cands)
    depth = 0.0
    for (pr, al) in cands
        pr <= best_perp + 0.001 || continue
        depth = max(depth, al)
    end
    return depth
end

"""Z of a vertex, or `nothing` when the skeleton is 2-D."""
function _eq137_vertex_z(struc, vi::Int)
    vi <= 0 && return nothing
    vc = struc.skeleton.geometry.vertex_coords
    size(vc, 2) < 3 && return nothing
    vi > size(vc, 1) && return nothing
    z = vc[vi, 3]
    return z isa Length ? ustrip(u"m", z) : Float64(z)
end

"""
Local `(along, t)` coordinates (meters) of plan point `p` about `frame`:
`along` on the unit direction `dir`, `t` on the unit perpendicular `perp`.
"""
function _eq137_local(p, frame, dir, perp)
    dx = p[1] - frame[1]
    dy = p[2] - frame[2]
    return (dx * dir[1] + dy * dir[2], dx * perp[1] + dy * perp[2])
end

"""
Distance along the ray `P + s·dir` (unit `dir`) at which it crosses the
segment AB, or `nothing` when they are parallel or do not meet.
"""
function _eq137_ray_cross(P, dir, A, B)
    ex = B[1] - A[1]
    ey = B[2] - A[2]
    den = dir[1] * ey - dir[2] * ex
    abs(den) < 1e-12 && return nothing
    wx = A[1] - P[1]
    wy = A[2] - P[2]
    u = (wx * dir[2] - wy * dir[1]) / den
    (-1e-12 <= u <= 1.0 + 1e-12) || return nothing
    return (wx * ey - wy * ex) / den
end

"""
Covered stretches of the segment from `P` along the unit direction `dir`
over `[0, len]` by the polygons `polys`, as sorted, merged `(from, to)`
intervals (meters along `dir`).  A point is covered when it lies in a
polygon or within `_EQ137_COINCIDE_M` of one, so a segment along shared
face edges is covered.  The segment is split at every polygon-edge crossing
and every corner projection, so each piece is wholly in or out of the union.
"""
function _eq137_cover_pieces(P, dir, len::Float64, polys)
    out = Tuple{Float64,Float64}[]
    len > 0 || return out
    tol = _EQ137_COINCIDE_M
    Q = (P[1] + len * dir[1], P[2] + len * dir[2])
    xlo, xhi = min(P[1], Q[1]) - tol, max(P[1], Q[1]) + tol
    ylo, yhi = min(P[2], Q[2]) - tol, max(P[2], Q[2]) + tol
    near = [poly for poly in polys if
            maximum(p[1] for p in poly) >= xlo && minimum(p[1] for p in poly) <= xhi &&
            maximum(p[2] for p in poly) >= ylo && minimum(p[2] for p in poly) <= yhi]
    bps = [0.0, len]
    for poly in near
        n = length(poly)
        for i in 1:n
            A = poly[i]
            s = (A[1] - P[1]) * dir[1] + (A[2] - P[2]) * dir[2]
            0.0 < s < len && push!(bps, s)
            s = _eq137_ray_cross(P, dir, A, poly[mod1(i + 1, n)])
            s !== nothing && 0.0 < s < len && push!(bps, s)
        end
    end
    sort!(bps)
    for k in 1:length(bps)-1
        a, b = bps[k], bps[k+1]
        b - a > 1e-9 || continue
        m = (a + b) / 2
        M = (P[1] + m * dir[1], P[2] + m * dir[2])
        any(poly -> _eq137_poly_dist(M, poly) <= tol, near) || continue
        if !isempty(out) && out[end][2] >= a - 1e-9
            out[end] = (out[end][1], b)
        else
            push!(out, (a, b))
        end
    end
    return out
end

"""
Covered run (meters) of the segment from `P` along the unit direction `dir`
over `[0, len]` by the polygons `polys` (`_eq137_cover_pieces`): the end of
the stretch from `P` that the polygons cover, with uncovered stretches no
longer than `gap` bridged.
"""
function _eq137_cover_run(P, dir, len::Float64, polys, gap::Float64)
    run = 0.0
    for (a, b) in _eq137_cover_pieces(P, dir, len, polys)
        a > run + gap && break
        run = max(run, b)
    end
    return run
end

"""
True when every uncovered stretch longer than `_EQ137_NEIGHBOURHOOD_M`
between the covered `pieces` (`_eq137_cover_pieces` of `polys` along the
segment from `P` on the unit direction `u` over `[0, len]`) is an opening:
the slab closes it on both perpendicular sides within `len` of the gap's
midpoint.  A gap open on one side (a slab edge, notch or joint across the
line) is not an opening.

ENGINEERING JUDGMENT: an uncovered stretch the slab surrounds is an
opening, not a slab edge; the slab continues around it to the column
beyond (§13.6.2.5 measures ℓn between supports, corpus: aci-318-11,
page 253).  The search for the enclosing slab is limited to `len`, the
column-to-column distance; a gap open farther than that is read as a
notch or joint, which `_eq137_far_support` envelopes down to a zero span.
"""
function _eq137_gaps_enclosed(P, u, len::Float64, pieces, polys)::Bool
    R = _EQ137_NEIGHBOURHOOD_M
    perp = (-u[2], u[1])
    for k in 1:length(pieces)-1
        g0, g1 = pieces[k][2], pieces[k+1][1]
        g1 - g0 > R || continue
        m = (g0 + g1) / 2
        M = (P[1] + m * u[1], P[2] + m * u[2])
        for σ in (1, -1)
            isempty(_eq137_cover_pieces(M, (σ * perp[1], σ * perp[2]), len, polys)) &&
                return false
        end
    end
    return true
end

"""
True when P lies inside polygon `poly` farther than `_EQ137_COINCIDE_M`
from its boundary.
"""
function _eq137_strictly_inside(P, poly)::Bool
    _eq137_point_in_poly(P, poly) || return false
    n = length(poly)
    return all(_eq137_seg_nearest(P, poly[i], poly[mod1(i + 1, n)])[2] > _EQ137_COINCIDE_M
               for i in 1:n)
end

"""
True when face `poly` overlaps another face of `polys` (`(cell, polygon)`
pairs; `ci` is its own cell): a corner of one lies strictly inside the
other (`_eq137_strictly_inside`).  Faces of one tessellation never do.
"""
function _eq137_overlaps_other(ci::Int, poly, polys)::Bool
    for (cj, q) in polys
        cj == ci && continue
        (any(p -> _eq137_strictly_inside(p, poly), q) ||
         any(p -> _eq137_strictly_inside(p, q), poly)) && return true
    end
    return false
end

"""
Same-storey slab faces of column vertex `vi`: `(cell, polygon)` pairs from
the neighbourhood index `partway` (`polys`, finite faces only), in cell
order.  A face is on the storey when one of its corners is
(`_eq137_z_agree`), as in `_eq137_partway_index`.
"""
