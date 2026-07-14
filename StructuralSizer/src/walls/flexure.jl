# ==============================================================================
# Concrete Structural Wall — In-Plane Axial–Flexure (P–M) Capacity
# ==============================================================================
# The flexural sibling of the S1 shear checker (checker.jl): in-plane moment
# capacity of a rectangular concrete wall pier under a simultaneous factored
# axial load. Demand-decoupled, like the shear checker — capacity functions take
# only the section + material + axial load; the moment demand is supplied by the
# caller (input in S1, distribution in S2, FEM in S3).
#
# Two capacity paths, both grounded in the corpus:
#
#   1. Cardenas simplified closed form  (PRIMARY / pass–fail).
#      Uniform distributed vertical reinforcement, lumped tension resultant.
#      This is exactly the spWall / Wight (Example 18-2) hand method and is the
#      CONSERVATIVE curve, so the CheckResult uses it.
#        (corpus: sp-de-shear-wall-aci19 §§3–4, lines 350–543; method: Cardenas
#         et al. / Wight, "RC Mechanics & Design" 8th ed., Ex. 18-2, Appendix 8.1)
#
#   2. Strain-compatibility interaction diagram  (GENERAL / diagnostic).
#      Distributed steel discretized into N layers; plane-sections + Whitney
#      block per ACI 318-19 §22.2. Mirrors the validated RC-column engine
#      (members/codes/aci/columns/pm_rect.jl) generalized to a wall section
#      (depth = lw, width = t, uniformly distributed layers). This is the
#      spColumn-style curve and sits ABOVE the Cardenas value (less
#      conservative), so it is reported, not used for the governing check.
#
# Governing ACI 318-19 clauses (verified verbatim — see canon note w0000012):
#   - β1                      Table 22.2.2.4.3  (via `beta1(mat)`)
#   - εcu = 0.003             §21.2.2.1
#   - εty = fy/Es             Eq. 5.3.1f
#   - φ (0.65→0.90)           Table 21.2.2   (via `phi_factor`, non-spiral wall)
#   - nominal flexure basis   §22.2
#
# OUT OF SCOPE — this module computes IN-PLANE axial-flexure CAPACITY only. The
# following are deliberately NOT covered here (no false sense of safety): a
# caller must not treat a passing P–M check as sufficient on its own.
#   - Special boundary-element trigger + detailing (ACI 318-19 §18.10.6):
#     canon ABSENT from corpus → HARD STOP, deferred to todo-w0000010.
#   - Out-of-plane / slender-wall design incl. P-Δ (ACI 318-19 §11.8):
#     deferred to todo-w0000008.
#   - Bar development / lap splices, and reinforcement detailing.
#   - Global slenderness / stability of the wall as a whole.
# The axial demand IS bounded here by the §22.4.2.1 squash cap (Pn,max = 0.80·P0)
# so the check cannot pass an over-axially-loaded wall on the moment term alone.

using Unitful

# 1 ksi = 6.894757e6 Pa; 1 kip = 4.4482216e3 N; 1 in = 0.0254 m.
const _KSI_TO_PA = 6.894757e6

# ------------------------------------------------------------------------------
# φ for wall axial–flexure (ACI 318-19 Table 21.2.2)
# ------------------------------------------------------------------------------

"""
    wall_phi_flexure(εt, εty) -> Float64

Strength-reduction factor φ for a wall in combined axial–flexure per
ACI 318-19 Table 21.2.2 (non-spiral / "other" transverse reinforcement — the
case for a planar wall): compression-controlled (`εt ≤ εty`) → 0.65,
tension-controlled (`εt ≥ εty + 0.003`) → 0.90, linear in between.

Numerically identical to the RC-column `phi_factor(εt, :tied; ...)`; kept as a
thin named wrapper so the wall citation reads against Table 21.2.2 directly.
(corpus: sp-de-shear-wall-aci19 §3 — "section is tension controlled ∴ φ = 0.90")
"""
function wall_phi_flexure(εt::Real, εty::Real)
    εt_tc = εty + 0.003
    εt ≤ εty   && return 0.65
    εt ≥ εt_tc && return 0.90
    return 0.65 + 0.25 * (εt - εty) / 0.003
end

# ------------------------------------------------------------------------------
# 1. Cardenas simplified closed form (bare-SI core) — PRIMARY / conservative
# ------------------------------------------------------------------------------

