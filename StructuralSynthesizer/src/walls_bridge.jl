# =============================================================================
# Wall-bridge geometry derivation (reduced lateral evaluator provenance)
# =============================================================================
#
# Pure derivation helpers that read the TRUE plate geometry and per-story centre
# of mass straight from the skeleton's `GeometryCache.vertex_coords` — the single
# datum the FLOOR polygon is defined in.
#
# FRAME INVARIANT (what is and is NOT guaranteed):
# - The plate and per-story CoM here are derived SOLELY from the skeleton floor
#   polygon (`GeometryCache.vertex_coords`), so they are frame-consistent with the
#   skeleton by construction.
# - A building `Wall`'s plan center is `wall_center` (`x1,y1,x2,y2`); a
#   `WallLine`'s is `.x,.y`. `initialize_members!` writes the building-wall
#   endpoints from the chain-end `vertex_coords`, so those walls share this
#   datum. `Wall.story` is 0-based (`edge_story`). `to_wall_line` sets
#   `WallLine.story = Wall.story + 1` (1-based). Hand-built walls can still
#   disagree with the datum, so this helper VERIFIES enclosure rather than
#   assuming it.
# - CONTRACT: the caller MUST express the walls' plan coordinates in the SAME
#   skeleton `vertex_coords` datum the plate is derived from. This helper does NOT
#   assume that — it VERIFIES it, failing closed. Pass the story's walls to
#   `story_plate_geometry(skeleton, story; walls=...)` (or call
#   `assert_walls_enclosed` directly) to assert WALLS ⊆ derived plate before the
#   plate is handed to the reduced lateral evaluator; a frame mismatch (or an
#   incomplete `story.faces`) then throws instead of silently mis-locating drift.
#   `initialize!` does this for every story that has walls via
#   `assert_story_walls_enclosed!`.
#
# Units: `vertex_coords` is a bare-Float64 N×3 matrix in METERS (the single source
# of truth; see GeometryCache docstring). All plan outputs here are therefore bare
# Float64 in metres, matching `WallLine`'s bare-SI convention. Cell loads are
# Unitful (`kN/m^2`), areas `m^2`; their product is a Unitful force (`kN`), which
# cancels in the mass-weighted centroid.
# =============================================================================

# Degenerate-geometry tolerance [m]. A real floor footprint spans metres, so a
# span below 1 nm is numerically degenerate (empty / collinear / zero-area).
const _WALLS_BRIDGE_DEGEN_TOL = 1e-9

"""
    _geometry_cache_or_error(skeleton) -> GeometryCache

Return `skeleton.geometry`, or throw if the cache has not been built yet
(`rebuild_geometry_cache!` must have run). Fails closed — callers must not read
coordinates from an unpopulated skeleton.
"""
function _geometry_cache_or_error(skeleton::BuildingSkeleton)
    geo = skeleton.geometry
    geo === nothing && throw(ArgumentError(
        "walls_bridge: skeleton.geometry is not built — call rebuild_geometry_cache!(skeleton) first"))
    return geo
end

"""
    _face_plan_vertices(skeleton, face_idx) -> Vector{NTuple{2,Float64}}

Ordered `(x, y)` plan coordinates [m] of a skeleton face's polygon, read from
`GeometryCache.vertex_coords` via `face_vertex_indices` (the same datum as
`to_wall_line`). Vertices are returned in face (polygon) order.
"""
function _face_plan_vertices(skeleton::BuildingSkeleton, face_idx::Int)
    geo = _geometry_cache_or_error(skeleton)
    vc = geo.vertex_coords
    vids = skeleton.face_vertex_indices[face_idx]
    return NTuple{2,Float64}[(vc[vi, 1], vc[vi, 2]) for vi in vids]
end

"""
    _polygon_area_centroid(pts) -> (cx::Float64, cy::Float64, area::Float64)

Area centroid and absolute area [m, m, m²] of a simple polygon given by ordered
plan vertices `pts` (shoelace formula; vertices in face order, open ring). This
is the centroid of a *uniformly loaded* cell, so lumping a cell's uniform floor
mass here is the correct discrete representation. For a parallelogram/rectangle
it reduces to the vertex average. Throws on a degenerate (collinear / zero-area)
face — fail closed, never return a silent zero.
"""
function _polygon_area_centroid(pts::AbstractVector{NTuple{2,Float64}})
    n = length(pts)
    n < 3 && throw(ArgumentError(
        "walls_bridge: face polygon has $n vertices (< 3) — degenerate floor"))
    A2 = 0.0   # 2·signed area
    cx = 0.0
    cy = 0.0
    @inbounds for i in 1:n
        x1, y1 = pts[i]
        x2, y2 = pts[mod1(i + 1, n)]
        cross = x1 * y2 - x2 * y1
        A2 += cross
        cx += (x1 + x2) * cross
        cy += (y1 + y2) * cross
    end
    area = abs(A2) / 2
    area <= _WALLS_BRIDGE_DEGEN_TOL && throw(ArgumentError(
        "walls_bridge: face polygon has zero area ($(area) m²) — degenerate floor"))
    # Centroid formula uses signed area (A2/2), not abs.
    cx /= (3 * A2)
    cy /= (3 * A2)
    return (cx, cy, area)
