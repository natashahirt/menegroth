# =============================================================================
# Slab Openings — storage on the skeleton and per-face queries
# =============================================================================
#
# Openings live on `skel.openings` (see `SlabOpening`), one record per story.
# Which faces an opening touches is derived on demand from the plan overlap,
# so it never goes stale when faces or groups change.

"""Overlap below this (m²) does not count: an opening that only shares an edge with a face."""
const OPENING_OVERLAP_TOL_M2 = 1e-6

_plan_coord_m(c::Unitful.Quantity) = Float64(ustrip(u"m", c))
_plan_coord_m(c::Real) = Float64(c)

"""Plan outline in meters from `(x, y)` points (plain numbers are meters); drops a repeated closing point."""
function _opening_loop(raw)
    loop = NTuple{2, Float64}[(_plan_coord_m(p[1]), _plan_coord_m(p[2])) for p in raw]
    length(loop) > 1 && loop[end] == loop[1] && pop!(loop)
    return loop
end

"""
    story_index_at(skel, z_m; tol=0.01) -> Union{Int, Nothing}

Story level index whose elevation is within `tol` meters of `z_m`. The default
covers `rebuild_stories!`, which rounds elevations to the centimetre.
"""
function story_index_at(skel::BuildingSkeleton, z_m::Real; tol::Real=0.01)
    for (level, story) in skel.stories
        abs(_plan_coord_m(story.elevation) - z_m) <= tol && return level
    end
    return nothing
end

"""Story level index that lists `face_idx`, or `nothing`."""
function face_story(skel::BuildingSkeleton, face_idx::Int)
    for (level, story) in skel.stories
        face_idx in story.faces && return level
    end
    return nothing
end

"""Face outline in plan meters."""
function _face_loop_m(skel::BuildingSkeleton, face_idx::Int)
    return NTuple{2, Float64}[(vertex_coords(skel, v).x, vertex_coords(skel, v).y)
                              for v in skel.face_vertex_indices[face_idx]]
end

# =============================================================================
# Adding openings
# =============================================================================

"""
    add_slab_opening!(skel, loop, stories) -> skel

Add one unframed opening with plan outline `loop` (`(x, y)` points; plain
numbers are meters) on each story in `stories` (a level index or a collection,
e.g. `1:5` for a stair repeated up the building).

Throws if the outline has fewer than 3 points or no area, a story does not
exist, or the opening overlaps another opening on the same story (draw
overlapping cuts as one outline, so net areas are not subtracted twice).
"""
function add_slab_opening!(skel::BuildingSkeleton, loop, stories)
    pts = _opening_loop(loop)
    length(pts) >= 3 || throw(ArgumentError("Slab opening needs at least 3 points; got $(length(pts))."))
    abs(_shoelace_area(pts)) > OPENING_OVERLAP_TOL_M2 ||
        throw(ArgumentError("Slab opening outline has no area."))
    for level in stories
        haskey(skel.stories, level) ||
            throw(ArgumentError("Slab opening story $level does not exist; stories are $(sort(collect(keys(skel.stories))))."))
        for (k, other) in enumerate(skel.openings)
            other.story == level || continue
            _overlap_area(pts, other.loop) > OPENING_OVERLAP_TOL_M2 &&
                throw(ArgumentError("Slab opening overlaps opening $k on story $level; draw them as one outline."))
        end
        push!(skel.openings, SlabOpening(level, pts))
    end
    return skel
end

# =============================================================================
# Per-face queries
# =============================================================================

"""Outlines (meters) of the nested beam networks that are voids of `face_idx`."""
face_hole_loops(skel::BuildingSkeleton, face_idx::Int) =
    get(skel.face_holes, face_idx, Vector{NTuple{2, Float64}}[])

"""Plan area (m²) of `loop` that lies on the face, outside its [`face_hole_loops`](@ref)."""
function _area_on_face(skel::BuildingSkeleton, face_idx::Int, face, loop)
    a = _overlap_area(face, loop)
    for hole in face_hole_loops(skel, face_idx)
        a -= _overlap_area(hole, loop)
    end
    return a
end

"""
    face_openings(skel, face_idx) -> Vector{Int}

Indices into `skel.openings` of the openings on the face's story that overlap
the face, outside its holes, by more than `OPENING_OVERLAP_TOL_M2`. An opening
straddling a cell edge is listed for every face it overlaps.
"""
function face_openings(skel::BuildingSkeleton, face_idx::Int)
    isempty(skel.openings) && return Int[]
    level = face_story(skel, face_idx)
    level === nothing && return Int[]
    face = _face_loop_m(skel, face_idx)
    return [k for (k, op) in enumerate(skel.openings)
            if op.story == level &&
               _area_on_face(skel, face_idx, face, op.loop) > OPENING_OVERLAP_TOL_M2]
end

"""
Warn for every vault face that contains an opening.

The opening is not framed and is not part of the vault span, stress, or
thrust. Framing and the vault check come later; until then the result is
for the full bay.
"""
function warn_vault_openings!(struc, only::Union{Nothing,Int}=nothing)
    idxs = only === nothing ? eachindex(struc.slabs) : (only,)
    for slab_idx in idxs
        slab = struc.slabs[slab_idx]
        slab.floor_type === :vault || continue
        for ci in slab.cell_indices
            face = struc.cells[ci].face_idx
            n = length(face_openings(struc.skeleton, face))
            n == 0 && continue
            @warn "vault slab $slab_idx face $face has $n unframed opening(s); they are left out of the vault check"
        end
    end
    return struc
