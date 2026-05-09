# =============================================================================
# Report Summary — structured JSON and condensed text overviews
#
# Complements the plain-text engineering_report() with machine-readable output
# for the LLM chat agents and the GET /report?format=json endpoint.
# =============================================================================

"""
    _floor_type_code(params::DesignParameters) -> String

Derive the API floor-type code from internal DesignParameters.
"""
function _floor_type_code(params::DesignParameters)
    f = params.floor
    isnothing(f) && return "unknown"
    f isa StructuralSizer.FlatPlateOptions && return "flat_plate"
    f isa StructuralSizer.FlatSlabOptions && return "flat_slab"
    f isa StructuralSizer.OneWayOptions && return "one_way"
    f isa StructuralSizer.VaultOptions && return "vault"
    return string(typeof(f).name.name)
end

"""
    _column_type_code(params::DesignParameters) -> String

Derive the API column-type code from internal DesignParameters.
"""
function _column_type_code(params::DesignParameters)
    opts = params.columns
    isnothing(opts) && return "unknown"
    opts isa StructuralSizer.ConcreteColumnOptions &&
        return opts.section_shape == :circular ? "rc_circular" : "rc_rect"
    opts isa StructuralSizer.SteelColumnOptions &&
        return opts.section_type == :hss ? "steel_hss" : "steel_w"
    opts isa StructuralSizer.PixelFrameColumnOptions && return "pixelframe"
    return "other"
end

"""
    _beam_type_code(params::DesignParameters) -> String

Derive the API beam-type code from internal DesignParameters.
"""
function _beam_type_code(params::DesignParameters)
    opts = params.beams
    isnothing(opts) && return "unknown"
    opts isa StructuralSizer.SteelBeamOptions &&
        return opts.section_type == :hss ? "steel_hss" : "steel_w"
    opts isa StructuralSizer.ConcreteBeamOptions &&
        return opts.include_flange ? "rc_tbeam" : "rc_rect"
    opts isa StructuralSizer.PixelFrameBeamOptions && return "pixelframe"
    return "other"
end

"""First key in a design-result component dict (stable numeric order)."""
function _first_design_result_idx(d::Dict{Int, <:Any})::Union{Int, Nothing}
    isempty(d) && return nothing
    return minimum(keys(d))
end

"""
    _column_type_code_from_design(design::BuildingDesign) -> String

When `params.columns === nothing`, infer the API column-type string from sized
`ColumnDesignResult.section_obj` (still populated after `restore!`; member `section`
on `BuildingStructure` may be cleared).
"""
function _column_type_code_from_design(design::BuildingDesign)::String
    k = _first_design_result_idx(design.columns)
    isnothing(k) && return "unknown"
    cr = design.columns[k]
    so = cr.section_obj
    isnothing(so) && return "unknown"
    so isa StructuralSizer.RCCircularSection && return "rc_circular"
    so isa StructuralSizer.RCColumnSection && return cr.shape == :circular ? "rc_circular" : "rc_rect"
    so isa StructuralSizer.ISymmSection && return "steel_w"
    so isa StructuralSizer.HSSRectSection && return "steel_hss"
    so isa StructuralSizer.HSSRoundSection && return "steel_hss"
    so isa StructuralSizer.PixelFrameSection && return "pixelframe"
    return "other"
end

"""
    _beam_type_code_from_design(design::BuildingDesign, params::DesignParameters) -> String

Infer beam API code from `BeamDesignResult.section_obj`. Returns `"n_a"` when the
beam-result map is empty, or when every entry lacks a section (common for flat
plate / flat slab: `struc.beams` may still carry unsized placeholders).
"""
function _beam_type_code_from_design(design::BuildingDesign, params::DesignParameters)::String
    beams = design.beams
    isempty(beams) && return "n_a"
    for k in sort!(collect(keys(beams)))
        so = beams[k].section_obj
        isnothing(so) && continue
        so isa StructuralSizer.ISymmSection && return "steel_w"
        so isa StructuralSizer.HSSRectSection && return "steel_hss"
        so isa StructuralSizer.HSSRoundSection && return "steel_hss"
        so isa StructuralSizer.RCTBeamSection && return "rc_tbeam"
        so isa StructuralSizer.RCBeamSection && return "rc_rect"
        so isa StructuralSizer.PixelFrameSection && return "pixelframe"
        return "other"
    end
    f = params.floor
    if !isnothing(f) &&
       (f isa StructuralSizer.FlatPlateOptions || f isa StructuralSizer.FlatSlabOptions)
        return "n_a"
    end
    return "unknown"
end