end

# Plan center `(x, y)` [m] of a wall, in the skeleton `vertex_coords` datum.
# Dispatches over the two wall representations the bridge accepts: a building
# `Wall` (plan endpoints → `wall_center`) and the sizer's bare-SI `WallLine`
# (`.x, .y`). A caller passing anything else is a frame/type error — let dispatch
# fail loudly rather than guess a coordinate.
_wall_plan_center(w::Wall) = wall_center(w)
_wall_plan_center(w::StructuralSizer.WallLine) = (w.x, w.y)

"""
    assert_walls_enclosed(plate_center, plan_halfwidth, walls) -> Nothing

Fail-closed verification that EVERY wall plan center in `walls` lies inside — or
exactly on — the derived plate rectangle `plate_center ± plan_halfwidth`. `walls`
may hold building [`Wall`](@ref)s (plan center via [`wall_center`](@ref)) or
`StructuralSizer.WallLine`s (center `(x, y)`). Throws a clear `ArgumentError`
naming the offending wall center and the plate box if any wall is outside;
returns `nothing` when all walls are enclosed (vacuously so for an empty `walls`).

WHY (crit7, construction side): this discharges the CHECKABLE part of the reduced
`ReducedDiaphragmEvaluator`'s enclosure obligation at the point the plate is
built, mirroring `_plate_encloses_walls` in `StructuralSizer`'s lateral
evaluator. The reduced model carries NO independent occupant outline, so
`plate_center`/`plan_halfwidth` is CONTRACTUALLY the true occupant diaphragm in
the `WallLine` frame; a wall whose center falls OUTSIDE the derived plate is then
either (a) a FRAME MISMATCH — the wall plan coordinates were not expressed in the
skeleton `vertex_coords` datum the plate is derived from — or (b) an INCOMPLETE
`story.faces` — a real occupant face was omitted, shrinking the derived plate.
Both are caught here.

Tolerance mirrors `_plate_encloses_walls` (ENGINEERING JUDGMENT, not a code
clause): `tol = 1e-9 + 1e-9·hypot(hx, hy)` — an absolute floor plus a
plate-scaled relative term — so a wall EXACTLY on the plate boundary
(`|w.x − cx| == hx`) PASSES despite floating-point assembly noise, while a genuine
over-hang (even a few mm beyond a plan-scale plate) FAILS closed. The test is
ORIGIN-INVARIANT: walls and plate translate together, so a joint origin shift
leaves every inequality unchanged.

RESIDUAL NOT caught here (mirrors the lateral evaluator crit7 wording): a plate
that ENCLOSES the walls but is declared SMALLER than the true occupant diaphragm
(walls ⊆ plate ⊂ occupants) — e.g. an incomplete `story.faces` whose walls happen
to still sit inside the shrunken plate — is NOT closable at this construction
site. It relies on `story.faces` being the COMPLETE story floor (the skeleton's
definition) and is delegated to the Phase 10 unified-FEM survivor check (true
geometry, the final authority).

Quantitatively, the assertion only fires once a wall center crosses the box edge,
so it tolerates any frame/geometry error that keeps every wall inside: a wall at
distance `d` from the plate center along an axis can absorb a silent offset of up
to `(h − d)` on that axis (half-extent `h`) before the check trips — up to the
FULL half-extent `h` for a wall sitting at the plate center, and ~0 for a wall on
the boundary. A uniform whole-system shift that moves walls and plate together is
undetectable by construction (origin-invariant). These bounds are the measure of
the residual above; closing them requires the true occupant outline (Phase 10 FEM).
"""
function assert_walls_enclosed(plate_center::NTuple{2,Float64},
                               plan_halfwidth::NTuple{2,Float64},
                               walls::AbstractVector)
    cx, cy = plate_center
    hx, hy = plan_halfwidth
    # Degenerate/invalid plate: a negative half-extent cannot bound anything.
    # Fail closed (mirrors `_plate_encloses_walls`, which rejects a negative plate).
    (hx < 0 || hy < 0) && throw(ArgumentError(
        "assert_walls_enclosed: negative plan_halfwidth $(plan_halfwidth) — a plate " *
        "half-extent must be ≥ 0 m. Fail closed (degenerate/invalid plate)."))
    tol = 1e-9 + 1e-9 * hypot(hx, hy)   # absolute + plate-scaled boundary tolerance
    for w in walls
        wx, wy = _wall_plan_center(w)
        enclosed = (cx - hx - tol <= wx <= cx + hx + tol) &&
                   (cy - hy - tol <= wy <= cy + hy + tol)
        enclosed || throw(ArgumentError(
            "assert_walls_enclosed: wall plan center ($(wx), $(wy)) m lies OUTSIDE the " *
            "derived plate box [$(cx - hx), $(cx + hx)] × [$(cy - hy), $(cy + hy)] m " *
            "(plate_center $(plate_center), plan_halfwidth $(plan_halfwidth), tol $(tol)). " *
            "A wall outside the derived plate is a FRAME MISMATCH (wall coords not in the " *
            "skeleton vertex_coords datum) or an INCOMPLETE story.faces — fail closed."))
    end
    return nothing
