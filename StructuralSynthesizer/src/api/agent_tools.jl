# =============================================================================
# Agent Tools — implementation functions for LLM agent tool dispatch
#
# Phase 1 (Orientation): get_building_summary, get_current_params
# Phase 2 (Diagnosis):   query_elements, explain_field, get_solver_trace
# Phase 3 (Exploration):  compare_designs, suggest_next_action
# =============================================================================

using Statistics: mean, std

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

    ctx["optimize_for"]    = string(params.optimize_for)
    ctx["max_iterations"]  = params.max_iterations
    ctx["fire_rating"]     = params.fire_rating
    ctx["pattern_loading"] = string(params.pattern_loading)

    # Material details (use cascade resolvers; Concrete uses `fc′`, not `fc`)
    mats = params.materials
    slab_fc = try round(ustrip(u"psi", resolve_slab_concrete(mats).fc′); digits=0) catch; nothing end
    col_fc  = try round(ustrip(u"psi", resolve_column_concrete(mats).fc′); digits=0) catch; nothing end
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
    agent_situation_card(struc, design, history; server_geometry_hash="", client_geometry_hash="") -> Dict{String, Any}

Single-call orientation snapshot. Combines geometry overview, resolved params,
results health, and session history status into one compact payload so the
LLM can orient itself without multiple tool calls.

When `client_geometry_hash` is provided and differs from `server_geometry_hash`,
`geometry_stale` is true: cached `geometry` / `health` / `params` describe the
last POST /design model, not necessarily the client's current Grasshopper geometry.
"""
function agent_situation_card(
    struc::Union{BuildingStructure, Nothing},
    design::Union{BuildingDesign, Nothing},
    history::Vector{DesignHistoryEntry};
    server_geometry_hash::String = "",
    client_geometry_hash::String = "",
)::Dict{String, Any}
    card = Dict{String, Any}("has_geometry" => !isnothing(struc), "has_design" => !isnothing(design))

    srv = strip(server_geometry_hash)
    cli = strip(client_geometry_hash)
    aligned = isempty(cli) || isempty(srv) ? nothing : cli == srv
    geometry_stale = aligned === false
    card["geometry_context"] = Dict{String, Any}(
        "server_cached_geometry_hash" => srv,
        "client_geometry_hash"        => cli,
        "aligned"                     => aligned,
        "geometry_stale"              => geometry_stale,
    )
    if geometry_stale
        card["geometry_context"]["note"] =
            "Cached structure/design snapshot below is for server_cached_geometry_hash, not necessarily the current Grasshopper model. " *
            "Design history is retained: each get_design_history entry includes geometry_hash — compare runs on the same hash, or explicitly contrast across geometry changes. " *
            "Do not map element IDs or detailed diagnostics from the cached design onto BUILDING GEOMETRY text until a Design run completes for this model."
    elseif aligned === true
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
                "For solver-level data (member sizing, check ratios, trace events), run Design so the server ingests geometry.",
        )
    end

    if !isnothing(design)
        card["params"] = agent_current_params(design)

        s = design.summary
        n_fail = count(p -> !p.second.ok, design.columns) +
                 count(p -> !p.second.ok, design.beams) +
                 count(p -> !(p.second.converged && p.second.deflection_ok && p.second.punching_ok), design.slabs) +
                 count(p -> !p.second.ok, design.foundations)
        card["health"] = Dict{String, Any}(
            "all_pass"         => s.all_checks_pass,
            "critical_ratio"   => round(s.critical_ratio; digits=3),
            "critical_element" => s.critical_element,
            "embodied_carbon"  => round(s.embodied_carbon; digits=0),
            "n_elements"       => length(design.columns) + length(design.beams) +
                                  length(design.slabs) + length(design.foundations),
            "n_failing"        => n_fail,
        )
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
    if !isempty(cli)
        session["n_designs_on_client_geometry_hash"] = count(h -> h == cli, hist_hashes)
    end
    card["session"] = session

    insights = get_session_insights()
    if !isempty(insights)
        card["session"]["n_insights"] = length(insights)
        card["session"]["insight_categories"] = sort(unique(string(s.category) for s in insights))
    end

    return card
end

# ─── Phase 2 continued: Breadcrumb Microscope (post-hoc explain_feasibility) ───
#
# Breadcrumbs are emitted into the solver trace (stage="breadcrumbs_members") as
# compact group-level bundles with per-element lookup keys. This tool resolves a
# lookup key and runs StructuralSizer.explain_feasibility for the chosen section.
#

"""
    agent_explain_trace_lookup(design::BuildingDesign; lookup, section_mode="chosen") -> Dict{String, Any}

Resolve a breadcrumb lookup key (emitted in the solver trace) and return a
machine-readable `explain_feasibility` breakdown for that specific element.

This is a post-hoc "microscope": it does not require the design run to have
focused tracing enabled, as long as the design result still contains the
necessary sizing inputs (section, demand, geometry, materials/options).

