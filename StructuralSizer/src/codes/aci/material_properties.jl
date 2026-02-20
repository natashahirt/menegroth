# ==============================================================================
# ACI 318-11 Material Property Utilities
# ==============================================================================
#
# Consolidated material property functions for all ACI concrete design:
# beams, columns, slabs, foundations.
#
# Dispatch hierarchy:
#   Pressure    → raw f'c value (used by slabs, standalone calculations)
#   Concrete    → material type (used by member design)
#   ReinforcedConcreteMaterial → composite material (concrete + rebar)
#   NamedTuple  → legacy/testing support
#
# Unified ACI material property dispatch.
# ==============================================================================

using Unitful
using Asap: ksi, to_ksi

# ==============================================================================
# Whitney Stress Block Factor (β₁)
# ==============================================================================

"""
    beta1(fc::Pressure) -> Float64
    beta1(mat::Concrete) -> Float64
    beta1(mat::ReinforcedConcreteMaterial) -> Float64
    beta1(mat::NamedTuple) -> Float64

Whitney stress block factor β₁ per ACI 318-11 §10.2.7.3.

- β₁ = 0.85 for f'c ≤ 4 ksi (4000 psi)
- β₁ = 0.85 - 0.05(f'c - 4)/1 for 4 < f'c < 8 ksi
- β₁ = 0.65 for f'c ≥ 8 ksi

Accepts Unitful pressure quantities or typed materials.
"""
function beta1(fc::Unitful.Pressure)
    fc_psi = ustrip(u"psi", fc)
    _beta1_from_fc_psi(fc_psi)
end

beta1(mat::Concrete)                    = beta1(mat.fc′)
beta1(mat::ReinforcedConcreteMaterial)  = beta1(mat.concrete)
beta1(mat::NamedTuple)                  = _beta1_from_fc_ksi(mat.fc)  # Legacy: fc in ksi

function _beta1_from_fc_psi(fc_psi::Real)
    if fc_psi ≤ 4000
        return 0.85
    elseif fc_psi ≥ 8000
        return 0.65
    else
        return 0.85 - 0.05 * (fc_psi - 4000) / 1000
    end
end

function _beta1_from_fc_ksi(fc_ksi::Real)
    if fc_ksi ≤ 4.0
        return 0.85
    elseif fc_ksi ≥ 8.0
        return 0.65
    else
        return 0.85 - 0.05 * (fc_ksi - 4.0)
    end
end

"""Alias so existing slab code that calls `β1(fc)` keeps working."""
const β1 = beta1

# ==============================================================================
# Concrete Elastic Modulus (Ec)
# ==============================================================================

"""
    Ec(fc::Pressure) -> Pressure
    Ec(fc::Pressure, wc_pcf::Real) -> Pressure
    Ec(mat::Concrete) -> Pressure
    Ec(mat::ReinforcedConcreteMaterial) -> Pressure

Concrete elastic modulus per ACI 318-11 §8.5.1.

**Two formulas available:**
- `Ec(fc)` — Simplified formula (19.2.2.1.b) for normal-weight concrete:
  `Ec = 57000 √f'c` (equivalent to wc ≈ 144 pcf)
- `Ec(fc, wc_pcf)` — General formula (19.2.2.1.a) for any unit weight:
  `Ec = 33 × wc^1.5 × √f'c` (wc in pcf, f'c in psi → Ec in psi)

StructurePoint uses the general formula with wc = 150 pcf, which gives
~6% higher Ec than the simplified formula (3998 vs 3759 ksi for f'c = 4350 psi).

# Examples
```julia
Ec(4000u"psi")        # ≈ 3,605 ksi  (simplified, wc ≈ 144 pcf)
Ec(4000u"psi", 150)   # ≈ 3,834 ksi  (general, wc = 150 pcf)
Ec(4350u"psi", 150)   # ≈ 3,998 ksi  (StructurePoint reference value)
```
"""
function Ec(fc::Unitful.Pressure)
    fc_psi = ustrip(u"psi", fc)
    return 57000 * sqrt(fc_psi) * u"psi"
end