end

"""
    story_plate_geometry(skeleton, story; walls=nothing) -> (plate_center, plan_halfwidth)

True plan bounding box of a story's floor footprint, derived from the union of
the story's cell-face polygon vertices in `GeometryCache.vertex_coords` (the
skeleton floor datum).

Returns `(plate_center::NTuple{2,Float64}, plan_halfwidth::NTuple{2,Float64})`
in metres, where
- `plate_center = ((minx+maxx)/2, (miny+maxy)/2)`
- `plan_halfwidth = ((maxx-minx)/2, (maxy-miny)/2)`

so the four plate corners are exactly `plate_center ± plan_halfwidth` — the
construction the reduced wall lateral evaluator assumes when it computes
interstory corner drift. The min/max bounding-box logic matches
`_chat_geo_envelope` (api/chat.jl) exactly so the two agree on identical
geometry. Throws on an empty or degenerate (collinear / zero-width) footprint —
fail closed, never return a zero-size plate.

# Enclosure self-check (`walls`) — the SAFE path for `ReducedDiaphragmEvaluator`
`walls::Union{Nothing,AbstractVector}` is an OPTIONAL set of the story's walls,
holding building [`Wall`](@ref)s (plan center via [`wall_center`](@ref)) or
`StructuralSizer.WallLine`s (center `(x, y)`). When `walls !== nothing`, after
computing `(plate_center, plan_halfwidth)` this asserts — via
[`assert_walls_enclosed`](@ref) — that EVERY wall center lies within
`plate_center ± plan_halfwidth` (same tolerance philosophy as the evaluator's
`_plate_encloses_walls`; on-boundary accepted), throwing `ArgumentError` (fail
closed) otherwise. This is the SAFE way to build the plate that feeds
`ReducedDiaphragmEvaluator`: it verifies the (otherwise unenforced) contract that
the walls and the derived plate share the skeleton datum, and catches a wall that
has fallen outside the derived plate (a frame mismatch OR an incomplete
`story.faces`). The default `walls=nothing` preserves the prior, check-free
behavior (back-compat).

# Residual limitation (honest scope — do NOT over-claim)
The `walls` check closes WALLS ⊆ plate. It does NOT close the complementary case
where the plate encloses the walls but is SMALLER than the true occupant
diaphragm (walls ⊆ plate ⊂ occupants) — e.g. an incomplete `story.faces` whose
walls still sit inside the shrunken plate. That residual relies on `story.faces`
being the COMPLETE story floor (the skeleton's definition) and is delegated to
the Phase 10 unified-FEM survivor check (true geometry, the final authority).
See [`assert_walls_enclosed`](@ref), which mirrors the lateral evaluator's crit7
enclosure-contract wording.

# `plate_center` is the BOUNDING-BOX center, not the material centroid
`plate_center` is the center of the axis-aligned bounding box, NOT the area
centroid. For an L-shaped / concave floor the bbox center can differ from the
material centroid and may even lie in a VOID. This is intentional and CONSERVATIVE
for drift: the bounding box CONTAINS the floor (bbox ⊇ floor), so the four
evaluated corners `plate_center ± plan_halfwidth` enclose the true floor corners
and never under-reach the drift-critical edge — PROVIDED `story.faces` is the
COMPLETE story floor. (The per-story material centroid used for the seismic mass /
eccentricity is computed separately in [`story_center_of_mass`](@ref).)
"""
function story_plate_geometry(skeleton::BuildingSkeleton, story::Story;
                              walls::Union{Nothing,AbstractVector}=nothing)
    _geometry_cache_or_error(skeleton)   # fail closed before touching coords
    isempty(story.faces) && throw(ArgumentError(
        "story_plate_geometry: story has no faces — empty floor"))

    xs = Float64[]
    ys = Float64[]
    for f in story.faces
        for (x, y) in _face_plan_vertices(skeleton, f)
            push!(xs, x)
            push!(ys, y)
        end
    end
    isempty(xs) && throw(ArgumentError(
        "story_plate_geometry: story faces reference no vertices — empty floor"))

    # Bounding box: identical min/max semantics to _chat_geo_envelope.
    minx, maxx = extrema(xs)
    miny, maxy = extrema(ys)

    if (maxx - minx) <= _WALLS_BRIDGE_DEGEN_TOL || (maxy - miny) <= _WALLS_BRIDGE_DEGEN_TOL
        throw(ArgumentError(
            "story_plate_geometry: degenerate floor footprint " *
            "(x-span $(maxx - minx) m, y-span $(maxy - miny) m) — collinear or zero-area"))
    end

    plate_center   = ((minx + maxx) / 2, (miny + maxy) / 2)
    plan_halfwidth = ((maxx - minx) / 2, (maxy - miny) / 2)

    # Fail-closed enclosure self-check: verify (do NOT assume) that the caller's
    # walls live in the same skeleton datum as the derived plate. See
    # assert_walls_enclosed / this docstring's "Enclosure self-check" section.
    walls === nothing || assert_walls_enclosed(plate_center, plan_halfwidth, walls)

    return (plate_center, plan_halfwidth)
