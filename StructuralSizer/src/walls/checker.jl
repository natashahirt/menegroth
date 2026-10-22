# ==============================================================================
# Concrete Structural Wall — In-Plane Shear Strength (ACI 318-19 §11.5.4)
# ==============================================================================
# A demand-decoupled capacity checker (plan S1, todo `wall-stiffness-contract`:
# "keep checker decoupled from demand source"). Capacity functions take only the
# section + material; demand is supplied separately by the caller (input in S1,
# rigid-diaphragm distribution in S2, or FEM in S3). This decoupling is what lets
# the same checker serve every demand tier.
#
# Code basis — reconciled against the extracted corpus (see test/walls/test_walls.jl
# "spWall worked example" for the numeric known-answer check):
#   - In-plane shear strength: ACI 318-19 §11.5.4.3
#         Vn = (αc·λ·√f'c + ρt·fyt)·Acv                [psi, in],  Acv = t·lw
#     with αc = 3.0 (hw/lw ≤ 1.5), 2.0 (hw/lw ≥ 2.0), linear between.
#     (corpus: sp-wall-shear-strength-flowchart; sp-de-shear-wall-aci19 Step 5)
#   - Upper limit: ACI 318-19 §11.5.4.2   Vn ≤ 8·λ·√f'c·Acv
#     (= ACI 318-11 §11.9.3 with d = 0.8·lw per §11.9.4; corpus: aci-318-11)
#   - Minimum web reinforcement: ACI 318-19 §11.6.2 — ρt ≥ 0.0025 (b); ρl ≥ the
#     hw/lw-dependent §11.6.2(a) minimum. (corpus: sp-de-shear-wall-aci19 Step 2)
#   - φ (shear) = 0.75  (ACI 318-19 §21.2.1; ACI 318-11 §9.3.2.3)
#   - Validation oracle: StructurePoint spWall shear wall worked example
#     (corpus: sp-de-shear-wall-aci19) — φVc=204.92, φVs=243.00, φVn=447.92 kips.

using Unitful

"""φ factor for shear in walls (ACI 318-19 §21.2.1 / ACI 318-11 §9.3.2.3 = 0.75)."""
const WALL_PHI_SHEAR = 0.75

"""
    wall_alpha_c(hw_over_lw) -> Float64

Coefficient αc for in-plane shear (ACI 318-19 §11.5.4.3): 3.0 for
`hw/lw ≤ 1.5`, 2.0 for `hw/lw ≥ 2.0`, linear in between. `hw` is the total wall
height, `lw` the wall length. (corpus: sp-wall-shear-strength-flowchart;
verified — sp-de-shear-wall-aci19 uses αc = 2.0 at hw/lw = 3.0)
"""
function wall_alpha_c(hw_over_lw::Real)
    hw_over_lw <= 1.5 && return 3.0
    hw_over_lw >= 2.0 && return 2.0
    return 3.0 + (2.0 - 3.0) * (hw_over_lw - 1.5) / (2.0 - 1.5)
end