# ─── Structured JSON Report Summary ──────────────────────────────────────────
# _api_section_type        → serialize.jl
# _normalize_failure_reason → schema.jl
# _normalize_failing_checks → schema.jl
# _column_governing_check, _beam_governing_check, _fdn_governing_check → diagnose.jl

"""
    report_summary_json(design::BuildingDesign; report_units=nothing) -> Dict

Build a structured JSON-friendly summary of design results.

Returns a Dict with keys `overall`, `slabs`, `columns`, `beams`,
`foundations`, `materials`. All numeric values use display units
matching `report_units` (or `design.params.display_units`).
"""
function report_summary_json(design::BuildingDesign; report_units=nothing)
    params = design.params
    du = report_units === nothing ? params.display_units : DisplayUnits(report_units)

    thick_label = _thickness_unit_string(du)
    vol_label   = _volume_unit_string(du)
    mass_label  = _mass_unit_string(du)

    s = design.summary
    result = Dict{String, Any}()

    # ─── Overall ──────────────────────────────────────────────────────
    n_stories = length(design.structure.skeleton.stories)
    result["overall"] = Dict{String, Any}(
        "all_pass"         => s.all_checks_pass,
        "critical_element" => s.critical_element,
        "critical_ratio"   => _round_val(s.critical_ratio),
        "stories"          => n_stories,
        "floor_system"     => _floor_type_code(params),
        "column_type"      => _column_type_code(params),
        "beam_type"        => _beam_type_code(params),
        "unit_system"      => du.units[:length] == u"ft" ? "imperial" : "metric",
        "compute_time_s"   => _round_val(design.compute_time_s; digits=2),
    )

    # ─── Slabs ────────────────────────────────────────────────────────
    result["slabs"] = _summary_slabs(design, du, thick_label)

    # ─── Columns ──────────────────────────────────────────────────────
    result["columns"] = _summary_columns(design, du)

    # ─── Beams ────────────────────────────────────────────────────────
    result["beams"] = _summary_beams(design, du)

    # ─── Foundations ──────────────────────────────────────────────────
    result["foundations"] = _summary_foundations(design, du)

    # ─── Materials ────────────────────────────────────────────────────
    materials = Dict{String, Any}(
        "concrete_volume" => Dict("value" => _round_val(_to_display(du, :volume, s.concrete_volume); digits=1), "unit" => vol_label),
        "steel_weight"    => Dict("value" => _round_val(_to_display(du, :mass, s.steel_weight); digits=0),     "unit" => mass_label),
        "rebar_weight"    => Dict("value" => _round_val(_to_display(du, :mass, s.rebar_weight); digits=0),     "unit" => mass_label),
        "embodied_carbon" => Dict("value" => _round_val(s.embodied_carbon; digits=0), "unit" => "kgCO2e"),
    )
    ec_parts = s.embodied_carbon_slabs + s.embodied_carbon_columns + s.embodied_carbon_beams +
               s.embodied_carbon_struts + s.embodied_carbon_foundations + s.embodied_carbon_fireproofing
    if s.embodied_carbon > 0 || ec_parts > 1e-9
        materials["embodied_carbon_by_system_kgco2e"] = Dict{String, Any}(
            "slabs"        => _round_val(s.embodied_carbon_slabs; digits=0),
            "columns"      => _round_val(s.embodied_carbon_columns; digits=0),
            "beams"        => _round_val(s.embodied_carbon_beams; digits=0),
            "struts"       => _round_val(s.embodied_carbon_struts; digits=0),
            "foundations"  => _round_val(s.embodied_carbon_foundations; digits=0),
            "fireproofing" => _round_val(s.embodied_carbon_fireproofing; digits=0),
        )
    end
    result["materials"] = materials

    # ─── Floor Area & EC Intensity ────────────────────────────────────
    struc = design.structure
    floor_area_m2 = sum(ustrip(u"m^2", c.area) for c in struc.cells; init=0.0)
    is_imp = du.units[:length] == u"ft"
    floor_area_disp = is_imp ? floor_area_m2 * 10.7639 : floor_area_m2
    area_unit = is_imp ? "ft2" : "m2"
    ec_intensity_m2 = floor_area_m2 > 0 ? s.embodied_carbon / floor_area_m2 : 0.0
    ec_intensity_disp = is_imp ? ec_intensity_m2 / 10.7639 : ec_intensity_m2
    intensity_unit = is_imp ? "kgCO2e/ft2" : "kgCO2e/m2"

    result["floor_area"] = Dict{String, Any}(
        "value" => _round_val(floor_area_disp; digits=0),
        "unit"  => area_unit,
        "value_m2" => _round_val(floor_area_m2; digits=0),
    )
    result["ec_intensity"] = Dict{String, Any}(
        "value"    => _round_val(ec_intensity_disp; digits=1),
        "unit"     => intensity_unit,
        "value_m2" => _round_val(ec_intensity_m2; digits=1),
        "unit_m2"  => "kgCO2e/m2",
    )

    return result
