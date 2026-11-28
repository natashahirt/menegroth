# ─────────────────────────────────────────────────────────────────────────────
# Two-way shear capacity: ACI 318-11 §11.11.2.1 / ACI 318-19 Table 22.6.5.2
# ─────────────────────────────────────────────────────────────────────────────

"""
    size_effect_factor(d) -> Float64

ACI 318-19 Eq. (22.5.5.1.3) (corpus: aci-318-19, printed p. 405):

    λs = √(2 / (1 + d/10)) ≤ 1,   d in inches

λs is 1 for d ≤ 10 in. It is the same factor in one-way shear (Table 22.5.5.1)
and two-way shear (Tables 22.6.5.2 and 22.6.6.1).
"""
function size_effect_factor(d::Length)
    d_in = ustrip(u"inch", d)
    return min(sqrt(2 / (1 + d_in / 10)), 1.0)
end

"""
√f′c in psi for shear, not above 100 psi. ACI 318-19 §22.5.3.1 (one-way) and
§22.6.3.1 (two-way, corpus: aci-318-19, printed p. 412); ACI 318-11 §11.1.2.
"""
_shear_sqrt_fc(fc::Pressure) = min(sqrt(ustrip(u"psi", fc)), 100.0)

"""
    punching_capacity_stress(fc, β, αs, b0, d; λ=1.0, λs=1.0) → Pressure

Nominal two-way shear stress vc of a nonprestressed slab without shear
reinforcement, the least of

    4 λs λ √f'c,   (2 + 4/β) λs λ √f'c,   (2 + αs d/b0) λs λ √f'c

ACI 318-19 Table 22.6.5.2 (corpus: aci-318-19, printed p. 416). With
`λs = 1` this is ACI 318-11 §11.11.2.1, Eqs. (11-31) to (11-33), which the
footing modules still use. Slab callers pass `λs = size_effect_factor(d)`.
√f'c is capped at 100 psi (§22.6.3.1).
"""
function punching_capacity_stress(fc::Pressure, β::Float64, αs::Int,
                                   b0::Length, d::Length; λ::Float64 = 1.0,
                                   λs::Float64 = 1.0)
    k = λs * λ * _shear_sqrt_fc(fc)
    vc_a = (2 + 4 / β) * k
    vc_b = (αs * d / b0 + 2) * k
    vc_c = 4 * k
    return min(vc_a, vc_b, vc_c) * u"psi"
end

"""
    punching_capacity_interior(b0, d, fc; ...) → Force

Nominal punching shear capacity Vc = vc × b₀ × d (as a force).
"""
function punching_capacity_interior(
    b0::Length, d::Length, fc::Pressure;
    c1::Length = 0u"inch", c2::Length = 0u"inch",
    λ::Float64 = 1.0, λs::Float64 = 1.0, position::Symbol = :interior,
    shape::Symbol = :rectangular
)
    β = punching_β(c1, c2; shape = shape)
    αs = punching_αs(position)
    vc = punching_capacity_stress(fc, β, αs, b0, d; λ = λ, λs = λs)
    # vc (psi) × b0 (inch) × d (inch) → lbf
    Vc = ustrip(u"psi", vc) * ustrip(u"inch", b0) * ustrip(u"inch", d)
    return Vc * u"lbf"
end

"""
    punching_minimum_top_steel(vuv, bslab, b0, fc, fy, αs; λ=1, λs=1, φ=0.75)
        -> Area

ACI 318-19 §8.6.1.2, Eq. (8.6.1.2) (corpus: aci-318-19, printed p. 111). If
`vuv > φ 2 λs λ √f'c` on the two-way critical section around a column,

    As,min = 5 vuv bslab b0 / (φ αs fy)

is required over the width `bslab` of Table 8.4.2.2.3. Otherwise zero. `vuv`
is the factored shear stress on that section without moment transfer
(Chapter 2 notation).
"""
function punching_minimum_top_steel(vuv::Pressure, bslab::Length, b0::Length,
                                    fc::Pressure, fy::Pressure, αs::Int;
                                    λ::Float64 = 1.0, λs::Float64 = 1.0,
                                    φ::Float64 = 0.75)
    vuv_psi = ustrip(u"psi", vuv)
    vuv_psi > φ * 2 * λs * λ * _shear_sqrt_fc(fc) || return 0.0u"inch^2"
    As = 5 * vuv_psi * ustrip(u"inch", bslab) * ustrip(u"inch", b0) /
         (φ * αs * ustrip(u"psi", fy))
    return As * u"inch^2"
end
