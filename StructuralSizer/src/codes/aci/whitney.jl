# ==============================================================================
# Whitney Stress Block — Required Reinforcement
# ==============================================================================
#
# Element-agnostic flexural reinforcement calculation per ACI 318.
# Works for any rectangular concrete section: beams, slab strips, walls.
# ==============================================================================

"""
    required_reinforcement(Mu, b, d, fc, fy) -> Area

Required tension steel area from Whitney stress block equilibrium.

Uses the quadratic solution for As from moment equilibrium:
    As = (β₁·f'c·b·d / fy) × (1 - √(1 - 2Rn/(β₁·f'c)))

where Rn = Mu / (φ·b·d²)

# Arguments
- `Mu`: Factored moment demand
- `b`: Section width (or strip width for slabs)
- `d`: Effective depth (h - cover - db/2)
- `fc`: Concrete compressive strength
- `fy`: Steel yield strength

# Returns
Required steel area As (with units). Returns `Inf * u"m^2"` if the section is
inadequate (demand exceeds capacity) — caller should increase depth.

# Reference
- ACI 318-11 §10.2.7 (Whitney rectangular stress block)
- Supplementary Document Section 1.7 (Setareh & Darvas derivation)
"""
function required_reinforcement(Mu::Moment, b::Length, d::Length, fc::Pressure, fy::Pressure)
    φ = 0.9  # Tension-controlled section (ACI 21.2.2)

    # Resistance coefficient Rn = Mu/(φ·b·d²) — has units of pressure
    Rn = Mu / (φ * b * d^2)

    # Stress block factor
    β = beta1(fc)

    # Required steel ratio (from quadratic solution)
    term = 2 * Rn / (β * fc)  # dimensionless
    if term > 1.0
        # Section inadequate: demand exceeds capacity. Return sentinel.
        return Inf * u"m^2"
    end

    # Check if section is tension-controlled (ACI limits)
    # Rn_max corresponds to the tension-controlled strain limit εt = 0.005
    Rn_max = 0.319 * β * fc
    if Rn > Rn_max
        ratio = ustrip(Rn / Rn_max)
        @warn "Section not tension-controlled (Rn/Rn_max=$(round(ratio, digits=2))). " *
              "φ=0.9 is unconservative; section needs more depth or the pipeline " *
              "should have caught this. Rn=$(round(ustrip(u"psi", Rn), digits=1)) psi, " *
              "Rn_max=$(round(ustrip(u"psi", Rn_max), digits=1)) psi"
    end

    ρ = (β * fc / fy) * (1 - sqrt(1 - term))  # dimensionless

    # Required area: As = ρ·b·d
    return ρ * b * d
end
