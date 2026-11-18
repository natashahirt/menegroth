# ─── Footing Proximity ─────────────────────────────────────────────────────────

"""
    _check_footing_proximity!(warnings, design, fdn_dicts, is_imp, fdn_t)

Compute actual edge-to-edge clearances between spread footings using their designed
plan dimensions and column positions. Emits a warning for each pair of footings
whose edges are closer than 12 in (or overlap), and a warning for footings whose
plan area exceeds the threshold.
"""
function _check_footing_proximity!(
    warnings::Vector{Dict{String, Any}},
    design::BuildingDesign,
    fdn_dicts::Vector,
    is_imp::Bool,
    fdn_t::Dict{String, Any},
)
    struc = design.structure
    (isnothing(struc) || isempty(struc.foundations)) && return

    skel = struc.skeleton
    nf = length(struc.foundations)
    nf < 2 && return

    # Build a vector of (fdn_idx, centroid_x_m, centroid_y_m, half_L_m, half_W_m)
    # for single-support (spread) footings only.
    fdata = NamedTuple{(:fi, :x, :y, :hL, :hW),
                       NTuple{5, Float64}}[]

    for (fi, fnd) in enumerate(struc.foundations)
        length(fnd.support_indices) != 1 && continue
        si = fnd.support_indices[1]
        (si < 1 || si > length(struc.supports)) && continue
        sup = struc.supports[si]
        v = skel.vertices[sup.vertex_idx]
        c = Meshes.coords(v)
        cx = ustrip(u"m", c.x)
        cy = ustrip(u"m", c.y)

        # Get designed plan dimensions from FoundationDesignResult
        !haskey(design.foundations, fi) && continue
        fr = design.foundations[fi]
        L_m = ustrip(u"m", fr.length)
        W_m = ustrip(u"m", fr.width)
        (L_m <= 0 || W_m <= 0) && continue

        push!(fdata, (fi=fi, x=cx, y=cy, hL=L_m/2, hW=W_m/2))
    end

    length(fdata) < 2 && return

    min_clearance_m = Asap.FT_TO_M   # 1 ft

    for i in eachindex(fdata)
        for j in (i+1):length(fdata)
            a = fdata[i]
            b = fdata[j]

            # Axis-aligned edge-to-edge gap between rectangles centered on columns.
            # gap_x, gap_y are edge separations along each axis (negative = overlap).
            gap_x = abs(a.x - b.x) - a.hL - b.hL
            gap_y = abs(a.y - b.y) - a.hW - b.hW

            # If both gaps are negative, footings fully overlap in plan.
            # If one is negative, footings overlap on that axis; clearance = the other.
            # If both positive, closest corner distance = hypot(gap_x, gap_y).
            gap = if gap_x < 0 && gap_y < 0
                max(gap_x, gap_y)   # both overlap; report the smaller intrusion
            elseif gap_x < 0
                gap_y               # overlap in x, clearance determined by y
            elseif gap_y < 0
                gap_x               # overlap in y, clearance determined by x
            else
                hypot(gap_x, gap_y) # diagonal separation
            end

            if gap < min_clearance_m
                gap_in = gap * 39.3701
                gap_disp = is_imp ? round(gap_in; digits=1) : round(gap * 1000; digits=0)
                gap_unit = is_imp ? "in" : "mm"

                if gap <= 0
                    severity = "critical"
                    interp = "Footings $(a.fi) and $(b.fi) overlap by $(abs(round(gap_in; digits=1))) in — " *
                        "consider combining into a combined/strip footing or adding columns."
                else
                    severity = "warning"
                    interp = "Footings $(a.fi) and $(b.fi) have only $(gap_disp) $(gap_unit) " *
                        "edge clearance — construction may be impractical. " *
                        "Consider combining into a strip footing or adding columns."
                end

                push!(warnings, Dict{String, Any}(
                    "element_type" => "foundation",
                    "element_id" => "$(a.fi)-$(b.fi)",
                    "check" => "footing_proximity",
                    "severity" => severity,
                    "value" => _round_val(gap_disp),
                    "threshold" => is_imp ? 12.0 : 305.0,
                    "unit" => gap_unit,
                    "interpretation" => interp,
                    "parameter_headroom" => gap <= 0 ? "none" : "limited",
                ))
            end
        end
    end

    # Also check individual footing plan area
    for fd in fdn_dicts
        fl = get(fd, "length", 0.0)
        fw = get(fd, "width", 0.0)
        fl_ft = is_imp ? fl : fl * 3.28084
        fw_ft = is_imp ? fw : fw * 3.28084
        area_ft2 = fl_ft * fw_ft

        if area_ft2 > fdn_t["plan_area_max_ft2"]
            push!(warnings, Dict{String, Any}(
                "element_type" => "foundation", "element_id" => get(fd, "id", "?"),
                "check" => "oversized_footing", "severity" => "warning",
                "value" => _round_val(area_ft2), "threshold" => fdn_t["plan_area_max_ft2"], "unit" => "ft²",
                "interpretation" => "Footing plan area $(round(area_ft2; digits=0)) ft² is very large. " *
                    "Consider adding columns or switching to strip/mat foundation.",
                "parameter_headroom" => "limited",
            ))
        end
    end