# Arguments
- `lookup`: Dict with keys `{version, kind, member_type, member_idx, group_id}` as emitted by breadcrumbs.
- `section_mode`: `"chosen"` (default) uses the designed section; `"catalog_screen"` (future) could explain rejection.
"""
function agent_explain_trace_lookup(
    design::BuildingDesign;
    lookup::AbstractDict,
    section_mode::String = "chosen",
)::Dict{String, Any}
    # --- Validate lookup payload ---
    ver = Int(get(lookup, "version", 0))
    kind = string(get(lookup, "kind", ""))
    ver == 1 || return Dict("error" => "invalid_lookup_version", "message" => "Expected lookup.version=1", "lookup" => lookup)
    kind == "member" || return Dict("error" => "invalid_lookup_kind", "message" => "Expected lookup.kind=\"member\"", "lookup" => lookup)

    mtype = string(get(lookup, "member_type", ""))
    midx  = Int(get(lookup, "member_idx", 0))
    (mtype in ("beam", "column")) || return Dict("error" => "invalid_member_type", "message" => "member_type must be \"beam\" or \"column\"", "lookup" => lookup)
    midx > 0 || return Dict("error" => "invalid_member_idx", "message" => "member_idx must be positive", "lookup" => lookup)
    section_mode == "chosen" || return Dict("error" => "invalid_section_mode", "message" => "section_mode must be \"chosen\" for now")

    struc = design.structure
    params = design.params

    if mtype == "beam"
        midx <= length(struc.beams) || return Dict("error" => "beam_not_found", "message" => "beam_idx out of range", "member_idx" => midx)
        beam = struc.beams[midx]
        sec = section(beam)
        isnothing(sec) && return Dict("error" => "no_section", "message" => "Beam has no designed section", "member_idx" => midx)

        # Determine which sizing path was used from params.beams
        opts = something(params.beams, StructuralSizer.SteelBeamOptions())
        # Reconstruct geometry (SI Unitful)
        L = member_length(beam); Lq = L isa Unitful.Quantity ? uconvert(u"m", L) : Float64(L) * u"m"
        Lb = unbraced_length(beam); Lbq = Lb isa Unitful.Quantity ? uconvert(u"m", Lb) : Float64(Lb) * u"m"
        geom = if opts isa StructuralSizer.SteelBeamOptions
            StructuralSizer.SteelMemberGeometry(Lq; Lb=Lbq, Cb=beam.base.Cb, Kx=beam.base.Kx, Ky=beam.base.Ky)
        else
            StructuralSizer.ConcreteMemberGeometry(Lq; Lu=Lbq, k=beam.base.Ky)
        end

        # Use design result demands (already in SI units)
        br = get(design.beams, midx, nothing)
        isnothing(br) && return Dict("error" => "no_beam_result", "message" => "No BeamDesignResult available", "member_idx" => midx)
        dem = if opts isa StructuralSizer.SteelBeamOptions
            StructuralSizer.MemberDemand(1;
                Pu_c = 0.0,
                Mux = ustrip(u"N*m", br.Mu),
                Vu_strong = ustrip(u"N", br.Vu),
            )
        else
            StructuralSizer.RCBeamDemand(1;
                Mu = ustrip(StructuralSizer.Asap.kip*u"ft", uconvert(StructuralSizer.Asap.kip*u"ft", br.Mu)),
                Vu = ustrip(StructuralSizer.Asap.kip, uconvert(StructuralSizer.Asap.kip, br.Vu)),
            )
        end

        # Run explain_feasibility with a single-entry cache/catalog.
        if opts isa StructuralSizer.SteelBeamOptions
            mat = StructuralSynthesizer.resolve_beam_steel(params.materials)
            checker = StructuralSizer.AISCChecker(; max_depth=opts.max_depth,
                deflection_limit = getfield(opts, :deflection_limit, nothing),
                total_deflection_limit = getfield(opts, :total_deflection_limit, nothing),
            )
            cat = [sec]
            cache = StructuralSizer.create_cache(checker, 1)
            StructuralSizer.precompute_capacities!(checker, cache, cat, mat, opts.objective)
            expl = StructuralSizer.explain_feasibility(checker, cache, 1, sec, mat, dem, geom)
        else
            # Concrete beam: use ACIBeamChecker with params materials
            rc = resolve_rc_material(params)
            checker = StructuralSizer.ACIBeamChecker(;
                fy_ksi  = ustrip(StructuralSizer.Asap.ksi, rc.rebar.Fy),
                fyt_ksi = ustrip(StructuralSizer.Asap.ksi, StructuralSizer.get_transverse_rebar(opts).Fy),
                Es_ksi  = ustrip(StructuralSizer.Asap.ksi, rc.rebar.E),
                λ       = rc.concrete.λ,
                max_depth = opts.max_depth,
            )
            cat = [sec]
            cache = StructuralSizer.create_cache(checker, 1)
            StructuralSizer.precompute_capacities!(checker, cache, cat, rc.concrete, opts.objective)
            expl = StructuralSizer.explain_feasibility(checker, cache, 1, sec, rc.concrete, dem, geom)
        end

        # Serialize explanation into JSON-friendly Dict
        return Dict{String, Any}(
            "member_type" => "beam",
            "member_idx"  => midx,
            "section"     => string(sec),
            "passed"      => expl.passed,
            "governing_check" => expl.governing_check,
            "governing_ratio" => expl.governing_ratio,
            "checks" => [Dict(
                "name" => c.name,
                "passed" => c.passed,
                "ratio" => c.ratio,
                "demand" => c.demand,
                "capacity" => c.capacity,
                "code_clause" => c.code_clause,
            ) for c in expl.checks],
        )
    else
        # column
        midx <= length(struc.columns) || return Dict("error" => "column_not_found", "message" => "column_idx out of range", "member_idx" => midx)
        col = struc.columns[midx]
        sec = section(col)
        isnothing(sec) && return Dict("error" => "no_section", "message" => "Column has no designed section", "member_idx" => midx)

        opts = something(params.columns, StructuralSizer.SteelColumnOptions())
        L = member_length(col); Lq = L isa Unitful.Quantity ? uconvert(u"m", L) : Float64(L) * u"m"
        Lb = unbraced_length(col); Lbq = Lb isa Unitful.Quantity ? uconvert(u"m", Lb) : Float64(Lb) * u"m"
        geom = if opts isa StructuralSizer.SteelColumnOptions
            StructuralSizer.SteelMemberGeometry(Lq; Lb=Lbq, Cb=col.base.Cb, Kx=col.base.Kx, Ky=col.base.Ky)
        else
            StructuralSizer.ConcreteMemberGeometry(Lq; Lu=Lbq, k=col.base.Ky)
        end

        cr = get(design.columns, midx, nothing)
        isnothing(cr) && return Dict("error" => "no_column_result", "message" => "No ColumnDesignResult available", "member_idx" => midx)

        if opts isa StructuralSizer.SteelColumnOptions
            mat = something(params.materials.steel, StructuralSizer.A992_Steel)
            checker = StructuralSizer.AISCChecker(; max_depth=opts.max_depth)
            dem = StructuralSizer.MemberDemand(1;
                Pu_c = ustrip(u"N", cr.Pu),
                Mux  = ustrip(u"N*m", cr.Mu_x),
                Muy  = ustrip(u"N*m", cr.Mu_y),
            )
            cat = [sec]
            cache = StructuralSizer.create_cache(checker, 1)
            StructuralSizer.precompute_capacities!(checker, cache, cat, mat, opts.objective)
            expl = StructuralSizer.explain_feasibility(checker, cache, 1, sec, mat, dem, geom)
        else
            rc = resolve_rc_material(params)
            checker = StructuralSizer.ACIColumnChecker(;
                include_slenderness = opts.include_slenderness,
                include_biaxial = opts.include_biaxial,
                fy_ksi = ustrip(StructuralSizer.Asap.ksi, rc.rebar.Fy),
                Es_ksi = ustrip(StructuralSizer.Asap.ksi, rc.rebar.E),
                max_depth = opts.max_depth,
            )
            Pu_kip = uconvert(StructuralSizer.Asap.kip, cr.Pu)
            Mux_kipft = uconvert(StructuralSizer.Asap.kip*u"ft", cr.Mu_x)
            Muy_kipft = uconvert(StructuralSizer.Asap.kip*u"ft", cr.Mu_y)
            dem = StructuralSizer.RCColumnDemand(1;
                Pu = ustrip(Pu_kip),
                Mux = ustrip(Mux_kipft),
                Muy = ustrip(Muy_kipft),
            )
            cat = [sec]
            cache = StructuralSizer.create_cache(checker, 1)
            StructuralSizer.precompute_capacities!(checker, cache, cat, rc.concrete, opts.objective)
            expl = StructuralSizer.explain_feasibility(checker, cache, 1, sec, rc.concrete, dem, geom)
        end

        return Dict{String, Any}(
            "member_type" => "column",
            "member_idx"  => midx,
            "section"     => string(sec),
            "passed"      => expl.passed,
            "governing_check" => expl.governing_check,
            "governing_ratio" => expl.governing_ratio,
            "checks" => [Dict(
                "name" => c.name,
                "passed" => c.passed,
                "ratio" => c.ratio,
                "demand" => c.demand,
                "capacity" => c.capacity,
                "code_clause" => c.code_clause,
            ) for c in expl.checks],
        )
    end
end

"""
    agent_diagnose_summary(design::BuildingDesign) -> Dict{String, Any}

