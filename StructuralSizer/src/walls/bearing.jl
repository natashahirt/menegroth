# ==============================================================================
# Concrete Structural Wall — Empirical / Simplified Bearing-Wall Method (§11.5.3)
# ==============================================================================
# The lightest-weight wall axial checker: the ACI 318-19 "simplified design
# method for walls" (§11.5.3), the closed-form axial-capacity screen for a solid
# rectangular bearing wall whose factored-load resultant stays within the middle
# third of the thickness (small out-of-plane eccentricity). It is the axial
# sibling of the §11.8 alternative slender-wall method (out_of_plane.jl): §11.8
# handles the tension-controlled, laterally-loaded slender panel; §11.5.3 handles
# the stockier, concentrically-loaded bearing wall with a single knock-down for
# slenderness. Where a wall qualifies for both, §11.5.3 is the faster screen.
#
# Governing ACI 318-19 clauses (single closed form — Eq. 11.5.3.1). This is the
# unchanged predecessor provision ACI 318-11 §14.5.2 Eq. (14-1), which IS in the
# corpus (aci-318-11) and anchors the equation choice; the §11.5.3 spelling is
# the 318-19 renumbering (same house convention as checker.jl §11.5.4):
#
#     Pn = 0.55·f'c·Ag·[1 − (k·lc/(32·h))²]                       Eq. (11.5.3.1)
#     φPn = φ·Pn,   φ = 0.65 (compression-controlled, tied)   §11.5.3.3 / §21.2.2
#
#   effective length factor k — Table 11.5.3.2:
#     0.8  braced against lateral translation, rotation restrained at one/both ends
#     1.0  braced against lateral translation, rotation unrestrained at both ends
#     2.0  not braced against lateral translation (cantilever)
#
# APPLICABILITY IS A HARD SAFETY BOUNDARY (§11.5.3.1). The simplified method is
# valid ONLY for a solid rectangular section whose factored-load resultant lies
# within the middle third of the wall thickness (e ≤ h/6) at every section, with
# a slenderness term k·lc/(32·h) < 1 (else the bracket ≤ 0 and the equation
# returns no usable capacity). Minimum thickness is set by ACI 318-19
# Table 11.3.1.1. If any gate fails the checker reports FAILURE (never a silent
# pass) — the wall must then be designed by the general §11.5.2/§10 sectional
# method or the §11.8 alternative method (outside this checker's scope).
#
# VALIDATION (no independent worked-example oracle in the corpus — the corpus
# "bearing wall" example is actually a §11.8 case). Cross-checked instead by:
#   (1) an independent hand calculation of Eq. (11.5.3.1), and
#   (2) an Asap shell FEA of the same panel (test/walls): the FEA reproduces the
#       axial material/geometry basis (σ = P/Ag) and its effective-stiffness
#       Euler load confirms φPn is a conservative fraction of elastic buckling
#       and that the §11.5.3 slenderness knock-down tracks the FEA reduction.
# (canon note w0000016; a textbook oracle — McCormac/Wight — is being sourced.)
#
# Bare-SI cores (Pa, m, N) mirror flexure.jl / out_of_plane.jl; a Unitful wrapper
# resolves the section + material and returns a CheckResult.

using Unitful

# ------------------------------------------------------------------------------
# Effective length factor (ACI 318-19 Table 11.5.3.2)
# ------------------------------------------------------------------------------

"""
    wall_empirical_k(boundary::Symbol) -> Float64

Effective length factor `k` for the simplified wall method, ACI 318-19
Table 11.5.3.2:

- `:restrained` → 0.8 — braced against lateral translation, rotation restrained
  at one or both ends (the usual floor-to-floor bearing wall).
- `:pinned`     → 1.0 — braced against lateral translation, rotation unrestrained
  at both ends.
- `:cantilever` → 2.0 — not braced against lateral translation (free-standing).

`:unbraced` is accepted as a synonym for `:cantilever`.
"""
function wall_empirical_k(boundary::Symbol)
    boundary === :restrained && return 0.8
    boundary === :pinned     && return 1.0
    (boundary === :cantilever || boundary === :unbraced) && return 2.0
    error("wall_empirical_k: boundary must be :restrained (k=0.8), :pinned " *
          "(k=1.0) or :cantilever/:unbraced (k=2.0); got $(boundary).")