"""
    wall_shear_capacity_si(fc, fy, lw, t, ρt, hw; λ=1.0) -> NamedTuple

Nominal + design in-plane shear capacity in bare SI. Inputs: `fc`, `fy` [Pa],
lengths [m], `ρt` transverse ratio, `hw` total height [m]. Returns
`(Vn, ϕVn, Vn_max, αc)` in [N]. Implements ACI 318-19 §11.5.4.3 with the
§11.5.4.2 cap (`8·λ·√f'c·Acv`); computed in psi/in internally then converted.
Verified against StructurePoint spWall (corpus: sp-de-shear-wall-aci19 Step 5).
"""
function wall_shear_capacity_si(fc::Real, fy::Real, lw::Real, t::Real, ρt::Real, hw::Real; λ::Real=1.0)
    # Convert to ACI customary units (psi, in) for the empirical √f'c formula.
    fc_psi = fc / 6894.757
    fy_psi = fy / 6894.757
    lw_in  = lw / 0.0254
    t_in   = t / 0.0254
    Acv_in2 = t_in * lw_in

    αc = wall_alpha_c(lw > 0 ? hw / lw : Inf)
    sqrt_fc = sqrt(max(fc_psi, 0.0))

    # In-plane nominal shear ACI 318-19 §11.5.4.3, Eq. (11.5.4.3):
    #   Vn = (αc·λ·√f'c + ρt·fyt)·Acv          [Acv = t·lw, psi/in]
    # Verified against StructurePoint spWall worked example (corpus:
    # sp-de-shear-wall-aci19 Step 5): f'c=4000 psi, fyt=60 ksi, t=10 in,
    # lw=216 in, ρt=0.0025, hw/lw=3 (αc=2) ⇒ φVn = 447.92 kips.
    Vn_lb = (αc * λ * sqrt_fc + ρt * fy_psi) * Acv_in2
    # Upper limit ACI 318-19 §11.5.4.2:  Vn ≤ 8·λ·√f'c·Acv. This is the ACI
    # 318-11 §11.9.3 cap (Vn ≤ 10·λ·√f'c·h·d) evaluated with d = 0.8·lw per
    # §11.9.4, since 10·(0.8·lw·t) = 8·(lw·t) = 8·Acv.
    # (corpus: aci-318-11 §11.9.3 & §11.9.4, verified verbatim)
    Vn_max_lb = 8.0 * λ * sqrt_fc * Acv_in2
    Vn_lb = min(Vn_lb, Vn_max_lb)

    lb_to_N = 4.4482216
    return (Vn = Vn_lb * lb_to_N,
            ϕVn = WALL_PHI_SHEAR * Vn_lb * lb_to_N,
            Vn_max = Vn_max_lb * lb_to_N,
            αc = αc)
end

# ------------------------------------------------------------------------------
# Material resolution for the in-plane shear check
# ------------------------------------------------------------------------------
# fyt is the specified yield strength of the TRANSVERSE (horizontal) web
# reinforcement in ACI 318-19 Eq. (11.5.4.3):  Vn = (αc·λ·√f'c + ρt·fyt)·Acv
# (corpus: aci-318-19 §11.5.4.3, page 172). It is a MATERIAL input, not a
# design default — resolve it from the wall material and fail closed if missing.

"""
    _wall_shear_materials(material; fyt=nothing) -> (fc, fyt, λ) [Pa, Pa, -]

Resolve `(f'c, fyt, λ)` for the in-plane shear check. `fyt` is the yield strength
of the TRANSVERSE (horizontal) web reinforcement per ACI 318-19 §11.5.4.3, which
is distinct from the vertical/longitudinal grade used by the flexure checks.

A `ReinforcedConcreteMaterial` supplies all three: `f'c`/`λ` from its concrete,
`fyt` from its dedicated `transverse` rebar grade (the tie/horizontal-bar steel).
A plain `Concrete` carries no reinforcement, so `fyt=` (a Unitful pressure, e.g.
`60u"ksi"`) MUST be supplied explicitly.

Safety (mirrors `_wall_flexure_materials`): there is NO Grade-60 default — a
missing transverse grade is an error, not a silent assumption. A supplied `fyt`
must be Unitful; bare numbers are rejected to avoid a ksi/Pa unit mismatch that
would scale steel strength by ~7×10⁶ and produce an unconservative capacity.
"""
function _wall_shear_materials(material; fyt=nothing)
    function _to_pa(x, name)
        x isa Unitful.Pressure && return ustrip(u"Pa", x)
        error("wall shear materials: `$name` must be a Unitful pressure " *
              "(e.g. 60u\"ksi\"), not a bare number, to avoid a ksi/Pa unit mismatch.")
    end
    if material isa ReinforcedConcreteMaterial
        fc  = ustrip(u"Pa", material.concrete.fc′)
        λ   = material.concrete.λ
        # Transverse/tie grade drives fyt in ACI 318-19 Eq. (11.5.4.3).
        fytP = fyt === nothing ? ustrip(u"Pa", material.transverse.Fy) : _to_pa(fyt, "fyt")
        return (fc, fytP, λ)
    else
        fc = ustrip(u"Pa", material.fc′)
        λ  = material.λ
        fyt === nothing && error(
            "wall in-plane shear requires a transverse reinforcement yield strength " *
            "fyt (ACI 318-19 §11.5.4.3). Pass a ReinforcedConcreteMaterial (preferred " *
            "— uses its `transverse` grade) or supply `fyt=` (Unitful, e.g. 60u\"ksi\"). " *
            "Refusing to silently default to Grade 60.")
        return (fc, _to_pa(fyt, "fyt"), λ)
    end
