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

"""
    NDSChecker(; CD=1.0, wet_service=false, high_temperature=false, repetitive=false, incised=false)

Keyword constructor for [`NDSChecker`](@ref) with NDS 2018 defaults.
"""
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

"""
    is_feasible(checker::NDSChecker, section, material, demand, geometry) -> Bool

Check whether a timber section satisfies NDS 2018 capacity requirements. **Not yet implemented.**
"""
function is_feasible(
    checker::NDSChecker,
    section::GlulamSection,
    material::Timber,
    demand::AbstractDemand,
    geometry::TimberMemberGeometry
)::Bool
    error("NDSChecker.is_feasible not yet implemented")
end

"""
    precompute_capacities!(checker::NDSChecker, cache, catalog, material, objective)

Precompute adjusted design values for all sections in `catalog`. **Not yet implemented.**
"""
function precompute_capacities!(
    checker::NDSChecker,
    cache,
    catalog,
    material::Timber,
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
