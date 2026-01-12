# Metal inherits AbstractMaterial from StructuralBase
struct Metal{T_P, T_D} <: AbstractMaterial
    E::T_P   # Young's modulus
    G::T_P   # Shear modulus
    Fy::T_P  # Yield strength
    Fu::T_P  # Ultimate strength
    ρ::T_D   # Density
    ν::Float64 # Poisson's ratio (unitless)
end

# Outer constructor
function Metal(E, G, Fy, Fu, ρ, ν)
    return Metal{typeof(E), typeof(ρ)}(E, G, Fy, Fu, ρ, Float64(ν))
end