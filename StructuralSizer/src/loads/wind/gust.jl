# ASCE 7-22 §26.11 gust effects, customary units (ft, mi/h, Hz).
#
# The equations were checked against the rendered PDF pages 338–340 of
# corpus asce-7-22; the text extract scrambles several of them.

"""
    wind_terrain_constants(exposure) -> NamedTuple

Table 26.11-1, customary units, for exposure `:B`, `:C`, or `:D`. Fields
`α`, `zg_ft`, `α̂`, `b̂`, `ᾱ`, `b̄`, `c`, `ℓ_ft`, `ε̄`, `zmin_ft`.

# Citation
ASCE 7-22 Table 26.11-1 (corpus: asce-7-22, PDF page 339).
"""
function wind_terrain_constants(exposure::Symbol)
    exposure === :B && return (α=7.5, zg_ft=3280.0, α̂=1 / 7.5, b̂=0.84, ᾱ=1 / 4.5,
                               b̄=0.47, c=0.30, ℓ_ft=320.0, ε̄=1 / 3.0, zmin_ft=30.0)
    exposure === :C && return (α=9.8, zg_ft=2460.0, α̂=1 / 9.8, b̂=1.00, ᾱ=1 / 6.4,
                               b̄=0.66, c=0.20, ℓ_ft=500.0, ε̄=1 / 5.0, zmin_ft=15.0)
    exposure === :D && return (α=11.5, zg_ft=1935.0, α̂=1 / 11.5, b̂=1.09, ᾱ=1 / 8.0,
                               b̄=0.78, c=0.15, ℓ_ft=650.0, ε̄=1 / 8.0, zmin_ft=7.0)
    throw(ArgumentError("Table 26.11-1 has exposures :B, :C, and :D; got $(repr(exposure))"))
end

"""
    wind_effective_length(h_ft, L_ft) -> Float64

`Leff = Σ hᵢLᵢ / Σ hᵢ`, Eq. (26.11-1). `h_ft[i]` is the height above grade
of level `i` and `L_ft[i]` the building length at that level parallel to
the wind.

# Citation
ASCE 7-22 §26.11.2.1 and Eq. (26.11-1) (corpus: asce-7-22, PDF page 338).
"""
function wind_effective_length(h_ft::AbstractVector, L_ft::AbstractVector)
    length(h_ft) == length(L_ft) || throw(ArgumentError(
        "Eq. 26.11-1: $(length(h_ft)) heights and $(length(L_ft)) lengths"))
    isempty(h_ft) && throw(ArgumentError("Eq. 26.11-1 needs at least one level"))
    den = sum(h_ft)
    den > 0 || throw(ArgumentError("Eq. 26.11-1: the level heights sum to $den"))
    return sum(h_ft[i] * L_ft[i] for i in eachindex(h_ft)) / den
end

"""
    approximate_frequency_permitted(h_ft, Leff_ft) -> Bool

§26.11.2.1: `na` may replace an analysis when the building height is at
most 300 ft and less than four times `Leff`.

# Citation
ASCE 7-22 §26.11.2.1 (corpus: asce-7-22, PDF page 338).
"""
approximate_frequency_permitted(h_ft::Real, Leff_ft::Real) =
    h_ft <= 300.0 && h_ft < 4 * Leff_ft

"""
    approximate_natural_frequency(h_ft; system) -> Float64

Lower-bound natural frequency `na` [Hz] for `system`:

- `:steel_moment_frame` — `22.2 / h^0.8`, Eq. (26.11-2)
- `:concrete_moment_frame` — `43.5 / h^0.9`, Eq. (26.11-3)
- `:other` — steel and concrete buildings with other systems, `75 / h`, Eq. (26.11-4)

`h_ft` is the mean roof height. The caller checks
[`approximate_frequency_permitted`](@ref).

# Citation
ASCE 7-22 §26.11.3 (corpus: asce-7-22, PDF pages 338–339).
"""
function approximate_natural_frequency(h_ft::Real; system::Symbol)
    h_ft > 0 || throw(ArgumentError("§26.11.3: h must be positive; got $h_ft ft"))
    system === :steel_moment_frame && return 22.2 / h_ft^0.8
    system === :concrete_moment_frame && return 43.5 / h_ft^0.9
    system === :other && return 75.0 / h_ft
    throw(ArgumentError("§26.11.3: system is :steel_moment_frame, " *
                        ":concrete_moment_frame, or :other; got $(repr(system))"))
