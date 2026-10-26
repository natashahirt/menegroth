# =============================================================================
# Directional Procedure MWFRS wind (ASCE 7-22 Chapter 27)
# =============================================================================
#
# Pure demand. Velocity pressure, Kd, G, and (GCpi) are caller inputs.
# Nothing here computes a wind speed, and nothing here is Chapter 26.
#
# `direction` is the horizontal direction the wind blows toward. It need not
# be a unit vector. Wind coming from +X is direction (-1, 0).
#
# Units
#   One consistent unit system. Pressure × length² is force. Force × length
#   is moment. `wind_minimum_horizontal_force` is the exception: its
#   pressures are the printed §27.1.5 values, selected by `system`.
#
# Not implemented, and not to be inferred here:
#   Chapter 26 velocity pressure, open-building CN (Eq. 27.3-2), roof Cp,
#   parapets (Eq. 27.3-3), the flexible-building eccentricity (Eq. 27.3-4).
# =============================================================================

"""
|n̂ · d̂| at or below this value means the edge is parallel to the wind and
is a side wall.

Geometry, not an ASCE 7 factor. An edge at 45° to the wind has
|n̂ · d̂| = √2/2 and is not a side wall.
"""
const WIND_EDGE_PARALLEL_COS = 1e-8

"""
    wind_figure_2731_roof(roof::Symbol) -> Symbol

`roof` must be a roof drawn in Figure 27.3-1: `:flat`, `:gable`, `:hip`,
`:monoslope`, or `:mansard`. Any other roof throws. This slice does not
invent a roof Cp.

# Citation
ASCE 7-22 Table 27.2-1 Step 6 and Figure 27.3-1 (corpus: asce-7-22,
PDF pages 343 and 344).
"""
function wind_figure_2731_roof(roof::Symbol)
    if roof === :flat || roof === :gable || roof === :hip ||
       roof === :monoslope || roof === :mansard
        return roof
    end
    throw(ArgumentError(
        "roof $(repr(roof)) is not in Figure 27.3-1 " *
        "(flat, gable, hip, monoslope, mansard). No roof Cp is invented."))
end

"""
    wind_wall_cp(L_over_B, surface) -> Float64

External pressure coefficient Cp for an MWFRS wall.

`surface` is `:windward`, `:leeward`, or `:side`. `L_over_B` is the story's
along-wind depth divided by its across-wind width. It must be > 0.

Windward Cp is 0.8 for every L/B. Sidewall Cp is -0.7 for every L/B.
Leeward Cp is -0.5 for L/B ≤ 1, -0.3 at L/B = 2, and -0.2 for L/B ≥ 4.
Note 2 permits linear interpolation between those leeward values. They are
all the same sign. The "0–1" row is the constant -0.5, not a ramp from 0.

# Citation
ASCE 7-22 Figure 27.3-1 wall table and Note 2 (corpus: asce-7-22, PDF page 345).
"""
function wind_wall_cp(L_over_B, surface::Symbol)
    ratio = _as_finite("L/B", L_over_B)
    ratio > 0 || throw(ArgumentError("L/B must be > 0; got $ratio"))
    if surface === :windward
        # Figure 27.3-1, windward wall, all L/B, use with qz
        # (corpus: asce-7-22, PDF page 345).
        return 0.8
    elseif surface === :side
        # Figure 27.3-1, sidewall, all L/B, use with qh
        # (corpus: asce-7-22, PDF page 345).
        return -0.7
    elseif surface === :leeward
        return _leeward_wall_cp(ratio)
    end
    throw(ArgumentError(
        "surface must be :windward, :leeward, or :side; got $(repr(surface))"))
end

