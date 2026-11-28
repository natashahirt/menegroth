# =============================================================================
# Agent Tools — implementation functions for LLM agent tool dispatch
#
# Phase 1 (Orientation): get_building_summary, get_current_params
# Phase 2 (Diagnosis):   query_elements, explain_field, get_solver_trace
# Phase 3 (Exploration):  compare_designs, suggest_next_action
# =============================================================================

using Statistics: mean, std

const _FLOOR_NAMES = Dict{String, String}(
    "flat_plate" => "Flat Plate (two-way beamless slab)",
    "flat_slab"  => "Flat Slab (flat plate with drop panels)",
    "one_way"    => "One-Way Slab-and-Beam",
    "vault"      => "Unreinforced Concrete Vault",
)

# ─── Slab panel plan metrics (face outlines, XY — not beam spans) ─────────────

function _slab_face_indices(skel::BuildingSkeleton)::Vector{Int}
    g = get(skel.groups_faces, :slabs, Int[])
    return !isempty(g) ? Int[gi for gi in g] : collect(1:length(skel.faces))
end

function _panel_xy_outline(skel::BuildingSkeleton, face_idx::Int)::Vector{NTuple{2,Float64}}
    vidx = skel.face_vertex_indices[face_idx]
    return map(vi -> begin
        c = vertex_coords(skel, vi)
        (c.x, c.y)
    end, vidx)
end

function _polygon_edge_lengths_m(pts::Vector{NTuple{2,Float64}})::Vector{Float64}
    n = length(pts)
    n < 2 && return Float64[]
    ls = Float64[]
    @inbounds for i in 1:n
        j = i == n ? 1 : i + 1
        push!(ls, hypot(pts[j][1] - pts[i][1], pts[j][2] - pts[i][2]))
    end
    return ls
end

"""Interior angles (degrees) at each vertex of a simple polygon in the XY plane."""
function _polygon_interior_angles_deg(pts::Vector{NTuple{2,Float64}})::Vector{Float64}
    n = length(pts)
    n < 3 && return Float64[]
    angs = Float64[]
    @inbounds for i in 1:n
        im = i == 1 ? n : i - 1
        ip = i == n ? 1 : i + 1
        p_im, p_i, p_ip = pts[im], pts[i], pts[ip]
        v1x, v1y = p_im[1] - p_i[1], p_im[2] - p_i[2]
        v2x, v2y = p_ip[1] - p_i[1], p_ip[2] - p_i[2]
        nv1 = hypot(v1x, v1y)
        nv2 = hypot(v2x, v2y)
        (nv1 < 1e-9 || nv2 < 1e-9) && continue
        d = clamp((v1x * v2x + v1y * v2y) / (nv1 * nv2), -1.0, 1.0)
        push!(angs, rad2deg(acos(d)))
    end
    return angs
end

