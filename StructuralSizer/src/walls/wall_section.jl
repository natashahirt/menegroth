# ==============================================================================
# Concrete Structural Wall — Section & Analytic Lateral Stiffness
# ==============================================================================
# The efficiency foundation for shear-wall layout optimization (plan S1): a
# closed-form, differentiable in-plane lateral stiffness for a rectangular
# concrete wall pier. This is what lets the layout optimizer evaluate thousands
# of candidate layouts without an FE mesh (see `lateral_evaluator.jl`).
#
# Code basis — reconciled against the extracted corpus:
#   - Effective (cracked/uncracked) flexural stiffness of walls: 0.70/0.35 Ig,
#       ACI 318-19 Table 6.6.3.1.1(a) = ACI 318-11 §10.10.4.1 (verified verbatim).
#       (corpus: aci-318-11, sp-effective-flexural-stiffness-aci318-14)
#   - In-plane shear strength provisions consumed by the checker: ACI 318-19 §11.5.4
#       (corpus: sp-wall-shear-strength-flowchart; see checker.jl)
#   - Validation oracle (worked example): StructurePoint spWall shear wall
#       (corpus: sp-de-shear-wall-aci19) — see test/walls/test_walls.jl.
#
# Still pending canon reconciliation: axial-flexure P–M interaction / boundary
# elements (not yet implemented).

using Unitful

# ------------------------------------------------------------------------------
# ACI effective-stiffness coefficients (ACI 318-19 Table 6.6.3.1.1(a))
# ------------------------------------------------------------------------------
# For elastic (service/first-order) lateral analysis the code permits a reduced
# moment of inertia to approximate cracking. Walls: 0.70 Ig uncracked,
# 0.35 Ig cracked — verified verbatim against ACI 318-11 §10.10.4.1 (identical
# to ACI 318-19 Table 6.6.3.1.1(a)); corpus: aci-318-11, and confirmed in the
# StructurePoint effective-stiffness guide Eq. 1 (α = 0.35 cracked).
const WALL_ISTIFF_UNCRACKED = 0.70
const WALL_ISTIFF_CRACKED   = 0.35

"""
    WallSection{L}

Rectangular concrete structural-wall cross-section (a single planar pier).

# Fields
- `lw::L`: wall length in plan (parallel to in-plane shear)
- `t::L`:  wall thickness (out of plane)
- `ρl::Float64`: vertical (longitudinal) reinforcement ratio (default ACI min 0.0025)
- `ρt::Float64`: horizontal (transverse) reinforcement ratio (default ACI min 0.0025)

`ρl`/`ρt` minimums per ACI 318-19 §11.6.1/§11.6.2
(corpus: sp-structural-wall-reinforcement-design; VERIFY).
"""
struct WallSection{L<:Unitful.Length}
    lw::L
    t::L
    ρl::Float64
    ρt::Float64
end

"""Construct a `WallSection`; reinforcement ratios default to the ACI wall minimum 0.0025."""
function WallSection(lw::Unitful.Length, t::Unitful.Length; ρl::Real=0.0025, ρt::Real=0.0025)
    L = promote_type(typeof(lw), typeof(t))
    WallSection{L}(convert(L, lw), convert(L, t), Float64(ρl), Float64(ρt))
end

"""Gross concrete shear area `Acv = t · lw` (ACI 318-19 §11.5.4.3; VERIFY)."""
gross_shear_area(ws::WallSection) = ws.t * ws.lw

"""
    gross_inertia_inplane(ws) -> Quantity

Gross moment of inertia of the wall about its in-plane (strong) centroidal axis,
`Ig = t · lw³ / 12`. Governs cantilever flexural stiffness for lateral loads
acting along the wall length.
"""
gross_inertia_inplane(ws::WallSection) = ws.t * ws.lw^3 / 12

"""
    effective_inertia_inplane(ws; cracked=true) -> Quantity

Effective in-plane moment of inertia, `I_eff = c · Ig`, with `c` from
ACI 318-19 Table 6.6.3.1.1(a) (0.35 cracked, 0.70 uncracked)
(corpus: sp-effective-flexural-stiffness-aci318-14; VERIFY).
"""
function effective_inertia_inplane(ws::WallSection; cracked::Bool=true)
    c = cracked ? WALL_ISTIFF_CRACKED : WALL_ISTIFF_UNCRACKED
    return c * gross_inertia_inplane(ws)
