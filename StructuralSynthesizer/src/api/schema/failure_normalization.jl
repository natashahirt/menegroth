# ─── Output Schema ───────────────────────────────────────────────────────────
# Output structs are immutable (write-only, never parsed from JSON).

"""Canonical failure reason codes for slab results."""
const API_SLAB_FAILURE_REASONS = (
    "non_convergence",
    "section_inadequate",
    "high_aspect_ratio",
    "ddm_ineligible",
    "applicability",
    "skeleton_build_failed",
    "solver_error",
    "unknown",
    "",
)

"""Canonical failing check codes for slab results."""
const API_SLAB_FAILING_CHECKS = (
    "punching_shear",
    "two_way_deflection",
    "two_way_deflection_secondary",
    "one_way_shear",
    "flexural_adequacy",
    "reinforcement_design",
    "reinforcement_design_secondary",
    "transfer_reinforcement",
    "column_pm",
    "applicability",
    "none",
    "",
)

"""
    _normalize_failure_reason(raw::String) -> String

Map a raw failure_reason string to a canonical enum token.
Joined multi-value strings, exception type names, and stack traces
are mapped to the closest canonical value.
"""
function _normalize_failure_reason(raw::String)
    isempty(raw) && return ""
    stripped = strip(raw)
    stripped in API_SLAB_FAILURE_REASONS && return stripped
    occursin("non_convergence", stripped) && return "non_convergence"
    occursin("section_inadequate", stripped) && return "section_inadequate"
    occursin("high_aspect_ratio", stripped) && return "high_aspect_ratio"
    occursin("ddm_ineligible", stripped) && return "ddm_ineligible"
    occursin("applicability", stripped) && return "applicability"
    occursin("skeleton_build_failed", stripped) && return "skeleton_build_failed"
    occursin("column_pm_infeasible", stripped) && return "section_inadequate"
    occursin("Error", stripped) || occursin("error", stripped) && return "solver_error"
    return "unknown"
end

"""
    _normalize_failing_checks(raw::String) -> Vector{String}

Parse a raw failing_check string into an array of canonical check codes.
Handles comma-separated values, single tokens, and stack trace fallback.
"""
function _normalize_failing_checks(raw::String)
    isempty(raw) && return String[]
    parts = [strip(p) for p in split(raw, r"[,;]")]
    result = String[]
    for part in parts
        isempty(part) && continue
        if part in API_SLAB_FAILING_CHECKS
            push!(result, part)
        elseif occursin("punching", part)
            push!(result, "punching_shear")
        elseif occursin("deflection", part)
            push!(result, "two_way_deflection")
        elseif occursin("shear", part)
            push!(result, "one_way_shear")
        elseif occursin("flexur", part)
            push!(result, "flexural_adequacy")
        elseif occursin("reinforcement", part)
            push!(result, "reinforcement_design")
        elseif occursin("transfer", part)
            push!(result, "transfer_reinforcement")
        elseif occursin("column_pm", part)
            push!(result, "column_pm")
        elseif occursin("applicability", part)
            push!(result, "applicability")
        else
            push!(result, part)
        end
    end
    return unique(result)
end

