# ─── Architectural layer ──────────────────────────────────────────────────────

"""
Build the architectural layer: system narrative and goal-ranked recommendations.
"""
function _diagnose_architectural(
    design::BuildingDesign,
    params::DesignParameters,
    du::DisplayUnits,
    col_dicts::Vector,
    beam_dicts::Vector,
    slab_dicts::Vector,
    fdn_dicts::Vector,
)
    n_stories = length(design.structure.skeleton.stories)
    n_cols    = length(col_dicts)
    n_slabs   = length(slab_dicts)
    n_beams   = length(beam_dicts)
    n_fdns    = length(fdn_dicts)

    floor_name = get(_FLOOR_NAMES, _floor_type_code(params), _floor_type_code(params))
    col_code   = _column_type_code(params)
    if col_code == "unknown"
        inferred = _column_type_code_from_design(design)
        inferred != "unknown" && (col_code = inferred)
    end
    col_name  = get(_COLUMN_NAMES, col_code, col_code)
    beam_code = _beam_type_code(params)
    if beam_code == "unknown"
        beam_code = _beam_type_code_from_design(design, params)
    end
    beam_name = get(_BEAM_NAMES, beam_code, beam_code)

    beam_clause = n_beams > 0 ? " with $n_beams $beam_name members" : ""
    narrative = "This is a $n_stories-story structure with a $floor_name and $n_cols $col_name" *
                " column$(n_cols == 1 ? "" : "s")$beam_clause. " *
                "There $(n_slabs == 1 ? "is" : "are") $n_slabs slab panel$(n_slabs == 1 ? "" : "s")" *
                " and $n_fdns foundation$(n_fdns == 1 ? "" : "s")."

    # Goal-ranked recommendations
    goal_recs = _build_goal_recommendations(design, params, du, col_dicts, beam_dicts, slab_dicts, fdn_dicts)

    return Dict{String, Any}(
        "system_narrative"  => narrative,
        "goal_recommendations" => goal_recs,
    )
end