Lightweight failure overview: counts by element type, top-N critical elements,
and failure breakdown by governing check — without the full per-element dump.
Designed for progressive disclosure: call this first, then `get_diagnose` or
`query_elements` for detail.
"""
function agent_diagnose_summary(design::BuildingDesign)::Dict{String, Any}
    diag = get_cached_diagnose(DESIGN_CACHE, design)

    type_stats = Dict{String, Any}()
    all_elements = Pair{Float64, Dict{String, Any}}[]
    check_counts = Dict{String, Int}()

    for (etype, plural) in [("column", "columns"), ("beam", "beams"),
                             ("slab", "slabs"), ("foundation", "foundations")]
        elems = get(diag, plural, Any[])
        n_fail = count(e -> !get(e, "ok", true), elems)
        type_stats[etype] = Dict{String, Any}("total" => length(elems), "failing" => n_fail)

        for e in elems
            ratio = get(e, "governing_ratio", 0.0)
            push!(all_elements, ratio => e)
            if !get(e, "ok", true)
                gc = get(e, "governing_check", "unknown")
                check_counts[gc] = get(check_counts, gc, 0) + 1
            end
        end
    end

    sort!(all_elements; by=first, rev=true)
    top_n = min(5, length(all_elements))
    top_critical = [Dict{String, Any}(
        "type"             => get(e, "type", ""),
        "id"               => get(e, "id", ""),
        "governing_ratio"  => round(ratio; digits=3),
        "governing_check"  => get(e, "governing_check", ""),
        "ok"               => get(e, "ok", true),
    ) for (ratio, e) in all_elements[1:top_n]]

    sorted_checks = sort(collect(check_counts); by=last, rev=true)
    failure_breakdown = [Dict("check" => k, "count" => v) for (k, v) in sorted_checks]

    # Size warnings from element reasonableness checks
    raw_sw = get(diag, "size_warnings", Any[])
    n_critical_sw = count(w -> get(w, "severity", "") == "critical", raw_sw)
    n_warning_sw  = length(raw_sw) - n_critical_sw
    top_sw = [Dict{String, Any}(
        "element_type" => get(w, "element_type", ""),
        "element_id"   => get(w, "element_id", ""),
        "check"        => get(w, "check", ""),
        "severity"     => get(w, "severity", ""),
        "interpretation" => get(w, "interpretation", ""),
        "parameter_headroom" => get(w, "parameter_headroom", ""),
    ) for w in raw_sw[1:min(5, length(raw_sw))]]

    result = Dict{String, Any}(
        "by_type"           => type_stats,
        "top_critical"      => top_critical,
        "failure_breakdown" => failure_breakdown,
        "n_total_elements"  => length(all_elements),
        "n_total_failing"   => sum(s -> s["failing"], values(type_stats)),
        "note"              => "Use query_elements or get_diagnose for full per-element detail.",
    )

    if !isempty(raw_sw)
        result["size_warnings"] = Dict{String, Any}(
            "n_critical" => n_critical_sw,
            "n_warning"  => n_warning_sw,
            "top"        => top_sw,
            "note"       => "Elements with abnormal sizes. 'parameter_headroom=none' means geometry change needed.",
        )
    end

    return result
end

# ─── Phase 2: Diagnosis ──────────────────────────────────────────────────────

"""
    agent_query_elements(design::BuildingDesign; kwargs...) -> Dict{String, Any}

