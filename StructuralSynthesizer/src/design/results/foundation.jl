
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
    
    # Checks. Zero means the design routine did not report that check.
    bearing_ratio::Float64 = 0.0        # service soil pressure / allowable
    punching_ratio::Float64 = 0.0       # two-way shear Vu/φVc
    one_way_shear_ratio::Float64 = 0.0  # one-way shear Vu/φVc
    flexure_ratio::Float64 = 0.0        # flexure check
    # The design routine's governing utilization; `ok` is decided on it.
    governing_ratio::Float64 = 0.0
    ok::Bool = true
    
    # Material quantities (propagated from Sizer-level result)
    concrete_volume::typeof(1.0u"m^3") = 0.0u"m^3"
    steel_volume::typeof(1.0u"m^3") = 0.0u"m^3"
    
    # Group assignment
    group_id::Int = 0
end

"""
    foundation_check_ratios(fr::FoundationDesignResult) -> Tuple

`(label, ratio)` pairs for each reported foundation check.
"""
foundation_check_ratios(fr::FoundationDesignResult) = (
    ("bearing", fr.bearing_ratio),
    ("punching_shear_fdn", fr.punching_ratio),
    ("one_way_shear_fdn", fr.one_way_shear_ratio),
    ("flexure_fdn", fr.flexure_ratio),
)

"""
    foundation_diagnostic_governing_check(fr::FoundationDesignResult) -> String

The check with the highest ratio. When the footing fails, only checks over
capacity (ratio > 1) are candidates. Returns `"utilization"` when the failing
governing ratio is not explained by any reported check.
"""
function foundation_diagnostic_governing_check(fr::FoundationDesignResult)::String
    checks = foundation_check_ratios(fr)
    label, r = argmax(last, checks)
    fr.ok && return label
    r > 1.0 && return label
    return fr.governing_ratio > 1.0 ? "utilization" : label
end
