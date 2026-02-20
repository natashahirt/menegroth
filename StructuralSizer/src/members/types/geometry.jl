# ==============================================================================
# Member Geometry Types
# ==============================================================================
# Material-specific geometric parameters for capacity calculations.
# Different materials have different stability/bracing considerations.

# ==============================================================================
# Steel Member Geometry (AISC)
# ==============================================================================

"""
    SteelMemberGeometry <: AbstractMemberGeometry

Geometric parameters for steel member capacity calculations per AISC 360.

# Fields
- `L`: Total member length
- `Lb`: Unbraced length for lateral-torsional buckling
- `Cb`: Moment gradient factor (1.0 for uniform moment, higher for gradient)
- `Kx`: Effective length factor for strong-axis buckling
- `Ky`: Effective length factor for weak-axis buckling
- `braced`: Whether the frame is braced against sidesway (for B1/B2 factors)

# Defaults
- `Cb = 1.0` (conservative)
- `Kx = Ky = 1.0` (pinned-pinned)
- `braced = true` (no sway amplification needed)

# AISC Chapter C - Second-Order Effects
For braced frames (braced=true): Only B1 (P-δ) amplification applies.
For sway frames (braced=false): Both B1 and B2 (P-Δ) amplification apply.

Note: Sway frame amplification (B2 factor) is not yet implemented.
Currently the checker assumes braced=true behavior regardless of this flag.
Set braced=false to flag sway frames for future implementation.
"""
struct SteelMemberGeometry{T<:Unitful.Length} <: AbstractMemberGeometry
    L::T             # Total length
    Lb::T            # Unbraced length for LTB
    Cb::Float64      # Moment gradient factor
    Kx::Float64      # Effective length factor (strong axis)
    Ky::Float64      # Effective length factor (weak axis)
    braced::Bool     # Frame braced against sidesway?
end

function SteelMemberGeometry(L::Unitful.Length; Lb::Unitful.Length=L, Cb=1.0, Kx=1.0, Ky=1.0, braced=true)
    L_m = uconvert(u"m", L)
    Lb_m = uconvert(u"m", Lb)
    SteelMemberGeometry{typeof(L_m)}(L_m, Lb_m, Float64(Cb), Float64(Kx), Float64(Ky), braced)
end

# Backward compat: bare numbers assumed to be in meters
function SteelMemberGeometry(L::Real; Lb::Real=L, Cb=1.0, Kx=1.0, Ky=1.0, braced=true)
    SteelMemberGeometry(Float64(L) * u"m"; Lb=Float64(Lb) * u"m", Cb=Cb, Kx=Kx, Ky=Ky, braced=braced)
end

# ==============================================================================
# Timber Member Geometry (NDS) - STUB
# ==============================================================================

"""
    TimberMemberGeometry <: AbstractMemberGeometry

Geometric parameters for timber member capacity calculations per NDS.

# Fields
- `L`: Total member length
- `Lu`: Unbraced length for lateral stability (beam lateral buckling)
- `Le`: Effective column length for buckling
- `support`: Support condition for Ke factor (:pinned, :fixed, :cantilever)

# NDS Stability Factors
- Beam stability factor CL depends on Lu, d, b
- Column stability factor Cp depends on Le, d
"""
struct TimberMemberGeometry <: AbstractMemberGeometry
    L::Float64       # Total length [m]
    Lu::Float64      # Unbraced length for beam stability [m]
    Le::Float64      # Effective column length [m]
    support::Symbol  # :pinned, :fixed, :cantilever
end

function TimberMemberGeometry(L; Lu=L, Le=L, support=:pinned)
    TimberMemberGeometry(Float64(L), Float64(Lu), Float64(Le), support)
end

# ==============================================================================
# Concrete Member Geometry (ACI)
# ==============================================================================

"""
    ConcreteMemberGeometry{T<:Unitful.Length} <: AbstractMemberGeometry

Geometric parameters for RC member capacity calculations per ACI 318.

# Fields
- `L::Length`: Total member length (span)
- `Lu::Length`: Unsupported length for slenderness effects
- `k::Float64`: Effective length factor
- `braced::Bool`: Whether the frame is braced against sidesway

# ACI Slenderness
- Slenderness ratio kLu/r determines if second-order effects are significant
- Braced frames: magnify moments if kLu/r > 34 - 12(M1/M2)
- Unbraced frames: always consider P-Δ effects
"""
struct ConcreteMemberGeometry{T<:Unitful.Length} <: AbstractMemberGeometry
    L::T             # Span length
    Lu::T            # Unsupported length
    k::Float64       # Effective length factor
    braced::Bool     # Frame braced against sidesway?
end

function ConcreteMemberGeometry(L::Unitful.Length; Lu::Unitful.Length=L, k=1.0, braced=true)
    L_m = uconvert(u"m", L)
    Lu_m = uconvert(u"m", Lu)
    ConcreteMemberGeometry{typeof(L_m)}(L_m, Lu_m, Float64(k), braced)
end

# Backward compat: bare numbers assumed to be in meters
function ConcreteMemberGeometry(L::Real; Lu::Real=L, k=1.0, braced=true)
    ConcreteMemberGeometry(Float64(L) * u"m"; Lu=Float64(Lu) * u"m", k=k, braced=braced)
end

# =============================================================================
# Bending Axis Tags (for PM diagram dispatch)
# =============================================================================

"""Bending axis discriminator for PM interaction dispatch."""
abstract type BendingAxis end

"""Strong-axis bending (about x-axis, default)."""
struct StrongAxis <: BendingAxis end

"""Weak-axis bending (about y-axis)."""
struct WeakAxis <: BendingAxis end