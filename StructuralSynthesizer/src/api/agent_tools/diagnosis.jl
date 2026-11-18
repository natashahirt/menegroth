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
            mat = opts.material
            checker = StructuralSizer.AISCChecker(; max_depth=opts.max_depth,
                deflection_limit = getfield(opts, :deflection_limit, nothing),
                total_deflection_limit = getfield(opts, :total_deflection_limit, nothing),
            )
            cat = [sec]
            cache = StructuralSizer.create_cache(checker, 1)
            StructuralSizer.precompute_capacities!(checker, cache, cat, mat, opts.objective)
            expl = StructuralSizer.explain_feasibility(checker, cache, 1, sec, mat, dem, geom)
        else
            # Concrete beam: the materials the beam sizer used
            conc, reb, _ = _beam_materials(params)
            checker = StructuralSizer.ACIBeamChecker(;
                fy_ksi  = ustrip(StructuralSizer.Asap.ksi, reb.Fy),
                fyt_ksi = ustrip(StructuralSizer.Asap.ksi, StructuralSizer.get_transverse_rebar(opts).Fy),
                Es_ksi  = ustrip(StructuralSizer.Asap.ksi, reb.E),
                λ       = conc.λ,
                max_depth = opts.max_depth,
            )
            cat = [sec]
            cache = StructuralSizer.create_cache(checker, 1)
            StructuralSizer.precompute_capacities!(checker, cache, cat, conc, opts.objective)
            expl = StructuralSizer.explain_feasibility(checker, cache, 1, sec, conc, dem, geom)
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
                # Explanation-layer corpus grounding (Harness Phase 1, P1):
                # live {source_id, clause, page} locator; no numeric effect.
                "citation" => ground_check(c.name, c.code_clause),
            ) for c in expl.checks],
        )
    else
        # column
        midx <= length(struc.columns) || return Dict("error" => "column_not_found", "message" => "column_idx out of range", "member_idx" => midx)
        col = struc.columns[midx]
        sec = section(col)
        isnothing(sec) && return Dict("error" => "no_section", "message" => "Column has no designed section", "member_idx" => midx)

        opts = if sec isa Union{StructuralSizer.RCColumnSection, StructuralSizer.RCCircularSection}
            concrete_column_options(params)
        else
            something(params.columns, StructuralSizer.SteelColumnOptions())
        end
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
            conc = something(col.concrete, column_concrete(params))
            reb = column_rebar(params)
            checker = StructuralSizer.ACIColumnChecker(;
                include_slenderness = opts.include_slenderness,
                include_biaxial = opts.include_biaxial,
                fy_ksi = ustrip(StructuralSizer.Asap.ksi, reb.Fy),
                Es_ksi = ustrip(StructuralSizer.Asap.ksi, reb.E),
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
            StructuralSizer.precompute_capacities!(checker, cache, cat, conc, opts.objective)
            expl = StructuralSizer.explain_feasibility(checker, cache, 1, sec, conc, dem, geom)
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
                # Explanation-layer corpus grounding (Harness Phase 1, P1):
                # live {source_id, clause, page} locator; no numeric effect.
                "citation" => ground_check(c.name, c.code_clause),
            ) for c in expl.checks],
        )
    end
end

"""
    agent_diagnose_summary(design::BuildingDesign) -> Dict{String, Any}

Lightweight failure overview: counts by element type, top-N critical elements,
and failure breakdown by governing check — without the full per-element dump.
Also forwards `agent_summary` EC fields (`total_ec_kgco2e`, `floor_area`, `ec_intensity`),
`embodied_carbon_by_system_kgco2e`, and `embodied_carbon_note` (total vs summed per-element EC).
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
            ratio_raw = get(e, "governing_ratio", 0.0)
            ratio = ratio_raw isa Number ? Float64(ratio_raw) : 0.0
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

    # Inline guidance — delivered at the moment the model is reviewing failures
    n_failing = result["n_total_failing"]
    if n_failing > 0 && n_critical_sw > 0
        result["_guidance"] =
            "GEOMETRY BOTTLENECK: Size warnings with parameter_headroom='none' mean parameter " *
            "changes alone cannot fix this. Call suggest_next_action(goal='fix_failures') to " *
            "get geometry_actions with Grasshopper targets."
    elseif n_failing > 0
        result["_guidance"] =
            "NEXT STEP: Call get_lever_map(check=<governing_check>) before recommending " *
            "parameter changes. Always validate_params before run_design."
    end

    # Same EC / floor / intensity as full `get_diagnose` → `agent_summary` (design.summary.embodied_carbon).
    as = get(diag, "agent_summary", nothing)
    if as isa AbstractDict
        for k in ("all_pass", "critical_element", "critical_ratio", "total_ec_kgco2e", "floor_area", "ec_intensity")
            haskey(as, k) && (result[k] = as[k])
        end
    end

    s = design.summary
    # Strip typed `kgCO₂e` once at the JSON-build boundary.
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
    ec_parts_kg = ec_slabs_kg + ec_columns_kg + ec_beams_kg +
                  ec_struts_kg + ec_foundations_kg + ec_fireproofing_kg
    if ec_total_kg > 0 || ec_parts_kg > 1e-9
        result["embodied_carbon_by_system_kgco2e"] = Dict{String, Any}(
            "slabs"         => round(ec_slabs_kg; digits=0),
            "columns"       => round(ec_columns_kg; digits=0),
            "beams"         => round(ec_beams_kg; digits=0),
            "struts"        => round(ec_struts_kg; digits=0),
            "foundations"   => round(ec_foundations_kg; digits=0),
            "fireproofing"  => round(ec_fireproofing_kg; digits=0),
        )
        result["embodied_carbon_by_material_kgco2e"] = Dict{String, Any}(
            "concrete"         => round(ec_concrete_kg; digits=0),
            "rebar"            => round(ec_rebar_kg; digits=0),
            "structural_steel" => round(ec_steel_kg; digits=0),
            "fireproofing"     => round(ec_fireproofing_kg; digits=0),
        )
    end
    result["embodied_carbon_note"] =
        "total_ec_kgco2e matches design.summary.embodied_carbon (includes struts and fireproofing when present). " *
        "Summing per-element ec_kgco2e from get_diagnose can be lower: that payload omits struts and fireproofing."

    return result
end

