# ─── Deflection Experiments ───────────────────────────────────────────────────

"""
    experiment_deflection(design, slab_idx; deflection_limit) -> Dict

Test what happens to a slab's deflection check under a different limit
(L/240, L/360, L/480). Uses the stored deflection values from the design.
"""
function experiment_deflection(
    design::BuildingDesign,
    slab_idx::Int;
    deflection_limit::String = "L_360",
)::Dict{String, Any}
    slab = get(design.slabs, slab_idx, nothing)
    isnothing(slab) && return Dict{String, Any}(
        "error" => "slab_not_found",
        "message" => "Slab index $slab_idx not found. Available: $(sort(collect(keys(design.slabs))))",
    )

    orig_deflection = slab.deflection_in
    orig_limit = slab.deflection_limit_in
    orig_ok = slab.deflection_ok
    orig_ratio = slab.deflection_ratio

    if isnothing(orig_deflection) || orig_deflection == 0.0
        return Dict{String, Any}(
            "error" => "no_deflection_data",
            "message" => "Slab $slab_idx has no stored deflection data.",
        )
    end

    # Get span from the structure's Slab object if available
    struc = design.structure
    span_in = nothing
    span_ft = nothing
    if !isnothing(struc) && slab_idx >= 1 && slab_idx <= length(struc.slabs)
        slab_obj = struc.slabs[slab_idx]
        gov_span = max(slab_obj.spans.primary, slab_obj.spans.secondary)
        span_in = try ustrip(u"inch", gov_span) catch; nothing end
        span_ft = try ustrip(u"ft", gov_span) catch; nothing end
    end

    # No fallback: deflection limit checks require real span data.
    # Without the structure, we can't reliably back-compute span from stored ratios.

    new_divisor = if deflection_limit == "L_240"
        240.0
    elseif deflection_limit == "L_360"
        360.0
    elseif deflection_limit == "L_480"
        480.0
    else
        return Dict{String, Any}(
            "error" => "invalid_limit",
            "message" => "deflection_limit must be L_240, L_360, or L_480. Got: $deflection_limit",
        )
    end

    if isnothing(span_in)
        return Dict{String, Any}(
            "error" => "no_span_data",
            "message" => "Slab $slab_idx has deflection data but no span information. Run with a design that includes structure data.",
        )
    end

    new_limit = span_in / new_divisor
    new_ratio = orig_deflection / new_limit
    new_ok = new_ratio <= 1.0

    # Determine what the original divisor was
    orig_divisor_approx = if orig_limit > 0
        round(Int, span_in / orig_limit)
    else
        0
    end

    thickness_in = try round(ustrip(u"inch", slab.thickness); digits=2) catch; nothing end

    orig_criterion = orig_divisor_approx > 0 ? "L/$(orig_divisor_approx)" : "unknown"

    setup = _experimental_setup(;
        changed = ["deflection limit: $(orig_criterion) → $(deflection_limit)"],
        held_constant = ["actual deflection = $(round(orig_deflection; digits=3)) in (not recomputed)",
                         "slab thickness = $(isnothing(thickness_in) ? "N/A" : "$(thickness_in) in")",
                         "span = $(isnothing(span_ft) ? "N/A" : "$(round(span_ft; digits=1)) ft")",
                         "concrete properties, loading, reinforcement"],
        source = "Cached design — slab $slab_idx",
        note = "Only the allowable limit changes. Actual deflection stays fixed. Actual deflection is not recomputed here.",
    )

    _dir_d = new_ratio < orig_ratio ? "decreased" : (new_ratio == orig_ratio ? "unchanged" : "increased")
    _ok_d  = new_ok ? "PASS" : "FAIL"

    result = Dict{String, Any}(
        "experiment" => "deflection",
        "result_summary" => "Ratio $_dir_d from $(round(orig_ratio; digits=3)) to " *
            "$(round(new_ratio; digits=3)) ($_ok_d). Delta = $(round(new_ratio - orig_ratio; digits=3)).",
        "experimental_setup" => setup,
        "slab_idx" => slab_idx,
        "slab_context" => Dict{String, Any}(
            "span_ft" => isnothing(span_ft) ? nothing : round(span_ft; digits=1),
            "thickness_in" => thickness_in,
            "current_limit_criterion" => orig_criterion,
        ),
        "original" => Dict{String, Any}(
            "deflection_in" => round(orig_deflection; digits=3),
            "limit_in" => round(orig_limit; digits=3),
            "ratio" => round(orig_ratio; digits=3),
            "ok" => orig_ok,
        ),
        "modified" => Dict{String, Any}(
            "deflection_limit" => deflection_limit,
            "limit_in" => round(new_limit; digits=3),
            "ratio" => round(new_ratio; digits=3),
            "ok" => new_ok,
        ),
        "delta_ratio" => round(new_ratio - orig_ratio; digits=3),
        "improved" => new_ratio < orig_ratio,
    )

    if !new_ok && orig_ok
        result["warning"] = "At $(deflection_limit), slab FAILS deflection: ratio = $(round(new_ratio; digits=3)) > 1.0."
    elseif new_ok && !orig_ok
        result["note"] = "At $(deflection_limit), slab PASSES deflection: $(round(orig_deflection; digits=3))\" < new limit $(round(new_limit; digits=3))\"."
    else
        result["note"] = "Actual deflection unchanged at $(round(orig_deflection; digits=3))\". Only the allowable limit changed."
    end

    return result
end

