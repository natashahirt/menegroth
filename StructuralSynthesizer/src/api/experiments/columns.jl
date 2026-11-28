# ─── P-M Interaction Experiments ──────────────────────────────────────────────

"""
    experiment_pm_column(design, col_idx; section_size) -> Dict

Test a column against its cached P-M demands with a different section size,
using the real StructuralSizer checkers (ACIColumnChecker for RC,
AISCChecker for steel) via `explain_feasibility`.

For RC columns, `section_size` is the new dimension in inches (square assumed).
For steel columns, `section_size` is the W-shape designation string (e.g. "W14X82").
"""
function experiment_pm_column(
    design::BuildingDesign,
    col_idx::Int;
    section_size::Union{Real, String, Nothing} = nothing,
)::Dict{String, Any}
    col = get(design.columns, col_idx, nothing)
    isnothing(col) && return Dict{String, Any}(
        "error" => "column_not_found",
        "message" => "Column index $col_idx not found.",
    )

    Pu = col.Pu
    Mux = col.Mu_x
    Muy = col.Mu_y
    # Comparison-safe baseline: unverified columns map to a failing `1.0` so the sub-functions'
    # `new_ratio < orig_ratio` logic still detects a verifiable improvement (see
    # `_column_orig_ratio`). The sub-functions re-derive `unverified` from `col` to keep the
    # DISPLAYED original ratio honest (null when unverified).
    orig_ratio, _ = _column_orig_ratio(col)

    mats = design.params.materials
    params = design.params
    is_rc = col.shape in (:rectangular, :circular, :rc_rect, :rc_circular)

    if is_rc
        return _experiment_pm_rc(design, col_idx, col, section_size, params, mats, orig_ratio)
    else
        return _experiment_pm_steel(design, col_idx, col, section_size, params, mats, orig_ratio)
    end
end

