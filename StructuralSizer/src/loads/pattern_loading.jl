# =============================================================================
# Pattern Loading Analysis - ACI 318-11 §13.7.6
# =============================================================================
#
# Pattern loading is required for continuous systems when L/D > 0.75.
# This module provides load pattern generation and envelope computation
# for use with any stiffness-based analysis method (EFM, FEA).
#
# Applicable to:
# - Flat plate (RC and PT)
# - Voided plate
# - One-way continuous slabs
# - Skip joist systems
#
# Reference:
# - ACI 318-11 §13.7.6 (pattern loading for two-way slabs)
#
# =============================================================================

"""
Pattern load case enumeration.

# Cases
- `FULL_LOAD`: All spans loaded with D + L (baseline)
- `CHECKERBOARD_ODD`: Odd spans D + L, even spans D only
- `CHECKERBOARD_EVEN`: Even spans D + L, odd spans D only
- `ADJACENT_PAIRS`: Adjacent span pairs loaded alternately (maximizes interior negative moment)
"""
@enum PatternLoadCase begin
    FULL_LOAD              # All spans: D + L
    CHECKERBOARD_ODD       # Odd spans: D + L, Even: D only
    CHECKERBOARD_EVEN      # Even spans: D + L, Odd: D only
    ADJACENT_PAIRS         # Adjacent pairs loaded (for 3+ spans)
end

"""
    requires_pattern_loading(qD, qL) -> Bool

Check if pattern loading is required per ACI 318-11 §13.7.6.

Pattern loading is required when the live-to-dead load ratio exceeds 0.75:
    L/D > 0.75

For typical buildings:
- Office (L=50 psf, D~100 psf): L/D ≈ 0.50 → NOT required
- Residential (L=40 psf, D~100 psf): L/D ≈ 0.40 → NOT required
- Assembly (L=100 psf, D~100 psf): L/D ≈ 1.00 → REQUIRED
- Storage (L=125 psf, D~100 psf): L/D ≈ 1.25 → REQUIRED

# Arguments
- `qD`: Dead load (pressure)
- `qL`: Live load (pressure)

# Returns
`true` if pattern loading is required, `false` otherwise

# Reference
- ACI 318-11 §13.7.6
"""
function requires_pattern_loading(qD, qL)
    # Compute the dimensionless ratio directly — Unitful cancels units automatically.
    # For bare Reals (pre-stripped), this also works.
    ratio = if qD isa Real && qL isa Real
        abs(qD) < 1e-10 && return true
        qL / qD
    else
        qD_Pa = ustrip(u"Pa", qD)
        abs(qD_Pa) < 1e-10 && return true
        ustrip(u"Pa", qL) / qD_Pa
    end
    return ratio > 0.75
end

"""
    generate_load_patterns(n_spans::Int) -> Vector{Vector{Symbol}}

Generate all required load patterns for a given number of spans.

# Returns
Vector of patterns, where each pattern is a vector of `:dead_plus_live` or 
`:dead_only` symbols for each span.

# Cases Generated
- Full load (always)
- Checkerboard patterns (2)
- Adjacent pairs (for 3+ spans)

# Example
```julia
patterns = generate_load_patterns(3)
# Returns:
# [[:dead_plus_live, :dead_plus_live, :dead_plus_live],  # Full
#  [:dead_plus_live, :dead_only, :dead_plus_live],       # Odd
#  [:dead_only, :dead_plus_live, :dead_only],            # Even
#  [:dead_plus_live, :dead_plus_live, :dead_only],       # Adjacent 1-2
#  [:dead_only, :dead_plus_live, :dead_plus_live]]       # Adjacent 2-3
```
"""
function generate_load_patterns(n_spans::Int)
    patterns = Vector{Vector{Symbol}}()
    
    # Case 1: Full load (always required as baseline)
    push!(patterns, fill(:dead_plus_live, n_spans))
    
    # Case 2: Checkerboard - odd spans loaded
    odd_pattern = [isodd(i) ? :dead_plus_live : :dead_only for i in 1:n_spans]
    push!(patterns, odd_pattern)
    
    # Case 3: Checkerboard - even spans loaded  
    even_pattern = [iseven(i) ? :dead_plus_live : :dead_only for i in 1:n_spans]
    push!(patterns, even_pattern)
    
    # Cases 4+: Adjacent spans (for 3+ spans, maximizes interior negative moment)
    if n_spans >= 3
        for start_span in 1:(n_spans-1)
            adjacent = fill(:dead_only, n_spans)
            adjacent[start_span] = :dead_plus_live
            adjacent[start_span + 1] = :dead_plus_live
            push!(patterns, adjacent)
        end
    end
    
    return patterns
end

"""
    apply_load_pattern(pattern::Vector{Symbol}, qD, qL) -> Vector

Create load intensity vector based on pattern.

# Arguments
- `pattern`: Vector of `:dead_plus_live` or `:dead_only` for each span
- `qD`: Dead load intensity
- `qL`: Live load intensity

# Returns
Vector of load intensities for each span
"""
function apply_load_pattern(pattern::Vector{Symbol}, qD, qL)
    loads = similar([qD], length(pattern))  # Preserve type
    
    for (i, load_type) in enumerate(pattern)
        if load_type == :dead_plus_live
            loads[i] = qD + qL
        else  # :dead_only
            loads[i] = qD
        end
    end
    
    return loads
end

"""
    pattern_case_name(case::PatternLoadCase) -> String

Human-readable name for a pattern load case.
"""
function pattern_case_name(case::PatternLoadCase)
    if case == FULL_LOAD
        return "Full Load (D+L all spans)"
    elseif case == CHECKERBOARD_ODD
        return "Checkerboard (odd spans loaded)"
    elseif case == CHECKERBOARD_EVEN
        return "Checkerboard (even spans loaded)"
    else
        return "Adjacent Pairs"
    end
end

# =============================================================================
# Factored Pattern Loads  (ACI 318-11 §13.7.6 / §9.2.1)
# =============================================================================

"""
    factored_pattern_loads(pattern, qD, qL) -> Vector{Pressure}

Compute per-span **factored** pressures for a given load pattern.

Within the governing load combination (1.2D + 1.6L), live load is placed only
on the loaded spans while dead load acts everywhere:
- `:dead_plus_live` → max(1.2D + 1.6L, 1.4D)
- `:dead_only`      → 1.2D

Using 1.2D (rather than 1.4D) for unloaded spans is correct because all
spans share the same load combination — we are only varying the placement
of the live-load component.

# Reference
- ACI 318-11 §13.7.6 (pattern loading trigger)
- ACI 318-11 §9.2.1 / ASCE 7 §2.3.1 (factored load combinations)
"""
function factored_pattern_loads(pattern::Vector{Symbol}, qD, qL)
    qu_loaded = max(1.2 * qD + 1.6 * qL, 1.4 * qD)
    qu_dead   = 1.2 * qD  # same combo, live portion omitted

    loads = similar([qD], length(pattern))
    for (i, load_type) in enumerate(pattern)
        loads[i] = load_type === :dead_plus_live ? qu_loaded : qu_dead
    end
    return loads
end

