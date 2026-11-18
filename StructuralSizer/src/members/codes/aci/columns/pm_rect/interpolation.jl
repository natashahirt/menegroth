# ==============================================================================
# Capacity Check Functions
# ==============================================================================

"""
    check_PM_capacity(diagram::PMInteractionDiagram, Pu::Real, Mu::Real) -> NamedTuple

Check if demand (Pu, Mu) is within the factored P-M capacity envelope.

# Arguments
- `diagram`: PMInteractionDiagram for the section
- `Pu`: Factored axial demand (kip), positive = compression
- `Mu`: Factored moment demand (kip-ft), absolute value

# Returns
NamedTuple with:
- `adequate`: Bool - true if demand is within capacity
- `utilization`: Float64 - demand/capacity ratio (1.0 = at limit)
- `φPn_at_Mu`: Float64 - factored axial capacity at the given moment
- `φMn_at_Pu`: Float64 - factored moment capacity at the given axial load
- `governing`: Symbol - which limit governs (`:axial`, `:moment`, `:combined`,
  or `:axial_cap` when ACI 318-11 §10.3.6 limits design φPn to φPn,max)

# Notes
- Uses linear interpolation between diagram points.
- Enforces ACI 318-11 §10.3.6 (Eq. 10-1, 10-2): design φPn ≤ φPn,max =
  α·φP0, where α = 0.85 (spiral) / 0.80 (tied). The diagram retains the
  theoretical PURE_COMPRESSION point (φP0) for plotting/diagnostics, but
  the design check refuses any Pu above the MAX_COMPRESSION cap.
"""
function check_PM_capacity(diagram::PMInteractionDiagram, Pu::Real, Mu::Real)
    Mu_abs = abs(Mu)  # Demand magnitude (kip-ft)

    # ACI 318-11 §10.3.6 — design axial strength shall not exceed φPn,max.
    # Eq. (10-1) spiral:  φPn,max = 0.85·φ·[0.85·f'c·(Ag - Ast) + fy·Ast]
    # Eq. (10-2) tied:    φPn,max = 0.80·φ·[0.85·f'c·(Ag - Ast) + fy·Ast]
    # The MAX_COMPRESSION control point is constructed with α·P0 already, so
    # its φPn is the design cap. Short-circuit before interpolation so the
    # PURE_COMPRESSION point (φP0) — kept on the curve for plotting — never
    # leaks into the design utilization above the cap.
    φPn_cap = _axial_design_cap(diagram)
    if Pu > φPn_cap
        return (
            adequate   = false,
            utilization = Pu / φPn_cap,
            φMn_at_Pu  = 0.0,
            φPn_at_Mu  = φPn_cap,
            governing  = :axial_cap,
        )
    end

    # Get factored curve
    curve = get_factored_curve(diagram)
    φPn = curve.φPn
    φMn = curve.φMn

    # Find φMn capacity at the given Pu by interpolation
    φMn_at_Pu = _interpolate_moment_at_P(φPn, φMn, Pu)

    # Find φPn capacity at the given Mu by interpolation
    φPn_at_Mu = _interpolate_axial_at_M(φPn, φMn, Mu_abs)

    # Cap the reported "axial capacity at this moment" at φPn,max so callers
    # (e.g., biaxial Bresler, NLP gradient) never see a compression capacity
    # above the ACI design ceiling, even at Mu = 0 where the curve reaches
    # φP0. Tension-side values (φPn_at_Mu < 0) are left untouched.
    if φPn_at_Mu > φPn_cap
        φPn_at_Mu = φPn_cap
    end

    # Near-pure axial (Mu = 0 is common from symmetric framing): at this P the diagram can
    # report φMn_at_Pu = 0 even when axial capacity is ample. The old fallback (utilization = 1.5)
    # incorrectly marked every such point inadequate and broke `design_column_reinforcement`.
    axial_tol_M = 1e-6  # kip-ft
    if Mu_abs ≤ axial_tol_M && abs(φPn_at_Mu) > 0
        utilization = abs(Pu) / abs(φPn_at_Mu)
        governing = :axial
    elseif φMn_at_Pu > 0 && abs(φPn_at_Mu) > 0
        # Combined check: ratio of demand to capacity at constant P/M ratio
        utilization_M = Mu_abs / max(φMn_at_Pu, 1e-6)
        utilization_P = abs(Pu) / max(abs(φPn_at_Mu), 1e-6)
        utilization = max(utilization_M, utilization_P)

        if utilization_M > utilization_P
            governing = :moment
        elseif utilization_P > utilization_M
            governing = :axial
        else
            governing = :combined
        end
    elseif φMn_at_Pu > 0
        utilization = Mu_abs / φMn_at_Pu
        governing = :moment
    elseif abs(φPn_at_Mu) > 0
        utilization = abs(Pu) / abs(φPn_at_Mu)
        governing = :axial
    else
        utilization = 1.5  # Over capacity / indeterminate
        governing = :combined
    end

    adequate = utilization ≤ 1.0 + PM_INTERACTION_UTIL_TOL

    return (
        adequate = adequate,
        utilization = utilization,
        φMn_at_Pu = φMn_at_Pu,
        φPn_at_Mu = φPn_at_Mu,
        governing = governing
    )
end

"""
    _axial_design_cap(diagram) -> Float64

φPn,max (kip), ACI 318-11 §10.3.6: the `:max_compression` control point,
built with α·P0, Eq. (10-1) spiral or Eq. (10-2) tied. Any strength check
must reject Pu above it before reading φMn off the curve, whose top point
is φP0.
"""
_axial_design_cap(diagram::PMInteractionDiagram) =
    get_control_point(diagram, :max_compression).φPn

