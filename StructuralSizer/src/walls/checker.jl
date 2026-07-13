# ==============================================================================
# Concrete Structural Wall — In-Plane Shear Strength (ACI 318-19 §11.5.4)
# ==============================================================================
# A demand-decoupled capacity checker (plan S1, todo `wall-stiffness-contract`:
# "keep checker decoupled from demand source"). Capacity functions take only the
# section + material; demand is supplied separately by the caller (input in S1,
# rigid-diaphragm distribution in S2, or FEM in S3). This decoupling is what lets
# the same checker serve every demand tier.
#
# Code basis (VERIFY clause/page against the extracted corpus before production):
#   - In-plane shear strength: ACI 318-19 §11.5.4.3
#         Vn = (αc·λ·√f'c + ρt·fy)·Acv                 [psi, in]
#     with αc = 3.0 (hw/lw ≤ 1.5), 2.0 (hw/lw ≥ 2.0), linear between.
#     (corpus: sp-wall-shear-strength-flowchart)
#   - Upper limit: ACI 318-19 §11.5.4.2   Vn ≤ 10·√f'c·Acv
#   - Minimum web reinforcement: ACI 318-19 §11.6.2 (ρl, ρt ≥ 0.0025)
#     (corpus: sp-structural-wall-reinforcement-design, sp-flowchart-governing-reinforcement)
#   - φ (shear) = 0.75  (ACI 318-19 §21.2.1)
#   - Validation oracle: StructurePoint spWall shear wall worked example
#     (corpus: sp-de-shear-wall-aci19)

using Unitful

"""φ factor for shear in walls (ACI 318-19 §21.2.1; VERIFY)."""
const WALL_PHI_SHEAR = 0.75

"""
    wall_alpha_c(hw_over_lw) -> Float64

Coefficient αc for in-plane shear (ACI 318-19 §11.5.4.3): 3.0 for
`hw/lw ≤ 1.5`, 2.0 for `hw/lw ≥ 2.0`, linear in between. `hw` is the total wall
height, `lw` the wall length. (corpus: sp-wall-shear-strength-flowchart; VERIFY)
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
§11.5.4.2 cap; computed in psi/in internally then converted. (VERIFY)
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

    # ACI 318-19 §11.5.4.3 (corpus: sp-wall-shear-strength-flowchart; VERIFY)
    Vn_lb = (αc * λ * sqrt_fc + ρt * fy_psi) * Acv_in2
    # ACI 318-19 §11.5.4.2 upper bound (corpus: sp-wall-shear-strength-flowchart; VERIFY)
    Vn_max_lb = 10.0 * sqrt_fc * Acv_in2
    Vn_lb = min(Vn_lb, Vn_max_lb)

    lb_to_N = 4.4482216
    return (Vn = Vn_lb * lb_to_N,
            ϕVn = WALL_PHI_SHEAR * Vn_lb * lb_to_N,
            Vn_max = Vn_max_lb * lb_to_N,
            αc = αc)
end

"""
    check_wall_inplane_shear(ws, concrete, Vu, hw) -> CheckResult

Demand-decoupled in-plane shear check. `Vu` is the factored in-plane shear
demand [N or Unitful force], `hw` the total wall height. Returns a `CheckResult`
carrying the governing clause so it flows into the report-feedback contract.
"""
function check_wall_inplane_shear(ws::WallSection, concrete, Vu, hw::Unitful.Length)
    fc = ustrip(u"Pa", concrete.fc′)
    fy_psi = 60_000.0  # ENGINEERING JUDGMENT: default Grade-60 transverse steel; TODO wire rebar material
    fy = fy_psi * 6894.757
    lw = ustrip(u"m", ws.lw)
    t  = ustrip(u"m", ws.t)
    hw_m = ustrip(u"m", hw)
    λ = concrete.λ

    cap = wall_shear_capacity_si(fc, fy, lw, t, ws.ρt, hw_m; λ=λ)
    Vu_N = Vu isa Unitful.Quantity ? ustrip(u"N", Vu) : Float64(Vu)
    ratio = Vu_N / max(cap.ϕVn, 1e-9)
    return CheckResult("in-plane shear", ratio <= 1.0, ratio, Vu_N, cap.ϕVn,
                       "ACI 318-19 11.5.4.3")  # (corpus: sp-wall-shear-strength-flowchart; VERIFY)
end

"""
    check_wall_min_reinforcement(ws) -> Vector{CheckResult}

Minimum longitudinal/transverse web reinforcement per ACI 318-19 §11.6.2
(ρ ≥ 0.0025). (corpus: sp-structural-wall-reinforcement-design; VERIFY)
"""
function check_wall_min_reinforcement(ws::WallSection)
    ρ_min = 0.0025
    rl = ρ_min / max(ws.ρl, 1e-9)
    rt = ρ_min / max(ws.ρt, 1e-9)
    return [
        CheckResult("min longitudinal reinf ρl", ws.ρl >= ρ_min, rl, ρ_min, ws.ρl,
                    "ACI 318-19 11.6.2"),
        CheckResult("min transverse reinf ρt", ws.ρt >= ρ_min, rt, ρ_min, ws.ρt,
                    "ACI 318-19 11.6.2"),
    ]
end
