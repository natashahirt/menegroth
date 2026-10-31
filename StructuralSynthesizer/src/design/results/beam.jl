
"""
Design result for a beam.
"""
Base.@kwdef mutable struct BeamDesignResult
    section_size::String = ""
    section_obj::Union{StructuralSizer.AbstractSection, Nothing} = nothing
    Mu::typeof(1.0u"kN*m") = 0.0u"kN*m"
    Vu::typeof(1.0u"kN") = 0.0u"kN"
    flexure_ratio::Float64 = 0.0
    shear_ratio::Float64 = 0.0
    ok::Bool = true
    # Material takeoff
    member_length::typeof(1.0u"m") = 0.0u"m"
    weight::typeof(1.0u"kg") = 0.0u"kg"
end

"""
    column_diagnostic_governing_check(cr::ColumnDesignResult) -> String

When `cr.ok`, returns the limit state with the highest demand/capacity ratio. When the column
fails, returns the check that actually drives failure: ratios above 1.0, or punching with
`punching.ok == false`, rather than whichever ratio is largest among still-passing checks.

An UNVERIFIED column — one whose §E3/§E4 steel-buckling axial capacity could not be evaluated,
carrying the `NaN` axial/interaction sentinel set in `_populate_column_results!` — is detected
FIRST and labeled `"axial_compression_unverified"`. Without this guard every `NaN` comparison
below is `false`, so the function would fall through to the else and MISLABEL the column
`"punching_shear_col"`. The returned label matches the summary path in `_compute_design_summary!`
exactly, so `/diagnose` and the summary agree on the unverified state.
"""
function column_diagnostic_governing_check(cr::ColumnDesignResult)::String
    # UNVERIFIED sentinel takes priority over every ratio comparison: NaN ≥/≤ anything is
    # `false`, so a fall-through would silently mis-attribute the failure to punching.
    if isnan(cr.axial_ratio) || isnan(cr.interaction_ratio)
        return "axial_compression_unverified"
    end
    punch_r = isnothing(cr.punching) ? 0.0 : cr.punching.ratio
    if cr.ok
        if cr.axial_ratio >= cr.interaction_ratio && cr.axial_ratio >= punch_r
            return "axial_compression"
        elseif cr.interaction_ratio >= punch_r
            return "pm_interaction"
        else
            return "punching_shear_col"
        end
    end
    candidates = Tuple{String, Float64}[]
    if cr.axial_ratio > 1.0
        push!(candidates, ("axial_compression", cr.axial_ratio))
    end
    if cr.interaction_ratio > 1.0
        push!(candidates, ("pm_interaction", cr.interaction_ratio))
    end
    if !isnothing(cr.punching) && (!cr.punching.ok || punch_r > 1.0)
        push!(candidates, ("punching_shear_col", punch_r))
    end
    if !isempty(candidates)
        _, j = findmax([c[2] for c in candidates])
        return candidates[j][1]
    end
    if cr.axial_ratio >= cr.interaction_ratio && cr.axial_ratio >= punch_r
        return "axial_compression"
    elseif cr.interaction_ratio >= punch_r
        return "pm_interaction"
    else
        return "punching_shear_col"
    end
end

"""
    beam_diagnostic_governing_check(br::BeamDesignResult) -> String

When `br.ok`, flexure vs shear by larger ratio. When `br.ok` is false, attributes failure to
checks with demand/capacity above 1.0 (worst among them), not merely the larger of two passing ratios.
"""
function beam_diagnostic_governing_check(br::BeamDesignResult)::String
    if br.ok
        return br.flexure_ratio >= br.shear_ratio ? "flexure" : "shear"
    end
    candidates = Tuple{String, Float64}[]
    if br.flexure_ratio > 1.0
        push!(candidates, ("flexure", br.flexure_ratio))
    end
    if br.shear_ratio > 1.0
        push!(candidates, ("shear", br.shear_ratio))
    end
    if !isempty(candidates)
        _, j = findmax([c[2] for c in candidates])
        return candidates[j][1]
    end
    return br.flexure_ratio >= br.shear_ratio ? "flexure" : "shear"
end