"""
    Ec(fc, wc_pcf) -> Pressure

General Ec formula per ACI 318-11 §8.5.1:
    Ec = 33 × wc^1.5 × √f'c

where `wc_pcf` is concrete unit weight in lb/ft³ (pcf) as a bare number.

This is the formula used by StructurePoint and is more accurate than the
simplified 57000√f'c when wc ≠ 144 pcf.
"""
function Ec(fc::Unitful.Pressure, wc_pcf::Real)
    fc_psi = ustrip(u"psi", fc)
    return (33.0 * wc_pcf^1.5 * sqrt(fc_psi)) * u"psi"
end

Ec(mat::Concrete)                    = Ec(mat.fc′)
Ec(mat::ReinforcedConcreteMaterial)  = Ec(mat.concrete)

"""
    Ec_ksi(mat) -> Float64

Concrete elastic modulus in ksi (stripped of units).
Convenience for internal calculations that need dimensionless values.
"""
Ec_ksi(mat::Concrete)                    = ustrip(ksi, Ec(mat))
Ec_ksi(mat::ReinforcedConcreteMaterial)  = Ec_ksi(mat.concrete)
Ec_ksi(mat::NamedTuple)                  = ustrip(ksi, Ec(mat.fc * ksi))

# ==============================================================================
# Modulus of Rupture (fr)
# ==============================================================================

"""
    fr(fc::Pressure) -> Pressure
    fr(mat::Concrete) -> Pressure
    fr(mat::ReinforcedConcreteMaterial) -> Pressure

Modulus of rupture per ACI 318-11 §9.5.2.3.
For normal-weight concrete: fr = 7.5 √f'c (psi units)

# Example
```julia
fr(4000u"psi")  # ≈ 474 psi
```
"""
function fr(fc::Unitful.Pressure)
    fc_psi = ustrip(u"psi", fc)
    return 7.5 * sqrt(fc_psi) * u"psi"
end

fr(mat::Concrete)                    = fr(mat.fc′)
fr(mat::ReinforcedConcreteMaterial)  = fr(mat.concrete)

# ==============================================================================
# Material Property Extractors (dimensionless, in ksi)
# ==============================================================================
# Unified interface for P-M calculations regardless of input type.

"""Extract concrete compressive strength f'c in ksi."""
fc_ksi(mat::Concrete)                    = to_ksi(mat.fc′)
fc_ksi(mat::ReinforcedConcreteMaterial)  = fc_ksi(mat.concrete)
fc_ksi(mat::NamedTuple)                  = Float64(mat.fc)  # Already in ksi

"""Extract rebar yield strength fy in ksi."""
fy_ksi(mat::ReinforcedConcreteMaterial)  = to_ksi(mat.rebar.Fy)
fy_ksi(mat::RebarSteel)                  = to_ksi(mat.Fy)
fy_ksi(mat::NamedTuple)                  = Float64(mat.fy)

"""Extract rebar elastic modulus Es in ksi."""
Es_ksi(mat::ReinforcedConcreteMaterial)  = to_ksi(mat.rebar.E)
Es_ksi(mat::RebarSteel)                  = to_ksi(mat.E)
Es_ksi(mat::NamedTuple)                  = haskey(mat, :Es) ? Float64(mat.Es) : error("NamedTuple material missing :Es field")

"""Extract ultimate compressive strain εcu."""
εcu(mat::Concrete)                    = mat.εcu
εcu(mat::ReinforcedConcreteMaterial)  = εcu(mat.concrete)
εcu(mat::NamedTuple)                  = haskey(mat, :εcu) ? Float64(mat.εcu) : error("NamedTuple material missing :εcu field")

# ==============================================================================
# Material Tuple Builder (legacy compatibility)
# ==============================================================================

"""
    to_material_tuple(mat::ReinforcedConcreteMaterial) -> NamedTuple
    to_material_tuple(mat::Concrete, rebar_fy_ksi, rebar_Es_ksi) -> NamedTuple

Convert typed material to NamedTuple `(fc, fy, Es, εcu)` for legacy P-M functions.
Rebar properties are required — pass from the user's rebar material.
"""
function to_material_tuple(mat::ReinforcedConcreteMaterial)
    (fc = fc_ksi(mat), fy = fy_ksi(mat), Es = Es_ksi(mat), εcu = εcu(mat))
end

function to_material_tuple(mat::Concrete, rebar_fy_ksi::Real, rebar_Es_ksi::Real)
    (fc = fc_ksi(mat), fy = Float64(rebar_fy_ksi), Es = Float64(rebar_Es_ksi), εcu = εcu(mat))
end

to_material_tuple(mat::NamedTuple) = mat