end

"""
    projected_plan_width(points, direction) -> Float64

Width of `points` measured perpendicular to `direction`, in metres.

`direction` is a horizontal vector `(dx, dy)`. It need not be a unit vector,
and the components may be integers: `(1, 0)` returns the Y extent and `(0, 1)`
returns the X extent. An empty point list throws.
"""
function projected_plan_width(points, direction::Tuple{Real, Real})
    isempty(points) && throw(ArgumentError(
        "projected_plan_width: no points"))
    dx = Float64(direction[1])
    dy = Float64(direction[2])
    nrm = hypot(dx, dy)
    nrm > 0 || throw(ArgumentError(
        "projected_plan_width: direction must be nonzero; got $direction"))
    dx /= nrm
    dy /= nrm
    # In-plane normal. The sign does not change the extent.
    px, py = -dy, dx
    lo = Inf
    hi = -Inf
    for (x, y) in points
        t = px * x + py * y
        lo = min(lo, t)
        hi = max(hi, t)
    end
    return hi - lo
end

"""
    story_floor_outline(skeleton, story) -> Vector{Vector{NTuple{2,Float64}}}

Closed plan loops of one story's floor, in metres, from the skeleton vertices.

Each loop is the exterior of `story.faces`: an edge shared by two of those
faces is interior and is dropped. Coordinates are `GeometryCache.vertex_coords`,
the same datum as [`story_plate_geometry`](@ref) and [`to_wall_line`](@ref).
A courtyard or a disconnected floor returns more than one loop. The loops are
open rings (the first vertex is not repeated at the end).

Each loop is oriented so the right-hand normal of a directed edge points out
of the floor. An exterior loop, and an island inside a courtyard, runs
counterclockwise (positive signed area). A courtyard hole runs clockwise
(negative signed area). The first vertex of each loop is the one with the
smallest `(x, y)`, and the loops are sorted by that vertex, so the result
does not depend on face order or on which boundary edge is walked first.

An edge that passes through another vertex of the story's faces is split
there. Pieces a second face covers are interior and are dropped, so a
T-junction in `face_vertex_indices` still yields the outer floor. Two slabs
that touch only at a corner are not one floor and throw. A joist landing
that was inserted into the member graph but not into `face_vertex_indices`
is not a split point.

The axis-aligned box from [`story_plate_geometry`](@ref) still encloses this
outline. It is not this outline. A re-entrant floor keeps the notch.

Throws if the story has no faces, if a face has fewer than three vertices, if
an edge belongs to more than two faces, if the boundary is not a set of closed
loops, or if the outline has no area.
"""
function story_floor_outline(skeleton::BuildingSkeleton, story::Story)
    geo = _geometry_cache_or_error(skeleton)
    isempty(story.faces) && throw(ArgumentError(
        "story_floor_outline: story has no faces — empty floor"))
    vc = geo.vertex_coords

    counts = _atomic_edge_counts(vc, skeleton, story.faces)
    for (key, c) in counts
        c <= 2 || throw(ArgumentError(
            "story_floor_outline: edge $key belongs to $c faces — the floor is not a surface"))
    end
    boundary = [key for (key, c) in counts if c == 1]
    isempty(boundary) && throw(ArgumentError(
        "story_floor_outline: story faces have no exterior edge"))

    adj = Dict{Int, Vector{Int}}()
    for (a, b) in boundary
        push!(get!(adj, a, Int[]), b)
        push!(get!(adj, b, Int[]), a)
    end
    for (v, nbrs) in adj
        length(nbrs) == 2 || throw(ArgumentError(
            "story_floor_outline: vertex $v meets $(length(nbrs)) exterior edges — " *
            "two slabs touch only at a corner, or a vertex lies off the edge it " *
            "was meant to split. The floor boundary is not a set of closed loops"))
    end

    unused = Set(boundary)
    loops = Vector{NTuple{2,Float64}}[]
    while !isempty(unused)
        a0, b0 = first(unused)
        ring = Int[a0]
        prev = a0
        cur = b0
        delete!(unused, a0 < b0 ? (a0, b0) : (b0, a0))
        steps = 0
        while cur != a0
            push!(ring, cur)
            nbrs = adj[cur]
            prev in nbrs || throw(ArgumentError(
                "story_floor_outline: exterior walk reached vertex $cur without a way back"))
            nxt = nbrs[1] == prev ? nbrs[2] : nbrs[1]
            key = cur < nxt ? (cur, nxt) : (nxt, cur)
            key in unused || throw(ArgumentError(
                "story_floor_outline: exterior edge $key was visited twice"))
            delete!(unused, key)
            prev = cur
            cur = nxt
            steps += 1
            steps > length(boundary) && throw(ArgumentError(
                "story_floor_outline: exterior walk did not close"))
        end
        push!(loops, [(vc[i, 1], vc[i, 2]) for i in ring])
    end

    # A collinear ring has no floor area. Fail closed rather than hand wind
    # or the 5% eccentricity a line.
    for loop in loops
        _polygon_area_centroid(loop)
    end
    return _canonicalize_outline_loops(loops)
