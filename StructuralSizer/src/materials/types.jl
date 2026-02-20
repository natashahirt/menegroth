# =============================================================================
# Material Type Definitions
# =============================================================================
#
# All material types that inherit from AbstractMaterial (defined in types.jl).
# Presets (specific material instances) are in separate files:
#   - steel.jl    → A992_Steel, S355_Steel, Rebar_*
#   - concrete.jl → NWC_4000, NWC_6000, etc.
#   - timber.jl   → (future presets)
#
# =============================================================================

# =============================================================================
# Material Name Registry
# =============================================================================
# Maps material instances to display names via objectid lookup.
# register_material! is called after each const preset definition.

const MATERIAL_NAME_REGISTRY = Dict{UInt, String}()

"""Register a material preset with its display name."""
register_material!(mat, name::String) = (MATERIAL_NAME_REGISTRY[objectid(mat)] = name; nothing)

"""Get short display name for any material. Falls back to type-specific formatting."""
function material_name(mat::AbstractMaterial)
    get(MATERIAL_NAME_REGISTRY, objectid(mat)) do
        _fallback_material_name(mat)
    end
end

# =============================================================================
# Metal (Steel)
# =============================================================================

# Type tags for dispatch (structural steel vs rebar)
abstract type MetalType end
struct StructuralSteelType <: MetalType end
struct RebarType <: MetalType end

"""
    Metal{K<:MetalType, T_P, T_D} <: AbstractMaterial

Parametric metal type supporting different steel categories via type tags.

# Type Parameters
- `K`: MetalType tag (StructuralSteelType or RebarType)
- `T_P`: Pressure unit type (e.g., typeof(1.0u"GPa"))
- `T_D`: Density unit type (e.g., typeof(1.0u"kg/m^3"))

# Fields
- `E`: Young's modulus
- `G`: Shear modulus
- `Fy`: Yield strength
- `Fu`: Ultimate strength
- `ρ`: Density
- `ν`: Poisson's ratio
- `ecc`: Embodied carbon [kgCO₂e/kg]
- `cost`: Unit cost [\$/kg] (NaN if not set; required for MinCost optimization)
"""
struct Metal{K<:MetalType, T_P, T_D} <: AbstractMaterial
    E::T_P      # Young's modulus
    G::T_P      # Shear modulus
    Fy::T_P     # Yield strength
    Fu::T_P     # Ultimate strength
    ρ::T_D      # Density
    ν::Float64  # Poisson's ratio
    ecc::Float64  # Embodied carbon [kgCO₂e/kg]
    cost::Float64 # Unit cost [$/kg] (NaN = not set)
end

# Type aliases for convenience
const StructuralSteel{T_P, T_D} = Metal{StructuralSteelType, T_P, T_D}
const RebarSteel{T_P, T_D} = Metal{RebarType, T_P, T_D}

# Constructors (cost is keyword-only, defaults to NaN)
StructuralSteel(E, G, Fy, Fu, ρ, ν, ecc; cost=NaN) = Metal{StructuralSteelType, typeof(E), typeof(ρ)}(E, G, Fy, Fu, ρ, Float64(ν), Float64(ecc), Float64(cost))
RebarSteel(E, G, Fy, Fu, ρ, ν, ecc; cost=NaN) = Metal{RebarType, typeof(E), typeof(ρ)}(E, G, Fy, Fu, ρ, Float64(ν), Float64(ecc), Float64(cost))

# =============================================================================
# Concrete
# =============================================================================

"""
    AggregateType

Concrete aggregate classification for fire resistance calculations (ACI 216.1-14).

- `siliceous`: Quartz, granite, sandstone — least fire resistant
- `carbonate`: Limestone, dolomite — better fire resistance
- `sand_lightweight`: Sand-lightweight aggregate
- `lightweight`: Fully lightweight aggregate — best fire resistance
"""
@enum AggregateType siliceous carbonate sand_lightweight lightweight