end

# ------------------------------------------------------------------------------
# Analytic in-plane lateral stiffness (differentiable, bare-SI core)
# ------------------------------------------------------------------------------
# A wall pier resisting lateral load along its length behaves as a shear-flexure
# cantilever. The lateral stiffness is the inverse of the sum of flexural and
# shear flexibility:
#
#   k = 1 / ( H³/(β·E·I_eff)  +  H/(G·A_v) )
#
#   β = 3   fixed-free  (cantilever pier, isolated wall)          [default]
#   β = 12  fixed-fixed (pier restrained top & bottom, e.g. coupled)
#   G = E / (2(1+ν))                        shear modulus
#   A_v = A / 1.2 = (t·lw)/1.2              effective shear area (rect. form factor 1.2)
#
# Because both I_eff (∝ t) and A_v (∝ t) are linear in thickness, the two
# flexibility terms scale as 1/t, so k is LINEAR in thickness: k(t) = t · (k/t).
# This linearity is what makes the SIMP density relaxation in the layout
# optimizer clean (see `layout_problem.jl`).

"""
    pier_lateral_stiffness_si(E, ν, Ieff, Av, H; boundary=:cantilever) -> Float64

In-plane lateral stiffness [N/m] of a wall pier, in bare SI. Shear-flexure
cantilever model. `boundary ∈ (:cantilever, :fixed)` selects β = 3 or 12.
Written generically (accepts `Real`/AD duals) so it is differentiable.
"""
function pier_lateral_stiffness_si(E::Real, ν::Real, Ieff::Real, Av::Real, H::Real;
                                   boundary::Symbol=:cantilever)
    β = boundary === :fixed ? 12.0 : 3.0
    G = E / (2 * (1 + ν))
    flex_flexibility  = H^3 / (β * E * Ieff)
    shear_flexibility = H / (G * Av)
    return 1 / (flex_flexibility + shear_flexibility)
end

"""
    wall_lateral_stiffness(ws, concrete, H; boundary=:cantilever, cracked=true) -> Quantity

In-plane lateral stiffness of a wall pier as a typed quantity [N/m], using the
ACI effective in-plane inertia. `H` is the pier (story) height.
"""
function wall_lateral_stiffness(ws::WallSection, concrete, H::Unitful.Length;
                                boundary::Symbol=:cantilever, cracked::Bool=true)
    E   = ustrip(u"Pa", concrete.E)
    ν   = concrete.ν
    Ie  = ustrip(u"m^4", effective_inertia_inplane(ws; cracked=cracked))
    Av  = ustrip(u"m^2", gross_shear_area(ws)) / 1.2
    Hm  = ustrip(u"m", H)
    k   = pier_lateral_stiffness_si(E, ν, Ie, Av, Hm; boundary=boundary)
    return k * u"N/m"
end

"""
    wall_stiffness_from_thickness_si(t, lw, E, ν, H; cracked=true, boundary=:cantilever) -> Float64

Bare-SI lateral stiffness as an explicit function of thickness `t` [m] (all
lengths in m, `E` in Pa). This is the form the layout optimizer differentiates;
`k` is linear in `t`. Returns [N/m].
"""
function wall_stiffness_from_thickness_si(t::Real, lw::Real, E::Real, ν::Real, H::Real;
                                          cracked::Bool=true, boundary::Symbol=:cantilever)
    c   = cracked ? WALL_ISTIFF_CRACKED : WALL_ISTIFF_UNCRACKED
    Ie  = c * t * lw^3 / 12
    Av  = (t * lw) / 1.2
    return pier_lateral_stiffness_si(E, ν, Ie, Av, H; boundary=boundary)
end

"""
    dwall_stiffness_dthickness_si(t, lw, E, ν, H; kwargs...) -> Float64

Analytic derivative `∂k/∂t` [N/m per m]. Since `k` is linear in `t`,
`∂k/∂t = k / t`; provided in closed form for the optimizer's sensitivities.
"""
function dwall_stiffness_dthickness_si(t::Real, lw::Real, E::Real, ν::Real, H::Real; kwargs...)
    k = wall_stiffness_from_thickness_si(t, lw, E, ν, H; kwargs...)
    return k / t
end