"""
    _agent_slab_panel_plan_metrics(skel) -> Union{Nothing, Dict}

Per-slab-face outline analysis in plan (XY): topology (tri/quad/other), corner
orthogonality for quads, and per-panel edge aspect ratio (max/min boundary edge).
Used to separate true non-orthogonal / mixed-panel plans from “different X vs Y
bay sizes” on an orthogonal grid (which mostly shows up in beam span CV, not here).
"""
function _agent_slab_panel_plan_metrics(skel::BuildingSkeleton)::Union{Nothing, Dict{String, Any}}
    faces_idx = _slab_face_indices(skel)
    isempty(faces_idx) && return nothing

    n_tri = 0
    n_quad = 0
    n_oth = 0
    panel_aspects = Float64[]
    quad_corner_devs = Float64[]
    quad_panel_max_dev = Float64[]
    n_quad_orthogonal = 0

    for fi in faces_idx
        (fi < 1 || fi > length(skel.face_vertex_indices)) && continue
        pts = _panel_xy_outline(skel, fi)
        nv = length(pts)
        if nv == 3
            n_tri += 1
        elseif nv == 4
            n_quad += 1
        else
            n_oth += 1
        end
        ls = _polygon_edge_lengths_m(pts)
        if !isempty(ls)
            mn = minimum(ls)
            mx = maximum(ls)
            if mn > 1.0e-4
                push!(panel_aspects, mx / mn)
            end
        end
        if nv == 4
            angs = _polygon_interior_angles_deg(pts)
            if length(angs) == 4
                devs = [abs(a - 90.0) for a in angs]
                append!(quad_corner_devs, devs)
                push!(quad_panel_max_dev, maximum(devs))
                if mean(devs) < 6.0
                    n_quad_orthogonal += 1
                end
            end
        end
    end

    n_panels = length(faces_idx)
    n_panels == 0 && return nothing

    tri_frac = n_tri / n_panels
    aspect_stats = if length(panel_aspects) > 1
        μ = mean(panel_aspects)
        cv = std(panel_aspects) / μ
        Dict{String, Any}(
            "mean" => round(μ; digits=3),
            "cv"   => round(cv; digits=3),
            "min"  => round(minimum(panel_aspects); digits=3),
            "max"  => round(maximum(panel_aspects); digits=3),
            "n"    => length(panel_aspects),
        )
    elseif length(panel_aspects) == 1
        Dict{String, Any}(
            "mean" => round(panel_aspects[1]; digits=3),
            "cv"   => 0.0,
            "min"  => round(panel_aspects[1]; digits=3),
            "max"  => round(panel_aspects[1]; digits=3),
            "n"    => 1,
        )
    else
        nothing
    end

    q_mean_dev = isempty(quad_corner_devs) ? nothing : mean(quad_corner_devs)
    q_max_dev = isempty(quad_panel_max_dev) ? nothing : maximum(quad_panel_max_dev)

    # Plan-shape classification from slab cells (not from beam spans).
    classification = "no_slab_faces"
    if n_panels == 0
        classification = "no_slab_faces"
    elseif n_oth > 0 || tri_frac > 0.35 || (n_quad == 0 && n_tri > 0)
        classification = "triangular_mixed_or_complex_panels"
    elseif n_quad > 0 && !isnothing(q_mean_dev) && !isnothing(q_max_dev) &&
           (q_mean_dev > 8.0 || q_max_dev > 15.0)
        classification = "non_orthogonal_or_skewed_quads"
    elseif n_quad > 0 && !isnothing(aspect_stats) && !isnothing(q_mean_dev) &&
           aspect_stats["cv"] > 0.28 && q_mean_dev <= 8.0
        classification = "orthogonal_cells_variable_bay_aspect"
    elseif n_quad > 0 && !isnothing(q_mean_dev) && q_mean_dev <= 8.0
        classification = "orthogonal_rectangular_cells"
    else
        classification = "undetermined_mixed_topology"
    end

    ortho_frac = n_quad > 0 ? n_quad_orthogonal / n_quad : nothing

    return Dict{String, Any}(
        "basis" => "slab_face_outlines_projected_to_xy",
        "n_panels" => n_panels,
        "topology" => Dict{String, Any}(
            "triangular"     => n_tri,
            "quadrilateral"  => n_quad,
            "other_vertex_count" => n_oth,
        ),
        "triangular_fraction" => round(tri_frac; digits=3),
        "quad_corner_deviation_from_90_deg" =>
            (isnothing(q_mean_dev) && isnothing(q_max_dev)) ? nothing :
            Dict{String, Any}(
                "mean" => round(something(q_mean_dev, 0.0); digits=2),
                "max"  => round(something(q_max_dev, 0.0); digits=2),
            ),
        "fraction_of_quads_orthogonal_mean_dev_lt_6_deg" =>
            isnothing(ortho_frac) ? nothing : round(ortho_frac; digits=3),
        "panel_edge_aspect_ratio_max_over_min" => aspect_stats,
        "plan_shape_classification" => classification,
        "interpretation" =>
            "Use this block (slab face outlines) for plan irregularity vs orthogonal grids. " *
            "Beam span_stats mix all frame edges and are misleading for plan regularity when X and Y bay sizes differ. " *
            "orthogonal_cells_variable_bay_aspect = rectangular panels with ~90° corners but different cell proportions across the floor; " *
            "non_orthogonal_or_skewed_quads = corners deviate from 90°; triangular_mixed_or_complex_panels = triangulated or non-quad dominant layouts. " *
            "Angles use XY projection (typical for level slabs); strongly sloped or warped faces may distort corner metrics.",
    )
