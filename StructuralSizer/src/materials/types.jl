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

"""Global registry mapping `objectid(material)` → display name string."""
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

"""
    MetalType

Abstract tag type for dispatch between structural steel and reinforcing steel.
Subtypes: [`StructuralSteelType`](@ref), [`RebarType`](@ref).
"""
abstract type MetalType end

"""Tag type indicating structural (rolled/welded) steel."""
struct StructuralSteelType <: MetalType end

"""Tag type indicating reinforcing bar steel."""
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
- `cost`: Unit cost [USD/kg] (NaN if not set; required for MinCost optimization)
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

"""Alias for `Metal{StructuralSteelType}` — rolled/welded structural steel."""
const StructuralSteel{T_P, T_D} = Metal{StructuralSteelType, T_P, T_D}

"""Alias for `Metal{RebarType}` — reinforcing bar steel."""
const RebarSteel{T_P, T_D} = Metal{RebarType, T_P, T_D}

"""Construct a `StructuralSteel` from elastic constants, strengths, density, and ECC."""
StructuralSteel(E, G, Fy, Fu, ρ, ν, ecc; cost=NaN) = Metal{StructuralSteelType, typeof(E), typeof(ρ)}(E, G, Fy, Fu, ρ, Float64(ν), Float64(ecc), Float64(cost))

"""Construct a `RebarSteel` from elastic constants, strengths, density, and ECC."""
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
- `cost`: Unit cost [USD/kg] (NaN if not set; required for MinCost optimization)
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

"""
    Concrete(E, fc′, ρ, ν, ecc; εcu=0.003, cost=NaN, λ=1.0, aggregate_type=siliceous)

Construct a `Concrete` material from elastic modulus, strength, density, Poisson's
ratio, and embodied carbon coefficient.
"""
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

"""
    ReinforcedConcreteMaterial(concrete, rebar)

Construct with the same `RebarSteel` for both longitudinal and transverse reinforcement.
"""
function ReinforcedConcreteMaterial(concrete::Concrete, rebar::RebarSteel)
    ReinforcedConcreteMaterial(concrete, rebar, rebar)
end

# =============================================================================
# Fiber Reinforced Concrete (FRC)
# =============================================================================

"""
    FiberReinforcedConcrete{C<:Concrete} <: AbstractMaterial

Fiber reinforced concrete for PixelFrame and similar systems without embedded rebar.
Wraps a base `Concrete` material and adds fiber-specific properties.

# Fields
- `concrete`: Base concrete material (fc′, E, ρ, εcu, ecc, etc.)
- `fiber_dosage`: Fiber dosage [kg-fiber / m³ concrete]
- `fR1`: Residual flexural tensile strength at CMOD=0.5mm [MPa] (fib MC2010 §5.6.3)
- `fR3`: Residual flexural tensile strength at CMOD=2.5mm [MPa] (fib MC2010 §5.6.3)
- `fiber_ecc`: Embodied carbon of fiber [kgCO₂e/kg-fiber] (default 1.4, original Pixelframe.jl)

# Notes
- `fR1` and `fR3` are used in the fib MC2010 linear shear model (Eq. 7.7-5).
- `fiber_dosage` is used for embodied carbon calculation (thesis Eq. 2.16).
- Property delegation: `E`, `fc′`, `ρ`, `ν`, `εcu`, `λ`, `ecc`, `cost` delegate
  to the inner `Concrete`.

# Example
```julia
frc = FiberReinforcedConcrete(NWC_6000, 20.0, 3.2, 2.5)  # 20 kg/m³, fR1=3.2, fR3=2.5 MPa
frc.concrete.fc′  # access concrete strength
```
"""
struct FiberReinforcedConcrete{C<:Concrete} <: AbstractMaterial
    concrete::C            # base concrete (fc′, E, ecc, etc.)
    fiber_dosage::Float64  # kg-fiber / m³ concrete
    fR1::Float64           # residual flexural tensile strength at CMOD=0.5mm (MPa)
    fR3::Float64           # residual flexural tensile strength at CMOD=2.5mm (MPa)
    fiber_ecc::Float64     # embodied carbon of fiber [kgCO₂e/kg-fiber]
end

"""
    FiberReinforcedConcrete(concrete, fiber_dosage, fR1, fR3; fiber_ecc=1.4)

Construct an FRC material from a base `Concrete`, fiber dosage [kg/m³],
residual tensile strengths [MPa], and optional fiber embodied carbon.
"""
function FiberReinforcedConcrete(concrete::Concrete, fiber_dosage::Real, fR1::Real, fR3::Real;
                                  fiber_ecc::Real=1.4)
    FiberReinforcedConcrete(concrete, Float64(fiber_dosage), Float64(fR1), Float64(fR3),
                            Float64(fiber_ecc))
end

"""Delegate property access on `FiberReinforcedConcrete` to the inner `Concrete`."""
Base.getproperty(m::FiberReinforcedConcrete, s::Symbol) = _frc_getproperty(m, Val(s))
"""_frc_getproperty: return the `concrete` field."""
_frc_getproperty(m::FiberReinforcedConcrete, ::Val{:concrete}) = getfield(m, :concrete)
"""_frc_getproperty: return the `fiber_dosage` field."""
_frc_getproperty(m::FiberReinforcedConcrete, ::Val{:fiber_dosage}) = getfield(m, :fiber_dosage)
"""_frc_getproperty: return the `fR1` field."""
_frc_getproperty(m::FiberReinforcedConcrete, ::Val{:fR1}) = getfield(m, :fR1)
"""_frc_getproperty: return the `fR3` field."""
_frc_getproperty(m::FiberReinforcedConcrete, ::Val{:fR3}) = getfield(m, :fR3)
"""_frc_getproperty: return the `fiber_ecc` field."""
_frc_getproperty(m::FiberReinforcedConcrete, ::Val{:fiber_ecc}) = getfield(m, :fiber_ecc)
"""_frc_getproperty fallback: delegate to the inner `Concrete`."""
_frc_getproperty(m::FiberReinforcedConcrete, ::Val{s}) where {s} = getproperty(getfield(m, :concrete), s)

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

"""
    Timber(species, grade, E, Emin, Fb, Ft, Fv, Fc, Fc_perp, ρ, ecc; cost=NaN)

Construct a `Timber` material from NDS reference design values and species/grade identifiers.
"""
function Timber(species::Symbol, grade::Symbol, E, Emin, Fb, Ft, Fv, Fc, Fc_perp, ρ, ecc; cost::Real=NaN)
    Timber{typeof(E), typeof(ρ)}(species, grade, E, Emin, Fb, Ft, Fv, Fc, Fc_perp, ρ, Float64(ecc), Float64(cost))
end
