# Demand Types
# Force demands for structural members. Geometry (L, Lb, K, Cb) comes from Member.
# Note: AbstractDemand is defined in StructuralSizer/src/types.jl

# ==============================================================================
# Steel/General Member Demand (AISC-style)
# ==============================================================================

"""
Unified demand for framing members (beams, columns, beam-columns).

# Fields
- `member_idx`: Index of the member group
- `Pu_c`: Compression magnitude (always positive) [N]
- `Pu_t`: Tension magnitude (always positive) [N]
- `Mux`: Strong-axis moment (envelope/max) [N*m]
- `Muy`: Weak-axis moment (envelope/max) [N*m]
- `M1x`: Smaller end moment about strong axis (for B1 Cm factor)
- `M2x`: Larger end moment about strong axis (for B1 Cm factor)
- `M1y`: Smaller end moment about weak axis (for B1 Cm factor)
- `M2y`: Larger end moment about weak axis (for B1 Cm factor)
- `Vu_strong`: Strong-axis shear [N]
- `Vu_weak`: Weak-axis shear [N]
- `Tu`: Factored torsion [N*m] (0 = no torsion demand)
- `δ_max`: Maximum local deflection from analysis [m] (for deflection scaling)
- `I_ref`: Reference moment of inertia used in analysis [m⁴] (for deflection scaling)
- `transverse_load`: Whether transverse loading exists between supports (for Cm)

# End Moment Convention (AISC Appendix 8)
- M1 = smaller end moment, M2 = larger end moment (|M2| ≥ |M1|)
- M1/M2 > 0: Double curvature (reverse curvature bending)
- M1/M2 < 0: Single curvature
- If M1/M2 not provided, assumes M1=0 (Cm=0.6, conservative for single curvature)
"""
struct MemberDemand{T} <: AbstractDemand
    member_idx::Int
    Pu_c::T      # Compression magnitude (always positive)
    Pu_t::T      # Tension magnitude (always positive)
    Mux::T       # Strong-axis moment (envelope)
    Muy::T       # Weak-axis moment (envelope)
    M1x::T       # Smaller end moment, strong axis (for B1)
    M2x::T       # Larger end moment, strong axis (for B1)
    M1y::T       # Smaller end moment, weak axis (for B1)
    M2y::T       # Larger end moment, weak axis (for B1)
    Vu_strong::T # Strong-axis shear
    Vu_weak::T   # Weak-axis shear
    Tu::T        # Factored torsion (0 = no torsion demand)
    δ_max::T     # Max local deflection from analysis (for scaling)
    I_ref::T     # Reference I used in analysis (for scaling)
    transverse_load::Bool  # Whether transverse loading between supports
end

# Flexible constructor with defaults
function MemberDemand(idx::Int; 
    Pu_c=0.0, Pu_t=0.0, Mux=0.0, Muy=0.0,
    M1x=nothing, M2x=nothing, M1y=nothing, M2y=nothing,
    Vu_strong=0.0, Vu_weak=0.0,
    Tu=0.0,
    δ_max=0.0, I_ref=1.0,
    transverse_load=false
)
    # Resolve M1x/M2x: if not provided, use M1=0, M2=Mux (conservative Cm=0.6)
    M1x_val = isnothing(M1x) ? zero(Mux) : M1x
    M2x_val = isnothing(M2x) ? Mux : M2x
    M1y_val = isnothing(M1y) ? zero(Muy) : M1y
    M2y_val = isnothing(M2y) ? Muy : M2y
    
    # Determine concrete type parameter (Float64 when all fields are plain numbers)
    all_vals = (Pu_c, Pu_t, Mux, Muy, M1x_val, M2x_val, M1y_val, M2y_val,
                Vu_strong, Vu_weak, Tu, δ_max, I_ref)
    T = promote_type(typeof.(all_vals)...)
    if T <: Real
        MemberDemand{T}(idx, T(Pu_c), T(Pu_t), T(Mux), T(Muy),
                        T(M1x_val), T(M2x_val), T(M1y_val), T(M2y_val),
                        T(Vu_strong), T(Vu_weak), T(Tu), T(δ_max), T(I_ref), transverse_load)
    else
        # Mixed Unitful dimensions — fall back to Any (checker handles conversions)
        MemberDemand{Any}(idx, Pu_c, Pu_t, Mux, Muy,
                          M1x_val, M2x_val, M1y_val, M2y_val,
                          Vu_strong, Vu_weak, Tu, δ_max, I_ref, transverse_load)
    end
end

# ==============================================================================
# RC Column Demand (ACI-style)
# ==============================================================================

