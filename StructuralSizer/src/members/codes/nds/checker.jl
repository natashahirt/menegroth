# ==============================================================================
# NDS Capacity Checker - STUB
# ==============================================================================
# Implements AbstractCapacityChecker for NDS timber design.

"""
    NDSChecker <: AbstractCapacityChecker

NDS 2018 capacity checker for timber members.

# Adjustment Factors (to be implemented)
- `CD`: Load duration factor (0.9 for permanent, 1.0 for 10-year, 1.25 for 7-day, etc.)
- `CM`: Wet service factor
- `Ct`: Temperature factor
- `CL`: Beam stability factor
- `CF`: Size factor (sawn lumber)
- `CV`: Volume factor (glulam)
- `Cfu`: Flat use factor
- `Ci`: Incising factor
- `Cr`: Repetitive member factor
- `CP`: Column stability factor
- `CT`: Buckling stiffness factor
- `Cb`: Bearing area factor

# Reference Design Values
NDS provides reference values (Fb, Ft, Fv, Fc, Fc⊥, E, Emin) which are
multiplied by adjustment factors to get adjusted design values (F'b, etc.)

# Usage (future)
```julia
checker = NDSChecker(CD=1.0, CM=1.0, dry_service=true)
feasible = is_feasible(checker, glulam_section, timber_material, demand, geometry)
```
"""
struct NDSChecker <: AbstractCapacityChecker
    # Load duration factor
    CD::Float64
    # Service conditions
    wet_service::Bool      # CM factor applies if true
    high_temperature::Bool # Ct factor applies if true
    # Repetitive member
    repetitive::Bool       # Cr = 1.15 if true (for dimension lumber in floors/roofs)
    # Incised treatment
    incised::Bool          # Ci factor applies if true
end

function NDSChecker(;
    CD = 1.0,              # Normal duration (10-year load)
    wet_service = false,
    high_temperature = false,
    repetitive = false,
    incised = false
)
    NDSChecker(CD, wet_service, high_temperature, repetitive, incised)
end

# ==============================================================================
# Stub Implementations
# ==============================================================================

# Timber material type (stub)
abstract type AbstractTimber <: AbstractMaterial end

struct Timber <: AbstractTimber
    species::Symbol      # :douglas_fir, :southern_pine, etc.
    grade::Symbol        # :select_structural, :no1, :no2, etc.
    E::Float64           # Modulus of elasticity [Pa]
    Emin::Float64        # Minimum E for stability calculations [Pa]
    Fb::Float64          # Reference bending stress [Pa]
    Ft::Float64          # Reference tension stress [Pa]
    Fv::Float64          # Reference shear stress [Pa]
    Fc::Float64          # Reference compression parallel [Pa]
    Fc_perp::Float64     # Reference compression perpendicular [Pa]
    ρ::Float64           # Density [kg/m³]
    ecc::Float64         # Embodied carbon [kgCO2e/kg]
end

# Placeholder: feasibility check (not implemented)
function is_feasible(
    checker::NDSChecker,
    section::GlulamSection,
    material::AbstractTimber,
    demand::AbstractDemand,
    geometry::TimberMemberGeometry
)::Bool
    error("NDSChecker.is_feasible not yet implemented")
end

# Placeholder: precompute capacities
function precompute_capacities!(
    checker::NDSChecker,
    cache,
    catalogue,
    material::AbstractTimber,
    objective::AbstractObjective
)
    error("NDSChecker.precompute_capacities! not yet implemented")
end

# ==============================================================================
# Reference: NDS Adjustment Factor Summary
# ==============================================================================
#
# Adjusted Design Value = Reference Value × (applicable factors)
#
# F'b  = Fb  × CD × CM × Ct × CL × CF × Cfu × Ci × Cr          (bending)
# F't  = Ft  × CD × CM × Ct × CF × Ci                          (tension)
# F'v  = Fv  × CD × CM × Ct × Ci                               (shear)
# F'c  = Fc  × CD × CM × Ct × CF × Ci × CP                     (compression ∥)
# F'c⊥ = Fc⊥ × CM × Ct × Ci × Cb                               (compression ⊥)
# E'   = E   × CM × Ct × Ci                                    (modulus)
# E'min = Emin × CM × Ct × Ci × CT                             (stability E)
#
# For glulam, use CV (volume factor) instead of CF (size factor)
# F'b = Fb × CD × CM × Ct × CL × CV × Cfu × Cc                 (glulam bending)