end

# Parameter of vertex `v` along a→b, or nothing when `v` is not strictly
# between the endpoints. The cross-track test uses `_WALLS_BRIDGE_DEGEN_TOL` metres.
function _strict_segment_parameter(vc, a::Int, b::Int, v::Int)
    x1 = vc[a, 1]
    y1 = vc[a, 2]
    x2 = vc[b, 1]
    y2 = vc[b, 2]
    px = vc[v, 1]
    py = vc[v, 2]
    dx = x2 - x1
    dy = y2 - y1
    len = hypot(dx, dy)
    len <= _WALLS_BRIDGE_DEGEN_TOL && return nothing
    cross = dx * (py - y1) - dy * (px - x1)
    abs(cross) / len > _WALLS_BRIDGE_DEGEN_TOL && return nothing
    t = ((px - x1) * dx + (py - y1) * dy) / (len * len)
    margin = _WALLS_BRIDGE_DEGEN_TOL / len
    return margin < t < 1 - margin ? t : nothing
end

_edge_key(a::Int, b::Int) = a < b ? (a, b) : (b, a)

# Split every face edge at other vertices of these faces that lie on it, then
# count the pieces. A piece covered by two faces is interior.
function _atomic_edge_counts(vc, skeleton::BuildingSkeleton, faces)
    used = Int[]
    seen = Set{Int}()
    raw = Tuple{Int,Int}[]
    nvc = size(vc, 1)
    for f in faces
        vids = skeleton.face_vertex_indices[f]
        n = length(vids)
        n >= 3 || throw(ArgumentError(
            "story_floor_outline: face $f has $n vertices (< 3)"))
        for i in 1:n
            a = vids[i]
            b = vids[mod1(i + 1, n)]
            a == b && throw(ArgumentError(
                "story_floor_outline: face $f has a zero-length edge at vertex $a"))
            (1 <= a <= nvc && 1 <= b <= nvc) || throw(ArgumentError(
                "story_floor_outline: face $f references a vertex outside the geometry cache"))
            push!(raw, (a, b))
            for v in (a, b)
                v in seen && continue
                push!(seen, v)
                push!(used, v)
            end
        end
    end
    counts = Dict{Tuple{Int,Int}, Int}()
    for (a, b) in raw
        splits = Tuple{Float64,Int}[]
        for v in used
            (v == a || v == b) && continue
            t = _strict_segment_parameter(vc, a, b, v)
            t === nothing && continue
            push!(splits, (t, v))
        end
        sort!(splits)
        chain = Int[a]
        for (_, v) in splits
            v == chain[end] && continue
            if hypot(vc[chain[end], 1] - vc[v, 1], vc[chain[end], 2] - vc[v, 2]) <=
               _WALLS_BRIDGE_DEGEN_TOL
                throw(ArgumentError(
                    "story_floor_outline: vertices $(chain[end]) and $v occupy the same point"))
            end
            push!(chain, v)
        end
        if chain[end] != b &&
           hypot(vc[chain[end], 1] - vc[b, 1], vc[chain[end], 2] - vc[b, 2]) <=
           _WALLS_BRIDGE_DEGEN_TOL
            throw(ArgumentError(
                "story_floor_outline: vertices $(chain[end]) and $b occupy the same point"))
        end
        push!(chain, b)
        for i in 1:(length(chain) - 1)
            key = _edge_key(chain[i], chain[i + 1])
            counts[key] = get(counts, key, 0) + 1
        end
    end
    return counts
end

# Signed area of an open ring. Positive is counterclockwise.
function _ring_signed_area(pts::AbstractVector{NTuple{2,Float64}})
    A2 = 0.0
    n = length(pts)
    @inbounds for i in 1:n
        x1, y1 = pts[i]
        x2, y2 = pts[mod1(i + 1, n)]
        A2 += x1 * y2 - x2 * y1
    end
    return A2 / 2
end

