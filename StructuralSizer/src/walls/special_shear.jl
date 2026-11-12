using Unitful

# ACI 318-19 special-wall shear and the gross-section stress the §18.10.6.3
# route reads. The rendered page (PDF page 323) gives Eq. (18.10.3.1)
# `Ve = Ωv ωv Vu ≤ 3 Vu`. PDF page 324 gives §18.10.4.4:
# `Vn ≤ 8√f′c Acv` for segments sharing a force, and
# `Vn ≤ 10√f′c Acw` for one segment. Those caps have no λ. The Chapter 11
# cap in `wall_shear_capacity_si` stays `8λ√f′c`.
#
# `0.007 hwcs` is the code expression with `hwcs` in inches, the same
# empirical-unit convention as `√f′c` in psi.

"""
    special_wall_overstrength(hwcs, lw, Mpr, Mu; detailed=nothing) -> NamedTuple

ACI 318-19 Table 18.10.3.1.2 (page 323). When `hwcs/ℓw ≤ 1.5`, `Ωv = 1.0`.
When `hwcs/ℓw > 1.5`, `Ωv` is the greater of `Mpr/Mu` and `1.5`. A caller
who has the footnote's more detailed analysis passes it as `detailed`; that
value may be smaller than the table, but not smaller than `1.0`. The short
wall does not take a detailed value.
"""
function special_wall_overstrength(hwcs::Length, lw::Length, Mpr, Mu; detailed=nothing)
    (ustrip(u"m", hwcs) > 0 && ustrip(u"m", lw) > 0) ||
        throw(ArgumentError("hwcs and ℓw must be positive"))
    tall = ustrip(u"m", hwcs) / ustrip(u"m", lw) > 1.5
    tall || detailed === nothing ||
        throw(ArgumentError("Table 18.10.3.1.2 sets Ωv = 1.0 when hwcs/ℓw ≤ 1.5"))
    tall || return (Ωv = 1.0, from_moments = nothing, tall = false, detailed = false)
    (ustrip(u"N*m", Mpr) > 0 && ustrip(u"N*m", Mu) > 0) ||
        throw(ArgumentError("Mpr and Mu must be positive"))
    moment_ratio = ustrip(u"N*m", Mpr) / ustrip(u"N*m", Mu)
    code = max(moment_ratio, 1.5)
    detailed === nothing && return (
        Ωv = code, from_moments = moment_ratio, tall = true, detailed = false)
    detailed > 0 || throw(ArgumentError("a detailed Ωv must be positive"))
    return (
        Ωv = max(Float64(detailed), 1.0),
        from_moments = moment_ratio,
        tall = true,
        detailed = true,
    )
end

"""
    special_wall_dynamic_amplification(hwcs, lw, ns) -> NamedTuple

ACI 318-19 §18.10.3.1.3 (page 323). `hwcs/ℓw < 2` gives `ωv = 1`. Otherwise
`ωv = 0.9 + ns/10` for `ns ≤ 6` and `ωv = 1.3 + ns/30`, not above `1.8`,
for `ns > 6`. `ns` is not taken below `0.007 hwcs` with `hwcs` in inches.
"""
function special_wall_dynamic_amplification(hwcs::Length, lw::Length, ns::Real)
    (ustrip(u"m", hwcs) > 0 && ustrip(u"m", lw) > 0) ||
        throw(ArgumentError("hwcs and ℓw must be positive"))
    ns >= 0 || throw(ArgumentError("ns must be non-negative"))
    ustrip(u"m", hwcs) / ustrip(u"m", lw) < 2 &&
        return (ωv = 1.0, stories = nothing, branch = :short, floored = false, capped = false)
    stories = max(Float64(ns), 0.007 * ustrip(u"inch", hwcs))
    if stories <= 6
        return (
            ωv = 0.9 + stories / 10,
            stories = stories,
            branch = :few,
            floored = ns < stories,
            capped = false,
        )
    end
    raw = 1.3 + stories / 30
    return (
        ωv = min(raw, 1.8),
        stories = stories,
        branch = :many,
        floored = ns < stories,
        capped = raw > 1.8,
    )
end

"""
    special_wall_design_shear(Vu, Ωv, ωv) -> NamedTuple

ACI 318-19 Eq. (18.10.3.1) (page 323): `Ve = Ωv ωv Vu`, and `Ve` shall not
be taken greater than `3 Vu`.
"""
function special_wall_design_shear(Vu, Ωv::Real, ωv::Real)
    ustrip(u"N", Vu) > 0 || throw(ArgumentError("Vu must be positive"))
    (Ωv > 0 && ωv > 0) || throw(ArgumentError("Ωv and ωv must be positive"))
    product = Ωv * ωv * Vu
    cap = 3 * Vu
    return (Ve = min(product, cap), product = product, cap = cap, capped = product > cap)
end

"""
    special_wall_shear_limit(fc, area; individual=false) -> NamedTuple

ACI 318-19 §18.10.4.4 (page 324). Segments sharing one lateral force:
`8√f′c Acv`. One segment: `10√f′c Acw`. `√f′c` uses psi so the product with
area in in² is lbf. `λ` is not in these caps.
"""
function special_wall_shear_limit(fc, area; individual::Bool = false)
    fc_psi = ustrip(u"psi", fc)
    a = ustrip(u"inch^2", area)
    (fc_psi > 0 && a > 0) || throw(ArgumentError("f′c and the area must be positive"))
    factor = individual ? 10.0 : 8.0
    return (limit = (factor * sqrt(fc_psi) * a) * u"lbf", factor = factor)
end

"""
    wall_gross_fiber_stress(P, M, lw, t) -> NamedTuple

Extreme-fiber stress on a rectangular gross section, the linearly elastic
model §18.10.6.3 names. Compression and a moment that compresses the
positive end are positive. `I = t ℓw³/12`.
"""
function wall_gross_fiber_stress(P, M, lw::Length, t::Length)
    (ustrip(u"m", lw) > 0 && ustrip(u"m", t) > 0) ||
        throw(ArgumentError("ℓw and the thickness must be positive"))
    Ag = t * lw
    I = t * lw^3 / 12
    flexure = M * (lw / 2) / I
    axial = P / Ag
    return (
        at_positive_end = axial + flexure,
        at_negative_end = axial - flexure,
        axial = axial,
        flexure = flexure,
    )
end