"""
    Concrete{T_P, T_D} <: AbstractMaterial

Concrete material with compressive strength.

# Fields
- `E`: Young's modulus
- `fc′`: Compressive strength (28-day)
- `ρ`: Density
- `ν`: Poisson's ratio
- `εcu`: Ultimate compressive strain (default 0.003 per ACI 318)
- `ecc`: Embodied carbon [kgCO₂e/kg]
- `cost`: Unit cost [\$/kg] (NaN if not set; required for MinCost optimization)
- `λ`: Lightweight concrete factor (1.0 for NWC, 0.75–0.85 for LWC per ACI 318-11 §8.6.1)
- `aggregate_type`: Aggregate classification for fire resistance (default `siliceous`)

# Notes
- `εcu = 0.003` is the standard ACI 318 value for concrete up to ~10 ksi
- High-strength concrete (>10 ksi) may use lower values (e.g., 0.0025)
"""
struct Concrete{T_P, T_D} <: AbstractMaterial
    E::T_P        # Young's modulus
    fc′::T_P      # Compressive strength
    ρ::T_D        # Density
    ν::Float64    # Poisson's ratio
    εcu::Float64  # Ultimate compressive strain
    ecc::Float64  # Embodied carbon [kgCO₂e/kg]
    cost::Float64 # Unit cost [$/kg] (NaN = not set)
    λ::Float64    # Lightweight concrete factor (ACI 318-11 §8.6.1)
    aggregate_type::AggregateType  # Aggregate type for fire resistance (ACI 216.1)
end

function Concrete(E, fc′, ρ, ν, ecc; εcu::Real=0.003, cost::Real=NaN, λ::Real=1.0,
                  aggregate_type::AggregateType=siliceous)
    Concrete{typeof(E), typeof(ρ)}(E, fc′, ρ, Float64(ν), Float64(εcu), Float64(ecc),
                                    Float64(cost), Float64(λ), aggregate_type)
end

# =============================================================================
# Reinforced Concrete Material (Concrete + Rebar)
# =============================================================================

"""
    ReinforcedConcreteMaterial <: AbstractMaterial

Combined concrete + reinforcing steel material for RC design.
Links a `Concrete` material with longitudinal and transverse `RebarSteel`.

# Fields
- `concrete`: Concrete material (fc′, E, εcu, etc.)
- `rebar`: RebarSteel for longitudinal reinforcement (Fy, Es)
- `transverse`: RebarSteel for ties/spirals (defaults to same as rebar)

# Example
```julia
# Using presets
rc_mat = ReinforcedConcreteMaterial(NWC_4000, Rebar_60)

# With different transverse steel
rc_mat = ReinforcedConcreteMaterial(NWC_5000, Rebar_75, Rebar_60)

# Access properties
fc = rc_mat.concrete.fc′     # Concrete strength
fy = rc_mat.rebar.Fy         # Rebar yield strength
```
"""
struct ReinforcedConcreteMaterial{C<:Concrete, R<:RebarSteel} <: AbstractMaterial
    concrete::C
    rebar::R
    transverse::R
end

# Convenience constructor (same rebar for longitudinal and transverse)
function ReinforcedConcreteMaterial(concrete::Concrete, rebar::RebarSteel)
    ReinforcedConcreteMaterial(concrete, rebar, rebar)
end

# =============================================================================
# Timber
# =============================================================================

"""
    Timber <: AbstractMaterial

Timber material with NDS reference design values.

# Fields
- `species`: Species identifier (e.g., :douglas_fir, :southern_pine)
- `grade`: Lumber grade (e.g., :select_structural, :no1, :no2)
- `E`: Modulus of elasticity
- `Emin`: Minimum E for stability calculations
- `Fb`: Reference bending stress
- `Ft`: Reference tension stress
- `Fv`: Reference shear stress
- `Fc`: Reference compression parallel to grain
- `Fc_perp`: Reference compression perpendicular to grain
- `ρ`: Density
- `ecc`: Embodied carbon [kgCO₂e/kg]

Note: Reference values are multiplied by adjustment factors (CD, CM, etc.) 
per NDS to get adjusted design values.
"""
struct Timber{T_P<:Pressure, T_D<:Density} <: AbstractMaterial
    species::Symbol      # :douglas_fir, :southern_pine, etc.
    grade::Symbol        # :select_structural, :no1, :no2, etc.
    E::T_P               # Modulus of elasticity
    Emin::T_P            # Minimum E for stability calculations
    Fb::T_P              # Reference bending stress
    Ft::T_P              # Reference tension stress
    Fv::T_P              # Reference shear stress
    Fc::T_P              # Reference compression parallel to grain
    Fc_perp::T_P         # Reference compression perpendicular to grain
    ρ::T_D               # Density
    ecc::Float64         # Embodied carbon [kgCO₂e/kg]
    cost::Float64        # Unit cost [$/kg] (NaN = not set)
end

function Timber(species::Symbol, grade::Symbol, E, Emin, Fb, Ft, Fv, Fc, Fc_perp, ρ, ecc; cost::Real=NaN)
    Timber{typeof(E), typeof(ρ)}(species, grade, E, Emin, Fb, Ft, Fv, Fc, Fc_perp, ρ, Float64(ecc), Float64(cost))
end