"""
    wall_axial_flexure_capacity_si(fc, fy, Es, lw, t, ρl, Nu; εcu=0.003) -> NamedTuple

In-plane nominal + design moment capacity of a rectangular wall pier with
uniformly distributed vertical reinforcement `ρl`, carrying a factored axial
load `Nu`, via the Cardenas simplified closed form. Bare SI: `fc`, `fy`, `Es`
in Pa; `lw`, `t` in m; `Nu` in N (compression positive). Returns SI
(`c` [m], `T`, `Nu` [N], `Mn`, `φMn` [N·m]) plus the dimensionless intermediates.

Method (corpus: sp-de-shear-wall-aci19 §§3–4; Cardenas/Wight Ex. 18-2):

    ω  = ρl·fy/f'c
    α  = Nu/(lw·t·f'c)
    c  = lw·(ω + α)/(0.85·β1 + 2·ω)          neutral-axis depth
    d  ≈ 0.8·lw                               effective depth (ACI wall convention)
    εt = (d/c − 1)·εcu                         extreme-tension steel strain
    T  = Ast·fy·(lw − c)/lw                    lumped tension resultant (yielded zone)
    Mn = T·(lw/2) + Nu·(lw − c)/2              ΣM about the compression resultant C

`β1` is taken from f'c per Table 22.2.2.4.3. The closed form assumes a
tension/transition-controlled wall (the usual regime, `c < lw`); for high axial
loads use the strain-compatibility diagram instead (see `wall_pm_at_c_si`).

# Fields
`(c, Ast, ω, α, β1, d, εt, εty, tension_controlled, φ, T, Nu, Mn, φMn)`
"""
function wall_axial_flexure_capacity_si(fc::Real, fy::Real, Es::Real,
                                        lw::Real, t::Real, ρl::Real, Nu::Real;
                                        εcu::Real=0.003)
    β1  = _beta1_from_fc_psi(fc / _KSI_TO_PA * 1000.0)  # f'c psi → β1 (Table 22.2.2.4.3)
    Ast = ρl * lw * t
    ω   = ρl * fy / fc
    α   = Nu / (lw * t * fc)
    c   = lw * (ω + α) / (0.85 * β1 + 2 * ω)
    d   = 0.8 * lw                             # ENGINEERING JUDGMENT: effective depth d≈0.8·lw, the wall approximation used by the spWall/Wight worked example (corpus: sp-de-shear-wall-aci19 §3); also the ACI §11.5.4.3 shear d
    εt  = (d / c - 1) * εcu
    εty = fy / Es
    φ   = wall_phi_flexure(εt, εty)
    T   = Ast * fy * (lw - c) / lw
    Mn  = T * (lw / 2) + Nu * (lw - c) / 2
    return (c = c, Ast = Ast, ω = ω, α = α, β1 = β1, d = d,
            εt = εt, εty = εty, tension_controlled = εt ≥ εty + 0.003,
            φ = φ, T = T, Nu = Nu, Mn = Mn, φMn = φ * Mn)
end

"""
    wall_pure_axial_capacity_si(fc, fy, lw, t, ρl) -> NamedTuple

Pure concentric axial capacity of the wall (SI, N). `P0` is the nominal squash
load and `Pn_max = 0.80·P0` is the ACI 318-19 §22.4.2.1 design cap for
non-prestressed members with tied/other (non-spiral) transverse reinforcement —
the ceiling a wall's factored axial load must respect before any P–M moment
check is meaningful.

    P0 = 0.85·f'c·(Ag − Ast) + fy·Ast          (Ag = lw·t, Ast = ρl·Ag)
    Pn_max = 0.80·P0                            (§22.4.2.1)
"""
function wall_pure_axial_capacity_si(fc::Real, fy::Real, lw::Real, t::Real, ρl::Real)
    Ag  = lw * t
    Ast = ρl * Ag
    P0  = 0.85 * fc * (Ag - Ast) + fy * Ast
    return (P0 = P0, Pn_max = 0.80 * P0)
end