end

# ─── Per-element helpers ─────────────────────────────────────────────────────

function _summary_slabs(design::BuildingDesign, du::DisplayUnits, thick_label::String)
    n = length(design.slabs)
    n == 0 && return Dict{String, Any}("count" => 0, "passing" => 0, "failing" => 0)

    slab_vec = sort(collect(design.slabs); by=first)
    passing = count(((_, sr),) -> sr.converged && sr.deflection_ok && sr.punching_ok, slab_vec)
    n_non_converged = count(((_, sr),) -> !sr.converged, slab_vec)

    thicknesses = [_round_val(_to_display(du, :thickness, sr.thickness); digits=2) for (_, sr) in slab_vec]

    # Only consider converged slabs for "worst" ratios — non-converged slabs
    # have 0.0 defaults that would mask real failures.
    converged_vec = [(k, sr) for (k, sr) in slab_vec if sr.converged]
    if !isempty(converged_vec)
        defl_ratios_c  = [sr.deflection_ratio     for (_, sr) in converged_vec]
        punch_ratios_c = [sr.punching_max_ratio    for (_, sr) in converged_vec]
        wd_idx = argmax(defl_ratios_c)
        wp_idx = argmax(punch_ratios_c)
        worst_defl  = Dict("id" => converged_vec[wd_idx][1], "ratio" => _round_val(defl_ratios_c[wd_idx]))
        worst_punch = Dict("id" => converged_vec[wp_idx][1], "ratio" => _round_val(punch_ratios_c[wp_idx]))
    else
        worst_defl  = Dict{String, Any}("id" => 0, "ratio" => -1.0, "note" => "no converged slabs")
        worst_punch = Dict{String, Any}("id" => 0, "ratio" => -1.0, "note" => "no converged slabs")
    end

    failing_details = [
        let
            nc = !sr.converged
            Dict{String, Any}(
                "id"              => k,
                "non_converged"   => nc,
                "failure_reason"  => _normalize_failure_reason(sr.failure_reason),
                "failing_checks"  => _normalize_failing_checks(sr.failing_check),
                "deflection_ratio" => nc ? -1.0 : _round_val(sr.deflection_ratio),
                "punching_ratio"  => nc ? -1.0 : _round_val(sr.punching_max_ratio),
            )
        end
        for (k, sr) in slab_vec
        if !(sr.converged && sr.deflection_ok && sr.punching_ok)
    ]

    result = Dict{String, Any}(
        "count"   => n,
        "passing" => passing,
        "failing" => n - passing,
        "thickness_range" => Dict("min" => minimum(thicknesses), "max" => maximum(thicknesses), "unit" => thick_label),
        "worst_deflection" => worst_defl,
        "worst_punching"   => worst_punch,
        "failing_details"  => failing_details,
    )
    n_non_converged > 0 && (result["non_converged"] = n_non_converged)
    return result
end

function _summary_columns(design::BuildingDesign, du::DisplayUnits)
    n = length(design.columns)
    n == 0 && return Dict{String, Any}("count" => 0, "passing" => 0, "failing" => 0)

    col_vec = sort(collect(design.columns); by=first)
    passing = count(((_, cr),) -> cr.ok, col_vec)

    interaction = [cr.interaction_ratio for (_, cr) in col_vec]
    axial = [cr.axial_ratio for (_, cr) in col_vec]
    sections = unique([cr.section_size for (_, cr) in col_vec if !isempty(cr.section_size)])
    worst_idx = argmax(interaction)

    failing_details = [
        Dict{String, Any}(
            "id"                => k,
            "section"           => cr.section_size,
            "section_type"      => _api_section_type(cr.section_obj),
            "governing_check"   => _column_governing_check(cr),
            "axial_ratio"       => _round_val(cr.axial_ratio),
            "interaction_ratio" => _round_val(cr.interaction_ratio),
        )
        for (k, cr) in col_vec if !cr.ok
    ]

    return Dict{String, Any}(
        "count"   => n,
        "passing" => passing,
        "failing" => n - passing,
        "sections_used" => sections,
        "worst_interaction" => Dict("id" => col_vec[worst_idx][1], "ratio" => _round_val(interaction[worst_idx])),
        "ratio_range" => Dict(
            "axial"       => Dict("min" => _round_val(minimum(axial)),       "max" => _round_val(maximum(axial))),
            "interaction" => Dict("min" => _round_val(minimum(interaction)), "max" => _round_val(maximum(interaction))),
        ),
        "failing_details" => failing_details,
    )
