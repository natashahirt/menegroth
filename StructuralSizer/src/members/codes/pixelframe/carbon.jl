# ==============================================================================
# PixelFrame Embodied Carbon
# ==============================================================================
# Embodied carbon calculation for PixelFrame sections.
# Reference: Wongsittikan (2024), Eqs. 2.16–2.17.
#
#   carbon = ec · A_c + fiber_ecc · ρ_steel · (dosage · A_c + A_s)  [kgCO₂e/m]
#
# where:
#   ec = 4.57 fc′ + 217  [kgCO₂e/m³]  (linear fit from ASME data, Eq. 2.17)
#   fiber_ecc = 1.4 kgCO₂e/kg          (original Pixelframe.jl, steel fiber + tendon)
#   ρ_steel = 7860 kg/m³               (steel density)
#
# This overrides the standard MinCarbon objective (A × L × ρ × ecc) because
# PixelFrame sections include steel tendon and fiber contributions that the
# generic formula does not capture.
# ==============================================================================

using Unitful

# Steel density for tendon + fiber carbon contributions. Typed once so the
# carbon arithmetic below stays dimensionally clean (kg/m³ × m² = kg/m).
const _STEEL_DENSITY = 7860.0u"kg/m^3"

"""
    pf_concrete_ecc(fc′) -> CarbonPerVolQuantity

Embodied carbon coefficient of concrete as a function of fc′.
Linear fit from ASME data (Wongsittikan 2024, Eq. 2.17).

    ec = 4.57 × fc′ [MPa] + 217  [kgCO₂e/m³]

# Arguments
- `fc′`: Concrete compressive strength (Unitful Pressure)

# Returns
Embodied carbon in `u"kgCO2e/m^3"` (typed `CarbonPerVolQuantity`).
"""
function pf_concrete_ecc(fc′::Pressure)
    fc′_MPa = ustrip(u"MPa", fc′)
    return (4.57 * fc′_MPa + 217.0) * u"kgCO2e/m^3"
end

"""
    pf_carbon_per_meter(s::PixelFrameSection) -> Quantity{Float64, 𝐗/𝐋}

Embodied carbon per unit length of a PixelFrame section [kgCO₂e/m].

Accounts for three contributions:
1. Concrete: ec(fc′) × A_c
2. Steel fiber: fiber_ecc × ρ_steel × dosage × A_c
3. Tendon steel: fiber_ecc × ρ_steel × A_s

Reference: Wongsittikan (2024) Eq. 2.16

# Returns
Typed `kgCO₂e / m` quantity — dimensions flow through Unitful, so the
result composes with a typed length to give a `CarbonMassQuantity` (see
[`objective_value(::MinCarbon, ::PixelFrameSection, …)`](@ref)).
"""
function pf_carbon_per_meter(s::PixelFrameSection)
    A_c       = section_area(s)                                  # m²
    A_s       = s.A_s                                            # m²
    dosage    = s.material.fiber_dosage * u"kg/m^3"              # typed
    fiber_ecc = s.material.fiber_ecc                             # kgCO₂e/kg
    ec        = pf_concrete_ecc(s.material.fc′)                  # kgCO₂e/m³

    carbon_concrete = ec * A_c                                   # kgCO₂e/m
    # (kg/m³ × m² + kg/m³ × m²) × kgCO₂e/kg = kgCO₂e/m
    carbon_steel    = fiber_ecc * (dosage * A_c + _STEEL_DENSITY * A_s)

    return uconvert(u"kgCO2e/m", carbon_concrete + carbon_steel)
end

# ==============================================================================
# MinCarbon objective override for PixelFrameSection
# ==============================================================================

"""
    objective_value(::MinCarbon, s::PixelFrameSection, ::AbstractMaterial, L)
        -> CarbonMassQuantity

PixelFrame-specific embodied carbon objective.

Overrides the generic `A × L × ρ × ecc` formula to include concrete, fiber,
and tendon contributions per Wongsittikan (2024) Eq. 2.16.

Returns total carbon as a typed `kgCO₂e` quantity. The MIP cache builder
calls `ustrip(unit(ref_obj), val)` once when populating `obj_coeffs`, so
the JuMP boundary sees a bare Float64.
"""
function objective_value(::MinCarbon, s::PixelFrameSection, ::AbstractMaterial, L)
    L_q = L isa Unitful.Quantity ? L : Float64(L) * u"m"
    return uconvert(u"kgCO2e", pf_carbon_per_meter(s) * L_q)
end