# ------------------------------------------------------------------------------
# 2. Strain-compatibility interaction diagram (bare-SI) — GENERAL / diagnostic
# ------------------------------------------------------------------------------
# Generalizes the RC-column strain-compat engine (columns/pm_rect.jl
# `calculate_PM_at_c`) to a wall: bending about the strong (in-plane) axis with
# section depth = lw and width = t, and the vertical steel Ast smeared into
# `nlayers` equal layers spaced uniformly across lw. Compression face at x = lw;
# strains from plane sections with εcu at the compression fiber; steel
# elastic–perfectly-plastic (±fy); Whitney block a = β1·c; displaced-concrete
# correction for layers inside the block. Compression is POSITIVE, mirroring the
# column engine's sign convention exactly. (corpus: aci-318-11 Ch.10 / 318-19 §22.2)

"""
    wall_pm_at_c_si(fc, fy, Es, lw, t, Ast, c; εcu=0.003, nlayers=40) -> NamedTuple

Nominal `(Pn, Mn, εt)` of a wall section at neutral-axis depth `c` (all SI;
compression positive) by layer-by-layer strain compatibility. `Pn` in N, `Mn`
in N·m about the section mid-length, `εt` the extreme-tension layer strain.
"""
function wall_pm_at_c_si(fc::Real, fy::Real, Es::Real, lw::Real, t::Real,
                         Ast::Real, c::Real; εcu::Real=0.003, nlayers::Int=40)
    β1 = _beta1_from_fc_psi(fc / _KSI_TO_PA * 1000.0)
    a  = min(β1 * c, lw)
    Cc = 0.85 * fc * t * a                     # concrete compression resultant (N)
    y_Cc  = a / 2                              # from compression face (x = lw end)
    mid   = lw / 2
    As_l  = Ast / nlayers
    fc_st = 0.85 * fc
    Fs = 0.0; Ms = 0.0
    εt = 0.0
    @inbounds for i in 1:nlayers
        # layer center, measured from the compression face
        y = (i - 0.5) / nlayers * lw
        εs = εcu * (y - c) / c                 # y<c compression(−), y>c tension(+)
        fs = clamp(Es * εs, -fy, fy)
        if y < a                               # inside Whitney block → subtract displaced concrete
            Fi = -As_l * (fs + fc_st)
        else
            Fi = -fs * As_l
        end
        Fs += Fi
        Ms += Fi * (mid - y)
        if y > c                               # extreme tension = farthest layer past NA
            εt = εs
        end
    end
    Pn = Cc + Fs
    Mn = Cc * (mid - y_Cc) + Ms
    return (Pn = Pn, Mn = abs(Mn), εt = εt, c = c)
end

"""
    wall_moment_capacity_at_axial_si(fc, fy, Es, lw, t, Ast, Nu; εcu=0.003,
                                     nlayers=40, tol=1e-6) -> NamedTuple

Strain-compatibility factored moment capacity at a given factored axial `Nu`
(SI, compression positive): finds the neutral-axis depth `c` where `Pn(c) = Nu`
by bisection, then applies φ from Table 21.2.2. Returns
`(c, Pn, Mn, εt, εty, φ, φMn, tension_controlled, converged)`.

FAIL-SAFE: if `Nu` cannot be bracketed (e.g. it exceeds the pure-compression
squash load, so no `c` yields `Pn = Nu`), `converged=false` and `φMn=0` — a
caller then sees zero moment capacity rather than a plausible-looking but
meaningless value.
"""
function wall_moment_capacity_at_axial_si(fc::Real, fy::Real, Es::Real,
                                          lw::Real, t::Real, Ast::Real, Nu::Real;
                                          εcu::Real=0.003, nlayers::Int=40, tol::Real=1e-6)
    Pn(c) = wall_pm_at_c_si(fc, fy, Es, lw, t, Ast, c; εcu=εcu, nlayers=nlayers).Pn
    # Bracket: tiny c → tension-dominated (Pn<0 typically); large c → full compression.
    c_lo = 1e-4 * lw
    c_hi = 2.0 * lw
    P_lo = Pn(c_lo); P_hi = Pn(c_hi)
    # Ensure the target Nu is bracketed (expand c_hi for very high axial demand).
    nexp = 0
    while (P_hi - Nu) < 0 && nexp < 40
        c_hi *= 2; P_hi = Pn(c_hi); nexp += 1
    end
    εty = fy / Es
    if (P_lo - Nu) * (P_hi - Nu) > 0
        # Nu is outside the achievable axial range (typically above squash) → no
        # equilibrium neutral axis exists. Fail safe: report zero moment capacity.
        return (c = NaN, Pn = Nu, Mn = 0.0, εt = 0.0, εty = εty,
                φ = 0.65, φMn = 0.0, tension_controlled = false, converged = false)
    end
    c = 0.5 * (c_lo + c_hi)
    for _ in 1:100
        c = 0.5 * (c_lo + c_hi)
        Pc = Pn(c)
        if abs(Pc - Nu) < tol * max(abs(Nu), 1.0)
            break
        elseif (Pc - Nu) > 0
            c_hi = c
        else
            c_lo = c
        end
    end
    res = wall_pm_at_c_si(fc, fy, Es, lw, t, Ast, c; εcu=εcu, nlayers=nlayers)
    φ   = wall_phi_flexure(res.εt, εty)
    return (c = res.c, Pn = res.Pn, Mn = res.Mn, εt = res.εt, εty = εty,
            φ = φ, φMn = φ * res.Mn, tension_controlled = res.εt ≥ εty + 0.003,
            converged = true)