end

"""φ for the simplified wall method (compression-controlled, tied): §21.2.2 = 0.65."""
const WALL_PHI_BEARING = 0.65

# ------------------------------------------------------------------------------
# Bare-SI capacity core — Eq. (11.5.3.1)
# ------------------------------------------------------------------------------

"""
    wall_empirical_axial_capacity_si(fc, lc, h, Ag; k=1.0, φ=WALL_PHI_BEARING) -> NamedTuple

Nominal + design axial capacity of a solid rectangular bearing wall by the
ACI 318-19 §11.5.3 simplified method, in bare SI (`fc` in Pa; `lc`, `h` in m;
`Ag` in m²; returns forces in N):

    slender = k·lc/(32·h)
    R       = 1 − slender²            (bracketed slenderness reduction)
    Pn      = 0.55·f'c·Ag·R           Eq. (11.5.3.1)
    φPn     = φ·Pn

`R` (and therefore `Pn`) is clamped at zero: at `slender ≥ 1` the closed form
would go negative, meaning the wall is too slender for the simplified method
(the caller's slenderness gate turns this into an explicit failure).

# Fields
`(Pn, φPn, slender, R, Ag, k, φ)`
"""
function wall_empirical_axial_capacity_si(fc::Real, lc::Real, h::Real, Ag::Real;
                                          k::Real=1.0, φ::Real=WALL_PHI_BEARING)
    slender = k * lc / (32 * h)
    R  = max(1 - slender^2, 0.0)
    Pn = 0.55 * fc * Ag * R
    return (Pn = Pn, φPn = φ * Pn, slender = slender, R = R, Ag = Ag, k = k, φ = φ)
end

# ------------------------------------------------------------------------------
# Minimum thickness (ACI 318-19 Table 11.3.1.1)
# ------------------------------------------------------------------------------

"""
    wall_min_thickness_si(lu, lc; foundation=false) -> Float64

Minimum bearing-wall thickness [m] per ACI 318-19 Table 11.3.1.1: the greater of
4 in (0.1016 m) and 1/25 of the lesser of the unsupported length `lu` and
unsupported height `lc` (both m). Exterior basement / foundation walls designed
by the simplified method have a 7.5 in (0.1905 m) floor (`foundation=true`).
"""
function wall_min_thickness_si(lu::Real, lc::Real; foundation::Bool=false)
    floor_in = foundation ? 0.1905 : 0.1016    # 7.5 in : 4 in
    return max(floor_in, min(lu, lc) / 25)
end

# ------------------------------------------------------------------------------
# Demand-coupled CheckResult wrapper
# ------------------------------------------------------------------------------