function _leeward_wall_cp(ratio::Float64)
    # Figure 27.3-1 leeward wall, use with qh (corpus: asce-7-22, PDF page 345):
    #   L/B = 0 to 1 → -0.5
    #   L/B = 2     → -0.3
    #   L/B ≥ 4     → -0.2
    # Note 2 (same page): linear interpolation is permitted for L/B other
    # than shown, and only between values of the same sign. Every leeward
    # entry is negative.
    if ratio <= 1
        return -0.5
    elseif ratio <= 2
        return -0.5 + (ratio - 1) / (2 - 1) * (-0.3 - (-0.5))
    elseif ratio < 4
        return -0.3 + (ratio - 2) / (4 - 2) * (-0.2 - (-0.3))
    else
        return -0.2
    end
end

"""
    wind_design_pressure(; q, qi, Kd, G, Cp, GCpi) -> Float64

Design wind pressure on one surface, Eq. 27.3-1.

`p = q·Kd·G·Cp − qi·Kd·(GCpi)`. Kd is applied once, here. `q` and `qi` are
already velocity pressures. A negative velocity pressure throws.

# Citation
ASCE 7-22 §27.3.1, Eq. 27.3-1 (corpus: asce-7-22, PDF page 342).
"""
function wind_design_pressure(; q, qi, Kd, G, Cp, GCpi)
    q = _as_finite("q", q)
    qi = _as_finite("qi", qi)
    Kd = _as_finite("Kd", Kd)
    G = _as_finite("G", G)
    Cp = _as_finite("Cp", Cp)
    GCpi = _as_finite("GCpi", GCpi)
    q >= 0 || throw(ArgumentError("q must be >= 0; got $q"))
    qi >= 0 || throw(ArgumentError("qi must be >= 0; got $qi"))
    # ASCE 7-22 Eq. 27.3-1 (corpus: asce-7-22, PDF page 342).
    return q * Kd * G * Cp - qi * Kd * GCpi
end

"""
    wind_surface(outward_normal, direction) -> Symbol

`:windward` when n·direction < 0, `:leeward` when n·direction > 0, and
`:side` when the edge is parallel to the wind.

Both vectors are normalized inside. The parallel test is
[`WIND_EDGE_PARALLEL_COS`](@ref), which is geometry, not a code factor.
`direction` is the direction the wind blows toward.
"""
function wind_surface(outward_normal, direction)
    d = _unit_direction(direction)
    nx = _as_finite("nx", outward_normal[1])
    ny = _as_finite("ny", outward_normal[2])
    nrm = hypot(nx, ny)
    nrm > 0 || throw(ArgumentError("outward normal must be nonzero"))
    return _wind_class(nx / nrm, ny / nrm, d)
end

function _wind_class(nx, ny, d)
    nd = nx * d[1] + ny * d[2]
    if abs(nd) <= WIND_EDGE_PARALLEL_COS
        return :side
    elseif nd < 0
        return :windward
    else
        return :leeward
    end
end

"""
    wind_rigid_eccentricity(B) -> Float64

Magnitude of the rigid-building eccentricity, `0.15 B`.

`B` is the horizontal dimension normal to the wind. The figure's e is
± this value. The sign is the caller's. Flexible buildings are not this
function; Eq. 27.3-4 throws at [`wind_wall_resultant`](@ref).

# Citation
ASCE 7-22 Figure 27.3-8, e = ±0.15 B (corpus: asce-7-22, PDF page 352).
Commentary C27.3.5 (corpus: asce-7-22, PDF page 959): the reduced wind
shear acts at 15% eccentricity. §27.3.5 (PDF page 353): e is measured
from the geometric center and both signs are considered.
"""
function wind_rigid_eccentricity(B)
    B = _as_finite("B", B)
    B > 0 || throw(ArgumentError("B must be > 0; got $B"))
    # Figure 27.3-8 (corpus: asce-7-22, PDF page 352): e = ±0.15 B.
    return 0.15 * B
end

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
throws.

