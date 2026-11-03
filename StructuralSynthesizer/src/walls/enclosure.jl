
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
    assert_walls_on_floor!(skeleton, story, walls) -> Nothing

Fail closed unless every wall center lies in one of `story`'s floor faces.

On a face edge counts as inside: the tolerance is `1e-9` plus `1e-9` of the
floor's plan diagonal, the same scale as [`assert_walls_enclosed`](@ref).
A center in the axis-aligned bounding box but in a notch, or past a rotated
edge, throws. An empty `walls` passes.
"""
function assert_walls_on_floor!(skeleton::BuildingSkeleton, story::Story, walls)
    isempty(walls) && return nothing
    isempty(story.faces) && throw(ArgumentError(
        "assert_walls_on_floor!: the story has walls and no floor faces."))
    polys = [_face_plan_vertices(skeleton, f) for f in story.faces]
    minx = minimum(p[1] for poly in polys for p in poly)
    maxx = maximum(p[1] for poly in polys for p in poly)
    miny = minimum(p[2] for poly in polys for p in poly)
    maxy = maximum(p[2] for poly in polys for p in poly)
    tol = 1e-9 + 1e-9 * hypot(maxx - minx, maxy - miny)
    for w in walls
        wx, wy = _wall_plan_center(w)
        enclosed = any(poly -> _point_on_polygon(poly, wx, wy, tol), polys)
        enclosed || throw(ArgumentError(
            "assert_walls_on_floor!: wall plan center ($(wx), $(wy)) m lies OUTSIDE " *
            "every floor face of this story. The drift plate is the bounding box; " *
            "this check is the floor itself."))
    end
    return nothing
end

"""Inside `poly`, or within `tol` of an edge. `poly` is an open ring."""
function _point_on_polygon(poly, x, y, tol)
    n = length(poly)
    n < 3 && return false
    for i in 1:n
        _segment_distance(x, y, poly[i], poly[mod1(i + 1, n)]) <= tol && return true
    end
    return _polygon_winding(poly, x, y) != 0
end

function _segment_distance(x, y, a, b)
    dx = b[1] - a[1]
    dy = b[2] - a[2]
    len2 = dx * dx + dy * dy
    len2 <= 0 && return hypot(x - a[1], y - a[2])
    t = clamp(((x - a[1]) * dx + (y - a[2]) * dy) / len2, 0.0, 1.0)
    return hypot(x - (a[1] + t * dx), y - (a[2] + t * dy))
end

"""Winding number of an open ring about `(x, y)`."""
function _polygon_winding(poly, x, y)
    w = 0
    n = length(poly)
    @inbounds for i in 1:n
        x1, y1 = poly[i]
        x2, y2 = poly[mod1(i + 1, n)]
        if y1 <= y
            if y2 > y && (x2 - x1) * (y - y1) > (x - x1) * (y2 - y1)
                w += 1
            end
        elseif y2 <= y && (x2 - x1) * (y - y1) < (x - x1) * (y2 - y1)
            w -= 1
        end
    end
    return w
end