function _experiment_pm_rc(
    design::BuildingDesign,
    col_idx::Int,
    col,
    section_size,
    params,
    mats,
    orig_ratio::Float64,
)::Dict{String, Any}
    isnothing(section_size) && return Dict{String, Any}(
        "error" => "section_size_required",
        "message" => "Provide section_size (inches) for RC column experiment.",
    )
    new_dim = _coerce_float(section_size)
    isnothing(new_dim) && return Dict{String, Any}(
        "error" => "invalid_section_size",
        "message" => "section_size must be numeric inches (e.g., 18 or \"18\"). Got: $(repr(section_size))",
    )
    new_dim <= 0 && return Dict{String, Any}(
        "error" => "invalid_section_size",
        "message" => "section_size must be > 0. Got: $new_dim",
    )

    col_concrete = something(col.concrete, column_concrete(params))
    col_rebar = column_rebar(params)

    cover = 1.5u"inch"
    new_b = new_dim * u"inch"

    # Scale rebar count with column size: minimum 4, add 2 per 6" beyond 12"
    n_bars = max(4, 4 + 2 * div(max(0, round(Int, new_dim) - 12), 6))
    # Scale bar size: #6 for ≤14", #8 for ≤22", #10 for ≤30", #11 beyond
    bar_size = new_dim <= 14 ? 6 : new_dim <= 22 ? 8 : new_dim <= 30 ? 10 : 11

    new_section = try
        StructuralSizer.RCColumnSection(
            b = new_b, h = new_b,
            bar_size = bar_size, n_bars = n_bars, cover = cover,
            tie_type = :tied, arrangement = :perimeter,
        )
    catch e
        return Dict{String, Any}(
            "error" => "section_build_failed",
            "message" => "Could not build RC section at $(new_dim)in: $(sprint(showerror, e))",
        )
    end

    col_opts = params.columns
    include_slenderness = col_opts isa StructuralSizer.ConcreteColumnOptions ? col_opts.include_slenderness : true
    include_biaxial = col_opts isa StructuralSizer.ConcreteColumnOptions ? col_opts.include_biaxial : true
    max_depth_val = col_opts isa StructuralSizer.ConcreteColumnOptions ? col_opts.max_depth : Inf * u"mm"
    objective = col_opts isa StructuralSizer.ConcreteColumnOptions ? col_opts.objective : StructuralSizer.MinWeight()

    struc = design.structure
    col_member = (!isnothing(struc) && col_idx >= 1 && col_idx <= length(struc.columns)) ?
        struc.columns[col_idx] : nothing
    L = !isnothing(col_member) ? member_length(col_member) : 10.0u"ft"
    Ky = !isnothing(col_member) ? col_member.base.Ky : 1.0
    geom = StructuralSizer.ConcreteMemberGeometry(L; Lu=L, k=Ky)

    fy_ksi_val = ustrip(StructuralSizer.Asap.ksi, col_rebar.Fy)
    Es_ksi_val = ustrip(StructuralSizer.Asap.ksi, col_rebar.E)
    checker = StructuralSizer.ACIColumnChecker(;
        include_slenderness = include_slenderness,
        include_biaxial = include_biaxial,
        fy_ksi = fy_ksi_val,
        Es_ksi = Es_ksi_val,
        max_depth = max_depth_val,
    )

    # RCColumnDemand takes bare Float64 in kip / kip·ft.
    Pu_kip = StructuralSizer.to_kip(col.Pu)
    Mux_kipft = StructuralSizer.to_kipft(col.Mu_x)
    Muy_kipft = StructuralSizer.to_kipft(col.Mu_y)
    dem = StructuralSizer.RCColumnDemand(1; Pu=Pu_kip, Mux=Mux_kipft, Muy=Muy_kipft)

    cat = [new_section]
    cache = StructuralSizer.create_cache(checker, 1)
    StructuralSizer.precompute_capacities!(checker, cache, cat, col_concrete, objective)
    expl = StructuralSizer.explain_feasibility(checker, cache, 1, new_section, col_concrete, dem, geom)

    new_ratio = expl.governing_ratio
    dim_str = new_dim == round(new_dim) ? "$(Int(new_dim))x$(Int(new_dim))" : "$(round(new_dim; digits=1))x$(round(new_dim; digits=1))"

    setup = _experimental_setup(;
        changed = ["section size: $(col.section_size) → $(dim_str) in", "rebar layout: scaled to $(n_bars)-#$(bar_size)"],
        held_constant = ["Pu = $(round(Pu_kip; digits=1)) kip", "Mux = $(round(Mux_kipft; digits=1)) kip·ft",
                         "Muy = $(round(Muy_kipft; digits=1)) kip·ft", "height = $(round(ustrip(u"ft", L); digits=1)) ft",
                         "Ky = $(round(Ky; digits=2))", "f'c, rebar grade, cover, slenderness parameters"],
        source = "Cached design — column $col_idx",
        note = "Rebar count/size scaled heuristically to section dimension. Actual optimizer may choose differently.",
    )

    # `orig_ratio` is a comparison-safe baseline (unverified → `1.0`); keep the DISPLAYED
    # original ratio null when unverified so a fabricated baseline is never read as real.
    orig_unverified = isnan(col.axial_ratio) || isnan(col.interaction_ratio)
    _orig_label = orig_unverified ? "unverified" : string(round(orig_ratio; digits=3))
    _dir = new_ratio < orig_ratio ? "decreased" : (new_ratio == orig_ratio ? "unchanged" : "increased")
    _ok  = expl.passed ? "PASS" : "FAIL"

    return Dict{String, Any}(
        "experiment" => "pm_column",
        "result_summary" => "Ratio $_dir from $_orig_label to " *
            "$(isfinite(new_ratio) ? string(round(new_ratio; digits=3)) : "∞ (capacity zero)") ($_ok). " *
            "Delta = $(isfinite(new_ratio) ? string(round(new_ratio - orig_ratio; digits=3)) : "N/A").",
        "experimental_setup" => setup,
        "column_idx" => col_idx,
        "column_type" => "RC",
        "demands" => Dict{String, Any}(
            "Pu_kip" => round(Pu_kip; digits=1),
            "Mux_kipft" => round(Mux_kipft; digits=1),
            "Muy_kipft" => round(Muy_kipft; digits=1),
            "height_ft" => round(ustrip(u"ft", L); digits=1),
            "Ky" => round(Ky; digits=2),
        ),
        "original" => Dict{String, Any}(
            "section" => col.section_size,
            "ratio" => orig_unverified ? nothing : _json_safe(round(orig_ratio; digits=3)),
            "unverified" => orig_unverified,
            "ok" => col.ok,
            "governing_check" => column_diagnostic_governing_check(col),
        ),
        "modified" => Dict{String, Any}(
            "section" => dim_str,
            "rebar" => "$(n_bars)-#$(bar_size)",
            "interaction_ratio" => _json_safe(round(new_ratio; digits=3)),
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
        "cross_check_caveat" =>
            "SCOPE: P-M interaction only. Punching shear (b₀ depends on column dimensions) " *
            "and foundation sizing are NOT re-checked. Use the punching experiment to test " *
            "the same section against punching demands, or run_design for all checks together.",
    )
end

function _experiment_pm_steel(
    design::BuildingDesign,
    col_idx::Int,
    col,
    section_size,
    params,
    mats,
    orig_ratio::Float64,
)::Dict{String, Any}
    isnothing(section_size) && return Dict{String, Any}(
        "error" => "section_size_required",
        "message" => "Provide section_size (W-shape designation, e.g. \"W14X82\") for steel column experiment.",
    )
    size_str = strip(string(section_size))
    isempty(size_str) && return Dict{String, Any}(
        "error" => "invalid_section_size",
        "message" => "section_size must be a non-empty W-shape designation string.",
    )

    new_section = try
        StructuralSizer.W(uppercase(size_str))
    catch e
        return Dict{String, Any}(
            "error" => "section_not_found",
            "message" => "W-shape \"$size_str\" not found in catalog: $(sprint(showerror, e))",
        )
    end

    col_opts = params.columns
    mat = if col_opts isa StructuralSizer.SteelColumnOptions
        col_opts.material
    else
        resolve_beam_steel(mats)
    end
    max_depth_val = col_opts isa StructuralSizer.SteelColumnOptions ? col_opts.max_depth : Inf * u"mm"
    objective = col_opts isa StructuralSizer.SteelColumnOptions ? col_opts.objective : StructuralSizer.MinWeight()

    struc = design.structure
    col_member = (!isnothing(struc) && col_idx >= 1 && col_idx <= length(struc.columns)) ?
        struc.columns[col_idx] : nothing

    L = !isnothing(col_member) ? member_length(col_member) : 10.0u"ft"
    Kx = !isnothing(col_member) ? col_member.base.Kx : 1.0
    Ky = !isnothing(col_member) ? col_member.base.Ky : 1.0
    Cb = !isnothing(col_member) ? col_member.base.Cb : 1.0
    geom = StructuralSizer.SteelMemberGeometry(L; Lb=L, Cb=Cb, Kx=Kx, Ky=Ky)

    # MemberDemand takes bare Float64 in SI (N, N·m).
    Pu_N = StructuralSizer.to_newtons(col.Pu)
    Mux_Nm = StructuralSizer.to_newton_meters(col.Mu_x)
    Muy_Nm = StructuralSizer.to_newton_meters(col.Mu_y)
    dem = StructuralSizer.MemberDemand(1; Pu_c=Pu_N, Mux=Mux_Nm, Muy=Muy_Nm)

    checker = StructuralSizer.AISCChecker(; max_depth=max_depth_val)
    cat = [new_section]
    cache = StructuralSizer.create_cache(checker, 1)
    StructuralSizer.precompute_capacities!(checker, cache, cat, mat, objective)
    expl = StructuralSizer.explain_feasibility(checker, cache, 1, new_section, mat, dem, geom)

    new_ratio = expl.governing_ratio

    # Extract section weight from name (e.g. "W14X82" → 82.0 plf)
    new_weight = try
        m = match(r"X(\d+\.?\d*)", uppercase(size_str))
        isnothing(m) ? nothing : parse(Float64, m.captures[1])
    catch; nothing end

    Pu_kip_val = round(ustrip(u"kip", col.Pu); digits=1)
    Mux_kipft_val = round(ustrip(u"kip*ft", col.Mu_x); digits=1)
    Muy_kipft_val = round(ustrip(u"kip*ft", col.Mu_y); digits=1)

    setup = _experimental_setup(;
        changed = ["section: $(col.section_size) → $(size_str)"],
        held_constant = ["Pu = $(Pu_kip_val) kip", "Mux = $(Mux_kipft_val) kip·ft",
                         "Muy = $(Muy_kipft_val) kip·ft", "height = $(round(ustrip(u"ft", L); digits=1)) ft",
                         "Kx = $(round(Kx; digits=2))", "Ky = $(round(Ky; digits=2))",
                         "Cb = $(round(Cb; digits=2))", "steel grade"],
        source = "Cached design — column $col_idx",
    )

    # `orig_ratio` is a comparison-safe baseline (unverified → `1.0`); keep the DISPLAYED
    # original ratio null when unverified so a fabricated baseline is never read as real.
    orig_unverified = isnan(col.axial_ratio) || isnan(col.interaction_ratio)
    _orig_label = orig_unverified ? "unverified" : string(round(orig_ratio; digits=3))
    _dir_s = new_ratio < orig_ratio ? "decreased" : (new_ratio == orig_ratio ? "unchanged" : "increased")
    _ok_s  = expl.passed ? "PASS" : "FAIL"

    result = Dict{String, Any}(
        "experiment" => "pm_column",
        "result_summary" => "Ratio $_dir_s from $_orig_label to " *
            "$(isfinite(new_ratio) ? string(round(new_ratio; digits=3)) : "∞ (capacity zero)") ($_ok_s). " *
            "Delta = $(isfinite(new_ratio) ? string(round(new_ratio - orig_ratio; digits=3)) : "N/A").",
        "experimental_setup" => setup,
        "column_idx" => col_idx,
        "column_type" => "steel",
        "demands" => Dict{String, Any}(
            "Pu_kip" => Pu_kip_val,
            "Mux_kipft" => Mux_kipft_val,
            "Muy_kipft" => Muy_kipft_val,
            "height_ft" => round(ustrip(u"ft", L); digits=1),
            "Kx" => round(Kx; digits=2),
            "Ky" => round(Ky; digits=2),
        ),
        "original" => Dict{String, Any}(
            "section" => col.section_size,
            "ratio" => orig_unverified ? nothing : _json_safe(round(orig_ratio; digits=3)),
            "unverified" => orig_unverified,
            "ok" => col.ok,
            "governing_check" => column_diagnostic_governing_check(col),
        ),
        "modified" => Dict{String, Any}(
            "section" => size_str,
            "weight_plf" => new_weight,
            "interaction_ratio" => _json_safe(round(new_ratio; digits=3)),
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

    # Sanity check: heavier section should generally reduce ratio
    if !isnothing(new_weight)
        orig_weight = try
            m = match(r"X(\d+\.?\d*)", uppercase(col.section_size))
            isnothing(m) ? nothing : parse(Float64, m.captures[1])
        catch; nothing end
        if !isnothing(orig_weight) && new_weight > orig_weight && new_ratio > orig_ratio
            result["sanity_warning"] = "Heavier section $(size_str) ($(new_weight) plf) has worse ratio than $(col.section_size) ($(orig_weight) plf). See the governing_check field for which limit state controls."
        end
    end

    result["cross_check_caveat"] =
        "SCOPE: P-M interaction only. Punching shear (b₀ depends on section dimensions) " *
        "and foundation sizing are NOT re-checked. Run run_design for all checks together."

    return result
end