end

# ─── Phase 1: Orientation ─────────────────────────────────────────────────────

"""
    agent_building_summary(struc::BuildingStructure) -> Dict{String, Any}

Geometry-only summary: stories, member counts, span statistics, regularity.
Does not require a completed design.
"""
function agent_building_summary(struc::BuildingStructure)::Dict{String, Any}
    skel = struc.skeleton
    n_stories = length(skel.stories)
    n_cols    = length(struc.columns)
    n_beams   = length(struc.beams)
    n_slabs   = length(struc.slabs)
    n_fdns    = length(struc.foundations)

    # Story heights from skeleton.stories_z (may be Unitful or plain Float64)
    story_z = sort(skel.stories_z)
    story_heights = Float64[]
    for i in 2:length(story_z)
        dz = story_z[i] - story_z[i-1]
        push!(story_heights, try ustrip(u"m", dz) catch; Float64(dz) end)
    end

    # Edge lengths for span statistics
    beam_lengths = Float64[]
    if !isnothing(skel.geometry)
        for len in skel.geometry.edge_lengths
            lm = try ustrip(u"m", len) catch; Float64(len) end
            lm > 0.1 && push!(beam_lengths, lm)
        end
    end

    span_stats = if !isempty(beam_lengths)
        mn = minimum(beam_lengths)
        mx = maximum(beam_lengths)
        μ  = mean(beam_lengths)
        cv = length(beam_lengths) > 1 ? std(beam_lengths) / μ : 0.0
        Dict{String, Any}(
            "basis"  => "beam_frame_edges_all_directions",
            "min_m"  => round(mn; digits=2),
            "max_m"  => round(mx; digits=2),
            "mean_m" => round(μ;  digits=2),
            "cv"     => round(cv; digits=3),
            "n_edges" => length(beam_lengths),
        )
    else
        nothing
    end

    height_stats = if !isempty(story_heights)
        Dict{String, Any}(
            "min_m" => round(minimum(story_heights); digits=2),
            "max_m" => round(maximum(story_heights); digits=2),
            "total_m" => round(sum(story_heights); digits=2),
        )
    else
        nothing
    end

    # Span length CV mixes all beam edges (X- and Y-oriented). Different orthogonal bay sizes
    # inflate CV — do NOT treat that as "plan irregularity". Regularity here = story-height variation only.
    span_diversity = nothing
    if !isnothing(span_stats)
        cv = span_stats["cv"]
        span_diversity = cv <= 0.15 ? "low" : (cv <= 0.30 ? "moderate" : "high")
    end

    regularity = "regular"
    if !isempty(story_heights) && maximum(story_heights) - minimum(story_heights) > 0.3
        regularity = "irregular_story_heights"
    end

    slab_panel_plan = _agent_slab_panel_plan_metrics(skel)

    # Structural semantics: flags that help the LLM identify important characteristics
    flags = String[]

    if !isempty(beam_lengths)
        max_span_ft = maximum(beam_lengths) * 3.28084
        if max_span_ft > 30.0
            push!(flags, "long_spans_over_30ft")
        end
        if span_stats !== nothing && span_stats["cv"] > 0.25
            # Beam graph only — not plan irregularity; see slab_panel_plan for cell shape.
            push!(flags, "diverse_beam_edge_lengths")
        end
    end

    if !isnothing(slab_panel_plan)
        cls = string(slab_panel_plan["plan_shape_classification"])
        if cls == "non_orthogonal_or_skewed_quads"
            push!(flags, "non_orthogonal_slab_panel_corners")
        elseif cls == "triangular_mixed_or_complex_panels"
            push!(flags, "mixed_or_triangulated_slab_panels")
        elseif cls == "orthogonal_cells_variable_bay_aspect"
            push!(flags, "orthogonal_grid_different_bay_sizes_in_plan")
        end
    end

    if !isempty(story_heights)
        if maximum(story_heights) - minimum(story_heights) > 0.5
            push!(flags, "variable_story_heights")
        end
        if any(h -> h > 5.0, story_heights)
            push!(flags, "tall_story_over_5m")
        end
    end

    if n_stories > 1
        col_per_story = try
            [count(c -> c.second isa StructuralSizer.AbstractMember, struc.columns)]
        catch
            Int[]
        end
        if length(col_per_story) > 1 && maximum(col_per_story) != minimum(col_per_story)
            push!(flags, "varying_columns_per_level")
        end
    end

    if n_slabs > 0 && n_cols > 0
        slab_to_col = n_slabs / n_cols
        if slab_to_col > 2.0
            push!(flags, "high_slab_to_column_ratio")
        end
    end

    result = Dict{String, Any}(
        "n_stories"     => n_stories,
        "n_columns"     => n_cols,
        "n_beams"       => n_beams,
        "n_slabs"       => n_slabs,
        "n_foundations"  => n_fdns,
        "story_heights" => height_stats,
        "span_stats"    => span_stats,
        "regularity"    => regularity,
    )

    if !isnothing(span_diversity)
        result["span_diversity"] = span_diversity
    end
    if !isnothing(slab_panel_plan)
        result["slab_panel_plan"] = slab_panel_plan
    end
    result["span_cv_note"] =
        "span_stats.cv uses all beam/frame edge lengths (see span_stats.basis). That mixes X- and Y-oriented members, so different orthogonal bay sizes in X vs Y inflate CV — that is not plan irregularity. " *
        "For irregularity vs rectangular bays, use slab_panel_plan: it is derived from slab face outlines in plan (XY), including quad corner deviation from 90° and per-panel edge aspect ratio; see plan_shape_classification and interpretation."

    if !isnothing(DESIGN_CACHE.last_design)
        ftc = _floor_type_code(DESIGN_CACHE.last_design.params)
        sol_note = if ftc == "flat_plate"
            "Uses the two-way flat-plate sizing pipeline (DDM/EFM/FEA per floor_options). " *
                "No drop-panel geometry is injected; punching and thickness are based on the uniform slab depth at the column region unless studs/column growth change the check outcome."
        elseif ftc == "flat_slab"
            "Uses the same two-way sizing pipeline as flat_plate, but the solver builds drop-panel geometry (depth/plan extent from FlatSlabOptions or auto-sizing) and passes it through that pipeline so column-region checks use the extra concrete depth/footprint — primary structural distinction vs flat_plate. " *
                "Visualization JSON may include drop panel patches/meshes."
        elseif ftc == "one_way"
            "Different floor system path than two-way plate/slab (one-way slab-and-beam assumptions in the solver)."
        elseif ftc == "vault"
            "Shell/vault sizing path (thrust, geometry from vault options) — not the flat-plate pipeline."
        else
            "See explain_field(\"floor_type\") and solver outputs for this floor system."
        end
        result["floor_system"] = Dict{String, Any}(
            "floor_type"   => ftc,
            "description"  => get(_FLOOR_NAMES, ftc, ftc),
            "source"       => "last_completed_design_parameters",
            "note"         =>
                "floor_type is an API / DesignParameters choice — not inferred from slab panel outlines. " * sol_note,
        )
    end

    if !isempty(flags)
        result["structural_flags"] = flags
    end

    result["_guidance"] =
        "IRREGULARITY NOTE: span_stats.cv aggregates ALL beam edges (X + Y). Different bay sizes " *
        "in X vs Y produce high CV even on a rectangular orthogonal grid — that is NOT plan " *
        "irregularity. Use slab_panel_plan.plan_shape_classification and quad corner deviation " *
        "from 90° for true irregularity. Column tributary area variation (from get_geometry_digest) " *
        "is the most reliable plan regularity indicator."

    return result