# `:inside`, `:outside`, or `:boundary` by the even-odd rule.
function _ring_location(x::Float64, y::Float64, ring::AbstractVector{NTuple{2,Float64}})
    tol = _WALLS_BRIDGE_DEGEN_TOL
    n = length(ring)
    @inbounds for i in 1:n
        x1, y1 = ring[i]
        x2, y2 = ring[mod1(i + 1, n)]
        dx = x2 - x1
        dy = y2 - y1
        len = hypot(dx, dy)
        if len <= tol
            hypot(x - x1, y - y1) <= tol && return :boundary
            continue
        end
        cross = dx * (y - y1) - dy * (x - x1)
        if abs(cross) / len <= tol
            t = ((x - x1) * dx + (y - y1) * dy) / (len * len)
            -tol <= t <= 1 + tol && return :boundary
        end
    end
    inside = false
    @inbounds for i in 1:n
        x1, y1 = ring[i]
        x2, y2 = ring[mod1(i + 1, n)]
        # Assign a vertex to the upper endpoint so a ray through it is counted once.
        if (y1 > y) != (y2 > y)
            xint = x1 + (y - y1) / (y2 - y1) * (x2 - x1)
            x < xint && (inside = !inside)
        end
    end
    return inside ? :inside : :outside
end

function _rotate_ring_to_min!(ring::Vector{NTuple{2,Float64}})
    i0 = 1
    best = ring[1]
    for i in 2:length(ring)
        p = ring[i]
        if (p[1], p[2]) < (best[1], best[2])
            best = p
            i0 = i
        end
    end
    i0 == 1 || circshift!(ring, 1 - i0)
    return ring
end

# Exterior and islands: counterclockwise. Courtyard holes: clockwise.
# A right-hand normal then points out of the floor, including into a courtyard.
function _canonicalize_outline_loops(loops::Vector{Vector{NTuple{2,Float64}}})
    n = length(loops)
    depth = zeros(Int, n)
    # A vertex is inside another loop, or it is not. The shoelace centroid is
    # the wrong probe: the centroid of an exterior ring falls inside a courtyard.
    for i in 1:n
        for j in 1:n
            i == j && continue
            inside = false
            outside = false
            for (x, y) in loops[i]
                hit = _ring_location(x, y, loops[j])
                hit == :inside && (inside = true)
                hit == :outside && (outside = true)
            end
            inside && !outside && (depth[i] += 1)
        end
    end
    for i in 1:n
        want_ccw = iseven(depth[i])
        if want_ccw != (_ring_signed_area(loops[i]) > 0)
            reverse!(loops[i])
        end
        _rotate_ring_to_min!(loops[i])
    end
    order = sortperm(loops, by = ring -> (ring[1][1], ring[1][2], -_ring_signed_area(ring)))
    return loops[order]
end

"""
    effective_seismic_weight(cell) -> Quantity

Effective seismic weight `W` contribution of one `Cell` [force, `kN`], per
**ASCE/SEI 7-22 §12.7.2 "Effective Seismic Weight"** (corpus: `asce-7-22`,
PDF page 184 = printed p. 123).

§12.7.2 verbatim: *"The effective seismic weight, W, of a structure shall include
the dead load above the base and other loads above the base as follows: (1) In
areas used for storage, a minimum of 25% of the floor live load … (2) …
partitions … (3) … permanent equipment … (4) … flat roof snow load … (5) …
landscaping … (6) … fluids …"*

Inclusion rule applied here, from the fields a `Cell` actually carries
(`self_weight`, `sdl`, `area`):

    W_cell = (self_weight + sdl) · area        # dead load above the base

- **Dead load included** (`self_weight` = structural slab self-weight; `sdl` =
  superimposed dead load) — the mandatory first term of §12.7.2.
- **Floor live load EXCLUDED** — §12.7.2 includes live load only in the special
  cases of its Item 1 (storage, 25%) and never for public garages/open parking
  (Exception b). A `Cell` carries no storage/occupancy flag, so the general rule
  (exclude floor live load from `W`) applies.

ENGINEERING JUDGMENT (not readable from a single clause — flagged, not a code
citation): this helper applies ONLY the dead-load core of §12.7.2. It does NOT
inspect `Cell.floor_type` or `Cell.position`, so it does NOT special-case any of
the §12.7.2 "other loads" that depend on occupancy/snow/equipment data the `Cell`
struct does not carry (values below verified against asce-7-22, PDF p. 184):
- Item 1 — storage: minimum 25% of the floor LIVE load (not applied; no storage flag).
- Item 2 — partitions: actual partition weight or min 10 lb/ft² (0.48 kN/m²) of
  floor area, whichever is greater — assumed already folded into `sdl`.
- Item 4 — flat-roof snow: where the flat-roof snow load P_f exceeds 45 lb/ft²
  (2.16 kN/m²), 15% of the uniform design snow load (not applied; no snow data).
- Items 3, 5, 6 — permanent-equipment operating weight, roof-garden/landscaping,
  fluids/bulk material (not applied; no per-area data).
If any such load governs a given floor, the caller MUST augment `sdl` (or this
helper) with the appropriate §12.7.2 fraction before using `W` for seismic mass.
No values are invented here. See NOTES in the change record.
"""
function effective_seismic_weight(cell::Cell)
    # ASCE 7-22 §12.7.2 (asce-7-22, PDF p. 184): dead load above the base.
    dead_pressure = cell.self_weight + cell.sdl     # kN/m^2
    return dead_pressure * cell.area                # kN (force)
