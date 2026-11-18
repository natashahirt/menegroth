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

