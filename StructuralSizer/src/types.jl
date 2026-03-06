"""Tag types for metal dispatch: structural steel vs. rebar."""
abstract type MetalType end
struct StructuralSteelType <: MetalType end
struct RebarType <: MetalType end

"""
    Metal{K, T_P, T_D} <: AbstractMaterial

Parametric metal material with elastic properties, strength limits, and embodied carbon.

`K` selects the metal category (`StructuralSteelType` or `RebarType`) for dispatch;
`T_P` is the pressure/stress unit type and `T_D` the density unit type.
"""
struct Metal{K<:MetalType, T_P, T_D} <: AbstractMaterial
    E::T_P      # Young's modulus
    G::T_P      # Shear modulus
    Fy::T_P     # Yield strength
    Fu::T_P     # Ultimate strength
    ρ::T_D      # Density
    ν::Float64  # Poisson's ratio
    ecc::Float64  # Embodied carbon [kgCO₂e/kg]
end

const StructuralSteel{T_P, T_D} = Metal{StructuralSteelType, T_P, T_D}
const RebarSteel{T_P, T_D} = Metal{RebarType, T_P, T_D}

StructuralSteel(E, G, Fy, Fu, ρ, ν, ecc) = Metal{StructuralSteelType, typeof(E), typeof(ρ)}(E, G, Fy, Fu, ρ, Float64(ν), Float64(ecc))
RebarSteel(E, G, Fy, Fu, ρ, ν, ecc) = Metal{RebarType, typeof(E), typeof(ρ)}(E, G, Fy, Fu, ρ, Float64(ν), Float64(ecc))

"""
    Concrete{T_P, T_D} <: AbstractMaterial

Concrete material with compressive strength, density, and embodied carbon coefficient.
"""
struct Concrete{T_P, T_D} <: AbstractMaterial
    E::T_P      # Young's modulus
    fc′::T_P    # Compressive strength
    ρ::T_D      # Density
    ν::Float64  # Poisson's ratio
    ecc::Float64  # Embodied carbon [kgCO₂e/kg]
end

function Concrete(E, fc′, ρ, ν, ecc)
    Concrete{typeof(E), typeof(ρ)}(E, fc′, ρ, Float64(ν), Float64(ecc))
end