Run `design_to_diagnose` and filter elements by the given criteria.
"""
function agent_query_elements(
    design::BuildingDesign;
    type::Union{String, Nothing}=nothing,
    min_ratio::Union{Float64, Nothing}=nothing,
    max_ratio::Union{Float64, Nothing}=nothing,
    governing_check::Union{String, Nothing}=nothing,
    ok::Union{Bool, Nothing}=nothing,
    story::Union{Int, Nothing}=nothing,
)::Dict{String, Any}
    diag = get_cached_diagnose(DESIGN_CACHE, design)

    function _matches(d::Dict)
        if !isnothing(min_ratio)
            get(d, "governing_ratio", 0.0) < min_ratio && return false
        end
        if !isnothing(max_ratio)
            get(d, "governing_ratio", 0.0) > max_ratio && return false
        end
        if !isnothing(governing_check)
            get(d, "governing_check", "") != governing_check && return false
        end
        if !isnothing(ok)
            get(d, "ok", true) != ok && return false
        end
        if !isnothing(story)
            elem_story = get(d, "story", nothing)
            !isnothing(elem_story) && elem_story != story && return false
        end
        return true
    end

    results = Dict{String, Any}()
    type_map = Dict(
        "column"     => "columns",
        "beam"       => "beams",
        "slab"       => "slabs",
        "foundation" => "foundations",
    )

    types_to_check = isnothing(type) ? keys(type_map) : [type]
    total = 0

    for t in types_to_check
        key = get(type_map, t, t * "s")
        elements = get(diag, key, [])
        matched = filter(_matches, elements)
        if !isempty(matched)
            results[key] = matched
            total += length(matched)
        end
    end

    results["total_matched"] = total
    results["unit_system"]   = get(diag, "unit_system", "imperial")
    return results
end

"""
    agent_explain_field(field_name::String) -> Dict{String, Any}