"""
    capacity_at_axial(diagram::PMInteractionDiagram, Pu::Real) -> Float64

Get factored moment capacity φMn at a given factored axial load Pu.

# Arguments
- `diagram`: PMInteractionDiagram
- `Pu`: Factored axial demand (kip), positive = compression

# Returns
- φMn: Factored moment capacity (kip-ft) at the given Pu
"""
function capacity_at_axial(diagram::PMInteractionDiagram, Pu::Real)
    curve = get_factored_curve(diagram)
    return _interpolate_moment_at_P(curve.φPn, curve.φMn, Pu)
end

"""
    capacity_at_moment(diagram::PMInteractionDiagram, Mu::Real) -> Float64

Get factored axial capacity φPn at a given factored moment Mu.

# Arguments
- `diagram`: PMInteractionDiagram  
- `Mu`: Factored moment demand (kip-ft)

# Returns
- φPn: Factored axial capacity (kip) at the given Mu
"""
function capacity_at_moment(diagram::PMInteractionDiagram, Mu::Real)
    curve = get_factored_curve(diagram)
    return _interpolate_axial_at_M(curve.φPn, curve.φMn, abs(Mu))
end

"""
    utilization_ratio(diagram::PMInteractionDiagram, Pu::Real, Mu::Real) -> Float64

Calculate the utilization ratio for a demand point (Pu, Mu).

# Returns
- Ratio ≤ 1.0 means adequate capacity
- Ratio > 1.0 means demand exceeds capacity
"""
function utilization_ratio(diagram::PMInteractionDiagram, Pu::Real, Mu::Real)
    result = check_PM_capacity(diagram, Pu, Mu)
    return result.utilization
end

# ==============================================================================
# Interpolation Helpers
# ==============================================================================

"""
    _interpolate_moment_at_P(φPn, φMn, Pu) -> Float64

Linearly interpolate factored moment capacity φMn (kip-ft) at a given axial load Pu (kip)
along the P-M interaction curve.
"""
function _interpolate_moment_at_P(φPn::Vector, φMn::Vector, Pu::Real)
    n = length(φPn)
    
    # Handle edge cases
    if Pu ≥ maximum(φPn)
        # At or above max compression - find the φMn at max φPn
        idx = argmax(φPn)
        return φMn[idx]
    elseif Pu ≤ minimum(φPn)
        # At or below max tension
        idx = argmin(φPn)
        return φMn[idx]
    end
    
    # Find bracketing points
    # The curve goes from high P (compression) to low P (tension)
    for i in 1:(n-1)
        P1, P2 = φPn[i], φPn[i+1]
        M1, M2 = φMn[i], φMn[i+1]
        
        # Check if Pu is between these points
        if (P1 ≥ Pu ≥ P2) || (P2 ≥ Pu ≥ P1)
            # Linear interpolation
            if abs(P1 - P2) < 1e-10
                return (M1 + M2) / 2
            end
            t = (Pu - P1) / (P2 - P1)
            return M1 + t * (M2 - M1)
        end
    end
    
    # Fallback: return closest point (allocation-free)
    best_idx = 1
    best_diff = abs(φPn[1] - Pu)
    @inbounds for k in 2:length(φPn)
        d = abs(φPn[k] - Pu)
        if d < best_diff
            best_diff = d
            best_idx = k
        end
    end
    return φMn[best_idx]
end

"""
    _interpolate_axial_at_M(φPn, φMn, Mu) -> Float64

Linearly interpolate factored axial capacity φPn (kip) at a given moment Mu (kip-ft)
along the P-M interaction curve. Returns the maximum φPn when multiple intersections exist.
"""
function _interpolate_axial_at_M(φPn::Vector, φMn::Vector, Mu::Real)
    n = length(φMn)
    
    # Handle edge cases
    if Mu ≤ minimum(φMn)
        # At or below minimum moment (pure axial cases)
        # Return max compression capacity
        return maximum(φPn)
    end
    
    max_M = maximum(φMn)
    if Mu ≥ max_M
        # Beyond the envelope - interpolate along the tension side
        # Find the point with maximum moment and return its P
        idx = argmax(φMn)
        return φPn[idx]
    end
    
    # The P-M curve is not single-valued in M (moment increases then decreases)
    # Find all points where M ≈ Mu and return the max P (conservative for compression)
    matching_P = Float64[]
    for i in 1:(n-1)
        M1, M2 = φMn[i], φMn[i+1]
        P1, P2 = φPn[i], φPn[i+1]
        
        # Check if Mu is between these points
        if (M1 ≤ Mu ≤ M2) || (M2 ≤ Mu ≤ M1)
            if abs(M1 - M2) < 1e-10
                push!(matching_P, (P1 + P2) / 2)
            else
                t = (Mu - M1) / (M2 - M1)
                push!(matching_P, P1 + t * (P2 - P1))
            end
        end
    end
    
    if isempty(matching_P)
        # Fallback: return closest point (allocation-free)
        best_idx = 1
        best_diff = abs(φMn[1] - Mu)
        @inbounds for k in 2:length(φMn)
            d = abs(φMn[k] - Mu)
            if d < best_diff
                best_diff = d
                best_idx = k
            end
        end
        return φPn[best_idx]
    end
    
    # Return max P (most conservative for compression check)
    return maximum(matching_P)
end

