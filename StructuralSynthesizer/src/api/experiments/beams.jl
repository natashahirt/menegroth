# ─── Beam Experiments ─────────────────────────────────────────────────────────

"""
    experiment_beam(design, beam_idx; section_size) -> Dict

Steel W-shapes only: test cached demands against a different AISC W section via
`explain_feasibility`. Returns original vs modified ratios and per-check results.
Non-steel beams respond with `beam_not_steel_w`.
"""
function experiment_beam(
    design::BuildingDesign,
    beam_idx::Int;
    section_size::Union{String, Nothing} = nothing,
)::Dict{String, Any}
    beam = get(design.beams, beam_idx, nothing)
    isnothing(beam) && return Dict{String, Any}(
        "error" => "beam_not_found",
        "message" => "Beam index $beam_idx not found. Available: $(sort(collect(keys(design.beams))))",
    )

    isnothing(section_size) && return Dict{String, Any}(
        "error" => "section_size_required",
        "message" => "Provide section_size (W-shape designation, e.g. \"W16X40\") for beam experiment.",
    )
    size_str = strip(string(section_size))
    isempty(size_str) && return Dict{String, Any}(
        "error" => "invalid_section_size",
        "message" => "section_size must be a non-empty W-shape designation string.",
    )

    sec0 = beam.section_obj
    if isnothing(sec0) || !(sec0 isa StructuralSizer.ISymmSection)
        return Dict{String, Any}(
            "error" => "beam_not_steel_w",
            "message" => "Beam experiment supports AISC W-shapes (rolled steel) only. " *
                (isnothing(sec0) ? "This beam has no section assigned in the cached design." :
                 "Got section type $(nameof(typeof(sec0))) — use run_design for RC or other systems."),
        )
    end

    new_section = try
        StructuralSizer.W(uppercase(size_str))
    catch e
        return Dict{String, Any}(
            "error" => "section_not_found",
            "message" => "W-shape \"$size_str\" not found in catalog: $(sprint(showerror, e))",
        )
    end

    mats = design.params.materials
    params = design.params
    beam_opts = params.beams
    mat = if beam_opts isa StructuralSizer.SteelBeamOptions
        beam_opts.material
    else
        resolve_beam_steel(mats)
    end
    max_depth_val = beam_opts isa StructuralSizer.SteelBeamOptions ? beam_opts.max_depth : Inf * u"mm"
    objective = beam_opts isa StructuralSizer.SteelBeamOptions ? beam_opts.objective : StructuralSizer.MinWeight()

    struc = design.structure
    beam_member = (!isnothing(struc) && beam_idx >= 1 && beam_idx <= length(struc.beams)) ?
        struc.beams[beam_idx] : nothing

    L  = !isnothing(beam_member) ? member_length(beam_member) : 20.0u"ft"
    Lb = !isnothing(beam_member) ? beam_member.base.Lb : L
    Kx = !isnothing(beam_member) ? beam_member.base.Kx : 1.0
    Ky = !isnothing(beam_member) ? beam_member.base.Ky : 1.0
    Cb = !isnothing(beam_member) ? beam_member.base.Cb : 1.0
    geom = StructuralSizer.SteelMemberGeometry(L; Lb=Lb, Cb=Cb, Kx=Kx, Ky=Ky)

    Mux_Nm = StructuralSizer.to_newton_meters(beam.Mu)
    Vu_N   = StructuralSizer.to_newtons(beam.Vu)
    dem = StructuralSizer.MemberDemand(1; Mux=Mux_Nm, Vu_strong=Vu_N)

    checker = StructuralSizer.AISCChecker(; max_depth=max_depth_val)
    cat = [new_section]
    cache = StructuralSizer.create_cache(checker, 1)
    StructuralSizer.precompute_capacities!(checker, cache, cat, mat, objective)
    expl = StructuralSizer.explain_feasibility(checker, cache, 1, new_section, mat, dem, geom)

    new_ratio = expl.governing_ratio
    orig_ratio = max(beam.flexure_ratio, beam.shear_ratio)

    new_weight = try
        m = match(r"X(\d+\.?\d*)", uppercase(size_str))
        isnothing(m) ? nothing : parse(Float64, m.captures[1])
    catch; nothing end

    Mu_kipft_val = round(ustrip(u"kip*ft", beam.Mu); digits=1)
    Vu_kip_val = round(ustrip(u"kip", beam.Vu); digits=1)

    setup = _experimental_setup(;
        changed = ["section: $(beam.section_size) → $(size_str)"],
        held_constant = ["Mu = $(Mu_kipft_val) kip·ft", "Vu = $(Vu_kip_val) kip",
                         "span = $(round(ustrip(u"ft", L); digits=1)) ft",
                         "Lb = $(round(ustrip(u"ft", Lb); digits=1)) ft",
                         "Cb = $(round(Cb; digits=2))", "steel grade, loading"],
        source = "Cached design — beam $beam_idx",
    )

    _dir_b = new_ratio < orig_ratio ? "decreased" : (new_ratio == orig_ratio ? "unchanged" : "increased")
    _ok_b  = expl.passed ? "PASS" : "FAIL"

    result = Dict{String, Any}(
        "experiment" => "beam",
        "result_summary" => "Ratio $_dir_b from $(round(orig_ratio; digits=3)) to " *
            "$(isfinite(new_ratio) ? string(round(new_ratio; digits=3)) : "∞ (capacity zero)") ($_ok_b). " *
            "Delta = $(isfinite(new_ratio) ? string(round(new_ratio - orig_ratio; digits=3)) : "N/A").",
        "experimental_setup" => setup,
        "beam_idx" => beam_idx,
        "demands" => Dict{String, Any}(
            "Mu_kipft" => Mu_kipft_val,
            "Vu_kip" => Vu_kip_val,
            "length_ft" => round(ustrip(u"ft", L); digits=1),
            "Lb_ft" => round(ustrip(u"ft", Lb); digits=1),
            "Cb" => round(Cb; digits=2),
        ),
        "original" => Dict{String, Any}(
            "section" => beam.section_size,
            "flexure_ratio" => _json_safe(round(beam.flexure_ratio; digits=3)),
            "shear_ratio" => _json_safe(round(beam.shear_ratio; digits=3)),
            "governing_ratio" => _json_safe(round(orig_ratio; digits=3)),
            "ok" => beam.ok,
            "governing_check" => beam_diagnostic_governing_check(beam),
        ),
        "modified" => Dict{String, Any}(
            "section" => size_str,
            "weight_plf" => new_weight,
            "governing_ratio" => _json_safe(round(new_ratio; digits=3)),
            "governing_check" => expl.governing_check,
            "ok" => expl.passed,
            "checks" => [Dict(
                "name" => c.name,
                "passed" => c.passed,
                "ratio" => _json_safe(round(c.ratio; digits=3)),
            ) for c in expl.checks],
        ),
        "delta_ratio" => _json_safe(round(new_ratio - orig_ratio; digits=3)),
        "improved" => isfinite(new_ratio) && new_ratio < orig_ratio,
    )

    if !isnothing(new_weight)
        orig_weight = try
            m = match(r"X(\d+\.?\d*)", uppercase(beam.section_size))
            isnothing(m) ? nothing : parse(Float64, m.captures[1])
        catch; nothing end
        if !isnothing(orig_weight) && new_weight > orig_weight && new_ratio > orig_ratio
            result["sanity_warning"] = "Heavier section $(size_str) ($(new_weight) plf) " *
                "has worse ratio than $(beam.section_size) ($(orig_weight) plf). " *
                "See governing_check for which limit state controls."
        end
    end

    result["cross_check_caveat"] =
        "SCOPE: Beam flexure/shear only. Slab tributary loads, deflections, floor-to-floor " *
        "height, and connection demands are NOT re-checked. Run run_design for all checks together."

    return result
end