end

# ─── Element Reasonableness Checks ────────────────────────────────────────────

"""
    _element_reasonableness_checks(design, du, col_dicts, beam_dicts, slab_dicts, fdn_dicts)

Compare sized element dimensions against industry-norm thresholds from
`ELEMENT_REASONABLENESS_THRESHOLDS`. Returns a `Vector{Dict{String,Any}}`
of warnings sorted by severity (critical first).
"""
function _element_reasonableness_checks(
    design::BuildingDesign,
    du::DisplayUnits,
    col_dicts::Vector,
    beam_dicts::Vector,
    slab_dicts::Vector,
    fdn_dicts::Vector,
)::Vector{Dict{String, Any}}
    warnings = Dict{String, Any}[]
    is_imp = _is_imperial(du)
    t = ELEMENT_REASONABLENESS_THRESHOLDS

    slab_t = t["slab"]
    col_t  = t["column"]
    beam_t = t["beam"]
    fdn_t  = t["foundation"]

    # ── Slab checks ──────────────────────────────────────────────────────
    for sd in slab_dicts
        h_disp = get(sd, "thickness", 0.0)
        h_in   = is_imp ? h_disp : h_disp / 25.4

        if h_in > slab_t["thickness_extreme_in"]
            push!(warnings, Dict{String, Any}(
                "element_type" => "slab", "element_id" => get(sd, "id", "?"),
                "check" => "extreme_thickness", "severity" => "critical",
                "value" => _round_val(h_in), "threshold" => slab_t["thickness_extreme_in"], "unit" => "in",
                "interpretation" => "Slab thickness $(round(h_in; digits=1)) in is extreme " *
                    "(> $(slab_t["thickness_extreme_in"]) in). This almost certainly indicates " *
                    "spans are too long for any slab system. Reduce column spacing in Grasshopper.",
                "parameter_headroom" => "none",
            ))
        elseif h_in > slab_t["thickness_max_in"]
            push!(warnings, Dict{String, Any}(
                "element_type" => "slab", "element_id" => get(sd, "id", "?"),
                "check" => "excessive_thickness", "severity" => "warning",
                "value" => _round_val(h_in), "threshold" => slab_t["thickness_max_in"], "unit" => "in",
                "interpretation" => "Slab thickness $(round(h_in; digits=1)) in exceeds typical " *
                    "flat plate limit (~$(slab_t["thickness_max_in"]) in). Consider reducing spans " *
                    "or switching to a beam-and-slab system.",
                "parameter_headroom" => "limited",
            ))
        end

        defl_ratio = get(sd, "deflection_ratio", 0.0)
        if defl_ratio > slab_t["deflection_ratio_marginal"]
            push!(warnings, Dict{String, Any}(
                "element_type" => "slab", "element_id" => get(sd, "id", "?"),
                "check" => "deflection_marginal", "severity" => "warning",
                "value" => _round_val(defl_ratio), "threshold" => slab_t["deflection_ratio_marginal"], "unit" => "ratio",
                "interpretation" => "Deflection ratio $(round(defl_ratio; digits=2)) is near " *
                    "the limit — almost no margin. Deeper slab would add self-weight, " *
                    "creating diminishing returns.",
                "parameter_headroom" => "limited",
            ))
        end
    end

    # Self-weight dominance: check from the design result objects directly
    # design.slabs is Dict{Int,SlabDesignResult}; enumerate(dict) yields (n, Pair{K,V}), not results.
    for (slab_idx, sr) in design.slabs
        qu_val  = sr.qu
        sw_val  = sr.self_weight
        (isnothing(qu_val) || isnothing(sw_val)) && continue
        qu_raw = Float64(ustrip(u"kPa", qu_val))
        sw_raw = Float64(ustrip(u"kPa", sw_val))
        qu_raw <= 0 && continue
        sw_frac = sw_raw / qu_raw
        if sw_frac > slab_t["self_weight_dominance"]
            push!(warnings, Dict{String, Any}(
                "element_type" => "slab", "element_id" => "slab_$slab_idx",
                "check" => "self_weight_dominance", "severity" => "critical",
                "value" => _round_val(sw_frac; digits=2), "threshold" => slab_t["self_weight_dominance"], "unit" => "fraction",
                "interpretation" => "Slab self-weight is $(round(sw_frac * 100; digits=0))% of " *
                    "factored load — the slab is mostly carrying itself. " *
                    "This is a classic sign of spans being too long for the floor system.",
                "parameter_headroom" => "none",
            ))
        end
    end

    # ── Column checks ────────────────────────────────────────────────────
    for cd in col_dicts
        c1_disp = get(cd, "c1", 0.0)
        c2_disp = get(cd, "c2", 0.0)
        c_max_disp = max(c1_disp, c2_disp)
        c_min_disp = min(c1_disp, c2_disp)
        c_max_in = is_imp ? c_max_disp : c_max_disp / 25.4
        c_min_in = is_imp ? c_min_disp : c_min_disp / 25.4

        if c_max_in > col_t["max_dimension_in"]
            push!(warnings, Dict{String, Any}(
                "element_type" => "column", "element_id" => get(cd, "id", "?"),
                "check" => "oversized_column", "severity" => "warning",
                "value" => _round_val(c_max_in), "threshold" => col_t["max_dimension_in"], "unit" => "in",
                "interpretation" => "Column dimension $(round(c_max_in; digits=1)) in exceeds " *
                    "$(col_t["max_dimension_in"]) in — unusual for buildings under ~20 stories. " *
                    "Consider adding columns to redistribute load.",
                "parameter_headroom" => "limited",
            ))
        end

        if c_min_in > 0 && c_min_in < col_t["min_dimension_in"]
            push!(warnings, Dict{String, Any}(
                "element_type" => "column", "element_id" => get(cd, "id", "?"),
                "check" => "undersized_column", "severity" => "warning",
                "value" => _round_val(c_min_in), "threshold" => col_t["min_dimension_in"], "unit" => "in",
                "interpretation" => "Column dimension $(round(c_min_in; digits=1)) in is below " *
                    "practical minimum (~$(col_t["min_dimension_in"]) in).",
                "parameter_headroom" => "available",
            ))
        end

        rho_g = get(cd, "rho_g", 0.0)
        if rho_g > col_t["rho_g_high"]
            push!(warnings, Dict{String, Any}(
                "element_type" => "column", "element_id" => get(cd, "id", "?"),
                "check" => "congested_reinforcement", "severity" => "warning",
                "value" => _round_val(rho_g; digits=4), "threshold" => col_t["rho_g_high"], "unit" => "ratio",
                "interpretation" => "Reinforcement ratio $(round(rho_g; digits=3)) exceeds " *
                    "$(col_t["rho_g_high"]) — congested rebar makes construction difficult. " *
                    "ACI max is 0.08. Consider larger column section or higher f'c.",
                "parameter_headroom" => "limited",
            ))
        end
    end

    # ── Beam checks ──────────────────────────────────────────────────────
    for bd in beam_dicts
        section = get(bd, "section", "")
        member_len = get(bd, "member_length", 0.0)  # ft (imp) or m (metric)
        len_in = is_imp ? member_len * 12.0 : member_len * 39.3701  # → inches

        # Extract depth from W-shape section name (e.g. "W24x94" → 24 in)
        m = match(r"W(\d+)", section)
        if !isnothing(m)
            depth_in = parse(Float64, m.captures[1])

            if depth_in > beam_t["depth_max_in"]
                push!(warnings, Dict{String, Any}(
                    "element_type" => "beam", "element_id" => get(bd, "id", "?"),
                    "check" => "very_deep_beam", "severity" => "warning",
                    "value" => depth_in, "threshold" => beam_t["depth_max_in"], "unit" => "in",
                    "interpretation" => "Beam depth $(round(depth_in; digits=0)) in is very deep — " *
                        "may conflict with MEP routing and ceiling clearance.",
                    "parameter_headroom" => "limited",
                ))
            end

            if len_in > 0 && depth_in > 0
                l_d = len_in / depth_in
                if l_d < beam_t["span_to_depth_min"]
                    push!(warnings, Dict{String, Any}(
                        "element_type" => "beam", "element_id" => get(bd, "id", "?"),
                        "check" => "low_span_depth_ratio", "severity" => "warning",
                        "value" => _round_val(l_d), "threshold" => beam_t["span_to_depth_min"], "unit" => "L/d",
                        "interpretation" => "Span-to-depth ratio $(round(l_d; digits=1)) is unusually low — " *
                            "beam is very deep relative to its span, suggesting heavy loads or geometry issues.",
                        "parameter_headroom" => "limited",
                    ))
                end
            end
        end

        # Weight per foot for steel beams (from section name, e.g. "W24x94" → 94 plf)
        mw = match(r"W\d+x(\d+)", section)
        if !isnothing(mw)
            wt_plf = parse(Float64, mw.captures[1])
            if wt_plf > beam_t["weight_per_ft_extreme"]
                push!(warnings, Dict{String, Any}(
                    "element_type" => "beam", "element_id" => get(bd, "id", "?"),
                    "check" => "heavy_beam", "severity" => "warning",
                    "value" => wt_plf, "threshold" => beam_t["weight_per_ft_extreme"], "unit" => "plf",
                    "interpretation" => "Beam weight $(round(wt_plf; digits=0)) plf is very heavy — " *
                        "suggests high demands. Consider reducing span or adding intermediate supports.",
                    "parameter_headroom" => "limited",
                ))
            end
        end
    end

    # ── Foundation checks ────────────────────────────────────────────────
    for fd in fdn_dicts
        fdepth = get(fd, "depth", 0.0)
        d_in = is_imp ? fdepth : fdepth / 25.4         # depth is in in (imp) or mm (metric)

        if d_in > fdn_t["depth_max_in"]
            push!(warnings, Dict{String, Any}(
                "element_type" => "foundation", "element_id" => get(fd, "id", "?"),
                "check" => "deep_footing", "severity" => "warning",
                "value" => _round_val(d_in), "threshold" => fdn_t["depth_max_in"], "unit" => "in",
                "interpretation" => "Footing depth $(round(d_in; digits=1)) in is very thick — " *
                    "high punching or flexure demands from large column reactions.",
                "parameter_headroom" => "limited",
            ))
        end
    end

    # ── Foundation proximity (actual edge-to-edge clearance) ──────────
    _check_footing_proximity!(warnings, design, fdn_dicts, is_imp, fdn_t)

    # Sort: critical first, then by element type
    sort!(warnings; by=w -> (get(w, "severity", "") == "critical" ? 0 : 1, get(w, "element_type", "")))
    return warnings
