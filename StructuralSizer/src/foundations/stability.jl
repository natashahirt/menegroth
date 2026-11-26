# =============================================================================
# Global stability of a shallow footing: sliding, overturning, uplift
# =============================================================================
#
# Demand basis — ASCE 7-22 allowable-stress combinations, including the
# counteracting combinations that govern stability: §2.4.1 comb. 7a
# `0.6D + 0.6(W or WT)` and §2.4.5 comb. 10 `0.6D − 0.7Ev + 0.7Eh`
# (corpus: asce-7-22, PDF pages 69–70). The checks are run over every
# allowable-stress action and enveloped; the `0.6D` reduction is the margin,
# so no separate factor of safety is applied (IBC 1807.2.3's 1.5 factors are
# intentionally not used — IBC is not in the corpus).
#
# Resistance basis — Bowles 5e Eq. (4-3) and Table 4-5 (corpus:
# textbook-bowles-foundation-analysis-design-5e, PDF pages 252–253, 268):
#
#     H_{B or L} ≤ (V·tanδ + cₐ·B'L' + Pp) / SF
#
# with δ the base–soil friction angle (Table 4-5: 0.5φ ≤ δ ≤ φ), cₐ the base
# adhesion (Table 4-5 Note 3: cₐ ≈ 0.6c … 1.0c), B'L' the contact area, and Pp
# the passive-pressure resistance on the embedded face. Here SF = 1 because
# the ASCE-7 `0.6D` combination already supplies the margin.
#
# NOTE on overturning: the ACI 336.2R §3.2.1 kern requirement enforced by the
# bearing/plan sizing (resultant in the middle third, e ≤ L/6) is *stricter*
# than the overturning limit (resultant within the base, e ≤ L/2). For any
# compression combination that passes bearing, overturning is therefore
# already satisfied; the utilization below is reported for completeness.
# =============================================================================

"""
    _stability_concrete_unit_weight(stab) -> force/volume

Unit weight of the footing concrete used for the uplift self-weight
resistance. `nothing` falls back to 23.6 kN/m³ (≈150 pcf standard normal-
weight reinforced concrete — ENGINEERING JUDGMENT, not a code value).
"""
_stability_concrete_unit_weight(stab::StabilityParams) =
    stab.concrete_unit_weight === nothing ? 23.6u"kN/m^3" :
    uconvert(u"kN/m^3", stab.concrete_unit_weight)

"""
    _passive_coefficient(ϕ) -> Float64

Rankine passive earth-pressure coefficient `Kp = tan²(45° + φ/2)` (corpus:
textbook-bowles-foundation-analysis-design-5e, PDF page 376). `φ` in degrees.
"""
_passive_coefficient(ϕ::Real) = tand(45.0 + ϕ / 2)^2

"""
    _passive_force(soil, H, width) -> Force

Frictional passive-pressure resistance on an embedded face of height `H` and
plan `width`, integrating the Rankine passive pressure `σ = Kp·γ·z` over the
depth (corpus: textbook-bowles-foundation-analysis-design-5e, Eq. (4-3) and
PDF page 376):

    Pp = ½·Kp·γ·H²·width

The cohesive passive term `2c√Kp·H·width` is deliberately omitted (its
exclusion is conservative — it only adds resistance). `H` is taken as the
footing base thickness (Bowles p.269 lets the user use the base depth `Dc`
rather than the full embedment `Df`; the base thickness is the conservative
choice and needs no separate embedment input).
"""
function _passive_force(soil::Soil, H::Length, width::Length)
    Kp = _passive_coefficient(soil.ϕ)
    return uconvert(u"N", 0.5 * Kp * soil.γ * H^2 * width)
end

"""
    _footing_self_weight(B, L, h, stab) -> Force

Factored stabilizing self-weight of the footing concrete,
`dead_counteracting_factor · γ_c · B · L · h`, matching the `0.6D` dead-load
factor of ASCE 7-22 comb. 7a (corpus: asce-7-22, PDF page 69). Overburden
soil above the footing ledges is conservatively omitted.
"""
function _footing_self_weight(B::Length, L::Length, h::Length, stab::StabilityParams)
    γc = _stability_concrete_unit_weight(stab)
    return uconvert(u"N", stab.dead_counteracting_factor * γc * B * L * h)
end

"""
    _action_sliding_util(a, B, L, h, soil, stab) -> Float64

Sliding demand/resistance for one allowable-stress action. Demand is the
resultant horizontal base shear `H = hypot(Hx, Hy)`; resistance is Bowles
Eq. (4-3) with SF = 1:

    R = V·tanδ + cₐ·A + Pp      (V = compression axial, > 0)

Friction and adhesion require soil contact, so when the action is in net
uplift (`V ≤ 0`) only the passive term resists. Returns `0.0` when there is
no horizontal demand and `Inf` when a horizontal demand has no resistance.
"""
function _action_sliding_util(a::FootingAction, B::Length, L::Length, h::Length,
                              soil::Soil, stab::StabilityParams)
    H = hypot(a.Hx, a.Hy) * u"N"
    H ≤ zero(H) && return 0.0
    V = a.P * u"N"
    A = B * L
    R = zero(H)
    if V > zero(V)
        # Friction V·tanδ with δ = delta_ratio·φ, and adhesion cₐ = ca_ratio·c
        # over the full contact area (Bowles Table 4-5; corpus:
        # textbook-bowles-foundation-analysis-design-5e, PDF pages 252–253).
        δ = stab.delta_ratio * soil.ϕ
        R += V * tand(δ)
        R += uconvert(u"N", stab.ca_ratio * soil.c * A)
    end
    if stab.include_passive
        # Passive acts on the leading face; use the smaller plan dimension's
        # perpendicular face width = min(B, L) as the conservative resisting
        # width for the resultant horizontal (Bowles Eq. (4-3)).
        R += _passive_force(soil, h, min(B, L))
    end
    R ≤ zero(R) && return Inf
    return ustrip(Unitful.NoUnits, H / R)