Look up a field in `api_params_schema_structured()` and return its metadata.
"""
function agent_explain_field(field_name::String)::Dict{String, Any}
    schema = api_params_schema_structured()
    fn_lower = lowercase(field_name)

    found_field = nothing
    found_details = nothing

    for (top_key, top_val) in schema
        if lowercase(string(top_key)) == fn_lower
            found_field = string(top_key)
            found_details = top_val
            break
        end
        if top_val isa Dict
            for (sub_key, sub_val) in top_val
                full_key = "$(top_key).$(sub_key)"
                if lowercase(string(sub_key)) == fn_lower || lowercase(full_key) == fn_lower
                    found_field = full_key
                    found_details = sub_val
                    break
                end
                if sub_val isa Dict
                    for (inner_key, inner_val) in sub_val
                        full_inner = "$(top_key).$(sub_key).$(inner_key)"
                        if lowercase(string(inner_key)) == fn_lower || lowercase(full_inner) == fn_lower
                            found_field = full_inner
                            found_details = inner_val
                            break
                        end
                    end
                end
                !isnothing(found_field) && break
            end
        end
        !isnothing(found_field) && break
    end

    if isnothing(found_field)
        return Dict{String, Any}(
            "error"   => "field_not_found",
            "message" => "Field \"$field_name\" not found in the parameter schema. " *
                         "Use get_applicability or check the /schema endpoint for valid field names.",
        )
    end

    result = Dict{String, Any}("field" => found_field, "details" => found_details)

    # Enrich with ontology rationale when available
    leaf = split(found_field, ".")[end]
    rationale = get_code_rationale(string(leaf))
    if !isnothing(rationale)
        result["rationale"] = rationale
    end

    # Surface related checks with provision summaries via LEVER_SURFACE_MAP + ontology
    related_checks = Dict{String, Any}[]
    for (check_name, lever_info) in LEVER_SURFACE_MAP
        params = get(lever_info, "parameters", String[])
        if string(leaf) in params
            entry = Dict{String, Any}("check" => check_name)
            provs = get_provisions_for_check(check_name)
            if !isempty(provs)
                p = provs[1]
                entry["provision"] = get(p, "provision", "")
                entry["failure_consequence"] = get(p, "failure_consequence", "")
                mech = get(p, "mechanism", "")
                entry["mechanism"] = length(mech) > 120 ? mech[1:117] * "..." : mech
            end
            push!(related_checks, entry)
        end
    end
    if !isempty(related_checks)
        result["related_checks"] = related_checks
    end

    return result
end

# ─── Phase 3: Exploration ─────────────────────────────────────────────────────

"""
    agent_compare_designs(index_a::Int, index_b::Int) -> Dict{String, Any}

Compare two designs from session history. Index 0 means "current" (latest).
"""
function agent_compare_designs(index_a::Int, index_b::Int)::Dict{String, Any}
    history = get_design_history_entries()
    isempty(history) && return Dict("error" => "no_history", "message" => "No designs in session history yet.")

    function _get_entry(idx)
        idx == 0 && return last(history)
        (idx < 1 || idx > length(history)) && return nothing
        return history[idx]
    end

    a = _get_entry(index_a)
    b = _get_entry(index_b)
    isnothing(a) && return Dict("error" => "invalid_index", "message" => "index_a=$index_a is out of range (1..$(length(history)), or 0 for current).")
    isnothing(b) && return Dict("error" => "invalid_index", "message" => "index_b=$index_b is out of range (1..$(length(history)), or 0 for current).")

    # Compute deltas
    Δ_ratio = round(b.critical_ratio - a.critical_ratio; digits=4)
    Δ_ec    = round(b.embodied_carbon - a.embodied_carbon; digits=0)
    Δ_fail  = b.n_failing - a.n_failing

    # Find params that differ
    all_keys = union(keys(a.params_patch), keys(b.params_patch))
    changed_params = Dict{String, Any}()
    for k in all_keys
        va = get(a.params_patch, k, nothing)
        vb = get(b.params_patch, k, nothing)
        if va != vb
            changed_params[k] = Dict("from" => va, "to" => vb)
        end
    end

    ha = strip(a.geometry_hash)
    hb = strip(b.geometry_hash)
    cross_geo = !isempty(ha) && !isempty(hb) && ha != hb
    unknown_geo = isempty(ha) || isempty(hb)

    note = if cross_geo
        "These two history entries used different geometry_hash values. Deltas summarize stored summary metrics only — " *
            "they are not a same-model parameter A/B test. Say so when explaining results."
    elseif unknown_geo
        "One or both entries lack geometry_hash (legacy). Treat cross-run deltas as approximate unless hashes match."
    else
        nothing
    end

    # Mechanism shift: did the governing element or its check family change?
    crit_a = strip(a.critical_element)
    crit_b = strip(b.critical_element)
    mechanism_shift = if isempty(crit_a) || isempty(crit_b)
        nothing
    elseif crit_a == crit_b
        "same_critical_element"
    else
        "critical_element_changed"
    end

    out = Dict{String, Any}(
        "design_a" => Dict(
            "index"            => index_a == 0 ? length(history) : index_a,
            "geometry_hash"    => ha,
            "all_pass"         => a.all_pass,
            "critical_ratio"   => a.critical_ratio,
            "critical_element" => crit_a,
            "embodied_carbon"  => a.embodied_carbon,
            "n_failing"        => a.n_failing,
            "source"           => a.source,
        ),
        "design_b" => Dict(
            "index"            => index_b == 0 ? length(history) : index_b,
            "geometry_hash"    => hb,
            "all_pass"         => b.all_pass,
            "critical_ratio"   => b.critical_ratio,
            "critical_element" => crit_b,
            "embodied_carbon"  => b.embodied_carbon,
            "n_failing"        => b.n_failing,
            "source"           => b.source,
        ),
        "deltas" => Dict(
            "critical_ratio_delta"  => Δ_ratio,
            "embodied_carbon_delta" => Δ_ec,
            "n_failing_delta"       => Δ_fail,
            "pass_improved"         => !a.all_pass && b.all_pass,
            "pass_regressed"        => a.all_pass && !b.all_pass,
        ),
        "changed_params" => changed_params,
        "cross_geometry_comparison" => cross_geo,
    )
    !isnothing(mechanism_shift) && (out["mechanism_shift"] = mechanism_shift)
    isnothing(note) || (out["comparison_note"] = note)
    return out
end

"""
    agent_suggest_next_action(design::BuildingDesign, goal::String) -> Dict{String, Any}