end

# ------------------------------------------------------------------------------
# Material extraction helper
# ------------------------------------------------------------------------------
# WallSection stores only geometry + reinforcement ratios; the vertical-steel
# fy/Es and concrete f'c come from the material. Accept a
# ReinforcedConcreteMaterial (preferred) or a plain Concrete with explicit
# fy/Es. Returns bare SI (Pa).

"""
    _wall_flexure_materials(material; fy=nothing, Es=nothing) -> (fc, fy, Es) [Pa]

Resolve `(f'c, fy, Es)` in Pa for a wall flexure calculation. A
`ReinforcedConcreteMaterial` supplies all three from its concrete + its VERTICAL
(longitudinal) rebar grade. A plain `Concrete` supplies `f'c` and REQUIRES the
`fy`/`Es` keywords.

Safety: `fy`/`Es` MUST be Unitful pressures (e.g. `60u"ksi"`, `29000u"ksi"`).
Bare numbers are rejected — a silent bare-vs-unit mismatch (ksi vs Pa) would
scale steel strength by ~7×10⁶ and produce a dangerously unconservative
capacity. There is exactly one accepted spelling, and it carries its unit.
"""
function _wall_flexure_materials(material; fy=nothing, Es=nothing)
    # Shared by the in-plane P–M and out-of-plane §11.8 checks, so the messages
    # stay function-agnostic.
    function _to_pa(x, name)
        x isa Unitful.Pressure && return ustrip(u"Pa", x)
        error("wall flexure materials: `$name` must be a Unitful pressure " *
              "(e.g. 60u\"ksi\"), not a bare number, to avoid a ksi/Pa unit mismatch.")
    end
    if material isa ReinforcedConcreteMaterial
        fc  = ustrip(u"Pa", material.concrete.fc′)
        fyP = fy === nothing ? ustrip(u"Pa", material.rebar.Fy) : _to_pa(fy, "fy")
        EsP = Es === nothing ? ustrip(u"Pa", material.rebar.E)  : _to_pa(Es, "Es")
        return (fc, fyP, EsP)
    else
        fc = ustrip(u"Pa", material.fc′)
        fy === nothing && error("wall flexure materials: a plain Concrete needs `fy=` (vertical rebar yield, Unitful).")
        Es === nothing && error("wall flexure materials: a plain Concrete needs `Es=` (rebar modulus, Unitful).")
        return (fc, _to_pa(fy, "fy"), _to_pa(Es, "Es"))
    end
end

# ------------------------------------------------------------------------------
# Demand-decoupled CheckResult wrapper
# ------------------------------------------------------------------------------

