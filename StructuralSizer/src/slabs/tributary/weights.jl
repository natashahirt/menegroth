# Edge weight strategies for tributary area calculation
#
# Higher weight = faster wavefront propagation = larger tributary area
# Weights are normalized to sum to 1.0 before use in grassfire algorithm

"""
    WeightStrategy

Strategy for computing edge weights in tributary area calculations.
Higher-weighted edges "attract" more load (larger tributary area).
"""
@enum WeightStrategy begin
    WEIGHT_UNIFORM       # All edges equal (w=1)
    WEIGHT_SECTION_EI    # From beam section stiffness: E*I/L³
    WEIGHT_INV_LENGTH    # Inverse of edge length: 1/L
    WEIGHT_USER_DEFINED  # User-provided weights per edge
end

"""
    compute_edge_weights(strategy, edge_lengths; user_weights=nothing, sections=nothing, E=nothing)

Compute normalized edge weights for tributary area calculation.

# Arguments
- `strategy::WeightStrategy`: Which weighting strategy to use
- `edge_lengths::Vector{<:Real}`: Length of each edge (same units)
- `user_weights::Union{Nothing, Vector{<:Real}}`: Required for WEIGHT_USER_DEFINED
- `sections`: Reserved for future WEIGHT_SECTION_EI (beam section objects)
- `E`: Reserved for future WEIGHT_SECTION_EI (elastic modulus)

# Returns
- `Vector{Float64}`: Normalized weights (sum = 1.0), one per edge
"""
function compute_edge_weights(
    strategy::WeightStrategy,
    edge_lengths::AbstractVector{<:Real};
    user_weights::Union{Nothing, AbstractVector{<:Real}} = nothing,
    sections = nothing,
    E = nothing,
)::Vector{Float64}
    n = length(edge_lengths)
    n > 0 || throw(ArgumentError("edge_lengths cannot be empty"))

    raw_weights = _compute_raw_weights(strategy, edge_lengths; 
                                        user_weights=user_weights, 
                                        sections=sections, E=E)
    
    # Normalize to sum = 1.0
    total = sum(raw_weights)
    total > 0 || throw(ArgumentError("Total weight is zero; cannot normalize"))
    
    return raw_weights ./ total
end

"""Compute raw (unnormalized) weights based on strategy."""
function _compute_raw_weights(
    strategy::WeightStrategy,
    edge_lengths::AbstractVector{<:Real};
    user_weights = nothing,
    sections = nothing,
    E = nothing,
)::Vector{Float64}
    n = length(edge_lengths)

    if strategy == WEIGHT_UNIFORM
        return ones(Float64, n)

    elseif strategy == WEIGHT_INV_LENGTH
        # Weight inversely proportional to edge length
        # Shorter edges → higher stiffness → larger tributary
        lengths = Float64.(edge_lengths)
        all(L -> L > 0, lengths) || throw(ArgumentError("All edge lengths must be positive"))
        return 1.0 ./ lengths

    elseif strategy == WEIGHT_USER_DEFINED
        isnothing(user_weights) && throw(ArgumentError("WEIGHT_USER_DEFINED requires user_weights"))
        length(user_weights) == n || throw(ArgumentError("user_weights length ($(length(user_weights))) must match edge count ($n)"))
        all(w -> w >= 0, user_weights) || throw(ArgumentError("user_weights must be non-negative"))
        return Float64.(user_weights)

    elseif strategy == WEIGHT_SECTION_EI
        # Future: compute E*I/L³ from beam sections
        # For now, fall back to inverse length as approximation
        @warn "WEIGHT_SECTION_EI not yet implemented; falling back to WEIGHT_INV_LENGTH" maxlog=1
        return _compute_raw_weights(WEIGHT_INV_LENGTH, edge_lengths)
    
    else
        error("Unknown WeightStrategy: $strategy")
    end
end

"""
    weight_ratios(weights::Vector{Float64})

Convert normalized weights to ratios relative to the first edge.
Useful for canonical form hashing (scale-invariant).
"""
function weight_ratios(weights::AbstractVector{<:Real})::Vector{Float64}
    n = length(weights)
    n > 0 || return Float64[]
    w0 = Float64(weights[1])
    w0 > 0 || throw(ArgumentError("First weight must be positive for ratio computation"))
    return Float64.(weights) ./ w0
end
