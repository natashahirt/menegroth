# ─── Phase 2 continued: Solver Trace ─────────────────────────────────────────
#
# Core serialization helpers (serialize_trace_event, build_stage_timeline,
# filter_trace, TIER_EVENT_FILTERS, etc.) live in StructuralSizer.trace so
# they can be tested independently. This function assembles the LLM-facing
# response Dict using those shared primitives.
# ─────────────────────────────────────────────────────────────────────────────

"""
    agent_solver_trace(design::BuildingDesign; tier, element, layer) -> Dict{String, Any}

Tiered serializer for the solver decision trace. Returns a structured Dict
optimized for LLM consumption.

# Tiers (progressive disclosure)
- `:summary`   — pipeline/workflow enter/exit only (~5–15 events)
- `:failures`  — summary + all failure/fallback events
- `:decisions` — failures + decision/iteration events
- `:full`      — every recorded event

# Filters
- `element::String` — restrict to events matching this `element_id`
- `layer::Symbol`   — restrict to events from this trace layer

The return Dict includes metadata (`tier`, `total_events`, `shown_events`,
`layers_present`) so the LLM knows what it's seeing and can request a
deeper tier or narrower filter if needed.
"""
function agent_solver_trace(
    design::BuildingDesign;
    tier::Symbol = :failures,
    element::Union{String, Nothing} = nothing,
    layer::Union{Symbol, Nothing} = nothing,
)::Dict{String, Any}
    events = design.solver_trace

    if isempty(events)
        return Dict{String, Any}(
            "tier"         => string(tier),
            "total_events" => 0,
            "shown_events" => 0,
            "events"       => Any[],
            "note"         => "No solver trace available. The design may have been produced " *
                              "outside design_building (e.g. tests) or tracing failed to record events.",
        )
    end

    tier in StructuralSizer.TRACE_TIERS || return Dict{String, Any}(
        "error"   => "invalid_tier",
        "message" => "Tier must be one of: $(join(StructuralSizer.TRACE_TIERS, ", ")). Got: :$tier",
    )

    filtered = StructuralSizer.filter_trace(events; tier, element, layer)

    layers_present = sort(unique(string(ev.layer) for ev in events))
    elements_present = sort(unique(ev.element_id for ev in events if !isempty(ev.element_id)))

    serialized = StructuralSizer.serialize_trace_event.(filtered)
    timeline   = StructuralSizer.build_stage_timeline(events)

    result = Dict{String, Any}(
        "tier"              => string(tier),
        "total_events"      => length(events),
        "shown_events"      => length(serialized),
        "layers_present"    => layers_present,
        "elements_present"  => elements_present,
        "stage_timeline"    => timeline,
        "events"            => serialized,
    )

    if !isnothing(element)
        result["filter_element"] = element
    end
    if !isnothing(layer)
        result["filter_layer"] = string(layer)
    end

    # Tier-dependent hints for progressive disclosure
    if tier == :summary && any(ev -> ev.event_type in (:failure, :fallback), events)
        result["hint"] = "Failures detected in trace. Use tier=failures to see them."
    elseif tier == :failures && any(ev -> ev.event_type in (:decision, :iteration), events)
        n_decisions = count(ev -> ev.event_type in (:decision, :iteration), events)
        result["hint"] = "$n_decisions decision/iteration events available. Use tier=decisions for detail."
    end

    # Operational guidance — tell the LLM what to do with these results
    guidance_parts = String[]
    has_failures = any(ev -> ev.event_type in (:failure, :fallback), filtered)
    has_breadcrumbs = any(ev -> haskey(ev.data, "top_elements") || haskey(ev.data, "lookup"), filtered)

    if has_failures && tier in (:summary, :failures)
        push!(guidance_parts,
            "FAILURES IN TRACE: Cite the failure stage and element_id to the user. " *
            "Call get_diagnose_summary to correlate trace failures with check ratios.")
    end
    if has_breadcrumbs
        push!(guidance_parts,
            "BREADCRUMBS AVAILABLE: Events contain lookup keys. " *
            "Call explain_trace_lookup(lookup=<lookup_dict>) for per-check feasibility " *
            "detail on specific elements without re-running the design.")
    end
    if tier == :full && length(serialized) > 100
        push!(guidance_parts,
            "LARGE TRACE: $(length(serialized)) events shown. " *
            "Filter by element or layer for targeted analysis.")
    end
    if !isempty(guidance_parts)
        result["_guidance"] = join(guidance_parts, "\n")
    end

    return result
end