end

"""
    agent_current_params(design::BuildingDesign) -> Dict{String, Any}

Return the fully resolved parameter set from the last design, formatted for
the agent. Uses `_diagnose_design_context` from diagnose.jl as the core.
"""
function agent_current_params(design::BuildingDesign)::Dict{String, Any}
    params = design.params
    du = params.display_units

    ctx = _diagnose_design_context(params, du; design=design)

    ctx["optimize_for"]            = string(params.optimize_for)
    ctx["max_iterations"]          = params.max_iterations
    ctx["fire_rating"]             = params.fire_rating
    ctx["pattern_loading"]         = string(params.pattern_loading)
    ctx["uniform_column_sizing"]   = string(params.uniform_column_sizing)

    # Material details (use cascade resolvers; Concrete uses `fc′`, not `fc`)
    mats = params.materials
    slab_fc = try round(ustrip(u"psi", resolve_slab_concrete(mats).fc′); digits=0) catch; nothing end
    col_fc  = try round(ustrip(u"psi", column_concrete(params).fc′); digits=0) catch; nothing end
    ctx["materials"] = Dict{String, Any}(
        "concrete_fc_psi"        => slab_fc,  # alias: slab concrete (legacy key)
        "slab_concrete_fc_psi"   => slab_fc,
        "column_concrete_fc_psi" => col_fc,
        "rebar_fy_ksi"           => try round(ustrip(u"ksi", resolve_slab_rebar(mats).Fy); digits=1) catch; nothing end,
        "steel_Fy_ksi"           => try round(ustrip(u"ksi", resolve_beam_steel(mats).Fy); digits=1) catch; nothing end,
    )

    return ctx