end

"""
    shear_wall_natural_frequency(h_ft, AB_ft2, walls) -> Float64

`na = 385 √Cw / h`, Eq. (26.11-5), for concrete or masonry shear-wall
buildings, with

```
Cw = (100/AB) Σ (h/hᵢ)² Aᵢ / [1 + 0.83 (hᵢ/Dᵢ)²]
```

`walls` holds one `(A_ft2, D_ft, h_ft)` per shear wall effective in the
direction considered: horizontal cross-sectional area, length, and height.
`AB_ft2` is the base area of the building.

# Citation
ASCE 7-22 §26.11.3 and Eq. (26.11-5) (corpus: asce-7-22, PDF page 339).
"""
function shear_wall_natural_frequency(h_ft::Real, AB_ft2::Real, walls)
    h_ft > 0 || throw(ArgumentError("Eq. 26.11-5: h must be positive; got $h_ft ft"))
    AB_ft2 > 0 || throw(ArgumentError("Eq. 26.11-5: AB must be positive; got $AB_ft2 ft²"))
    isempty(walls) && throw(ArgumentError(
        "Eq. 26.11-5: no shear wall is effective in this direction"))
    s = 0.0
    for (A, D, hi) in walls
        (A > 0 && D > 0 && hi > 0) || throw(ArgumentError(
            "Eq. 26.11-5: wall area, length, and height must be positive; got ($A, $D, $hi)"))
        s += (h_ft / hi)^2 * A / (1 + 0.83 * (hi / D)^2)
    end
    Cw = 100 / AB_ft2 * s
    return 385.0 * sqrt(Cw) / h_ft
end

"""
    wind_low_rise(h_ft, least_dimension_ft) -> Bool

§26.2 low-rise: mean roof height at most 60 ft and not more than the least
horizontal dimension. The enclosure condition is the caller's. §26.11.2
permits a low-rise building to be considered rigid.

# Citation
ASCE 7-22 §26.2, BUILDING, LOW-RISE, and §26.11.2 (corpus: asce-7-22, PDF
pages 323 and 338).
"""
wind_low_rise(h_ft::Real, least_dimension_ft::Real) =
    h_ft <= 60.0 && h_ft <= least_dimension_ft

"""Equivalent height `z̄ = max(0.6h, zmin)` [ft], §26.11.4 and Table 26.11-1."""
function gust_equivalent_height(h_ft::Real, exposure::Symbol)
    h_ft > 0 || throw(ArgumentError("§26.11.4: h must be positive; got $h_ft ft"))
    return max(0.6 * h_ft, wind_terrain_constants(exposure).zmin_ft)
end

function _gust_background(h_ft, B_ft, exposure)
    B_ft > 0 || throw(ArgumentError("§26.11.4: B must be positive; got $B_ft ft"))
    tc = wind_terrain_constants(exposure)
    z̄ = gust_equivalent_height(h_ft, exposure)
    Iz = tc.c * (33 / z̄)^(1 / 6)                           # Eq. (26.11-7)
    Lz = tc.ℓ_ft * (z̄ / 33)^tc.ε̄                           # Eq. (26.11-9)
    Q = sqrt(1 / (1 + 0.63 * ((B_ft + h_ft) / Lz)^0.63))   # Eq. (26.11-8)
    return (; tc, z̄, Iz, Lz, Q)
end