Return ranked parameter suggestions for the given goal by pulling from
the /diagnose architectural and constraint layers.
"""
function agent_suggest_next_action(design::BuildingDesign, goal::String)::Dict{String, Any}
    valid_goals = ["fix_failures", "reduce_column_size", "reduce_slab_thickness", "reduce_ec"]
    goal in valid_goals || return Dict(
        "error"   => "invalid_goal",
        "message" => "Goal must be one of: $(join(valid_goals, ", ")). Got: \"$goal\".",
    )

    diag = get_cached_diagnose(DESIGN_CACHE, design)
    arch = get(diag, "architectural", Dict())
    cons = get(diag, "constraints", Dict())

    recs = get(arch, "goal_recommendations", [])
    impacts = get(cons, "lever_impacts", [])

    goal_recs = filter(r -> get(r, "goal", "") == goal, recs)

    goal_params = Dict(
        "fix_failures"          => ["punching_strategy", "deflection_limit", "column_catalog", "beam_catalog"],
        "reduce_column_size"    => ["punching_strategy", "column_catalog"],
        "reduce_slab_thickness" => ["deflection_limit"],
        "reduce_ec"             => ["deflection_limit", "punching_strategy"],
    )
    related_params = get(goal_params, goal, String[])
    goal_impacts = filter(i -> get(i, "parameter", "") in related_params, impacts)

    summary = get(diag, "agent_summary", Dict())

    # ── Runtime failure analysis ──
    failing_checks = _extract_failing_checks(diag)
    ranked_actions = _rank_actions_by_failure(goal, failing_checks, related_params)

    # ── Geometry remediation evaluation ──
    geo_remediations = _geometry_remediation_eval(design, diag, failing_checks)

    # ── Parameter headroom from size warnings ──
    size_warnings = get(diag, "size_warnings", Any[])
    any_exhausted = any(w -> get(w, "parameter_headroom", "") == "none", size_warnings)
    param_headroom = any_exhausted ? "exhausted" : "available"

    # ── System dependency context ──
    floor_type = _extract_floor_type(design)
    sys_context = isnothing(floor_type) ? nothing : get_system_dependencies(floor_type)

    # ── Build tl;dr summary for fast LLM parsing ──
    total_failing_n = sum(get(fc, "n_failing", 0) for fc in failing_checks; init=0)
    check_parts = [
        "$(get(fc, "check", "?")): $(get(fc, "n_failing", 0)) elements"
        for fc in failing_checks[1:min(end, 3)]
    ]
    top_action = isempty(ranked_actions) ? "none" :
        "$(get(ranked_actions[1], "parameter", "?")) (addresses $(round(Int, get(ranked_actions[1], "coverage_fraction", 0.0) * 100))% of failures)"

    tldr = if total_failing_n == 0
        "All checks pass. Goal: $goal."
    elseif !isempty(geo_remediations)
        geo_gap = get(geo_remediations[1], "gap", "")
        "Geometry is the bottleneck: $geo_gap Parameter changes alone cannot resolve this. " *
        "$(length(failing_checks)) check families failing ($(join(check_parts, ", ")))."
    else
        "$(length(failing_checks)) check families failing ($(join(check_parts, ", "))). Top action: $top_action."
    end

    result = Dict{String, Any}(
        "goal"               => goal,
        "tldr"               => tldr,
        "ranked_actions"     => ranked_actions,
        "failing_checks"     => failing_checks,
        "parameter_headroom" => param_headroom,
        "current_status"     => Dict(
            "all_pass"       => get(summary, "all_pass", false),
            "critical_ratio" => get(summary, "critical_ratio", 0.0),
            "n_failing"      => total_failing_n,
        ),
    )

    if !isempty(geo_remediations)
        result["geometry_actions"] = geo_remediations
    end

    if !isnothing(sys_context)
        result["system_context"] = sys_context
    end

    if !isempty(goal_recs) || !isempty(goal_impacts)
        result["raw_data"] = Dict{String, Any}(
            "recommendations" => goal_recs,
            "lever_impacts"   => goal_impacts,
        )
    end

    return result
end

"""
Extract a frequency-sorted list of failing check families from diagnose data.