end

function _summary_beams(design::BuildingDesign, du::DisplayUnits)
    n = length(design.beams)
    n == 0 && return Dict{String, Any}("count" => 0, "passing" => 0, "failing" => 0)

    beam_vec = sort(collect(design.beams); by=first)
    passing = count(((_, br),) -> br.ok, beam_vec)

    flex = [br.flexure_ratio for (_, br) in beam_vec]
    shear = [br.shear_ratio for (_, br) in beam_vec]
    sections = unique([br.section_size for (_, br) in beam_vec if !isempty(br.section_size)])
    worst_flex = argmax(flex)

    failing_details = [
        Dict{String, Any}(
            "id"              => k,
            "section"         => br.section_size,
            "section_type"    => _api_section_type(br.section_obj),
            "governing_check" => _beam_governing_check(br),
            "flexure_ratio"   => _round_val(br.flexure_ratio),
            "shear_ratio"     => _round_val(br.shear_ratio),
        )
        for (k, br) in beam_vec if !br.ok
    ]

    return Dict{String, Any}(
        "count"   => n,
        "passing" => passing,
        "failing" => n - passing,
        "sections_used" => sections,
        "worst_flexure" => Dict("id" => beam_vec[worst_flex][1], "ratio" => _round_val(flex[worst_flex])),
        "ratio_range" => Dict(
            "flexure" => Dict("min" => _round_val(minimum(flex)),  "max" => _round_val(maximum(flex))),
            "shear"   => Dict("min" => _round_val(minimum(shear)), "max" => _round_val(maximum(shear))),
        ),
        "failing_details" => failing_details,
    )
end

function _summary_foundations(design::BuildingDesign, du::DisplayUnits)
    n = length(design.foundations)
    n == 0 && return Dict{String, Any}("count" => 0, "passing" => 0, "failing" => 0)

    fdn_vec = sort(collect(design.foundations); by=first)
    passing = count(((_, fr),) -> fr.ok, fdn_vec)
    bearing = [fr.bearing_ratio for (_, fr) in fdn_vec]
    worst_idx = argmax(bearing)

    failing_details = [
        Dict{String, Any}(
            "id"              => k,
            "governing_check" => _fdn_governing_check(fr),
            "length"          => _round_val(_to_display_length(du, fr.length); digits=2),
            "width"           => _round_val(_to_display_length(du, fr.width); digits=2),
            "bearing_ratio"   => _round_val(fr.bearing_ratio),
            "punching_ratio"  => _round_val(fr.punching_ratio),
            "flexure_ratio"   => _round_val(fr.flexure_ratio),
        )
        for (k, fr) in fdn_vec if !fr.ok
    ]

    return Dict{String, Any}(
        "count"   => n,
        "passing" => passing,
        "failing" => n - passing,
        "worst_bearing" => Dict("id" => fdn_vec[worst_idx][1], "ratio" => _round_val(bearing[worst_idx])),
        "failing_details" => failing_details,
    )
end

# ─── Condensed Text Summary (for LLM context injection) ─────────────────────

