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
± this value. The sign is the caller's. A flexible building uses
[`wind_flexible_eccentricity`](@ref) at each sign of this value.

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

"""
    wind_flexible_eccentricity(eQ, eR; Iz, gQ, Q, gR, R) -> Float64

Eccentricity of a flexible building, Eq. (27.3-4).

`eQ` is the rigid-building eccentricity of Figure 27.3-8, including its
sign. `eR` is the distance between the elastic shear center and the center
of mass of the floor. The two signs of `eQ` are not mirrors of each other:
the square-root term does not change sign. The caller evaluates both.

# Citation
ASCE 7-22 Eq. (27.3-4) and §27.3.5 (corpus: asce-7-22, PDF page 353).
`Iz`, `gQ`, `Q`, `gR`, and `R` are the §26.11 gust-effect quantities
(PDF pages 338–340). The text extract places a square-root bar over each
sum of squares.
"""
function wind_flexible_eccentricity(eQ, eR; Iz, gQ, Q, gR, R)
    eQ = _as_finite("eQ", eQ)
    eR = _as_finite("eR", eR)
    Iz = _as_finite("Iz", Iz)
    gQ = _as_finite("gQ", gQ)
    Q = _as_finite("Q", Q)
    gR = _as_finite("gR", gR)
    R = _as_finite("R", R)
    # ASCE 7-22 Eq. (27.3-4) (corpus: asce-7-22, PDF page 353):
    # e = [e_Q + 1.7 I_z √((g_Q Q e_Q)^2 + (g_R R e_R)^2)]
    #   / [1 + 1.7 I_z √((g_Q Q)^2 + (g_R R)^2)].
    root_num = sqrt((gQ * Q * eQ)^2 + (gR * R * eR)^2)
    root_den = sqrt((gQ * Q)^2 + (gR * R)^2)
    den = 1.0 + 1.7 * Iz * root_den
    den > 0 || throw(ArgumentError(
        "Eq. 27.3-4 denominator must be positive; got $den."))
    return (eQ + 1.7 * Iz * root_num) / den
end

