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