"""
    gust_effect_factor_rigid(h_ft, B_ft; exposure) -> NamedTuple

`G = 0.925 (1 + 1.7 gQ Iz Q) / (1 + 1.7 gv Iz)`, Eq. (26.11-6), with
`gQ = gv = 3.4`. Returns `G`, `Iz`, `Q`, `z̄`, and `Lz`. §26.11.4 also
permits `G = 0.85`; that choice is the caller's.

# Citation
ASCE 7-22 §26.11.4, Eqs. (26.11-6) to (26.11-9) (corpus: asce-7-22, PDF page 339).
"""
function gust_effect_factor_rigid(h_ft::Real, B_ft::Real; exposure::Symbol)
    bg = _gust_background(h_ft, B_ft, exposure)
    gQ = gv = 3.4
    G = 0.925 * (1 + 1.7 * gQ * bg.Iz * bg.Q) / (1 + 1.7 * gv * bg.Iz)
    return (G=G, Iz=bg.Iz, Q=bg.Q, z̄=bg.z̄, Lz=bg.Lz)
end

"Size-effect factor of Eq. (26.11-15a). Its limit at η = 0 is 1."
function _gust_size_effect(η)
    η > 1e-9 || return 1.0
    return 1 / η - (1 - exp(-2η)) / (2 * η^2)
end

"""
    gust_effect_factor_flexible(h_ft, B_ft, L_ft; exposure, V_mph, n1, β) -> NamedTuple

Gust-effect factor of a flexible building, Eq. (26.11-10):

```
Gf = 0.925 (1 + 1.7 Iz √(gQ²Q² + gR²R²)) / (1 + 1.7 gv Iz)
```

`B_ft` is normal to the wind, `L_ft` parallel to it, `h_ft` the mean roof
height. `V_mph` is the basic wind speed, `n1` the fundamental natural
frequency [Hz], and `β` the damping ratio as a fraction of critical. Returns
`Gf` and every term, including `Iz`, `gQ`, `Q`, `gR`, and `R` for Eq. 27.3-4.

# Citation
ASCE 7-22 §26.11.5, Eqs. (26.11-10) to (26.11-16) (corpus: asce-7-22, PDF
pages 339–340).
"""
function gust_effect_factor_flexible(h_ft::Real, B_ft::Real, L_ft::Real;
                                     exposure::Symbol, V_mph::Real, n1::Real, β::Real)
    L_ft > 0 || throw(ArgumentError("§26.11.5: L must be positive; got $L_ft ft"))
    V_mph > 0 || throw(ArgumentError("§26.11.5: V must be positive; got $V_mph mi/h"))
    0 < β < 1 || throw(ArgumentError("§26.11.5: β is a fraction of critical; got $β"))
    3600 * n1 > 1 || throw(ArgumentError(
        "Eq. 26.11-11 needs ln(3600 n1) > 0; got n1 = $n1 Hz"))
    bg = _gust_background(h_ft, B_ft, exposure)
    tc = bg.tc
    gQ = gv = 3.4
    ln = log(3600 * n1)
    gR = sqrt(2 * ln) + 0.577 / sqrt(2 * ln)                 # Eq. (26.11-11)
    Vz = tc.b̄ * (bg.z̄ / 33)^tc.ᾱ * (88 / 60) * V_mph         # Eq. (26.11-16), ft/s
    N1 = n1 * bg.Lz / Vz                                      # Eq. (26.11-14)
    Rn = 7.47 * N1 / (1 + 10.3 * N1)^(5 / 3)                  # Eq. (26.11-13)
    Rh = _gust_size_effect(4.6 * n1 * h_ft / Vz)              # Eqs. (26.11-15a, b)
    RB = _gust_size_effect(4.6 * n1 * B_ft / Vz)
    RL = _gust_size_effect(15.4 * n1 * L_ft / Vz)
    R = sqrt(Rn * Rh * RB * (0.53 + 0.47 * RL) / β)           # Eq. (26.11-12)
    Gf = 0.925 * (1 + 1.7 * bg.Iz * sqrt(gQ^2 * bg.Q^2 + gR^2 * R^2)) /
         (1 + 1.7 * gv * bg.Iz)                               # Eq. (26.11-10)
    return (Gf=Gf, Iz=bg.Iz, gQ=gQ, gv=gv, Q=bg.Q, gR=gR, R=R, Rn=Rn, Rh=Rh,
            RB=RB, RL=RL, N1=N1, Vz_fps=Vz, z̄=bg.z̄, Lz=bg.Lz)
end
