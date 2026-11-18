"""Resultant of Chapter 27 wall pressures on one floor outline."""
struct WindWallResultant
    "Force in global X, caller's force unit."
    Fx::Float64
    "Force in global Y, caller's force unit."
    Fy::Float64
    "Moment about the exterior-loop centroid. +Z is right-hand."
    Mz::Float64
    "Projected depth of the exterior loop along the wind."
    L::Float64
    "Projected width of the exterior loop perpendicular to the wind."
    B::Float64
    L_over_B::Float64
    Cp_leeward::Float64
    centroid::NTuple{2, Float64}
    "Center of the exterior loop's projection, in wind-aligned axes."
    geometric_center::NTuple{2, Float64}
    "Σ p·A over every edge, including internal pressure."
    sum_pA::Float64
    "Unit vector the wind blows toward."
    direction::NTuple{2, Float64}
    "The floor rings this resultant was computed on, after the closing vertex is dropped."
    rings::Vector{Vector{NTuple{2, Float64}}}
    "§26.11 terms for Eq. 27.3-4, or `nothing` for the rigid 0.15 B eccentricity."
    gust::Union{Nothing, NamedTuple}
end

"""
One Figure 27.3-8 case for a single floor.

`Mz` is about the exterior-loop centroid. `:case1` and `:case2` set
`direction_2` to `nothing`. `:case3` and `:case4` carry both directions.
`sign_1` and `sign_2` are 0 when that direction has no eccentricity, and
±1 when it does.
"""
struct WindMWFRSCase
    kind::Symbol
    direction::NTuple{2, Float64}
    direction_2::Union{Nothing, NTuple{2, Float64}}
    sign_1::Int
    sign_2::Int
    Fx::Float64
    Fy::Float64
    Mz::Float64
end

"""
    wind_wall_resultant(loops, direction; qz, qh, Kd, G, GCpi, height=1, qi=nothing, flexible=false)

Edge pressures on one floor, and their resultant.

`loops` is one open ring, or a vector of open rings. The last vertex is
connected to the first. A repeated closing vertex is dropped. Exactly one
loop may have positive signed area; that loop is the exterior and supplies
L, B, and the centroid. A clockwise loop is a courtyard hole and is loaded
too. Two exterior loops throw. A zero-area ring throws.

The outward normal of an edge (x1, y1) → (x2, y2) is (dy, −dx), normalized.
n·direction < 0 is windward (qz), n·direction > 0 is leeward (qh and the
story's one leeward Cp), and a parallel edge is a side wall (qh).

Positive pressure acts toward the surface, so the force on the floor is
−p·A·n. A positive windward pressure pushes the floor downwind.

`qi` defaults to `qh`: enclosed buildings, partially open buildings, and
negative internal pressure in partially enclosed buildings. Pass `qi` for
positive internal pressure in a partially enclosed building. `flexible=true`
uses Eq. 27.3-4. `gust` then holds `eR`, `Iz`, `gQ`, `Q`, `gR`, and `R`.

# Citation
ASCE 7-22 Eq. 27.3-1 (corpus: asce-7-22, PDF page 342); qi = qh for
enclosed and partially open buildings (PDF page 343); Figure 27.3-1
(PDF page 345); Figure 27.3-8 Note 3 permits omitting sidewalls at a rigid
diaphragm and this resultant still includes them.
"""
function wind_wall_resultant(loops, direction;
                             qz, qh, Kd, G, GCpi,
                             height=1.0, qi=nothing, flexible::Bool=false,
                             gust=nothing)
    if flexible
        gust = _require_wind_gust(gust)
    else
        gust = nothing
    end
    inputs = _wind_pressure_inputs(; qz, qh, Kd, G, GCpi, qi, height)
    rings, _, centroids, iexterior = _wind_prepare_loops(loops)
    d = _unit_direction(direction)
    center, L, B = _projected_center(rings[iexterior], d)
    L > 0 || throw(ArgumentError("along-wind depth L must be > 0; got $L"))
    B > 0 || throw(ArgumentError("across-wind width B must be > 0; got $B"))
    ratio = L / B
    Cp_lee = wind_wall_cp(ratio, :leeward)
    cx, cy = centroids[iexterior]

    pressures = Float64[]
    for pts in rings
        n = length(pts)
        for i in 1:n
            x1, y1 = pts[i]
            x2, y2 = pts[mod1(i + 1, n)]
            dx = x2 - x1
            dy = y2 - y1
            len = hypot(dx, dy)
            len > 0 || throw(ArgumentError(
                "wind_wall_resultant: an edge has zero length"))
            # Right-hand normal of the directed edge. Exterior rings are
            # counterclockwise, so this points out of the floor. A clockwise
            # hole points into the courtyard.
            nx = dy / len
            ny = -dx / len
            surface = _wind_class(nx, ny, d)
            Cp = wind_wall_cp(ratio, surface)
            # Figure 27.3-1 (corpus: asce-7-22, PDF page 345): windward
            # walls use qz. Leeward walls and sidewalls use qh.
            q = surface === :windward ? inputs.qz : inputs.qh
            p = wind_design_pressure(; q, qi=inputs.qi, Kd=inputs.Kd,
                G=inputs.G, Cp, GCpi=inputs.GCpi)
            push!(pressures, p)
        end
    end
    Fx, Fy, Mz, sum_pA = _wind_accumulate_pressures(
        rings, pressures, inputs.height, (cx, cy))
    return WindWallResultant(Fx, Fy, Mz, L, B, ratio, Cp_lee, (cx, cy),
        center, sum_pA, d, [copy(r) for r in rings], gust)
