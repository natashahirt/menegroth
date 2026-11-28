# ==============================================================================
# Shear friction across a monolithic joint (ACI 318-19 §22.9)
# ==============================================================================
# Demand-decoupled, same pattern as the in-plane shear checker. The caller
# supplies Ac and Avf. This file does not decide what those areas are for a
# wall corner.

"""
    monolithic_shear_friction_si(fc, fy, Ac, Avf; λ=1.0) -> NamedTuple

Nominal and design shear-friction strength of a monolithic cast-in-place
joint, in newtons.

`fc` and `fy` are pascals. `Ac` and `Avf` are square metres. Returns
`(μ, Vn, ϕVn, Vn_max)`.

The reinforcement is taken as perpendicular to the shear plane, so

    Vn = μ · Avf · fy

with `μ = 1.4λ` for concrete placed monolithically. `fy` used in design
shall not exceed 60,000 psi. `λ` of lightweight concrete shall not exceed
0.85; normalweight uses `λ = 1.0` and is not reduced.

`Vn` shall not exceed the Table 22.9.4.4 limit. Normalweight monolithic
concrete uses the least of `0.2 f'c Ac`, `(480 + 0.08 f'c) Ac`, and
`1600 Ac` (psi, in). Lightweight concrete uses the other-cases limit, the
lesser of `0.2 f'c Ac` and `800 Ac`.

Permanent compression is not added. §22.9.4.5 permits it and does not
require it. Net tension across the plane is not added; the caller passes
the shear it wants checked.

# Citations
ACI 318-19 §22.9.4.2 and Eq. (22.9.4.2) (corpus: aci-318-19, PDF page 434).
Table 22.9.4.2(a), monolithic `μ = 1.4λ` (PDF page 434).
Table 22.9.4.4 (PDF page 435).
§22.9.1.3 and Table 20.2.2.4(a), shear-friction `fy` ≤ 60,000 psi
(PDF page 378).
`φ = 0.75` for shear, §21.2.1.
"""
function monolithic_shear_friction_si(fc::Real, fy::Real, Ac::Real, Avf::Real; λ::Real=1.0)
    fc > 0 || throw(ArgumentError("shear friction: f'c must be positive."))
    Ac > 0 || throw(ArgumentError("shear friction: Ac must be positive."))
    Avf >= 0 || throw(ArgumentError("shear friction: Avf must be non-negative."))
    λ > 0 || throw(ArgumentError("shear friction: λ must be positive."))

    fc_psi = fc / Asap.PSI_TO_PA
    # ACI 318-19 §22.9.1.3 / Table 20.2.2.4(a) (corpus: aci-318-19, PDF page 378).
    fy_psi = min(fy / Asap.PSI_TO_PA, 60_000.0)
    Ac_in2 = Ac / Asap.IN_TO_M^2
    Avf_in2 = Avf / Asap.IN_TO_M^2

    # Table 22.9.4.2, note [1]: λ shall not exceed 0.85. Normalweight is 1.0
    # and is the row this function implements for λ ≥ 1. A larger λ is not
    # used to raise μ.
    normalweight = λ >= 1.0
    λ_use = normalweight ? 1.0 : min(Float64(λ), 0.85)
    # Table 22.9.4.2(a) (corpus: aci-318-19, PDF page 434): monolithic μ = 1.4λ.
    μ = 1.4 * λ_use

    # Eq. (22.9.4.2): reinforcement perpendicular to the shear plane.
    Vn_lb = μ * Avf_in2 * fy_psi
    # Table 22.9.4.4 (corpus: aci-318-19, PDF page 435). 480, 800, and 1600
    # are psi. Lightweight is not the normalweight row.
    if normalweight
        Vn_max_lb = min(0.2 * fc_psi * Ac_in2,
                        (480.0 + 0.08 * fc_psi) * Ac_in2,
                        1600.0 * Ac_in2)
    else
        Vn_max_lb = min(0.2 * fc_psi * Ac_in2, 800.0 * Ac_in2)
    end
    Vn_lb = min(Vn_lb, Vn_max_lb)

    to_N = Asap.LBF_TO_N
    return (μ = μ,
            Vn = Vn_lb * to_N,
            ϕVn = WALL_PHI_SHEAR * Vn_lb * to_N,
            Vn_max = Vn_max_lb * to_N)
end

"""
    check_monolithic_shear_friction(fc, fy, Ac, Avf, Vu; λ=1.0) -> CheckResult

`φVn ≥ Vu` for [`monolithic_shear_friction_si`](@ref). `Vu` is newtons.
The clause on the result is ACI 318-19 §22.9.4.2; the upper bound inside
the capacity is Table 22.9.4.4.

# Citation
ACI 318-19 §22.9.3.1 (corpus: aci-318-19, PDF page 433): `φVn ≥ Vu`.
"""
function check_monolithic_shear_friction(fc::Real, fy::Real, Ac::Real, Avf::Real, Vu::Real;
                                        λ::Real=1.0)
    cap = monolithic_shear_friction_si(fc, fy, Ac, Avf; λ=λ)
    demand = abs(Float64(Vu))
    ratio = cap.ϕVn > 0 ? demand / cap.ϕVn : (demand == 0 ? 0.0 : Inf)
    return CheckResult(
        "shear friction",
        demand <= cap.ϕVn + 1e-6,
        ratio,
        demand,
        cap.ϕVn,
        "ACI 318-19 22.9.4.2")
end
