"""
    wind_minimum_horizontal_force(projected_wall_area, projected_roof_area; system) -> Float64

§27.1.5 horizontal force. `system` is `:kN_m2` (0.77 kN/m² on the wall
projection and 0.38 kN/m² on the roof projection) or `:psf` (16 lb/ft² and
8 lb/ft²). Areas are in the matching area unit. The force is in kN or lb.

This is a separate load case from the Figure 27.3-8 cases. Wall and roof
terms are added, as the clause requires them to act together.

# Citation
ASCE 7-22 §27.1.5 (corpus: asce-7-22, PDF page 342). Commentary C27.1.5
and Figure C27.1-1 (corpus: asce-7-22, PDF pages 956–957): the load is
applied horizontally on the vertical projection, in addition to the
Chapter 27 cases.
"""
function wind_minimum_horizontal_force(projected_wall_area, projected_roof_area; system)
    wall = _as_finite("projected_wall_area", projected_wall_area)
    roof = _as_finite("projected_roof_area", projected_roof_area)
    wall >= 0 || throw(ArgumentError("projected wall area must be >= 0; got $wall"))
    roof >= 0 || throw(ArgumentError("projected roof area must be >= 0; got $roof"))
    if system === :kN_m2
        # §27.1.5 printed SI values (corpus: asce-7-22, PDF page 342).
        p_wall = 0.77
        p_roof = 0.38
    elseif system === :psf
        # §27.1.5 printed customary values (corpus: asce-7-22, PDF page 342).
        p_wall = 16.0
        p_roof = 8.0
    else
        throw(ArgumentError("system must be :kN_m2 or :psf; got $(repr(system))"))
    end
    return p_wall * wall + p_roof * roof
end

"""
    wind_minimum_resultant(wall_area, roof_area, direction, centroid, geometric_center; system)

§27.1.5 force along `direction`, acting through `geometric_center`. The
returned `Mz` is that force's moment about `centroid`. No 0.15 B
eccentricity is added: this is not a Figure 27.3-8 case.
"""
function wind_minimum_resultant(wall_area, roof_area, direction, centroid, geometric_center; system)
    F = wind_minimum_horizontal_force(wall_area, roof_area; system)
    d = _unit_direction(direction)
    Fx = F * d[1]
    Fy = F * d[2]
    cx = _as_finite("cx", centroid[1])
    cy = _as_finite("cy", centroid[2])
    gx = _as_finite("gx", geometric_center[1])
    gy = _as_finite("gy", geometric_center[2])
    Mz = (gx - cx) * Fy - (gy - cy) * Fx
    return (; Fx, Fy, Mz)
end

# -----------------------------------------------------------------------------
# Geometry and input checks. Not code factors.
# -----------------------------------------------------------------------------

function _wind_pressure_inputs(; qz, qh, Kd, G, GCpi, qi, height)
    qz = _as_finite("qz", qz)
    qh = _as_finite("qh", qh)
    Kd = _as_finite("Kd", Kd)
    G = _as_finite("G", G)
    GCpi = _as_finite("GCpi", GCpi)
    height = _as_finite("height", height)
    qz >= 0 || throw(ArgumentError("qz must be >= 0; got $qz"))
    qh >= 0 || throw(ArgumentError("qh must be >= 0; got $qh"))
    height > 0 || throw(ArgumentError("height must be > 0; got $height"))
    # §27.3.1 (corpus: asce-7-22, PDF page 343): qi = qh for enclosed and
    # partially open buildings, and for negative internal pressure in a
    # partially enclosed building. The caller passes qi when it is not qh.
    qi_v = qi === nothing ? qh : _as_finite("qi", qi)
    qi_v >= 0 || throw(ArgumentError("qi must be >= 0; got $qi_v"))
    return (; qz, qh, Kd, G, GCpi, qi=qi_v, height)
end

"""
    wind_unit_direction(direction) -> NTuple{2, Float64}

Plan direction as a unit vector. A zero vector throws. This does not check
that two directions are principal axes.
"""
wind_unit_direction(direction) = _unit_direction(direction)