end

# ─── Top-level ────────────────────────────────────────────────────────────────

"""
    design_to_diagnose(design::BuildingDesign; report_units=nothing) -> Dict{String, Any}

Serialize a `BuildingDesign` into the high-resolution diagnostic JSON format.

Returns a three-layer Dict:
- `columns`, `beams`, `slabs`, `foundations`: per-element engineering data
  (checks, demands, capacities, governing check, levers, EC).
- `agent_summary`: overall pass/fail status, check distribution, worst elements.
- `architectural`: system narrative, goal recommendations.
- `constraints`: geometry-fixed values and analytical lever impact estimates.
- `size_warnings`: element reasonableness checks (abnormal sizes, parameter headroom).
- `design_context`: input parameters (loads, methods, limits) in machine-readable form.

All numeric values are in the display unit system specified by `report_units`
(`:imperial` or `:metric`) or `design.params.display_units` if not specified.
"""
function design_to_diagnose(design::BuildingDesign; report_units=nothing)
    params = design.params
    du = report_units === nothing ? params.display_units : DisplayUnits(report_units)
    struc = design.structure

    # Per-element serializers attach live corpus citations to each check dict
    # (explanation-layer only, via `_ground_checks!` in corpus_grounding.jl).
    col_dicts  = _diagnose_columns(design, struc, du)
    beam_dicts = _diagnose_beams(design, struc, du)
    slab_dicts = _diagnose_slabs(design, struc, du)
    fdn_dicts  = _diagnose_foundations(design, du)

    design_context = _diagnose_design_context(params, du; design=design)
    agent_summary  = _diagnose_agent_summary(design, du, col_dicts, beam_dicts, slab_dicts, fdn_dicts)
    architectural  = _diagnose_architectural(design, params, du, col_dicts, beam_dicts, slab_dicts, fdn_dicts)
    constraints    = _diagnose_constraints(design, struc, params, du, col_dicts, beam_dicts, slab_dicts, fdn_dicts)
    size_warnings  = _element_reasonableness_checks(design, du, col_dicts, beam_dicts, slab_dicts, fdn_dicts)

    return Dict{String, Any}(
        "status"         => "ok",
        "unit_system"    => _is_imperial(du) ? "imperial" : "metric",
        "length_unit"    => _length_unit_string(du),
        "thickness_unit" => _thickness_unit_string(du),
        "force_unit"     => _force_unit_str(du),
        "moment_unit"    => _moment_unit_str(du),
        "pressure_unit"  => _pressure_unit_str(du),
        "design_context" => design_context,
        "agent_summary"  => agent_summary,
        "columns"        => col_dicts,
        "beams"          => beam_dicts,
        "slabs"          => slab_dicts,
        "foundations"    => fdn_dicts,
        "architectural"  => architectural,
        "constraints"    => constraints,
        "size_warnings"  => size_warnings,
    )
end