"""
    check_wall_bearing_empirical(ws, concrete, Pu; e=0.0u"m", lc, lu=nothing,
                                 boundary=:restrained, foundation=false) -> CheckResult

ACI 318-19 §11.5.3 simplified bearing-wall axial check for a `WallSection` `ws`
(supplies horizontal length `lw` and thickness `t = h`) and its `concrete`. `Pu`
is the factored axial load (compression positive), `e` the out-of-plane
eccentricity of its resultant, and `lc` the clear unsupported HEIGHT — each a
Unitful quantity or bare SI (`N`, `m`). `boundary` selects `k` (Table 11.5.3.2,
see [`wall_empirical_k`](@ref)); `foundation` raises the minimum-thickness floor.

`lu` is the unsupported horizontal LENGTH between lateral supports (cross walls /
pilasters), used only by the Table 11.3.1.1 minimum-thickness rule. It defaults
to `ws.lw`; when designing a narrow tributary strip you MUST pass the true
unsupported length here, otherwise the `min(lu, lc)/25` term collapses to the
strip width and could non-conservatively accept a too-thin wall.

The check enforces the applicability boundary as a sequence of hard gates before
the strength check — a failure of any gate is a genuine FAILURE (the simplified
method does not apply; use a general method), never a silent pass:

 0. axial compression       §11.5.3          (`Pu ≥ 0`; the method is a BEARING /
                                              compression method — net tension is
                                              inapplicable, never a silent pass)
 1. minimum thickness       Table 11.3.1.1   (`h ≥ max(4in, min(lu,lc)/25)`)
 2. middle-third resultant  §11.5.3.1        (`|e| ≤ h/6`)
 3. slenderness             Eq. (11.5.3.1)   (`k·lc/(32·h) < 1`)
 4. strength                Eq. (11.5.3.1)   (`Pu ≤ φPn`)

The passing result carries clause `"ACI 318-19 11.5.3.1"` and ratio `Pu/φPn`.
(canon note w0000016; equation = ACI 318-11 §14.5.2 Eq. 14-1 from the corpus;
validated by an independent hand calc of the closed form + an Asap FEA
cross-check of its two ingredients — see test/walls. A fully independent
textbook numeric oracle (McCormac / Wight) is still pending.)
"""
function check_wall_bearing_empirical(ws::WallSection, concrete, Pu;
                                      e=0.0u"m", lc, lu=nothing,
                                      boundary::Symbol=:restrained,
                                      foundation::Bool=false)
    fc  = ustrip(u"Pa", concrete.fc′)
    lw  = ustrip(u"m", ws.lw)
    h   = ustrip(u"m", ws.t)
    lum = lu === nothing ? lw : (lu isa Unitful.Quantity ? ustrip(u"m", lu) : Float64(lu))
    lcm = lc isa Unitful.Quantity ? ustrip(u"m", lc) : Float64(lc)
    em  = e  isa Unitful.Quantity ? ustrip(u"m", e)  : Float64(e)
    Pu_N = Pu isa Unitful.Quantity ? ustrip(u"N", Pu) : Float64(Pu)
    k   = wall_empirical_k(boundary)
    Ag  = lw * h

    # Gate 0 — the simplified method is for AXIAL COMPRESSION bearing walls. Net
    # tension (Pu < 0) is outside its scope; refuse rather than pass on a
    # negative utilization ratio.
    if Pu_N < 0
        return CheckResult("bearing wall (§11.5.3): net axial tension — method inapplicable",
                           false, Inf, Pu_N, 0.0, "ACI 318-19 11.5.3")
    end

    # Gate 1 — minimum thickness (Table 11.3.1.1). demand = required min, capacity
    # = provided thickness, so ratio = demand/capacity = h_min/h (> 1 ⇒ too thin).
    h_min = wall_min_thickness_si(lum, lcm; foundation=foundation)
    if h < h_min - 1e-12
        return CheckResult("bearing wall (§11.5.3): thickness below minimum", false,
                           h_min / max(h, 1e-9), h_min, h, "ACI 318-19 11.3.1.1")
    end

    # Gate 2 — middle-third resultant (§11.5.3.1): |e| ≤ h/6 (sign-agnostic).
    e_lim = h / 6
    if abs(em) > e_lim + 1e-12
        return CheckResult("bearing wall (§11.5.3): resultant outside middle third", false,
                           abs(em) / max(e_lim, 1e-9), abs(em), e_lim, "ACI 318-19 11.5.3.1")
    end

    cap = wall_empirical_axial_capacity_si(fc, lcm, h, Ag; k=k)

    # Gate 3 — slenderness (Eq. 11.5.3.1): k·lc/(32·h) < 1, else no usable capacity.
    if cap.slender >= 1.0
        return CheckResult("bearing wall (§11.5.3): too slender for simplified method", false,
                           cap.slender, cap.slender, 1.0, "ACI 318-19 11.5.3.1")
    end

    # Gate 4 — strength: Pu ≤ φPn.
    ratio = Pu_N / max(cap.φPn, 1e-9)
    return CheckResult("bearing wall axial (§11.5.3 simplified)", ratio <= 1.0, ratio,
                       Pu_N, cap.φPn, "ACI 318-19 11.5.3.1")
end