"""
    RCColumnDemand <: AbstractDemand

Demand for reinforced concrete columns including biaxial moments.
All force/moment values can be in any Unitful units - they will be
converted internally to kip/kip-ft for ACI calculations.

# Fields
- `member_idx`: Index of the member group
- `Pu`: Factored axial load (positive = compression)
- `Mux`: Maximum factored moment about x-axis (= max(|M1x|, |M2x|))
- `Muy`: Maximum factored moment about y-axis (= max(|M1y|, |M2y|))
- `M1x`: Smaller end moment about x-axis (for slenderness Cm factor)
- `M2x`: Larger end moment about x-axis (absolute value, same sign as M1x for single curvature)
- `M1y`: Smaller end moment about y-axis
- `M2y`: Larger end moment about y-axis
- `βdns`: Ratio of sustained to total factored load (for slenderness)

# End Moment Convention (ACI 318-11 §10.10.6.4)
- M1 = smaller end moment, M2 = larger end moment (|M2| ≥ |M1|)
- M1/M2 > 0: Single curvature (both ends rotate same direction)
- M1/M2 < 0: Double curvature (ends rotate opposite directions)
- For columns with significant end moments, provide M1x/M2x and M1y/M2y
- If not provided, defaults to M1=0 (conservative single curvature assumption)

# Examples
```julia
# Simple: envelope moment only (uses conservative M1=0)
demand = RCColumnDemand(1; Pu=500.0, Mux=100.0, Muy=50.0)

# Full: with end moments for proper slenderness (double curvature)
demand = RCColumnDemand(1; 
    Pu=500.0, 
    M1x=-80.0, M2x=100.0,  # Double curvature (opposite signs)
    M1y=-40.0, M2y=50.0,
)
```
"""
struct RCColumnDemand{T} <: AbstractDemand
    member_idx::Int
    Pu::T           # Factored axial (positive = compression)
    Mux::T          # Maximum moment about x-axis = max(|M1x|, |M2x|)
    Muy::T          # Maximum moment about y-axis = max(|M1y|, |M2y|)
    M1x::T          # Smaller end moment about x-axis (for Cm)
    M2x::T          # Larger end moment about x-axis
    M1y::T          # Smaller end moment about y-axis
    M2y::T          # Larger end moment about y-axis
    βdns::Float64   # Sustained load ratio (for slenderness) - always Float64
end

function RCColumnDemand(idx::Int;
    Pu = 0.0,
    Mux = nothing,  # If nothing, computed from M1x/M2x
    Muy = nothing,  # If nothing, computed from M1y/M2y
    M1x = 0.0,      # Default: M1=0 (conservative single curvature)
    M2x = nothing,  # If nothing, uses Mux
    M1y = 0.0,
    M2y = nothing,  # If nothing, uses Muy
    βdns = 0.6      # Default: 60% sustained (typical for gravity)
)
    # Resolve Mux: either provided directly, or max of |M1x|, |M2x|
    if isnothing(Mux)
        if isnothing(M2x)
            Mux = abs(M1x)
        else
            Mux = max(abs(M1x), abs(M2x))
        end
    end
    
    # Resolve M2x: either provided, or equals Mux (assuming M1x=0 convention)
    if isnothing(M2x)
        M2x = Mux
    end
    
    # Same for y-axis
    if isnothing(Muy)
        if isnothing(M2y)
            Muy = abs(M1y)
        else
            Muy = max(abs(M1y), abs(M2y))
        end
    end
    
    if isnothing(M2y)
        M2y = Muy
    end
    
    T = promote_type(typeof(Pu), typeof(Mux), typeof(Muy), typeof(M1x), typeof(M2x), typeof(M1y), typeof(M2y))
    RCColumnDemand{T}(idx, T(Pu), T(Mux), T(Muy), T(M1x), T(M2x), T(M1y), T(M2y), Float64(βdns))
end

# ==============================================================================
# RC Beam Demand (ACI-style)
# ==============================================================================

"""
    RCBeamDemand <: AbstractDemand

Demand for reinforced concrete beams (flexure + shear + torsion + optional axial).
All force/moment values can be in any Unitful units — they will be
converted internally to kip/kip·ft for ACI calculations.

# Fields
- `member_idx`: Index of the member group
- `Mu`: Factored moment (positive)
- `Vu`: Factored shear (positive)
- `Nu`: Factored axial compression (positive = compression, 0 for pure beams)
- `Tu`: Factored torsion (positive, 0.0 = no torsion demand)

When `Nu > 0`, the ACI 318 shear capacity `Vc` is increased via the
axial compression modifier (ACI 318-11 §11.2.2.1, Eq. 11-4):
`Vc = 2λ(1 + Nu/(2000 Ag)) √f'c bw d`.

# Examples
```julia
# Pure beam (no axial, no torsion)
demand = RCBeamDemand(1; Mu=150.0, Vu=30.0)

# With torsion
demand = RCBeamDemand(1; Mu=150.0, Vu=30.0, Tu=20.0)

# With axial compression (column-like member under shear)
demand = RCBeamDemand(1; Mu=150.0, Vu=30.0, Nu=10.0)

# Unitful — converted automatically
demand = RCBeamDemand(1; Mu=200.0u"kN*m", Vu=80.0u"kN", Tu=15.0u"kN*m")
```
"""
struct RCBeamDemand{T} <: AbstractDemand
    member_idx::Int
    Mu::T           # Factored moment
    Vu::T           # Factored shear
    Nu::T           # Factored axial compression (0 for pure beams)
    Tu::T           # Factored torsion (0 = no torsion)
end

function RCBeamDemand(idx::Int; Mu=0.0, Vu=0.0, Nu=0.0, Tu=0.0)
    all_vals = (Mu, Vu, Nu, Tu)
    T = promote_type(typeof.(all_vals)...)
    if T <: Real
        RCBeamDemand{T}(idx, T(Mu), T(Vu), T(Nu), T(Tu))
    else
        # Mixed Unitful dimensions — fall back to Any (checker handles conversions)
        RCBeamDemand{Any}(idx, Mu, Vu, Nu, Tu)
    end
end