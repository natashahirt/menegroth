# ==============================================================================
# ACI Capacity Checker - STUB
# ==============================================================================
# Implements AbstractCapacityChecker for ACI 318 concrete design.

"""
    ACIChecker <: AbstractCapacityChecker

ACI 318-19 capacity checker for reinforced concrete members.

# Strength Reduction Factors (φ)
- Flexure (tension-controlled): φ = 0.90
- Shear: φ = 0.75
- Compression (spiral): φ = 0.75
- Compression (tied): φ = 0.65
- Transition zone: interpolated based on εt

# Design Approach
ACI uses ultimate strength design:
- φMn ≥ Mu (flexure)
- φVn ≥ Vu (shear)
- φPn ≥ Pu (axial)
- P-M interaction for beam-columns

# Serviceability
- Deflection limits (L/360 for floors, etc.)
- Crack width control (exposure classes)

# Usage (future)
```julia
checker = ACIChecker(; exposure=:moderate, deflection_limit=1/360)
feasible = is_feasible(checker, rc_section, concrete, rebar, demand, geometry)
```
"""
struct ACIChecker <: AbstractCapacityChecker
    # Exposure class affects cover and crack control
    exposure::Symbol     # :moderate, :severe, :corrosive
    # Seismic design category
    sdc::Symbol          # :A, :B, :C, :D, :E, :F
    # Serviceability limits
    deflection_limit::Union{Nothing, Float64}
    # Lightweight concrete?
    lightweight::Bool
    λ::Float64           # Lightweight factor (1.0 for normal weight)
end

function ACIChecker(;
    exposure = :moderate,
    sdc = :B,
    deflection_limit = nothing,
    lightweight = false
)
    λ = lightweight ? 0.75 : 1.0  # Simplified; actual λ depends on concrete properties
    ACIChecker(exposure, sdc, deflection_limit, lightweight, λ)
end

# ==============================================================================
# Stub Implementations
# ==============================================================================

# Placeholder: feasibility check (not implemented)
function is_feasible(
    checker::ACIChecker,
    section::RCBeamSection,
    concrete::Concrete,
    demand::AbstractDemand,
    geometry::ConcreteMemberGeometry
)::Bool
    error("ACIChecker.is_feasible not yet implemented")
end

# ==============================================================================
# Reference: ACI 318 Key Equations
# ==============================================================================
#
# Flexural Strength (Rectangular Section):
#   a = As × fy / (0.85 × f'c × b)
#   Mn = As × fy × (d - a/2)
#
# Shear Strength:
#   Vc = 2 × λ × √f'c × bw × d  (simplified)
#   Vs = Av × fy × d / s
#   Vn = Vc + Vs
#
# Strain Limits:
#   εcu = 0.003 (concrete crushing)
#   εy = fy / Es (steel yield)
#   εt ≥ 0.005 for tension-controlled (φ = 0.90)
#   εt ≤ εy for compression-controlled (φ = 0.65)
#
# Minimum Reinforcement:
#   As,min = max(3√f'c/fy × bw × d, 200/fy × bw × d)
#
# Maximum Reinforcement (ductility):
#   ρmax such that εt ≥ 0.004
