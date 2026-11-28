
"""
Design result for a beam.
"""
Base.@kwdef mutable struct BeamDesignResult
    section_size::String = ""
    section_obj::Union{StructuralSizer.AbstractSection, Nothing} = nothing
    Mu::typeof(1.0u"kN*m") = 0.0u"kN*m"
    # Moment of the ACI flexure check with the highest ratio (kip·ft from the
    # checker, stored in kN·m). `nothing` when that check was not reported.
    # `Mu` stays the peak of the solved load case.
    check_Mu::Union{Nothing, typeof(1.0u"kN*m")} = nothing
    Vu::typeof(1.0u"kN") = 0.0u"kN"
    flexure_ratio::Float64 = 0.0
    shear_ratio::Float64 = 0.0
    # The sizer's governing check and ratio for this section. Empty when the
    # section came from a path that does not report checks; the flexure and
    # shear ratios are then a plastic-moment and web-shear estimate.
    governing_check::String = ""
    governing_ratio::Float64 = 0.0
    # Clause, demand, and capacity of `governing_check`, copied from the sizer.
    # Demand and capacity stay NaN when that check has no single pair of units
    # (an H1 ratio mixes axial force and moment). A deflection check stores δ/L
    # and its limit.
    governing_clause::String = ""
    governing_demand::Float64 = NaN
    governing_capacity::Float64 = NaN
    ok::Bool = true
    # Row F 25% frame check. `nothing` when this beam was not in that check.
    seismic_frame::Union{SeismicFrameCheck, Nothing} = nothing
    # Material takeoff
    member_length::typeof(1.0u"m") = 0.0u"m"
    weight::typeof(1.0u"kg") = 0.0u"kg"
end

"""
    column_diagnostic_governing_check(cr::ColumnDesignResult) -> String

When `cr.ok`, returns the limit state with the highest demand/capacity ratio. When the column
fails, returns the check that actually drives failure: ratios above 1.0, or punching with
`punching.ok == false`, rather than whichever ratio is largest among still-passing checks.

A column the sizer checked returns that check's name. Otherwise an UNVERIFIED
column — one whose §E3/§E4 steel-buckling axial capacity could not be evaluated,
carrying the `NaN` axial/interaction sentinel set in `_populate_column_results!` — is
labeled `"axial_compression_unverified"`. Without this guard every `NaN` comparison
below is `false`, so the function would fall through to the else and MISLABEL the column
`"punching_shear_col"`.
"""
function column_diagnostic_governing_check(cr::ColumnDesignResult)::String
    # UNVERIFIED sentinel takes priority over every ratio comparison: NaN ≥/≤ anything is
    # `false`, so a fall-through would silently mis-attribute the failure to punching.
    # The sizer's name wins over the NaN sentinel. A steel section stored
    # without its material leaves the Chapter E screen unverified, while the
    # sizing pass itself recorded a real check.
    if !isempty(cr.governing_check)
        return cr.governing_check
    end
    if isnan(cr.axial_ratio) || isnan(cr.interaction_ratio)
        return "axial_compression_unverified"
    end
    punch_r = isnothing(cr.punching) ? 0.0 : cr.punching.ratio
    seis_r = _seismic_frame_ratio(cr.seismic_frame)
    # Equal ratios keep the earlier name: axial, then P-M, then shear, then punching,
    # then the row F frame check.
    scores = (
        ("axial_compression", cr.axial_ratio),
        ("pm_interaction", cr.interaction_ratio),
        ("column_shear", cr.shear_ratio),
        ("punching_shear_col", punch_r),
        ("seismic_frame", seis_r),
    )
    best = scores[1][1]
    best_r = scores[1][2]
    for (name, r) in scores[2:end]
        if r > best_r
            best = name
            best_r = r
        end
    end
    if cr.ok
        return best
    end
    candidates = Tuple{String, Float64}[]
    if cr.axial_ratio > 1.0
        push!(candidates, ("axial_compression", cr.axial_ratio))
    end
    if cr.interaction_ratio > 1.0
        push!(candidates, ("pm_interaction", cr.interaction_ratio))
    end
    if !cr.shear_ok || cr.shear_ratio > 1.0
        push!(candidates, ("column_shear", max(cr.shear_ratio, 1.0)))
    end
    if !isnothing(cr.punching) && (!cr.punching.ok || punch_r > 1.0)
        push!(candidates, ("punching_shear_col", punch_r))
    end
    if !isnothing(cr.seismic_frame) && !cr.seismic_frame.passed
        push!(candidates, ("seismic_frame", max(seis_r, 1.0)))
    end
    if !isempty(candidates)
        _, j = findmax([c[2] for c in candidates])
        return candidates[j][1]
    end
    return best
end

"""Finite row F ratio, or 0 when the check is absent or its ratio is not finite."""
function _seismic_frame_ratio(sf::Union{SeismicFrameCheck, Nothing})
    sf === nothing && return 0.0
    return isfinite(sf.ratio) ? sf.ratio : 0.0
end

"""
    beam_diagnostic_governing_check(br::BeamDesignResult) -> String

When `br.ok`, flexure vs shear by larger ratio, unless the row F frame check
is higher. When `br.ok` is false, attributes failure to checks with
demand/capacity above 1.0 (worst among them). A failing row F check is
`"seismic_frame"`.
"""
function beam_diagnostic_governing_check(br::BeamDesignResult)::String
    seis_r = _seismic_frame_ratio(br.seismic_frame)
    seis_fail = br.seismic_frame !== nothing && !br.seismic_frame.passed
    sizer_r = isempty(br.governing_check) ?
        max(br.flexure_ratio, br.shear_ratio) : br.governing_ratio
    sizer_r = isfinite(sizer_r) ? sizer_r : 0.0
    if seis_fail && (!br.ok && max(seis_r, 1.0) >= sizer_r)
        return "seismic_frame"
    end
    if br.ok && br.seismic_frame !== nothing && seis_r > sizer_r
        return "seismic_frame"
    end
    isempty(br.governing_check) || return br.governing_check
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