end

"""Plan outlines (meters) of the voids in `face_idx`: its openings, then its holes."""
face_opening_loops(skel::BuildingSkeleton, face_idx::Int) =
    vcat([skel.openings[k].loop for k in face_openings(skel, face_idx)],
         face_hole_loops(skel, face_idx))

"""
    face_net_area(skel, face_idx)

Face area minus its holes and the parts of its openings that fall on it (same
units as [`face_area`](@ref)).
"""
function face_net_area(skel::BuildingSkeleton, face_idx::Int)
    gross = face_area(skel, face_idx)
    holes = face_hole_loops(skel, face_idx)
    ks = face_openings(skel, face_idx)
    (isempty(ks) && isempty(holes)) && return gross
    face = _face_loop_m(skel, face_idx)
    cut = sum((abs(_shoelace_area(h)) for h in holes); init = 0.0) +
          sum((_area_on_face(skel, face_idx, face, skel.openings[k].loop) for k in ks); init = 0.0)
    return max(gross - cut * u"m^2", zero(gross))
end

# =============================================================================
# Plan polygon geometry
# =============================================================================

"""Signed shoelace area (positive for counterclockwise)."""
function _shoelace_area(loop)
    n = length(loop)
    a = 0.0
    @inbounds for i in 1:n
        p, q = loop[i], loop[i == n ? 1 : i + 1]
        a += p[1] * q[2] - q[1] * p[2]
    end
    return a / 2
end

_cross2(o, a, b) = (a[1] - o[1]) * (b[2] - o[2]) - (a[2] - o[2]) * (b[1] - o[1])

"""
Triangles covering a simple polygon (ear clipping). Collinear vertices are
dropped; throws if the outline is self-intersecting.
"""
function _ear_triangles(loop)
    pts = _shoelace_area(loop) < 0 ? reverse(loop) : copy(loop)
    xs, ys = first.(pts), last.(pts)
    tol = 1e-12 * max(maximum(xs) - minimum(xs), maximum(ys) - minimum(ys), 1.0)^2
    idx = collect(eachindex(pts))
    tris = NTuple{3, NTuple{2, Float64}}[]
    while length(idx) > 3
        m = length(idx)
        clipped = false
        for k in 1:m
            a, b, c = pts[idx[mod1(k - 1, m)]], pts[idx[k]], pts[idx[mod1(k + 1, m)]]
            cr = _cross2(a, b, c)
            if abs(cr) <= tol
                deleteat!(idx, k)
                clipped = true
                break
            end
            cr < 0 && continue
            blocked = any(idx) do j
                p = pts[j]
                (p == a || p == b || p == c) && return false
                _cross2(a, b, p) >= -tol && _cross2(b, c, p) >= -tol && _cross2(c, a, p) >= -tol
            end
            blocked && continue
            push!(tris, (a, b, c))
            deleteat!(idx, k)
            clipped = true
            break
        end
        clipped || throw(ArgumentError("Polygon outline could not be triangulated; it may self-intersect."))
    end
    if length(idx) == 3
        a, b, c = pts[idx[1]], pts[idx[2]], pts[idx[3]]
        abs(_cross2(a, b, c)) > tol && push!(tris, (a, b, c))
    end
    return tris
end

"""
Clip `subject` to a counterclockwise triangle (Sutherland–Hodgman). The subject
may be non-convex: the result can carry zero-area bridge edges, which leave its
shoelace area exact.
"""
function _clip_to_triangle(subject, tri)
    out = collect(subject)
    for i in 1:3
        isempty(out) && break
        a, b = tri[i], tri[i == 3 ? 1 : i + 1]
        input = out
        out = NTuple{2, Float64}[]
        s = input[end]
        for e in input
            e_in = _cross2(a, b, e) >= 0
            s_in = _cross2(a, b, s) >= 0
            if e_in != s_in
                ds, de = _cross2(a, b, s), _cross2(a, b, e)
                t = ds / (ds - de)
                push!(out, (s[1] + t * (e[1] - s[1]), s[2] + t * (e[2] - s[2])))
            end
            e_in && push!(out, e)
            s = e
        end
    end
    return out
end

"""Plan area (m²) shared by two simple polygons."""
function _overlap_area(p, q)
    (length(p) < 3 || length(q) < 3) && return 0.0
    pmin = (minimum(first, p), minimum(last, p)); pmax = (maximum(first, p), maximum(last, p))
    qmin = (minimum(first, q), minimum(last, q)); qmax = (maximum(first, q), maximum(last, q))
    (pmax[1] <= qmin[1] || qmax[1] <= pmin[1] || pmax[2] <= qmin[2] || qmax[2] <= pmin[2]) && return 0.0
    return sum((abs(_shoelace_area(_clip_to_triangle(p, tri))) for tri in _ear_triangles(q)); init=0.0)
end