end

"""
    story_center_of_mass(skeleton, story, cells) -> (ex::Float64, ey::Float64)

Per-story centre of mass [m], as the seismic-weight-weighted centroid of the
story's floor cells:

    (ex, ey) = Σ(face_centroidᵢ · Wᵢ) / Σ Wᵢ

where `face_centroidᵢ` is the area centroid of cell *i*'s face polygon (read from
`GeometryCache.vertex_coords`, the same datum/frame as `to_wall_line`), and `Wᵢ`
is its effective seismic weight ([`effective_seismic_weight`](@ref), ASCE 7-22
§12.7.2). `cells` is the building's `Cell` vector; cells are matched to the
story's faces by `Cell.face_idx`.

The result shares the frame of `story_plate_geometry` / `WallLine`, so the
eccentricity `(ex, ey) − plate_center` is directly meaningful to the lateral
evaluator. Throws if the story has no faces, if no cell matches any of the
story's faces, or if the total seismic weight is non-positive — fail closed.
"""
function story_center_of_mass(skeleton::BuildingSkeleton, story::Story,
                              cells::AbstractVector{<:Cell})
    _geometry_cache_or_error(skeleton)
    isempty(story.faces) && throw(ArgumentError(
        "story_center_of_mass: story has no faces — empty floor"))

    # `Cell.face_idx` is CONTRACTUALLY UNIQUE per cell: the production builder
    # `initialize_cells!` (analyze/slabs/utils.jl) dedups faces through a
    # `processed_faces` set, so one skeleton face carries at most one load cell.
    # A duplicate `face_idx` in `cells` therefore signals a CORRUPTED cell vector,
    # not a legitimate multi-cell face — fail closed rather than let a comprehension
    # `Dict(c.face_idx => c ...)` SILENTLY drop the earlier cell (which would bias
    # the mass-weighted centroid toward the surviving one).
    cell_by_face = Dict{Int,eltype(cells)}()
    for c in cells
        haskey(cell_by_face, c.face_idx) && throw(ArgumentError(
            "story_center_of_mass: duplicate Cell.face_idx $(c.face_idx) — face_idx must be " *
            "unique per cell (see initialize_cells!); a duplicate would silently drop floor mass"))
        cell_by_face[c.face_idx] = c
    end

    sumW  = 0.0   # Σ Wᵢ  [kN]
    sumWx = 0.0   # Σ Wᵢ·xᵢ
    sumWy = 0.0   # Σ Wᵢ·yᵢ
    n_used = 0
    for f in story.faces
        c = get(cell_by_face, f, nothing)
        c === nothing && continue   # a face with no load cell carries no floor mass
        pts = _face_plan_vertices(skeleton, f)
        cx, cy, _ = _polygon_area_centroid(pts)
        w = ustrip(u"kN", effective_seismic_weight(c))   # bare kN
        sumW  += w
        sumWx += w * cx
        sumWy += w * cy
        n_used += 1
    end

    n_used == 0 && throw(ArgumentError(
        "story_center_of_mass: no Cell matches any of the story's $(length(story.faces)) faces"))
    sumW <= _WALLS_BRIDGE_DEGEN_TOL && throw(ArgumentError(
        "story_center_of_mass: non-positive total effective seismic weight ($(sumW) kN)"))

    return (sumWx / sumW, sumWy / sumW)
end

"""
    assert_story_walls_enclosed!(struc) -> Nothing

Run the plate-enclosure check for every skeleton story that has at least
one building [`Wall`](@ref).

`Wall.story` is 0-based (the same key as `edge_story` / `skeleton.stories`).
[`to_wall_line`](@ref) sets `WallLine.story = Wall.story + 1` because
`WallLine.story` is 1-based; this check does not add 1. Stories with no
walls are skipped. For each story that has walls, calls
[`story_plate_geometry`](@ref) with those walls, which runs
[`assert_walls_enclosed`](@ref) on [`wall_center`](@ref). A wall center
outside the story's floor faces throws `ArgumentError`. A `Wall.story`
that is not a skeleton story key also throws.

Called at the end of [`initialize!`](@ref), after [`initialize_members!`](@ref).
"""
function assert_story_walls_enclosed!(struc::BuildingStructure)
    skel = struc.skeleton
    walls_by_story = Dict{Int, Vector{eltype(struc.walls)}}()
    for w in struc.walls
        haskey(skel.stories, w.story) || throw(ArgumentError(
            "assert_story_walls_enclosed!: Wall.story $(w.story) is not a skeleton " *
            "story key. Wall.story is 0-based; WallLine.story is Wall.story + 1 " *
            "via to_wall_line, and that +1 is not applied here."))
        push!(get!(walls_by_story, w.story, eltype(struc.walls)[]), w)
    end
    for (story_idx, story) in skel.stories
        walls = get(walls_by_story, story_idx, nothing)
        (walls === nothing || isempty(walls)) && continue
        story_plate_geometry(skel, story; walls=walls)
    end
    return nothing