The diagnose dict stores elements under `engineering.columns`, `engineering.beams`,
`engineering.slabs`, `engineering.foundations`. Each element has top-level `ok`,
`governing_check`, and `governing_ratio` fields.
"""
function _extract_failing_checks(diag::Dict)::Vector{Dict{String, Any}}
    check_counts = Dict{String, Int}()
    check_worst = Dict{String, Float64}()

    for plural in ("columns", "beams", "slabs", "foundations")
        elems = get(diag, plural, Any[])
        !(elems isa AbstractVector) && continue
        for elem in elems
            !(elem isa AbstractDict) && continue
            ok = get(elem, "ok", true)
            ok && continue
            gc = string(get(elem, "governing_check", "unknown"))
            ratio_raw = get(elem, "governing_ratio", 0.0)
            ratio = ratio_raw isa Number ? Float64(ratio_raw) : 0.0
            check_counts[gc] = get(check_counts, gc, 0) + 1
            check_worst[gc] = max(get(check_worst, gc, 0.0), ratio)
        end
    end

    sorted = sort(collect(check_counts); by=last, rev=true)
    return [Dict{String, Any}(
        "check"       => name,
        "n_failing"   => count,
        "worst_ratio" => get(check_worst, name, 0.0),
    ) for (name, count) in sorted]
end

"""
Rank actionable parameters by how many distinct failing check families they address,
using LEVER_SURFACE_MAP to connect parameters to checks and PROVISION_ONTOLOGY for
cross-references.
"""
function _rank_actions_by_failure(
    goal::String,
    failing_checks::Vector{Dict{String, Any}},
    related_params::Vector{String},
)::Vector{Dict{String, Any}}
    total_failing = sum(get(fc, "n_failing", 0) for fc in failing_checks; init=0)

    failing_by_norm = Dict{String, Dict{String, Any}}()
    for fc in failing_checks
        cn = get(fc, "check", "")
        failing_by_norm[_lever_norm(cn)] = fc
    end

    param_scores = Dict{String, Dict{String, Any}}()
    for param in related_params
        addressed = String[]
        addressed_count = 0
        provisions_involved = Dict{String, Any}[]
        for (check_name, lever_info) in LEVER_SURFACE_MAP
            params_list = get(lever_info, "parameters", String[])
            fc = get(failing_by_norm, _lever_norm(check_name), nothing)
            if param in params_list && !isnothing(fc)
                push!(addressed, check_name)
                addressed_count += get(fc, "n_failing", 0)
                for prov in get_provisions_for_check(check_name)
                    push!(provisions_involved, Dict{String, Any}(
                        "section"              => get(prov, "section", ""),
                        "provision"            => get(prov, "provision", ""),
                        "failure_consequence"  => get(prov, "failure_consequence", ""),
                    ))
                end
            end
        end
        direction = _lever_direction(param)
        rationale = get_code_rationale(param)
        entry = Dict{String, Any}(
            "parameter"         => param,
            "addresses_checks"  => addressed,
            "addresses_n"       => addressed_count,
            "coverage_fraction" => total_failing > 0 ? addressed_count / total_failing : 0.0,
            "direction"         => direction,
            "provisions"        => unique(provisions_involved),
        )
        if !isnothing(rationale)
            entry["rationale"] = rationale
        end
        param_scores[param] = entry
    end

    sorted = sort(collect(values(param_scores)); by=d -> -get(d, "addresses_n", 0))
    return sorted
end

function _lever_direction(param::String)::String
    for (_, lever_info) in LEVER_SURFACE_MAP
        params_list = get(lever_info, "parameters", String[])
        if param in params_list
            return get(lever_info, "direction", "")
        end
    end
    return ""
end

"""
Extract floor_type string from a BuildingDesign for system dependency lookup.
"""
function _extract_floor_type(design::BuildingDesign)::Union{String, Nothing}
    try
        params = design.params
        if hasproperty(params, :floor_type)
            ft = params.floor_type
            return ft isa Symbol ? string(ft) : string(ft)
        end
    catch
    end
    return nothing
end

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

    if tier == :summary && any(ev -> ev.event_type in (:failure, :fallback), events)
        result["hint"] = "Failures detected in trace. Use tier=failures to see them."
    elseif tier == :failures && any(ev -> ev.event_type in (:decision, :iteration), events)
        n_decisions = count(ev -> ev.event_type in (:decision, :iteration), events)
        result["hint"] = "$n_decisions decision/iteration events available. Use tier=decisions for detail."
    end

    return result
end

# ─── Geometry Remediation Evaluation ──────────────────────────────────────────

"""
    _geometry_remediation_eval(design, diag, failing_checks) -> Vector{Dict}

