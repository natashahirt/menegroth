# ─── Phase 3: Exploration ─────────────────────────────────────────────────────

"""
    _compare_design_history_pair(prev::DesignHistoryEntry, cur::DesignHistoryEntry;
        idx_prev::Int, idx_cur::Int) -> Dict{String, Any}

Build the LLM-facing comparison dict for two history entries. Deltas are **current − previous**
(`pass_improved` means the previous run failed and the latest passes).
"""
function _compare_design_history_pair(
    prev::DesignHistoryEntry,
    cur::DesignHistoryEntry;
    idx_prev::Int,
    idx_cur::Int,
)::Dict{String, Any}
    Δ_ratio = round(cur.critical_ratio - prev.critical_ratio; digits=4)
    Δ_ec    = round(cur.embodied_carbon - prev.embodied_carbon; digits=0)
    Δ_fail  = cur.n_failing - prev.n_failing

    params_prev = isempty(prev.cumulative_params) ? prev.params_patch : prev.cumulative_params
    params_cur  = isempty(cur.cumulative_params) ? cur.params_patch : cur.cumulative_params
    all_keys = union(keys(params_prev), keys(params_cur))
    changed_params = Dict{String, Any}()
    for k in all_keys
        va = get(params_prev, k, nothing)
        vb = get(params_cur, k, nothing)
        if va != vb
            changed_params[k] = Dict("from" => va, "to" => vb)
        end
    end

    ha = strip(prev.geometry_hash)
    hb = strip(cur.geometry_hash)
    cross_geo = !isempty(ha) && !isempty(hb) && ha != hb
    unknown_geo = isempty(ha) || isempty(hb)

    note = if cross_geo
        "These two history entries used different geometry_hash values. Deltas summarize stored summary metrics only — " *
            "they are not a same-geometry parameter study. Say so when explaining results."
    elseif unknown_geo
        "One or both entries lack geometry_hash (legacy). Treat cross-run deltas as approximate unless hashes match."
    else
        nothing
    end

    crit_prev = strip(prev.critical_element)
    crit_cur  = strip(cur.critical_element)
    mechanism_shift = if isempty(crit_prev) || isempty(crit_cur)
        nothing
    elseif crit_prev == crit_cur
        "same_critical_element"
    else
        "critical_element_changed"
    end

    out = Dict{String, Any}(
        "comparison_mode" => "previous_vs_current",
        "previous" => Dict(
            "history_index"    => idx_prev,
            "geometry_hash"    => ha,
            "all_pass"         => prev.all_pass,
            "critical_ratio"   => prev.critical_ratio,
            "critical_element" => crit_prev,
            "embodied_carbon_kgco2e" => prev.embodied_carbon,
            "n_failing"        => prev.n_failing,
            "source"           => prev.source,
        ),
        "current" => Dict(
            "history_index"    => idx_cur,
            "geometry_hash"    => hb,
            "all_pass"         => cur.all_pass,
            "critical_ratio"   => cur.critical_ratio,
            "critical_element" => crit_cur,
            "embodied_carbon_kgco2e" => cur.embodied_carbon,
            "n_failing"        => cur.n_failing,
            "source"           => cur.source,
        ),
        "deltas" => Dict(
            "critical_ratio_delta"  => Δ_ratio,
            "embodied_carbon_delta" => Δ_ec,
            "n_failing_delta"       => Δ_fail,
            "pass_improved"         => !prev.all_pass && cur.all_pass,
            "pass_regressed"        => prev.all_pass && !cur.all_pass,
        ),
        "changed_params" => changed_params,
        "cross_geometry_comparison" => cross_geo,
    )
    !isnothing(mechanism_shift) && (out["mechanism_shift"] = mechanism_shift)
    isnothing(note) || (out["comparison_note"] = note)

    guidance_parts = String[]
    if cross_geo
        push!(guidance_parts,
            "CROSS-GEOMETRY: These runs used different geometry. Deltas are not a controlled " *
            "parameter comparison on one model — tell the user both geometry and parameters may have changed. " *
            "Cite comparison_note in your response.")
    end
    if mechanism_shift == "critical_element_changed"
        push!(guidance_parts,
            "MECHANISM SHIFT: The governing element changed between runs. " *
            "Explain what failure mode now dominates and why the change shifted it.")
    end
    deltas = out["deltas"]
    if get(deltas, "pass_improved", false)
        push!(guidance_parts, "PASS IMPROVED: Latest run passes while the previous run failed — highlight this.")
    elseif get(deltas, "pass_regressed", false)
        push!(guidance_parts, "REGRESSION: Latest run fails while the previous run passed — warn the user.")
    end
    if !isempty(guidance_parts)
        out["_guidance"] = join(guidance_parts, "\n")
    end

    return out
end

"""
    agent_compare_previous_vs_current() -> Dict{String, Any}

Compare the **immediately previous** session history entry to the **latest** (most recent).
No indices — always the last two completed designs (POST /design and/or chat `run_design`).
"""
function agent_compare_previous_vs_current()::Dict{String, Any}
    history = get_design_history_entries()
    isempty(history) && return Dict(
        "error" => "no_history",
        "message" => "No designs in session history yet.",
        "recovery_hint" => "Complete a design (Grasshopper POST /design or chat run_design) first.",
    )
    length(history) < 2 && return Dict(
        "error" => "need_two_runs",
        "message" => "Need at least two completed designs in session history to compare previous vs current. Only $(length(history)) run(s) recorded.",
        "recovery_hint" => "Run another design, then call compare_designs again (no index arguments).",
    )
    n = length(history)
    return _compare_design_history_pair(history[end-1], history[end]; idx_prev=n - 1, idx_cur=n)
end