function _unit_direction(direction)
    dx = _as_finite("direction_x", direction[1])
    dy = _as_finite("direction_y", direction[2])
    nrm = hypot(dx, dy)
    nrm > 0 || throw(ArgumentError("direction must be nonzero; got $direction"))
    return (dx / nrm, dy / nrm)
end

function _wind_as_rings(loops)
    isempty(loops) && throw(ArgumentError("wind_wall_resultant: no floor outline"))
    if first(loops) isa Tuple
        return Any[loops]
    end
    return loops
end

function _wind_ring_points(raw)
    pts = NTuple{2, Float64}[]
    for p in raw
        x = _as_finite("x", p[1])
        y = _as_finite("y", p[2])
        push!(pts, (x, y))
    end
    if length(pts) >= 2
        span = 0.0
        x1, y1 = pts[1]
        for (x, y) in pts
            span = max(span, hypot(x - x1, y - y1))
        end
        x2, y2 = pts[end]
        # A repeated closing vertex is not an extra edge. Geometry only.
        if hypot(x2 - x1, y2 - y1) <= 1e-12 * (1.0 + span)
            pop!(pts)
        end
    end
    length(pts) >= 3 || throw(ArgumentError(
        "wind_wall_resultant: a ring needs at least 3 vertices; got $(length(pts))"))
    return pts
end

function _ring_area_centroid(pts)
    twice = 0.0
    sx = 0.0
    sy = 0.0
    n = length(pts)
    for i in 1:n
        x1, y1 = pts[i]
        x2, y2 = pts[mod1(i + 1, n)]
        cross = x1 * y2 - x2 * y1
        twice += cross
        sx += (x1 + x2) * cross
        sy += (y1 + y2) * cross
    end
    area = 0.5 * twice
    span = 0.0
    x0, y0 = pts[1]
    for (x, y) in pts
        span = max(span, hypot(x - x0, y - y0))
    end
    # Collinear vertices have no floor. Geometry, not a code factor.
    if !isfinite(area) || abs(area) <= 1e-12 * max(span * span, 1.0)
        throw(ArgumentError("wind_wall_resultant: a ring has zero area"))
    end
    return area, (sx / (3.0 * twice), sy / (3.0 * twice))
end

function _wind_prepare_loops(loops)
    prepared = [_wind_ring_points(ring) for ring in _wind_as_rings(loops)]
    areas = Float64[]
    centroids = NTuple{2, Float64}[]
    for pts in prepared
        area, c = _ring_area_centroid(pts)
        push!(areas, area)
        push!(centroids, c)
    end
    exterior = findall(a -> a > 0, areas)
    if length(exterior) != 1
        throw(ArgumentError(
            length(exterior) == 0 ?
            "wind_wall_resultant: no exterior loop (positive signed area)" :
            "wind_wall_resultant: $(length(exterior)) exterior loops; L and B need exactly one"))
    end
    return prepared, areas, centroids, exterior[1]
end

"""Center and extents of `pts` in axes aligned with the unit wind `d`."""
function _projected_center(pts, d)
    dx, dy = d
    # Perpendicular, same construction as projected_plan_width: (-dy, dx).
    tx, ty = -dy, dx
    a_lo = Inf
    a_hi = -Inf
    s_lo = Inf
    s_hi = -Inf
    for (x, y) in pts
        a = dx * x + dy * y
        s = tx * x + ty * y
        a_lo = min(a_lo, a)
        a_hi = max(a_hi, a)
        s_lo = min(s_lo, s)
        s_hi = max(s_hi, s)
    end
    a_mid = 0.5 * (a_lo + a_hi)
    s_mid = 0.5 * (s_lo + s_hi)
    return (a_mid * dx + s_mid * tx, a_mid * dy + s_mid * ty), a_hi - a_lo, s_hi - s_lo
end

function _same_floor(r1::WindWallResultant, r2::WindWallResultant)
    # Cases 3 and 4 add two resultants of one floor. Both are computed from
    # the same rings, so equal geometry is exact equality, not a tolerance.
    r1.rings == r2.rings || throw(ArgumentError(
        "wind_cases_from_resultants: the two resultants are not the same floor outline"))
    return nothing
end