end

"""
    agent_api_params_ssot() -> Dict{String, Any}

Return the server's canonical wire-format `APIParams` JSON (`DESIGN_CACHE.last_api_params_json`).
This is overwritten in full on each successful `POST /design` or chat `run_design` — there is no
separate \"original Grasshopper\" copy. Used as the merge base for `validate_params` / `run_design`
patches when `merge_with_ssot` is true.
"""
function agent_api_params_ssot()::Dict{String, Any}
    snap = with_cache_read(c -> copy(c.last_api_params_json), DESIGN_CACHE)
    Dict{String, Any}(
        "api_params" => snap,
        "empty" => isempty(snap),
        "note" => isempty(snap) ?
            "No snapshot yet — the merge base falls back to default APIParams() until a design completes." :
            "Single source of truth for API parameters on the server; next successful design replaces this object entirely.",
    )
end

"""
    agent_situation_card(struc, design, history; ...) -> Dict{String, Any}

Single-call orientation snapshot. Combines geometry overview, resolved params,
results health, and session history status into one compact payload so the
LLM can orient itself without multiple tool calls.

Staleness detection uses `resolved_geometry_hash` (derived from structured
`building_geometry` when available, falling back to `client_geometry_hash`).
When the resolved hash differs from `server_geometry_hash`, `geometry_context`
reports which side is outdated:
  - `"server_behind_client"`: user changed geometry but hasn't re-run Design
  - `"client_behind_server"`: a Design completed but the chat session carries an old hash
  - `"aligned"`: hashes match
  - `"unknown"`: one or both hashes are missing — cannot determine staleness
"""
function agent_situation_card(
    struc::Union{BuildingStructure, Nothing},
    design::Union{BuildingDesign, Nothing},
    history::Vector{DesignHistoryEntry};
    server_geometry_hash::String = "",
    client_geometry_hash::String = "",
    resolved_geometry_hash::String = "",
    design_version::Int = 0,
)::Dict{String, Any}
    card = Dict{String, Any}("has_geometry" => !isnothing(struc), "has_design" => !isnothing(design))

    srv = strip(server_geometry_hash)
    cli = strip(client_geometry_hash)
    res = strip(resolved_geometry_hash)
    effective = !isempty(res) ? res : cli

    alignment = if isempty(effective) || isempty(srv)
        "unknown"
    elseif effective == srv
        "aligned"
    else
        in_history = any(strip(e.geometry_hash) == effective for e in history)
        in_history ? "client_behind_server" : "server_behind_client"
    end
    geometry_stale = alignment == "server_behind_client"

    card["geometry_context"] = Dict{String, Any}(
        "server_cached_geometry_hash" => srv,
        "client_geometry_hash"        => cli,
        "resolved_geometry_hash"      => effective,
        "alignment"                   => alignment,
        "geometry_stale"              => geometry_stale,
        "design_version"              => design_version,
    )
    if alignment == "server_behind_client"
        card["geometry_context"]["note"] =
            "The client's geometry is NEWER than the server's cached design. " *
            "Cached results below describe the previous model (server hash), not the current Grasshopper geometry. " *
            "Tell the user to run Design from Grasshopper to update the server."
    elseif alignment == "client_behind_server"
        card["geometry_context"]["note"] =
            "The server has NEWER design results than the client hash suggests. " *
            "A Design was run (e.g. from Grasshopper) since the last chat geometry snapshot. " *
            "The cached results below are current — report them to the user."
    elseif alignment == "aligned"
        card["geometry_context"]["note"] = "Client geometry hash matches the server's cached POST /design geometry."
    end

    if !isnothing(struc)
        card["geometry"] = agent_building_summary(struc)
    else
        card["geometry_availability"] = Dict{String, Any}(
            "server_has_building_structure" => false,
            "note" =>
                "The API server has no cached BuildingStructure yet (POST /design has not completed for this model). " *
                "get_situation_card.geometry and get_building_summary are therefore absent. " *
                "However, the system prompt's 'Geometry analysis' block contains pre-computed beam spans, " *
                "story heights, slab panel shapes, column grid, structural flags, and warnings derived from " *
                "the raw building_geometry JSON — use those quantitatively. " *
                "run_design will fail with no_geometry until Grasshopper runs a full Design — do not call it. " *
                "For solver-level data (member sizing, check ratios, trace events), run Design so the server ingests geometry.",
        )
    end

    if !isnothing(design)
        card["params"] = agent_current_params(design)

        s = design.summary
        n_fail_cols = count(p -> !p.second.ok, design.columns)
        n_fail_beams = count(p -> !p.second.ok, design.beams)
        n_fail_slabs = count(p -> !_slab_design_ok(p.second), design.slabs)
        n_fail_fdns = count(p -> !p.second.ok, design.foundations)
        n_fail = n_fail_cols + n_fail_beams + n_fail_slabs + n_fail_fdns
        du = design.params.display_units
        is_imp = du.units[:length] == u"ft"
        vol_label  = is_imp ? "ft3"  : "m3"
        mass_label = is_imp ? "lb"   : "kg"
        conc_vol  = round(ustrip(is_imp ? u"ft^3" : u"m^3", s.concrete_volume); digits=1)
        steel_wt  = round(ustrip(is_imp ? u"lb"   : u"kg",  s.steel_weight); digits=0)
        rebar_wt  = round(ustrip(is_imp ? u"lb"   : u"kg",  s.rebar_weight); digits=0)

        # Strip typed `kgCO₂e` once at the JSON-build boundary so the
        # downstream Dict / round / arithmetic stays numeric.
        ec_total_kg        = ustrip(u"kgCO2e", s.embodied_carbon)
        ec_slabs_kg        = ustrip(u"kgCO2e", s.embodied_carbon_slabs)
        ec_columns_kg      = ustrip(u"kgCO2e", s.embodied_carbon_columns)
        ec_beams_kg        = ustrip(u"kgCO2e", s.embodied_carbon_beams)
        ec_struts_kg       = ustrip(u"kgCO2e", s.embodied_carbon_struts)
        ec_foundations_kg  = ustrip(u"kgCO2e", s.embodied_carbon_foundations)
        ec_fireproofing_kg = ustrip(u"kgCO2e", s.embodied_carbon_fireproofing)
        ec_concrete_kg     = ustrip(u"kgCO2e", s.embodied_carbon_concrete)
        ec_rebar_kg        = ustrip(u"kgCO2e", s.embodied_carbon_rebar)
        ec_steel_kg        = ustrip(u"kgCO2e", s.embodied_carbon_structural_steel)

        health = Dict{String, Any}(
            "all_pass"         => s.all_checks_pass,
            "critical_ratio"   => round(s.critical_ratio; digits=3),
            "critical_element" => s.critical_element,
            "embodied_carbon_kgco2e" => round(ec_total_kg; digits=0),
            "n_elements"       => length(design.columns) + length(design.beams) +
                                  length(design.slabs) + length(design.foundations),
            "n_failing"        => n_fail,
            "failing_by_type"  => Dict{String, Any}(
                "columns"     => n_fail_cols,
                "beams"       => n_fail_beams,
                "slabs"       => n_fail_slabs,
                "foundations" => n_fail_fdns,
            ),
            "materials" => Dict{String, Any}(
                "concrete_volume" => Dict("value" => conc_vol, "unit" => vol_label),
                "steel_weight"    => Dict("value" => steel_wt, "unit" => mass_label),
                "rebar_weight"    => Dict("value" => rebar_wt, "unit" => mass_label),
            ),
            "health_note"      => "critical_element = single worst element (highest ratio). " *
                "failing_by_type = counts per category. These may disagree: " *
                "e.g. critical_element can be a slab while most failures are columns.",
        )

        ec_parts_kg = ec_slabs_kg + ec_columns_kg + ec_beams_kg +
                      ec_struts_kg + ec_foundations_kg + ec_fireproofing_kg
        if ec_total_kg > 0 || ec_parts_kg > 1e-9
            health["embodied_carbon_by_system_kgco2e"] = Dict{String, Any}(
                "slabs"        => round(ec_slabs_kg; digits=0),
                "columns"      => round(ec_columns_kg; digits=0),
                "beams"        => round(ec_beams_kg; digits=0),
                "struts"       => round(ec_struts_kg; digits=0),
                "foundations"  => round(ec_foundations_kg; digits=0),
                "fireproofing" => round(ec_fireproofing_kg; digits=0),
            )
            health["embodied_carbon_by_material_kgco2e"] = Dict{String, Any}(
                "concrete"         => round(ec_concrete_kg; digits=0),
                "rebar"            => round(ec_rebar_kg; digits=0),
                "structural_steel" => round(ec_steel_kg; digits=0),
                "fireproofing"     => round(ec_fireproofing_kg; digits=0),
            )
        end

        card["health"] = health
        card["has_trace"] = !isempty(design.solver_trace)
    end

    hist_hashes = String[strip(e.geometry_hash) for e in history]
    distinct = sort(unique(h for h in hist_hashes if !isempty(h)))
    session = Dict{String, Any}(
        "n_designs" => length(history),
        "latest_passed" => isempty(history) ? nothing : last(history).all_pass,
        "can_compare_deltas" => length(history) >= 2,
        "n_distinct_geometry_hashes_in_history" => length(distinct),
    )
    if !isempty(distinct)
        session["geometry_hashes_in_history"] = distinct
    end
    if !isempty(effective)
        session["n_designs_on_resolved_geometry_hash"] = count(h -> h == effective, hist_hashes)
    end
    card["session"] = session

    insights = get_session_insights()
    if !isempty(insights)
        card["session"]["n_insights"] = length(insights)
        card["session"]["insight_categories"] = sort(unique(string(s.category) for s in insights))
    end

    # Inline guidance — state-dependent, delivered at the moment the model needs it
    guidance_parts = String[]
    if alignment == "server_behind_client"
        push!(guidance_parts,
            "STALE SERVER: The user changed geometry but hasn't re-run Design. " *
            "Cached results describe the PREVIOUS model. " *
            "Do not map diagnostic data onto the current geometry. " *
            "Suggest the user run Design from Grasshopper to update the server.")
    elseif alignment == "client_behind_server"
        push!(guidance_parts,
            "FRESH RESULTS: The server has newer results than the client's last-known hash. " *
            "A Design was completed (likely from Grasshopper). " *
            "The cached results are current — report them directly to the user.")
    end
    if !isnothing(design)
        n_fail = card["health"]["n_failing"]
        if n_fail > 0
            push!(guidance_parts,
                "FAILURES DETECTED: Report failing_by_type counts to the user. " *
                "Call get_diagnose_summary next for failure detail. " *
                "Do not guess at causes — use tool data.")
        end
    elseif !isnothing(struc)
        push!(guidance_parts,
            "NO DESIGN YET: Geometry is loaded but no design has run. " *
            "Quote exact span/height numbers from the geometry digest in your opening. " *
            "Call get_geometry_digest if you need more detail.")
    elseif isnothing(struc)
        push!(guidance_parts,
            "NO SERVER GEOMETRY: run_design and diagnose tools are unavailable. " *
            "Advise from the digest — quote spans, recommend geometry changes (add columns, shorten bays), use predict_geometry_effect. " *
            "Tell the user to run Design from Grasshopper to enable solver tools.")
    end
    if !isempty(guidance_parts)
        card["_guidance"] = join(guidance_parts, "\n")
    end

    return card
end

