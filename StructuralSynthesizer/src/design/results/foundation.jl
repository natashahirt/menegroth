
"""
Design result for a foundation.
"""
Base.@kwdef mutable struct FoundationDesignResult
    # Geometry
    length::typeof(1.0u"m") = 0.0u"m"
    width::typeof(1.0u"m") = 0.0u"m"
    depth::typeof(1.0u"m") = 0.0u"m"
    
    # Demands
    reaction::typeof(1.0u"kN") = 0.0u"kN"
    
    # Checks
    bearing_ratio::Float64 = 0.0      # actual / allowable bearing pressure
    punching_ratio::Float64 = 0.0     # punching shear check
    flexure_ratio::Float64 = 0.0      # flexure check
    ok::Bool = true
    
    # Material quantities (propagated from Sizer-level result)
    concrete_volume::typeof(1.0u"m^3") = 0.0u"m^3"
    steel_volume::typeof(1.0u"m^3") = 0.0u"m^3"
    
    # Group assignment
    group_id::Int = 0
end

"""
    foundation_diagnostic_governing_check(fr::FoundationDesignResult) -> String

When `fr.ok`, highest utilization among bearing, punching, and flexure. When the footing fails,
picks the limit state(s) over capacity (ratio > 1) with the worst ratio, not the largest ratio
among checks that still pass.
"""
function foundation_diagnostic_governing_check(fr::FoundationDesignResult)::String
    rb = fr.bearing_ratio
    rp = fr.punching_ratio
    rf = fr.flexure_ratio
    if fr.ok
        if rb >= rp && rb >= rf
            return "bearing"
        elseif rp >= rf
            return "punching_shear_fdn"
        else
            return "flexure_fdn"
        end
    end
    candidates = Tuple{String, Float64}[]
    rb > 1.0 && push!(candidates, ("bearing", rb))
    rp > 1.0 && push!(candidates, ("punching_shear_fdn", rp))
    rf > 1.0 && push!(candidates, ("flexure_fdn", rf))
    if !isempty(candidates)
        _, j = findmax([c[2] for c in candidates])
        return candidates[j][1]
    end
    if rb >= rp && rb >= rf
        return "bearing"
    elseif rp >= rf
        return "punching_shear_fdn"
    else
        return "flexure_fdn"
    end
end

