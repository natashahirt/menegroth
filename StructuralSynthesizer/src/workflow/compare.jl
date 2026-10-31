# =============================================================================
# Design Comparison Utilities
# =============================================================================

"""
    compare_designs(designs::Vector{BuildingDesign})

Create a comparison table of multiple designs.
"""
function compare_designs(designs::Vector{BuildingDesign})
    results = Dict{String, Dict{Symbol, Any}}()
    
    for d in designs
        results[d.params.name] = Dict(
            :concrete_volume => d.summary.concrete_volume,
            :steel_weight => d.summary.steel_weight,
            :embodied_carbon => d.summary.embodied_carbon,
            :all_ok => d.summary.all_checks_pass,
            :critical_ratio => d.summary.critical_ratio,
            :compute_time => d.compute_time_s
        )
    end
    
    return results
end

"""Two-design convenience: wraps into a vector and delegates."""
compare_designs(d1::BuildingDesign, d2::BuildingDesign) = compare_designs([d1, d2])
