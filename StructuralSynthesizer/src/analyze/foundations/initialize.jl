"""
    initialize_foundations!(struc::BuildingStructure; groupings=nothing)

Create Foundation objects for supports.

# Arguments
- `groupings`: Optional vector of support index vectors for combined foundations.
  If `nothing`, creates 1:1 mapping (one spread footing per support).

# Example
```julia
# One footing per column (default)
initialize_foundations!(struc)

# Combined footing for supports 1 & 2
initialize_foundations!(struc; groupings=[[1, 2], [3], [4]])
```
"""
function initialize_foundations!(struc::BuildingStructure{T};
                                  groupings::Union{Nothing, Vector{Vector{Int}}}=nothing,
                                  skip::Set{Int}=Set{Int}()) where T
    isempty(struc.supports) && throw(ArgumentError("No supports. Call initialize_supports!() first."))
    
    empty!(struc.foundations)
    
    if isnothing(groupings)
        # Default: one foundation per support. Supports already carried by a
        # grade-wall footing are left out.
        for (i, _) in enumerate(struc.supports)
            i in skip && continue
            # Placeholder result - will be filled by size_foundations!
            placeholder = _placeholder_foundation_result(T)
            fnd = Foundation([i], placeholder; foundation_type=:spread)
            push!(struc.foundations, fnd)
        end
    else
        # Explicit groupings
        for supp_indices in groupings
            idxs = filter(i -> i ∉ skip, supp_indices)
            isempty(idxs) && continue
            ftype = length(idxs) > 1 ? :combined : :spread
            placeholder = _placeholder_foundation_result(T)
            fnd = Foundation(idxs, placeholder; foundation_type=ftype)
            push!(struc.foundations, fnd)
        end
    end
    
    @debug "Initialized $(length(struc.foundations)) foundations"
    return struc
end

"""Create a zero-valued `SpreadFootingResult` placeholder for undesigned foundations."""
function _placeholder_foundation_result(::Type{T}) where T
    L = typeof(1.0u"m")
    V = typeof(1.0u"m^3")
    F = typeof(1.0u"kN")
    StructuralSizer.SpreadFootingResult{L, V, F}(
        0.0u"m", 0.0u"m", 0.0u"m", 0.0u"m",
        0.0u"m", 0, 0.0u"m",
        0.0u"m^3", 0.0u"m^3", 0.0
    )
end