"""
    condense_result(design::BuildingDesign; report_units=nothing) -> String

Produce a concise (~500-token) text summary of design results for injection
into an LLM system prompt. Covers overall status, per-element-type pass/fail
counts, worst ratios, and material totals.
"""
function condense_result(design::BuildingDesign; report_units=nothing)
    d = report_summary_json(design; report_units=report_units)
    ov = d["overall"]
    mat = d["materials"]

    lines = String[]
    push!(lines, "DESIGN SUMMARY")
    push!(lines, "Status: $(ov["all_pass"] ? "ALL CHECKS PASS" : "SOME CHECKS FAIL")")
    push!(lines, "Stories: $(ov["stories"]), Floor: $(ov["floor_system"]), Columns: $(ov["column_type"]), Beams: $(ov["beam_type"])")
    if !isempty(ov["critical_element"])
        push!(lines, "Critical element: $(ov["critical_element"]), ratio=$(ov["critical_ratio"])")
    end

    # Top failure modes by governing check
    check_freqs = Dict{String, Int}()
    for key in ("slabs", "columns", "beams", "foundations")
        sec = get(d, key, Dict())
        for fd in get(sec, "failing_details", [])
            for gc_key in ("governing_check", "failing_checks")
                gc = get(fd, gc_key, nothing)
                if gc isa AbstractString && !isempty(gc)
                    check_freqs[gc] = get(check_freqs, gc, 0) + 1
                elseif gc isa AbstractVector
                    for c in gc
                        c isa AbstractString && !isempty(c) && (check_freqs[c] = get(check_freqs, c, 0) + 1)
                    end
                end
            end
        end
    end
    if !isempty(check_freqs)
        sorted_checks = sort(collect(check_freqs); by=last, rev=true)
        top_checks = [first(c) for c in sorted_checks[1:min(3, length(sorted_checks))]]
        push!(lines, "Top failure modes: $(join(top_checks, ", "))")
    end

    # Size warnings from element reasonableness checks
    try
        diag = design_to_diagnose(design)
        sw = get(diag, "size_warnings", Any[])
        if !isempty(sw)
            n_crit = count(w -> get(w, "severity", "") == "critical", sw)
            n_warn = length(sw) - n_crit
            parts = String[]
            n_crit > 0 && push!(parts, "$n_crit critical")
            n_warn > 0 && push!(parts, "$n_warn warning")
            detail_parts = String[]
            for w in sw[1:min(3, length(sw))]
                push!(detail_parts, get(w, "interpretation", ""))
            end
            push!(lines, "Size warnings: $(join(parts, ", ")). $(join(detail_parts, "; "))")
        end
    catch; end

    push!(lines, "Compute: $(ov["compute_time_s"])s")
    push!(lines, "")

    for (label, key) in [("Slabs", "slabs"), ("Columns", "columns"), ("Beams", "beams"), ("Foundations", "foundations")]
        sec = d[key]
        n = sec["count"]
        n == 0 && continue
        p = sec["passing"]
        f = sec["failing"]
        line = "$label: $n total, $p pass, $f fail"
        n_nc = get(sec, "non_converged", 0)
        if n_nc > 0
            line *= " ($n_nc non-converged — ratios are N/A, not real zeros)"
        end
        if haskey(sec, "worst_deflection")
            wd = sec["worst_deflection"]
            wp = sec["worst_punching"]
            _fmt_ratio(r) = r isa Number && r < 0 ? "N/A" : string(r)
            line *= ". Worst deflection=$(_fmt_ratio(wd["ratio"])) (id=$(wd["id"])), punching=$(_fmt_ratio(wp["ratio"])) (id=$(wp["id"]))"
        end
        if haskey(sec, "worst_interaction")
            wi = sec["worst_interaction"]
            line *= ". Worst interaction=$(wi["ratio"]) (id=$(wi["id"]))"
        end
        if haskey(sec, "worst_flexure")
            wf = sec["worst_flexure"]
            line *= ". Worst flexure=$(wf["ratio"]) (id=$(wf["id"]))"
        end
        if haskey(sec, "worst_bearing")
            wb = sec["worst_bearing"]
            line *= ". Worst bearing=$(wb["ratio"]) (id=$(wb["id"]))"
        end
        if haskey(sec, "sections_used") && !isempty(sec["sections_used"])
            line *= ". Sections: $(join(sec["sections_used"], ", "))"
        end
        if haskey(sec, "thickness_range")
            tr = sec["thickness_range"]
            line *= ". Thickness: $(tr["min"])-$(tr["max"]) $(tr["unit"])"
        end
        push!(lines, line)
    end

    push!(lines, "")
    push!(lines, "Materials: concrete=$(mat["concrete_volume"]["value"]) $(mat["concrete_volume"]["unit"]), " *
                 "steel=$(mat["steel_weight"]["value"]) $(mat["steel_weight"]["unit"]), " *
                 "rebar=$(mat["rebar_weight"]["value"]) $(mat["rebar_weight"]["unit"]), " *
                 "EC=$(mat["embodied_carbon"]["value"]) $(mat["embodied_carbon"]["unit"])")

    by_sys = get(mat, "embodied_carbon_by_system_kgco2e", nothing)
    if by_sys isa AbstractDict
        parts = String[]
        for k in ("slabs", "columns", "beams", "struts", "foundations", "fireproofing")
            v = get(by_sys, k, 0)
            (v isa Number && v > 0) && push!(parts, "$k=$(Int(round(v)))")
        end
        !isempty(parts) && push!(lines, "EC by system (kgCO2e): $(join(parts, ", "))")
    end

    fa = get(d, "floor_area", nothing)
    eci = get(d, "ec_intensity", nothing)
    if !isnothing(fa) && !isnothing(eci)
        push!(lines, "Floor area: $(fa["value"]) $(fa["unit"]) ($(fa["value_m2"]) m2). " *
                     "EC intensity: $(eci["value"]) $(eci["unit"]) ($(eci["value_m2"]) kgCO2e/m2)")
    end

    return join(lines, "\n")
end
