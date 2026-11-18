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
    # Figure 27.3-8 e_Q is ±0.15 B. Eq. 27.3-4 is evaluated at that signed
    # e_Q. The two results are not opposites (corpus: asce-7-22, PDF page 353).
    eQ = sign * wind_rigid_eccentricity(r.B)
    e = r.gust === nothing ? eQ : wind_flexible_eccentricity(
        eQ, r.gust.eR; Iz=r.gust.Iz, gQ=r.gust.gQ, Q=r.gust.Q,
        gR=r.gust.gR, R=r.gust.R)
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

