# =============================================================================
# Pattern Loading Analysis - ACI 318-14 §6.4.3.2
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
# - ACI 318-14 Section 6.4.3.2
# - ACI 318-19 Section 6.4.3.2 (unchanged)
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

Check if pattern loading is required per ACI 318-14 §6.4.3.2.

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
- ACI 318-14 §6.4.3.2
- ACI 318-19 §6.4.3.2
"""
function requires_pattern_loading(qD, qL)
    # Extract numeric values (handle Unitful quantities)
    qD_val = qD isa Real ? qD : ustrip(qD)
    qL_val = qL isa Real ? qL : ustrip(qL)
    
    # Avoid division by zero
    if qD_val < 1e-10
        return true  # Conservative: if D ≈ 0, pattern loading required
    end
    
    return qL_val / qD_val > 0.75
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
# Moment Envelope (Stub - to be implemented with analysis integration)
# =============================================================================

"""
    MomentEnvelope

Results from pattern loading envelope analysis.

# Fields
- `M_neg_max`: Maximum negative moments at each support
- `M_pos_max`: Maximum positive moments at each span midpoint
- `M_neg_min`: Minimum negative moments (for load reversal checks)
- `controlling_cases`: Which load case controls at each location

# Note
This is a stub type. Full implementation requires integration with 
the specific analysis method (EFM, FEA) being used.
"""
struct MomentEnvelope
    M_neg_max::Vector{Float64}
    M_pos_max::Vector{Float64}
    M_neg_min::Vector{Float64}
    controlling_cases::Dict{Symbol, Int}
end

# =============================================================================
# Exports
# =============================================================================

export PatternLoadCase, FULL_LOAD, CHECKERBOARD_ODD, CHECKERBOARD_EVEN, ADJACENT_PAIRS
export requires_pattern_loading, generate_load_patterns, apply_load_pattern
export pattern_case_name, MomentEnvelope
