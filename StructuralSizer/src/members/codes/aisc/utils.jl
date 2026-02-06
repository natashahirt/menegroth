# ==============================================================================
# AISC Utilities (shared helpers across shapes)
# ==============================================================================

@inline function _linear_interp(x, x0, x1, y0, y1)
    x <= x0 && return y0
    x >= x1 && return y1
    y0 + (y1 - y0) * ((x - x0) / (x1 - x0))
end

@inline function _Fe_euler(E, L, r)
    KL_r = L / r
    return π^2 * E / KL_r^2
end

@inline function _Fcr_column(Fe, Fy)
    ratio = Fy / Fe
    if ratio <= 2.25
        return (0.658^ratio) * Fy
    else
        return 0.877 * Fe
    end
end

# ==============================================================================
# Smooth (Differentiable) AISC Utilities
# ==============================================================================
# These functions provide smooth approximations of piecewise AISC functions
# for use with automatic differentiation (ForwardDiff, Zygote, etc.).
# The smoothing parameter k controls transition sharpness (larger = sharper).

"""
    _smooth_sigmoid(x; k=20.0) -> Float64

Smooth sigmoid function: σ(x) = 1 / (1 + exp(-k*x)).
Transitions from 0 to 1 around x=0.
"""
@inline function _smooth_sigmoid(x::T; k::Real=20.0) where T<:Real
    return one(T) / (one(T) + exp(-k * x))
end

"""
    _smooth_step(x, threshold; k=20.0) -> Float64

Smooth step function: transitions from 0 to 1 as x crosses threshold.
"""
@inline function _smooth_step(x::T, threshold::Real; k::Real=20.0) where T<:Real
    return _smooth_sigmoid(x - threshold; k=k)
end

"""
    _softplus(x; β=1.0) -> Float64

Softplus function: smooth approximation of max(0, x).
softplus(x) = log(1 + exp(β*x)) / β
"""
@inline function _softplus(x::T; β::Real=50.0) where T<:Real
    # Numerically stable implementation
    if x * β > 20
        return x
    elseif x * β < -20
        return zero(T)
    else
        return log(one(T) + exp(β * x)) / β
    end
end

"""
    _smooth_clamp(x, lo, hi; k=50.0) -> Float64

Smooth clamp using softplus: differentiable approximation of clamp(x, lo, hi).
"""
@inline function _smooth_clamp(x::T, lo::Real, hi::Real; k::Real=50.0) where T<:Real
    # soft_max(lo, soft_min(x, hi))
    return lo + _softplus(x - lo; β=k) - _softplus(x - hi; β=k)
end

"""
    _smooth_max(a, b; k=20.0) -> Float64

Smooth max function: differentiable approximation of max(a, b).
Uses LogSumExp for numerical stability.
"""
@inline function _smooth_max(a::T, b::T; k::Real=20.0) where T<:Real
    m = max(a, b)
    return m + log(exp(k*(a - m)) + exp(k*(b - m))) / k
end

"""
    _smooth_min(a, b; k=20.0) -> Float64

Smooth min function: differentiable approximation of min(a, b).
"""
@inline function _smooth_min(a::T, b::T; k::Real=20.0) where T<:Real
    return -_smooth_max(-a, -b; k=k)
end

"""
    _Fe_euler_smooth(E, KL_r)

Euler buckling stress (already smooth - just a renamed version for consistency).
Fe = π²E / (KL/r)²
"""
@inline function _Fe_euler_smooth(E::T, KL_r::T) where T<:Real
    return π^2 * E / KL_r^2
end

"""
    _Fcr_column_smooth(Fe, Fy; k=20.0) -> Float64

Smooth AISC E3 column curve: critical buckling stress Fcr.

Original piecewise function:
- If Fy/Fe ≤ 2.25: Fcr = (0.658^(Fy/Fe)) × Fy  (inelastic)
- If Fy/Fe > 2.25: Fcr = 0.877 × Fe            (elastic)

Smooth version uses sigmoid blending at the transition.
"""
@inline function _Fcr_column_smooth(Fe::T, Fy::T; k::Real=20.0) where T<:Real
    ratio = Fy / Fe
    
    # Sigmoid transition at ratio = 2.25
    # σ → 1 for ratio < 2.25 (inelastic), σ → 0 for ratio > 2.25 (elastic)
    σ = _smooth_sigmoid(2.25 - ratio; k=k)
    
    # Inelastic buckling (Fy/Fe ≤ 2.25)
    Fcr_inelastic = (0.658^ratio) * Fy
    
    # Elastic buckling (Fy/Fe > 2.25)
    Fcr_elastic = 0.877 * Fe
    
    # Smooth blend
    return σ * Fcr_inelastic + (one(T) - σ) * Fcr_elastic
end

"""
    _smooth_linear_interp(x, x0, x1, y0, y1; k=20.0) -> Float64

Smooth linear interpolation with clamped endpoints.
Unlike _linear_interp, this is differentiable at the boundaries.
"""
@inline function _smooth_linear_interp(x::T, x0::Real, x1::Real, y0::T, y1::T; k::Real=20.0) where T<:Real
    # Smooth clamping
    x_clamped = _smooth_clamp(x, x0, x1; k=k)
    # Linear interpolation
    return y0 + (y1 - y0) * ((x_clamped - x0) / (x1 - x0))
end