# Citation
ASCE 7-22 Eq. 27.3-1 (corpus: asce-7-22, PDF page 342); qi = qh for
enclosed and partially open buildings (PDF page 343); Figure 27.3-1
(PDF page 345); Figure 27.3-8 Note 3 permits omitting sidewalls at a rigid
diaphragm and this resultant still includes them.
"""
function wind_wall_resultant(loops, direction;
                             qz, qh, Kd, G, GCpi,
                             height=1.0, qi=nothing, flexible::Bool=false)
    if flexible
        throw(ArgumentError(
            "flexible buildings are outside this slice. ASCE 7-22 Eq. 27.3-4 " *
            "is not implemented (corpus: asce-7-22, PDF page 353)."))
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
        center, sum_pA, d, [copy(r) for r in rings])
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

"""
    wind_principal_directions(direction_1, direction_2; perpendicular=true) -> (d1, d2)

The two wind directions for Figure 27.3-8, as unit vectors. By default they
must be perpendicular: the figure loads "each principal axis of the
structure," and Cases 3 and 4 add one 75% wind on each. Two copies of one
direction, or opposite directions, always throw. A pair that is not
perpendicular throws unless `perpendicular` is false.

`perpendicular=false` is an explicit override. Cases 3 and 4 are still built
from the two directions. The figure defines that combination for principal
axes, so using it on a skewed pair is the caller's choice.

The perpendicular and parallel tests use [`WIND_EDGE_PARALLEL_COS`](@ref),
which is geometry, not a code factor.

# Citation
ASCE 7-22 Figure 27.3-8 Case 1 and Case 3 (corpus: asce-7-22, PDF page 352).
"""
function wind_principal_directions(direction_1, direction_2; perpendicular::Bool=true)
    d1 = _unit_direction(direction_1)
    d2 = _unit_direction(direction_2)
    c = d1[1] * d2[1] + d1[2] * d2[2]
    if abs(c) >= 1 - WIND_EDGE_PARALLEL_COS
        throw(ArgumentError(
            "the two wind directions must be distinct axes, not the same or " *
            "opposite direction (Figure 27.3-8, corpus: asce-7-22, PDF page 352); " *
            "got $direction_1 and $direction_2, cos = $c"))
    end
    if perpendicular && abs(c) > WIND_EDGE_PARALLEL_COS
        throw(ArgumentError(
            "the two wind directions must be perpendicular principal axes " *
            "(Figure 27.3-8, corpus: asce-7-22, PDF page 352); got $direction_1 " *
            "and $direction_2, cos = $c. Pass perpendicular=false to use a skewed pair."))
    end
    return d1, d2
end

"""
    wind_direction_cases(resultant) -> Vector{WindMWFRSCase}

Case 1 and both signs of Case 2 for one wind direction. This is the load
for a direction that is not one of the two Figure 27.3-8 principal axes.
Cases 3 and 4 are not built here.

# Citation
ASCE 7-22 Figure 27.3-8 Cases 1 and 2 (corpus: asce-7-22, PDF page 352).
"""
function wind_direction_cases(resultant::WindWallResultant)
    return WindMWFRSCase[
        _wind_case1(resultant),
        _wind_case2(resultant, 1),
        _wind_case2(resultant, -1),
    ]
end

"""
    wind_cases_from_resultants(r1, r2; perpendicular=true) -> Vector{WindMWFRSCase}

Figure 27.3-8 cases for two resultants of the same floor. The two
resultants must come from the same rings. Their directions must be
perpendicular unless `perpendicular` is false. See
[`wind_principal_directions`](@ref).

Order: Case 1 and Case 2 (±) for `r1`, the same for `r2`, one Case 3, then
Case 4 for eccentricity signs (++), (+−), (−+), (−−). Case 2 adds
±0.15 B to the shape moment. It does not replace it. Case 3 is 75% of each
Case 1, added. Case 4 is 75% of each Case 2, added. A 45° wind is not one
of these combinations; it is a Case 1 direction of its own.