end

"""
    _action_overturning_util(a, B, L) -> Float64

Resultant-eccentricity overturning utilization for one compression action,
`e / (base/2)` on each principal axis — the resultant must stay within the
base. `ex = Mx/P` pairs with `L`, `ey = My/P` with `B`, matching the
[`_eccentric_soil_pressure`](@ref) convention. Returns `0.0` for an action
with no net compression (uplift is handled by [`_action_uplift_util`](@ref)).
"""
function _action_overturning_util(a::FootingAction, B::Length, L::Length)
    P = a.P * u"N"
    P ≤ zero(P) && return 0.0
    Mx = a.Mx * u"N*m"
    My = a.My * u"N*m"
    ex = abs(Mx / P)
    ey = abs(My / P)
    util_x = ustrip(Unitful.NoUnits, ex / (L / 2))
    util_y = ustrip(Unitful.NoUnits, ey / (B / 2))
    return max(util_x, util_y)
end

"""
    _action_uplift_util(a, B, L, h, stab) -> Float64

Net-uplift utilization for one action: factored tension `|V|` resisted by the
factored footing self-weight (Bowles — flotation/uplift resisted by dead
weight; self-weight factored per ASCE 7-22 comb. 7a `0.6D`). Returns `0.0`
for a compression action.
"""
function _action_uplift_util(a::FootingAction, B::Length, L::Length,
                             h::Length, stab::StabilityParams)
    V = a.P * u"N"
    V ≥ zero(V) && return 0.0
    W = _footing_self_weight(B, L, h, stab)
    W ≤ zero(W) && return Inf
    return ustrip(Unitful.NoUnits, (-V) / W)
end

"""
    footing_stability_utils(actions, B, L, h, soil, stab)
        -> (sliding, overturning, uplift)

Envelope the three global-stability utilizations over every allowable-stress
`action` on a footing of plan `B × L` and thickness `h`. Each returned value
is the worst (maximum) over the combinations; `0.0` means the check does not
govern (e.g. no horizontal shear, or no uplift). See [`StabilityParams`](@ref)
for the demand and resistance basis.
"""
function footing_stability_utils(actions, B::Length, L::Length, h::Length,
                                 soil::Soil, stab::StabilityParams)
    isempty(actions) && return (sliding = 0.0, overturning = 0.0, uplift = 0.0)
    sliding = maximum(_action_sliding_util(a, B, L, h, soil, stab) for a in actions)
    overturning = maximum(_action_overturning_util(a, B, L) for a in actions)
    uplift = maximum(_action_uplift_util(a, B, L, h, stab) for a in actions)
    return (sliding = sliding, overturning = overturning, uplift = uplift)
end

"""
    _stability_min_square_side(actions, soil, stab, h_floor, min_B, si; cap=200)
        -> Length

Smallest square side `B = L` (on the `si` grid, at least `min_B`) at which
every allowable-stress action passes sliding, overturning, and uplift for a
footing of thickness `h_floor`. Used as a lower bound on the plan before the
bearing/shear sizing, which only makes the footing larger and thicker and so
can only improve stability (more contact area, more passive height, more
self-weight). A thinner `h_floor` (use the minimum depth) keeps the bound
conservative.

Throws when no size up to `cap` increments resists sliding — this happens
only when there is a horizontal demand with no mobilizable resistance
(e.g. passive excluded and the governing action is in net uplift).
"""
function _stability_min_square_side(actions, soil::Soil, stab::StabilityParams,
                                    h_floor::Length, min_B::Length, si::Length;
                                    cap::Int = 200)
    isempty(actions) && return min_B
    B = min_B
    for _ in 0:cap
        u = footing_stability_utils(actions, B, B, h_floor, soil, stab)
        (u.sliding ≤ 1.0 && u.overturning ≤ 1.0 && u.uplift ≤ 1.0) && return B
        B += si
    end
    throw(ErrorException(
        "Footing global stability (sliding/overturning/uplift) did not " *
        "converge within $cap size increments. The governing ASCE 7-22 " *
        "counteracting combination has a horizontal or uplift demand that " *
        "the mobilizable resistance (friction + adhesion + passive + self-" *
        "weight) cannot meet. Add passive resistance, embed deeper, or revisit " *
        "the lateral demands (corpus: asce-7-22 PDF pp.69–70; " *
        "textbook-bowles-foundation-analysis-design-5e PDF pp.252–253, 268)."))
end
