# ==============================================================================
# Fiber Reinforced Concrete (FRC) Material Presets & Regression Functions
# ==============================================================================
# FRC presets for PixelFrame and similar fiber-reinforced systems.
#
# fR1/fR3 values are residual flexural tensile strengths per fib MC2010 §5.6.3.
# Actual values depend on fiber type, geometry, and concrete mix — use
# project-specific test data when available.
#
# Regression functions from Wongsittikan (2024) dataset provide fR1 and fR3
# as a function of fc′ and fiber dosage for standard Dramix-type hooked-end
# steel fibers.
#
# Fiber ECC: 1.4 kgCO₂e/kg (original Pixelframe.jl value for steel fiber + tendon)
# ==============================================================================

# ==============================================================================
# fR1 / fR3 regression: fc′ × dosage → residual strength [MPa]
# ==============================================================================
# Linear regressions from Wongsittikan (2024) Catalog/dosage_to_fRx.jl.
# Valid for Dramix-type hooked-end steel fibers at dosages 20–40 kg/m³
# and fc′ ∈ [28, 100] MPa.

"""
    fc′_dosage2fR1(fc′_MPa, dosage) -> Float64

Residual flexural tensile strength fR1 [MPa] at CMOD = 0.5 mm.
Linear regression from Wongsittikan (2024) dataset.

# Arguments
- `fc′_MPa`: Concrete compressive strength [MPa, bare number]
- `dosage`: Fiber dosage [kg/m³] — must be one of {0, 20, 25, 30, 35, 40}

# Reference
Wongsittikan (2024), Catalog/dosage_to_fRx.jl
"""
function fc′_dosage2fR1(fc′_MPa::Real, dosage::Real)::Float64
    dosage == 0  && return 0.0
    dosage == 20 && return 0.0498 * fc′_MPa + 1.3563
    dosage == 25 && return 0.0584 * fc′_MPa + 1.5976
    dosage == 30 && return 0.0672 * fc′_MPa + 1.8378
    dosage == 35 && return 0.0757 * fc′_MPa + 2.0858
    dosage == 40 && return 0.0845 * fc′_MPa + 2.3244
    # Interpolate linearly between bracketing dosages for non-standard values
    _interpolate_fRx(fc′_MPa, dosage, fc′_dosage2fR1)
end

"""
    fc′_dosage2fR3(fc′_MPa, dosage) -> Float64

Residual flexural tensile strength fR3 [MPa] at CMOD = 2.5 mm.
Linear regression from Wongsittikan (2024) dataset.

# Arguments
- `fc′_MPa`: Concrete compressive strength [MPa, bare number]
- `dosage`: Fiber dosage [kg/m³] — must be one of {0, 20, 25, 30, 35, 40}

# Reference
Wongsittikan (2024), Catalog/dosage_to_fRx.jl
"""
function fc′_dosage2fR3(fc′_MPa::Real, dosage::Real)::Float64
    dosage == 0  && return 0.0
    dosage == 20 && return 0.0542 * fc′_MPa + 1.7409
    dosage == 25 && return 0.0610 * fc′_MPa + 2.1484
    dosage == 30 && return 0.0678 * fc′_MPa + 2.523
    dosage == 35 && return 0.0748 * fc′_MPa + 2.8556
    dosage == 40 && return 0.0815 * fc′_MPa + 3.1691
    _interpolate_fRx(fc′_MPa, dosage, fc′_dosage2fR3)
end

"""Linear interpolation between bracketing dosage levels for non-standard dosages."""
function _interpolate_fRx(fc′_MPa::Real, dosage::Real, fn::Function)::Float64
    standard = [20.0, 25.0, 30.0, 35.0, 40.0]
    dosage < 20.0 && return fn(fc′_MPa, 20) * dosage / 20.0  # scale linearly from zero
    dosage > 40.0 && return fn(fc′_MPa, 40) * dosage / 40.0  # extrapolate linearly
    idx = findfirst(d -> d ≥ dosage, standard)
    idx === nothing && return fn(fc′_MPa, 40)
    d_hi = standard[idx]
    d_lo = idx > 1 ? standard[idx - 1] : 20.0
    d_hi ≈ d_lo && return fn(fc′_MPa, d_hi)
    frac = (dosage - d_lo) / (d_hi - d_lo)
    return (1 - frac) * fn(fc′_MPa, d_lo) + frac * fn(fc′_MPa, d_hi)
end

# ==============================================================================
# Fallback display name
# ==============================================================================

"""Generate a display name for an FRC material when no explicit name is provided."""
function _fallback_material_name(mat::FiberReinforcedConcrete)
    conc = material_name(mat.concrete)
    dosage = round(Int, mat.fiber_dosage)
    "FRC ($(conc), $(dosage) kg/m³ fiber)"
end