end

"""
    check_wall_inplane_shear(ws, material, Vu, hw; fyt=nothing) -> CheckResult

Demand-decoupled in-plane shear check. `Vu` is the factored in-plane shear
demand [N or Unitful force], `hw` the total wall height. `material` is a
`ReinforcedConcreteMaterial` (its `transverse`/tie grade drives `fyt`) or a plain
`Concrete` with `fyt=` supplied explicitly (Unitful). Returns a `CheckResult`
carrying the governing clause so it flows into the report-feedback contract.
"""
function check_wall_inplane_shear(ws::WallSection, material, Vu, hw::Unitful.Length; fyt=nothing)
    # fy = fyt, the transverse reinforcement yield strength resolved from the
    # material — never a hardcoded default (ACI 318-19 §11.5.4.3; corpus:
    # aci-318-19 p.172).
    fc, fy, λ = _wall_shear_materials(material; fyt=fyt)
    lw = ustrip(u"m", ws.lw)
    t  = ustrip(u"m", ws.t)
    hw_m = ustrip(u"m", hw)

    cap = wall_shear_capacity_si(fc, fy, lw, t, ws.ρt, hw_m; λ=λ)
    Vu_N = Vu isa Unitful.Quantity ? ustrip(u"N", Vu) : Float64(Vu)
    ratio = Vu_N / max(cap.ϕVn, 1e-9)
    return CheckResult("in-plane shear", ratio <= 1.0, ratio, Vu_N, cap.ϕVn,
                       "ACI 318-19 11.5.4.3")  # (corpus: sp-wall-shear-strength-flowchart; VERIFY)
end

"""
    check_wall_min_reinforcement(ws; hw=nothing) -> Vector{CheckResult}

Minimum distributed web reinforcement for walls governed by in-plane shear
(ACI 318-19 §11.6.2, applicable where `Vu > 0.5·φ·Vc`):

  - Transverse (horizontal):  `ρt ≥ 0.0025`                          §11.6.2(b)
  - Longitudinal (vertical):  `ρl ≥ max(0.0025, 0.0025 + 0.5·(2.5 − hw/lw)·(ρt − 0.0025))`
                                                                     §11.6.2(a)

`hw` is the total wall height (bare `Real` [m] or `Unitful.Length`). When
omitted, the §11.6.2(a) coupling term collapses to the 0.0025 floor, which is
exact for `hw/lw ≥ 2.5`. For squat walls (`hw/lw < 2.5`) with `ρt > 0.0025` the
longitudinal minimum is raised accordingly.
(corpus: sp-de-shear-wall-aci19 Step 2, sp-structural-wall-reinforcement-design)
"""
function check_wall_min_reinforcement(ws::WallSection;
                                      hw::Union{Nothing,Real,Unitful.Length}=nothing)
    ρt_min = 0.0025
    ρl_min = if hw === nothing
        0.0025
    else
        hw_m = hw isa Unitful.Length ? ustrip(u"m", hw) : Float64(hw)
        lw_m = ustrip(u"m", ws.lw)
        hwlw = lw_m > 0 ? hw_m / lw_m : Inf
        max(0.0025, 0.0025 + 0.5 * (2.5 - hwlw) * (ws.ρt - 0.0025))
    end
    rl = ρl_min / max(ws.ρl, 1e-9)
    rt = ρt_min / max(ws.ρt, 1e-9)
    return [
        CheckResult("min longitudinal reinf ρl", ws.ρl >= ρl_min - 1e-12, rl, ρl_min, ws.ρl,
                    "ACI 318-19 11.6.2(a)"),
        CheckResult("min transverse reinf ρt", ws.ρt >= ρt_min - 1e-12, rt, ρt_min, ws.ρt,
                    "ACI 318-19 11.6.2(b)"),
    ]
end