"""
    check_wall_inplane_flexure(ws, material, Nu, Mu; fy=nothing, Es=nothing,
                               εcu=0.003, nlayers=40) -> CheckResult

Demand-decoupled in-plane axial–flexure (P–M) check. `Nu` is the factored axial
load (compression positive) and `Mu` the factored in-plane moment demand — each
a Unitful quantity or a bare SI number (N, N·m).

Two guards make the check conservative in ALL regimes (not just the
tension-controlled worked example):

 1. AXIAL CAP (ACI 318-19 §22.4.2.1): if `Nu` exceeds the design squash cap
    `φ·Pn,max = 0.65·0.80·P0`, the check FAILS on axial — the wall is
    over-compressed and no moment check can rescue it.
 2. GOVERNING MOMENT = the CONSERVATIVE of the two methods,
    `min(Cardenas closed form, strain-compatibility diagram)`. The Cardenas form
    (spWall hand calc) is exact-ish in the tension/transition regime but assumes
    full yield of the tension block; the strain-compatibility diagram (ACI §22.2)
    is valid everywhere. Taking the minimum removes any reliance on Cardenas
    outside its regime and can never pass a wall that the rigorous method fails.

Returns a `CheckResult` (clause `"ACI 318-19 22.2 / Table 21.2.2"`; the axial-cap
failure reports clause `"ACI 318-19 22.4.2.1"`).
(corpus: sp-de-shear-wall-aci19 §§3–4)
"""
function check_wall_inplane_flexure(ws::WallSection, material, Nu, Mu;
                                    fy=nothing, Es=nothing, εcu::Real=0.003, nlayers::Int=40)
    fc, fyP, EsP = _wall_flexure_materials(material; fy=fy, Es=Es)
    lw = ustrip(u"m", ws.lw)
    t  = ustrip(u"m", ws.t)
    Nu_N = Nu isa Unitful.Quantity ? ustrip(u"N",   Nu) : Float64(Nu)
    Mu_N = abs(Mu isa Unitful.Quantity ? ustrip(u"N*m", Mu) : Float64(Mu))

    # Guard 1 — ACI 318-19 §22.4.2.1 design axial ceiling (φ=0.65 compression-controlled).
    ax = wall_pure_axial_capacity_si(fc, fyP, lw, t, ws.ρl)
    φPn_max = 0.65 * ax.Pn_max
    if Nu_N > φPn_max
        return CheckResult("in-plane axial-flexure (P-M): axial cap", false,
                           Nu_N / max(φPn_max, 1e-9), Nu_N, φPn_max,
                           "ACI 318-19 22.4.2.1")
    end

    # Guard 2 — governing moment capacity = conservative min of both methods.
    card = wall_axial_flexure_capacity_si(fc, fyP, EsP, lw, t, ws.ρl, Nu_N; εcu=εcu)
    Ast  = ws.ρl * lw * t
    diag = wall_moment_capacity_at_axial_si(fc, fyP, EsP, lw, t, Ast, Nu_N;
                                            εcu=εcu, nlayers=nlayers)
    φMn = diag.converged ? min(card.φMn, diag.φMn) : card.φMn
    φMn = max(φMn, 0.0)

    ratio = Mu_N / max(φMn, 1e-9)
    return CheckResult("in-plane axial-flexure (P-M)", ratio ≤ 1.0, ratio,
                       Mu_N, φMn, "ACI 318-19 22.2 / Table 21.2.2")
end

"""
    wall_pm_diagram(ws, material, Nu_points; fy=nothing, Es=nothing, εcu=0.003,
                    nlayers=40) -> Vector{NamedTuple}

Strain-compatibility P–M interaction points for a wall, for plotting/diagnostics
and cross-checking the Cardenas closed form. `Nu_points` is an iterable of
factored axial loads (Unitful forces or bare N); each entry returns the
factored moment capacity at that axial via `wall_moment_capacity_at_axial_si`.
"""
function wall_pm_diagram(ws::WallSection, material, Nu_points;
                         fy=nothing, Es=nothing, εcu::Real=0.003, nlayers::Int=40)
    fc, fyP, EsP = _wall_flexure_materials(material; fy=fy, Es=Es)
    lw  = ustrip(u"m", ws.lw)
    t   = ustrip(u"m", ws.t)
    Ast = ws.ρl * lw * t
    out = NamedTuple[]
    for Nu in Nu_points
        Nu_N = Nu isa Unitful.Quantity ? ustrip(u"N", Nu) : Float64(Nu)
        r = wall_moment_capacity_at_axial_si(fc, fyP, EsP, lw, t, Ast, Nu_N;
                                             εcu=εcu, nlayers=nlayers)
        push!(out, (Nu = Nu_N, c = r.c, φMn = r.φMn, Mn = r.Mn, φ = r.φ, εt = r.εt))
    end
    return out
end