For each failing check, evaluate whether the actual geometry exceeds the
`GEOMETRY_REMEDIATION_MAP` thresholds. Returns matched remediations with
quantified gaps and specific Grasshopper instructions.
"""
function _geometry_remediation_eval(
    design::BuildingDesign,
    diag::Dict,
    failing_checks::Vector{Dict{String, Any}},
)::Vector{Dict{String, Any}}
    results = Dict{String, Any}[]
    struc = design.structure
    skel = struc.skeleton

    # Extract geometry metrics
    edge_lengths_m = Float64[]
    for eidx in eachindex(skel.geometry.edges)
        e = skel.geometry.edges[eidx]
        v1 = skel.geometry.vertices[e[1]]
        v2 = skel.geometry.vertices[e[2]]
        dx = v1[1] - v2[1]; dy = v1[2] - v2[2]; dz = v1[3] - v2[3]
        push!(edge_lengths_m, sqrt(dx^2 + dy^2 + dz^2))
    end
    max_span_m = isempty(edge_lengths_m) ? 0.0 : maximum(edge_lengths_m)
    max_span_ft = max_span_m * 3.28084

    story_heights_m = Float64[]
    zs = skel.stories_z
    if length(zs) > 1
        for i in 2:length(zs)
            push!(story_heights_m, abs(zs[i] - zs[i-1]))
        end
    end
    max_story_m = isempty(story_heights_m) ? 0.0 : maximum(story_heights_m)

    n_columns = haskey(skel.groups_edges, :columns) ? length(skel.groups_edges[:columns]) : 0

    for fc in failing_checks
        check = get(fc, "check", "")
        norm_check = _lever_norm(check)
        remed = get(GEOMETRY_REMEDIATION_MAP, norm_check, nothing)
        isnothing(remed) && continue

        governs_when = get(remed, "geometry_likely_governs_when", Dict())
        matched = false
        gap_description = ""

        # Evaluate condition based on available thresholds
        thresh_span = get(governs_when, "max_span_m", nothing)
        thresh_story = get(governs_when, "max_story_height_m", nothing)
        thresh_trib = get(governs_when, "max_trib_area_m2", nothing)

        if !isnothing(thresh_span) && max_span_m > thresh_span
            matched = true
            target_ft = round(thresh_span * 3.28084; digits=0)
            gap_description = "Max span $(round(max_span_ft; digits=0)) ft exceeds " *
                "target ~$(target_ft) ft. Reduce by ~$(round(max_span_ft - target_ft; digits=0)) ft."
        end

        if !isnothing(thresh_story) && max_story_m > thresh_story
            matched = true
            target_ft = round(thresh_story * 3.28084; digits=0)
            actual_ft = round(max_story_m * 3.28084; digits=0)
            gap_description *= isempty(gap_description) ? "" : " "
            gap_description *= "Max story height $(actual_ft) ft exceeds target ~$(target_ft) ft."
        end

        !matched && continue

        push!(results, Dict{String, Any}(
            "check"        => check,
            "n_failing"    => get(fc, "n_failing", 0),
            "rationale"    => get(governs_when, "rationale", ""),
            "gap"          => gap_description,
            "actions"      => get(remed, "geometric_actions", []),
            "geometry_now" => Dict{String, Any}(
                "max_span_ft"    => round(max_span_ft; digits=1),
                "max_story_ft"   => round(max_story_m * 3.28084; digits=1),
                "n_columns"      => n_columns,
            ),
        ))
    end

    return results
end

# ─── Geometric Sensitivity Tool ──────────────────────────────────────────────

"""
    agent_predict_geometry_effect(variable, direction) -> Dict{String, Any}

Predict the structural effects of changing a geometric variable. Uses the static
`GEOMETRIC_SENSITIVITY_MAP` for scaling laws and economical ranges.
"""
function agent_predict_geometry_effect(
    variable::String,
    direction::String,
)::Dict{String, Any}
    valid_dirs = ["increase", "decrease"]
    direction in valid_dirs || return Dict{String, Any}(
        "error"   => "invalid_direction",
        "message" => "Direction must be one of: $(join(valid_dirs, ", ")). Got: \"$direction\".",
    )

    entry = get(GEOMETRIC_SENSITIVITY_MAP, variable, nothing)
    if isnothing(entry)
        available = sort(collect(keys(GEOMETRIC_SENSITIVITY_MAP)))
        return Dict{String, Any}(
            "error"     => "unknown_variable",
            "message"   => "Variable \"$variable\" not found. Available: $(join(available, ", ")).",
            "available" => available,
        )
    end

    # Build effects list, flipping direction labels for "decrease"
    effects = Dict{String, Any}[]
    for eff in get(entry, "affects", [])
        raw_dir = get(eff, "direction", "")
        effective_dir = if direction == "decrease"
            # Flip: "increase_span → worse" becomes "decrease_span → better"
            if occursin("worse", raw_dir)
                replace(raw_dir, "worse" => "better")
            elseif occursin("better", raw_dir)
                replace(raw_dir, "better" => "worse")
            elseif occursin("larger", raw_dir)
                replace(raw_dir, "larger" => "smaller")
            elseif occursin("thicker", raw_dir)
                replace(raw_dir, "thicker" => "thinner")
            else
                raw_dir
            end
        else
            raw_dir
        end

        push!(effects, Dict{String, Any}(
            "check"        => get(eff, "check", ""),
            "relationship" => get(eff, "relationship", ""),
            "direction"    => effective_dir,
            "explanation"  => get(eff, "explanation", ""),
        ))
    end

    result = Dict{String, Any}(
        "variable"          => variable,
        "direction"         => direction,
        "affected_checks"   => effects,
        "economical_ranges" => get(entry, "typical_economical_ranges", Dict()),
        "trade_offs"        => get(entry, "trade_offs", ""),
    )

    return result
end