end

"""
    walls_bridge_selfcheck() -> Bool

Self-check for the wall-bridge geometry derivations. Builds a small synthetic
two-cell skeleton with an **off-origin** footprint and **asymmetric** cell mass,
then asserts:

1. `story_plate_geometry` reproduces the true bounding box, with
   `plate_center ≠ (0,0)` (eccentric plate).
2. `story_center_of_mass` matches a hand-computed weight-weighted centroid and
   lands **off** `plate_center`.
3. A degenerate (collinear) footprint throws.

Returns `true` on success; throws `AssertionError` (or a geometry error) on any
failure. Not run at load time; call explicitly from tests or the REPL.
"""
function walls_bridge_selfcheck()
    approx(a, b) = isapprox(a, b; atol = 1e-9, rtol = 1e-9)

    # --- synthetic skeleton: two unit-height rectangles sharing edge 2–3 ------
    # Vertices (x, y, z):  off-origin footprint x∈[2,10], y∈[0,4].
    #   1:(2,0) 2:(6,0) 3:(6,4) 4:(2,4) 5:(10,0) 6:(10,4)
    # Face 1 (cell A): [1,2,3,4] → x∈[2,6], centroid (4,2), area 16 m².
    # Face 2 (cell B): [2,5,6,3] → x∈[6,10], centroid (8,2), area 16 m².
    skel = BuildingSkeleton{Float64}()
    skel.face_vertex_indices = [[1, 2, 3, 4], [2, 5, 6, 3]]
    vc = [2.0 0.0 0.0;
          6.0 0.0 0.0;
          6.0 4.0 0.0;
          2.0 4.0 0.0;
          10.0 0.0 0.0;
          10.0 4.0 0.0]
    skel.geometry = GeometryCache(vc,
                                  Vector{typeof(1.0u"m")}(),
                                  Vector{typeof(1.0u"m^2")}(),
                                  Dict{Int,Int}(), Dict{Int,Int}())
    story = Story{Float64}(0.0)
    story.faces = [1, 2]

    # --- (1) plate geometry ---------------------------------------------------
    (pc, hw) = story_plate_geometry(skel, story)
    @assert approx(pc[1], 6.0) && approx(pc[2], 2.0) "plate_center expected (6,2), got $pc"
    @assert approx(hw[1], 4.0) && approx(hw[2], 2.0) "plan_halfwidth expected (4,2), got $hw"
    @assert !(approx(pc[1], 0.0) && approx(pc[2], 0.0)) "plate_center must be off-origin"

    # --- (2) centre of mass (asymmetric) -------------------------------------
    # Dead loads via sdl (self_weight left 0): A = 5 kN/m², B = 1 kN/m².
    #   W_A = 5·16 = 80 kN at (4,2);  W_B = 1·16 = 16 kN at (8,2)
    #   ex = (80·4 + 16·8)/96 = 448/96 = 4.666…,  ey = 2
    spans = SpanInfo{Float64}(1.0, 1.0, (1.0, 0.0), 1.0)
    cellA = Cell(1, 16.0u"m^2", spans, 5.0u"kN/m^2", 3.0u"kN/m^2")
    cellB = Cell(2, 16.0u"m^2", spans, 1.0u"kN/m^2", 3.0u"kN/m^2")
    @assert approx(ustrip(u"kN", effective_seismic_weight(cellA)), 80.0) "W_A expected 80 kN"
    @assert approx(ustrip(u"kN", effective_seismic_weight(cellB)), 16.0) "W_B expected 16 kN"

    (ex, ey) = story_center_of_mass(skel, story, [cellA, cellB])
    @assert approx(ex, 448.0 / 96.0) "CoM ex expected $(448/96), got $ex"
    @assert approx(ey, 2.0) "CoM ey expected 2, got $ey"
    @assert !approx(ex, pc[1]) "CoM must be eccentric to plate_center in x"

    # --- (3) degenerate footprint throws -------------------------------------
    degen = BuildingSkeleton{Float64}()
    degen.face_vertex_indices = [[1, 2, 3]]
    degen.geometry = GeometryCache([0.0 0.0 0.0; 1.0 0.0 0.0; 2.0 0.0 0.0],
                                   Vector{typeof(1.0u"m")}(),
                                   Vector{typeof(1.0u"m^2")}(),
                                   Dict{Int,Int}(), Dict{Int,Int}())
    dstory = Story{Float64}(0.0)
    dstory.faces = [1]
    threw = false
    try
        story_plate_geometry(degen, dstory)
    catch
        threw = true
    end
    @assert threw "degenerate (collinear) footprint must throw"

    return true
end
