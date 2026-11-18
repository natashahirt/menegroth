
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

"""A hole loop lies on `poly` when every vertex is inside it or on its boundary."""
function _loop_inside_face(loop, poly)
    for p in loop
        _point_in_polygon_xy(p[1], p[2], poly) && continue
        _point_on_polygon_boundary(p[1], p[2], poly; tol = 1e-6) && continue
        return false
    end
    return true
end

"""
Area centroid of a face, with openings and beam rings taken out.

A hole that is not contained in the face is left in place: its outline is
not this face's void.
"""
function _net_face_centroid(skeleton::BuildingSkeleton, face::Int)
    pts = _face_plan_vertices(skeleton, face)
    cx, cy, area = _polygon_area_centroid(pts)
    numx = cx * area
    numy = cy * area
    net = area
    for h in face_opening_loops(skeleton, face)
        _loop_inside_face(h, pts) || continue
        hx, hy, ha = _polygon_area_centroid(h)
        numx -= hx * ha
        numy -= hy * ha
        net -= ha
    end
    net <= _WALLS_BRIDGE_DEGEN_TOL && return (cx, cy)
    return (numx / net, numy / net)
end

"""
    story_center_of_mass(skeleton, story, cells) -> (ex::Float64, ey::Float64)

Per-story centre of mass [m], as the seismic-weight-weighted centroid of the
story's floor cells:

    (ex, ey) = Σ(face_centroidᵢ · Wᵢ) / Σ Wᵢ

where `face_centroidᵢ` is the area centroid of cell *i*'s face, net of the
openings and beam rings on that face (read from `GeometryCache.vertex_coords`,
the same datum/frame as `to_wall_line`), and `Wᵢ` is its effective seismic
weight ([`effective_seismic_weight`](@ref), ASCE 7-22 §12.7.2). `cells` is the
building's `Cell` vector; cells are matched to the story's faces by `Cell.face_idx`.

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
        cx, cy = _net_face_centroid(skeleton, f)
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
