# ==============================================================================
# ACI 318-19 Material Property Utilities
# ==============================================================================
# Unified material property functions for ACI concrete design.
# Consolidates beta1, Ec, fr, and material extractors in one place.
#
# These functions work with:
# - Concrete (plain concrete)
# - ReinforcedConcreteMaterial (concrete + rebar)
# - NamedTuple (legacy/testing support)
# ==============================================================================

using Unitful
using Asap: ksi, to_ksi

# ==============================================================================
# Whitney Stress Block Factor (β₁)
# ==============================================================================

"""
    beta1(mat) -> Float64

Whitney stress block factor β₁ per ACI 318-19 Table 22.2.2.4.3.

- β₁ = 0.85 for f'c ≤ 4 ksi
- β₁ = 0.85 - 0.05(f'c - 4) for 4 < f'c < 8 ksi
- β₁ = 0.65 for f'c ≥ 8 ksi

# Arguments
- `mat`: Concrete, ReinforcedConcreteMaterial, or NamedTuple with `fc` field

# Returns
- β₁ factor (dimensionless, 0.65 to 0.85)
"""
function beta1(mat::Concrete)
    fc_ksi = to_ksi(mat.fc′)
    _beta1_from_fc(fc_ksi)
end

beta1(mat::ReinforcedConcreteMaterial) = beta1(mat.concrete)
beta1(mat::NamedTuple) = _beta1_from_fc(mat.fc)  # Legacy: fc already in ksi

function _beta1_from_fc(fc_ksi::Real)
    if fc_ksi ≤ 4.0
        return 0.85
    elseif fc_ksi ≥ 8.0
        return 0.65
    else
        return 0.85 - 0.05 * (fc_ksi - 4.0)
    end
end

# ==============================================================================
# Concrete Elastic Modulus (Ec)
# ==============================================================================
# ACI 318-19 (19.2.2.1.b): Ec = 57000 × √(f'c in psi)
#
# IMPORTANT: All functions accept Unitful quantities or typed materials.
# The formula is unit-safe - just convert f'c to psi, apply formula, return with units.
# This prevents the bug of forgetting conversion factors like √1000.
# ==============================================================================

"""
    Ec(fc::Unitful.Pressure) -> Unitful.Pressure

Concrete elastic modulus per ACI 318-19 (19.2.2.1.b).
For normal-weight concrete: Ec = 57000 × √(f'c in psi)

Accepts f'c in ANY pressure unit (psi, ksi, MPa, etc.) - Unitful handles conversion.

# Example
```julia
Ec(4.0u"ksi")   # Returns ~3605 ksi
Ec(27.6u"MPa")  # Returns ~24.9 GPa (same concrete, metric)
```
"""
function Ec(fc::Unitful.Pressure)
    fc_psi = ustrip(u"psi", fc)
    return 57000 * sqrt(fc_psi) * u"psi"
end

# Material type dispatches
Ec(mat::Concrete) = Ec(mat.fc′)
Ec(mat::ReinforcedConcreteMaterial) = Ec(mat.concrete)

"""
    Ec_ksi(mat) -> Float64

Concrete elastic modulus in ksi (stripped of units).
Convenience function for internal calculations that need dimensionless values.
"""
Ec_ksi(mat::Concrete) = ustrip(ksi, Ec(mat))
Ec_ksi(mat::ReinforcedConcreteMaterial) = Ec_ksi(mat.concrete)
# For legacy NamedTuple: fc is assumed to be in ksi (dimensionless)
# We construct a proper Unitful quantity, apply the formula, then strip
Ec_ksi(mat::NamedTuple) = ustrip(ksi, Ec(mat.fc * ksi))

# ==============================================================================
# Modulus of Rupture (fr)
# ==============================================================================

"""
    fr(mat) -> Quantity

Modulus of rupture for deflection calculations per ACI 318-19 (19.2.3.1).
For normal-weight concrete: fr = 7.5 √f'c (psi)

# Arguments
- `mat`: Concrete or ReinforcedConcreteMaterial

# Returns
- fr with units (psi)
"""
function fr(mat::Concrete)
    fc_psi = ustrip(u"psi", mat.fc′)
    return 7.5 * sqrt(fc_psi) * u"psi"
end

fr(mat::ReinforcedConcreteMaterial) = fr(mat.concrete)

# ==============================================================================
# Material Property Extractors (in ksi for ACI calculations)
# ==============================================================================
# These provide a unified interface for P-M calculations regardless of
# whether the input is Concrete, ReinforcedConcreteMaterial, or NamedTuple.

"""Extract concrete compressive strength f'c in ksi."""
fc_ksi(mat::Concrete) = to_ksi(mat.fc′)
fc_ksi(mat::ReinforcedConcreteMaterial) = fc_ksi(mat.concrete)
fc_ksi(mat::NamedTuple) = Float64(mat.fc)  # Already in ksi

"""Extract rebar yield strength fy in ksi."""
fy_ksi(mat::ReinforcedConcreteMaterial) = to_ksi(mat.rebar.Fy)
fy_ksi(mat::RebarSteel) = to_ksi(mat.Fy)  # Direct rebar material
fy_ksi(mat::NamedTuple) = Float64(mat.fy)  # Already in ksi

"""Extract rebar elastic modulus Es in ksi."""
Es_ksi(mat::ReinforcedConcreteMaterial) = to_ksi(mat.rebar.E)
Es_ksi(mat::RebarSteel) = to_ksi(mat.E)  # Direct rebar material
Es_ksi(mat::NamedTuple) = haskey(mat, :Es) ? Float64(mat.Es) : 29000.0

"""Extract ultimate compressive strain εcu."""
εcu(mat::Concrete) = mat.εcu
εcu(mat::ReinforcedConcreteMaterial) = εcu(mat.concrete)
εcu(mat::NamedTuple) = haskey(mat, :εcu) ? Float64(mat.εcu) : 0.003

# ==============================================================================
# Material Tuple Builder (for legacy compatibility)
# ==============================================================================

"""
    to_material_tuple(mat::ReinforcedConcreteMaterial) -> NamedTuple

Convert ReinforcedConcreteMaterial to a NamedTuple for legacy P-M functions.
This allows gradual migration while maintaining backward compatibility.

Returns NamedTuple with: (fc, fy, Es, εcu)
"""
function to_material_tuple(mat::ReinforcedConcreteMaterial)
    (
        fc = fc_ksi(mat),
        fy = fy_ksi(mat),
        Es = Es_ksi(mat),
        εcu = εcu(mat)
    )
end

function to_material_tuple(mat::Concrete, rebar_fy_ksi::Real=60.0, rebar_Es_ksi::Real=29000.0)
    (
        fc = fc_ksi(mat),
        fy = Float64(rebar_fy_ksi),
        Es = Float64(rebar_Es_ksi),
        εcu = εcu(mat)
    )
end

# Pass through if already a NamedTuple
to_material_tuple(mat::NamedTuple) = mat