end

"The §26.11 quantities Eq. 27.3-4 names, each finite."
function _require_wind_gust(gust)
    gust === nothing && throw(ArgumentError(
        "flexible buildings use ASCE 7-22 Eq. 27.3-4 (corpus: asce-7-22, " *
        "PDF page 353). Pass gust with eR, Iz, gQ, Q, gR, and R from §26.11."))
    out = NamedTuple()
    for key in (:eR, :Iz, :gQ, :Q, :gR, :R)
        haskey(gust, key) || throw(ArgumentError(
            "Eq. 27.3-4 gust is missing $key (corpus: asce-7-22, PDF page 353)."))
        out = merge(out, NamedTuple{(key,)}((_as_finite(string(key), gust[key]),)))
    end
    return out
end

"""
One edge of a floor outline, in the order [`wind_facade_edges`](@ref) walks it.

`outward_normal` is the right-hand normal of the directed edge. `cosine` is
`n·direction` when a wind direction was supplied, and `nothing` otherwise.
`pressure` starts at zero. Chapter 27 fills pressures through
[`wind_wall_resultant`](@ref). A later field, including a CFD pressure on
these edges or on a finer set of surfaces with the same normal and area,
replaces `pressure` and calls [`wind_forces_from_pressures`](@ref). The
cosine is not a code coefficient.
"""
struct WindFacadeEdge
    x1::Float64
    y1::Float64
    x2::Float64
    y2::Float64
    length::Float64
    outward_normal::NTuple{2, Float64}
    cosine::Union{Nothing, Float64}
    pressure::Float64
end

"""
    wind_facade_edges(loops; direction=nothing) -> Vector{WindFacadeEdge}

The discrete facade surfaces of one floor outline. Rings are walked in the
order given. Each ring is closed by connecting the last vertex to the first.
A repeated closing vertex is dropped.

Pass `direction` (the direction the wind blows toward) to store `n·direction`
on each edge. Omit it when the pressure source does not use a wind vector.
"""
function wind_facade_edges(loops; direction=nothing)
    rings, _, _, _ = _wind_prepare_loops(loops)
    d = direction === nothing ? nothing : _unit_direction(direction)
    edges = WindFacadeEdge[]
    for pts in rings
        n = length(pts)
        for i in 1:n
            x1, y1 = pts[i]
            x2, y2 = pts[mod1(i + 1, n)]
            dx = x2 - x1
            dy = y2 - y1
            len = hypot(dx, dy)
            len > 0 || throw(ArgumentError(
                "wind_facade_edges: an edge has zero length"))
            nx = dy / len
            ny = -dx / len
            cosine = d === nothing ? nothing : nx * d[1] + ny * d[2]
            push!(edges, WindFacadeEdge(x1, y1, x2, y2, len, (nx, ny), cosine, 0.0))
        end
    end
    return edges
end

"""
    wind_forces_from_pressures(loops, pressures; height=1) -> NamedTuple

Story force from one pressure per facade edge. `pressures` follows
[`wind_facade_edges`](@ref): each ring in order, each edge from vertex `i`
to the next, positive pressure toward the surface. The force on the floor
is `−p·A·n`, and the moment is about the exterior-loop centroid.

This function does not look up Figure 27.3-1 and does not apply `Kd`, `G`,
or `(GCpi)`. The caller has already put those into `pressures`, or has
supplied a pressure from another source.
"""
function wind_forces_from_pressures(loops, pressures; height=1.0)
    rings, _, centroids, iexterior = _wind_prepare_loops(loops)
    h = _as_finite("height", height)
    h > 0 || throw(ArgumentError("height must be > 0; got $h"))
    p = Float64[_as_finite("pressure", v) for v in pressures]
    nedge = sum(length(ring) for ring in rings)
    length(p) == nedge || throw(ArgumentError(
        "wind_forces_from_pressures: $(length(p)) pressures for $nedge edges"))
    Fx, Fy, Mz, _ = _wind_accumulate_pressures(rings, p, h, centroids[iexterior])
    return (Fx=Fx, Fy=Fy, Mz=Mz, centroid=centroids[iexterior])
end

function _wind_accumulate_pressures(rings, pressures, height, centroid)
    cx, cy = centroid
    Fx = 0.0
    Fy = 0.0
    Mz = 0.0
    sum_pA = 0.0
    k = 0
    for pts in rings
        n = length(pts)
        for i in 1:n
            k += 1
            x1, y1 = pts[i]
            x2, y2 = pts[mod1(i + 1, n)]
            dx = x2 - x1
            dy = y2 - y1
            len = hypot(dx, dy)
            len > 0 || throw(ArgumentError(
                "wind_forces_from_pressures: an edge has zero length"))
            nx = dy / len
            ny = -dx / len
            p = pressures[k]
            A = len * height
            # Positive p is toward the surface (Figure 27.3-1 Note 1,
            # corpus: asce-7-22, PDF page 345), so the force on the floor
            # is −p·A·n. The same assembly is used for a caller-supplied pressure.
            fx = -p * A * nx
            fy = -p * A * ny
            mx = 0.5 * (x1 + x2)
            my = 0.5 * (y1 + y2)
            Fx += fx
            Fy += fy
            Mz += (mx - cx) * fy - (my - cy) * fx
            sum_pA += p * A
        end
    end
    return Fx, Fy, Mz, sum_pA
end