# Citation
ASCE 7-22 Figure 27.3-8 and §27.3.5 (corpus: asce-7-22, PDF pages 352–353).
The figure prints Case 4's wall pressure as 0.563 (56.3%) of Case 1, which
is 0.75 × 0.75 rounded. The factor used is the stated 75% of Case 2.
"""
function wind_cases_from_resultants(r1::WindWallResultant, r2::WindWallResultant;
                                    perpendicular::Bool=true)
    _same_floor(r1, r2)
    wind_principal_directions(r1.direction, r2.direction; perpendicular)
    cases = WindMWFRSCase[]
    push!(cases, _wind_case1(r1))
    push!(cases, _wind_case2(r1, 1))
    push!(cases, _wind_case2(r1, -1))
    push!(cases, _wind_case1(r2))
    push!(cases, _wind_case2(r2, 1))
    push!(cases, _wind_case2(r2, -1))
    push!(cases, _wind_case3(r1, r2))
    for s1 in (1, -1), s2 in (1, -1)
        push!(cases, _wind_case4(r1, r2, s1, s2))
    end
    return cases
end

"""
    wind_mwfrs_cases(loops, direction_1, direction_2; kwargs...) -> Vector{WindMWFRSCase}

[`wind_wall_resultant`](@ref) for each direction, then
[`wind_cases_from_resultants`](@ref). `perpendicular` is the principal-axis
check. `kwargs` are the resultant's keywords.
"""
function wind_mwfrs_cases(loops, direction_1, direction_2; perpendicular::Bool=true, kwargs...)
    r1 = wind_wall_resultant(loops, direction_1; kwargs...)
    r2 = wind_wall_resultant(loops, direction_2; kwargs...)
    return wind_cases_from_resultants(r1, r2; perpendicular)
end

function _wind_case1(r::WindWallResultant)
    # Figure 27.3-8 Case 1 (corpus: asce-7-22, PDF page 352): full design
    # pressure. The moment is only the moment of the edge forces.
    return WindMWFRSCase(:case1, r.direction, nothing, 0, 0, r.Fx, r.Fy, r.Mz)
end

function _wind_case2(r::WindWallResultant, sign::Int)
    sign == 1 || sign == -1 || throw(ArgumentError(
        "Case 2 eccentricity sign must be ±1; got $sign"))
    # Figure 27.3-8 Case 2 (corpus: asce-7-22, PDF page 352):
    # three-quarters of the design wind pressure, and
    # Mz = 0.75 (pWw + pLw) B e with e = ±0.15 B.
    # pWw and pLw on the figure are the along-wind pressures. With the
    # signed Eq. 27.3-1 pressure, that sum is the along-wind shear.
    # Commentary C27.3.5 (PDF page 959). The shape moment is scaled with
    # the pressures and the eccentricity is added.
    f = 0.75
    Fx = f * r.Fx
    Fy = f * r.Fy
    F_along = f * (r.Fx * r.direction[1] + r.Fy * r.direction[2])
    e = sign * wind_rigid_eccentricity(r.B)
    Mz = f * r.Mz + F_along * e
    return WindMWFRSCase(:case2, r.direction, nothing, sign, 0, Fx, Fy, Mz)
end

function _wind_case3(r1::WindWallResultant, r2::WindWallResultant)
    # Figure 27.3-8 Case 3 (corpus: asce-7-22, PDF page 352): wall pressures
    # are 75% of Case 1 in both principal directions at once. Note 2 keeps
    # roof pressures at 100% of the larger value; this slice applies no roof Cp.
    f = 0.75
    return WindMWFRSCase(:case3, r1.direction, r2.direction, 0, 0,
        f * r1.Fx + f * r2.Fx,
        f * r1.Fy + f * r2.Fy,
        f * r1.Mz + f * r2.Mz)
end

function _wind_case4(r1, r2, s1, s2)
    # Figure 27.3-8 Case 4 (corpus: asce-7-22, PDF page 352): wall pressures
    # and the torsional moment are 75% of Case 2. 0.75 × 0.75 = 0.5625,
    # which the figure rounds to 0.563 (56.3% of Case 1).
    c1 = _wind_case2(r1, s1)
    c2 = _wind_case2(r2, s2)
    f = 0.75
    return WindMWFRSCase(:case4, r1.direction, r2.direction, s1, s2,
        f * c1.Fx + f * c2.Fx,
        f * c1.Fy + f * c2.Fy,
        f * c1.Mz + f * c2.Mz)
end

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
