# ==============================================================================
# Whitney Stress Block — Required Reinforcement
# ==============================================================================
#
# Element-agnostic flexural reinforcement calculation per ACI 318.
# Works for any rectangular concrete section: beams, slab strips, walls.
# ==============================================================================

"""
    tension_controlled_strain(fy; Es=29000 ksi) -> Float64

Net tensile strain at which a section is tension-controlled.

ACI 318-11 §10.3.4 (corpus: aci-318-11, page 142): εt ≥ 0.005 when the
concrete reaches its 0.003 strain limit. The limit does not depend on `fy`.
`fy` and `Es` are accepted because the slab loop passes them.
"""
function tension_controlled_strain(fy::Pressure; Es::Pressure = 29_000.0u"ksi")
    return 0.005
end

"""
    required_reinforcement(Mu, b, d, fc, fy) -> Area

Required tension steel area from Whitney stress block equilibrium.

Uses the quadratic solution for As from moment equilibrium:
    As = (0.85·f'c·b·d / fy) × (1 - √(1 - 2Rn/(0.85·f'c)))

where Rn = Mu / (φ·b·d²), φ = 0.9 by default (`φ` keyword; footings pass
their `ϕ_flexure` option).

With `require_tension_controlled = true` (default) the section must be
tension-controlled for that φ: εt ≥ 0.005, with c = a/β₁ and
εt = 0.003(d − c)/c.  A section that is not is reported as inadequate
(`Inf`), the same as one whose demand exceeds the stress block, so the caller
adds depth.  Pass `false` only when the caller computes εt and φ itself
(beam designers using `flexure_phi`).

# Arguments
- `Mu`: Factored moment demand
- `b`: Section width (or strip width for slabs)
- `d`: Effective depth (h - cover - db/2)
- `fc`: Concrete compressive strength
- `fy`: Steel yield strength

# Returns
Required steel area As (with units). Returns `Inf * u"m^2"` if the section is
inadequate (demand exceeds the stress block, or εt < 0.005) — caller should
increase depth.

# Reference
- ACI 318-11 §10.2.7.1 (corpus: aci-318-11, page 140): 0.85 f'c over a = β₁c
- ACI 318-11 §10.3.4 (corpus: aci-318-11, page 142): tension-controlled at εt ≥ 0.005
- ACI 318-11 §9.3.2.1: φ = 0.90 for tension-controlled sections
- Supplementary Document Section 1.7 (Setareh & Darvas derivation)
"""
function required_reinforcement(Mu::Moment, b::Length, d::Length, fc::Pressure, fy::Pressure;
                                require_tension_controlled::Bool = true,
                                φ::Float64 = 0.9, εt_min::Float64 = 0.005)

    # Resistance coefficient Rn = Mu/(φ·b·d²) — has units of pressure
    Rn = Mu / (φ * b * d^2)

    term = uconvert(NoUnits, 2 * Rn / (0.85 * fc))
    term > 1.0 && return Inf * u"m^2"

    # Mechanical ratio ω = ρ·fy/f'c = 0.85·a/d
    ω = 0.85 * (1 - sqrt(1 - term))

    if require_tension_controlled && ω > 0
        c_over_d = (ω / 0.85) / beta1(fc)
        εt = 0.003 * (1 - c_over_d) / c_over_d
        # Tolerance so a demand exactly at the εt_min capacity is not rejected by roundoff.
        # Default εt_min is ACI 318-11 §10.3.4 (corpus: aci-318-11, page 142).
        εt < εt_min - 1e-12 && return Inf * u"m^2"
    end

    return ω * fc / fy * b * d
end
