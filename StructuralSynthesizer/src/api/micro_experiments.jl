# =============================================================================
# Micro-Experiments — Lightweight what-if checks using cached design data
#
# These functions re-run individual structural checks with modified parameters
# WITHOUT requiring a full design_building pass. They extract demands and
# geometry from a completed BuildingDesign and call StructuralSizer checker
# APIs directly.
#
# Experiment types:
#   - punching:    vary column size or slab thickness for a punching check
#   - pm_column:   try alternative column sections against cached P-M demands
#   - deflection:  test different deflection limits against stored slab data
#   - catalog:     screen a section catalog against a single demand envelope
# =============================================================================

using Unitful

# ─── Argument Coercion Helpers ────────────────────────────────────────────────

"""
    _coerce_float(x) -> Union{Float64, Nothing}

Convert JSON/tool argument `x` to `Float64` when possible. Returns `nothing` for
missing or invalid values.
"""
function _coerce_float(x)::Union{Float64, Nothing}
    isnothing(x) && return nothing
    x isa Real && return Float64(x)
    if x isa AbstractString
        s = strip(x)
        isempty(s) && return nothing
        v = tryparse(Float64, replace(s, "," => ""))
        return v
    end
    return nothing
end

"""
    _coerce_int(x) -> Union{Int, Nothing}

Convert JSON/tool argument `x` to `Int` when possible. Returns `nothing` for
missing or invalid values.
"""
function _coerce_int(x)::Union{Int, Nothing}
    isnothing(x) && return nothing
    if x isa Integer
        return Int(x)
    elseif x isa Real
        return isinteger(x) ? Int(x) : nothing
    elseif x isa AbstractString
        s = strip(x)
        isempty(s) && return nothing
        return tryparse(Int, s)
    end
    return nothing
end

# ─── Helpers: resolve column position from BuildingStructure ──────────────────

"""
    _resolve_column_position(design, col_idx) -> Symbol

Look up the column's position (:interior, :edge, :corner) from the
BuildingStructure stored on the design. Falls back to :interior when the
structure is unavailable.
"""
function _resolve_column_position(design::BuildingDesign, col_idx::Int)::Symbol
    struc = design.structure
    isnothing(struc) && return :interior
    (col_idx < 1 || col_idx > length(struc.columns)) && return :interior
    return struc.columns[col_idx].position
end

"""
    _resolve_column_shape(design, col_idx) -> Symbol

Look up the column's cross-section shape from the BuildingStructure.
Falls back to the ColumnDesignResult.shape if the structure is unavailable.
"""
function _resolve_column_shape(design::BuildingDesign, col_idx::Int)::Symbol
    struc = design.structure
    if !isnothing(struc) && col_idx >= 1 && col_idx <= length(struc.columns)
        return struc.columns[col_idx].shape
    end
    col_result = get(design.columns, col_idx, nothing)
    isnothing(col_result) && return :rectangular
    return col_result.shape
end

# ─── Punching Experiments ─────────────────────────────────────────────────────

"""
    experiment_punching(design, col_idx; c1_in, c2_in, h_in) -> Dict

Re-run the ACI punching shear check for column `col_idx` with modified column
dimensions or slab thickness. Uses the actual `check_punching_for_column`
from StructuralSizer, respecting column position (interior/edge/corner) and
stored unbalanced moment.
"""
function experiment_punching(
    design::BuildingDesign,
    col_idx::Int;
    c1_in::Union{Float64, Nothing} = nothing,
    c2_in::Union{Float64, Nothing} = nothing,
    h_in::Union{Float64, Nothing} = nothing,
)::Dict{String, Any}
    col_result = get(design.columns, col_idx, nothing)
    isnothing(col_result) && return Dict{String, Any}(
        "error" => "column_not_found",
        "message" => "Column index $col_idx not found. Available: $(sort(collect(keys(design.columns))))",
    )

    punching = col_result.punching
    isnothing(punching) && return Dict{String, Any}(
        "error" => "no_punching_data",
        "message" => "Column $col_idx has no punching shear data (may not be a flat plate column).",
    )

    orig_c1 = col_result.c1
    orig_c2 = col_result.c2
    orig_Vu = punching.Vu

    new_c1 = isnothing(c1_in) ? orig_c1 : c1_in * u"inch"
    new_c2 = isnothing(c2_in) ? orig_c2 : c2_in * u"inch"

    slab_concrete = resolve_slab_concrete(design.params.materials)
    fc = slab_concrete.fc′
    cover = 0.75u"inch"
    bar_d = 0.5u"inch"

    orig_h = nothing
    for (_, slab) in design.slabs
        if !isnothing(slab.thickness)
            orig_h = slab.thickness
            break
        end
    end

    isnothing(orig_h) && return Dict{String, Any}(
        "error" => "no_slab_thickness",
        "message" => "Cannot determine slab thickness from design.",
    )

    new_h = isnothing(h_in) ? orig_h : h_in * u"inch"
    d = new_h - cover - bar_d

    position = _resolve_column_position(design, col_idx)
    shape = _resolve_column_shape(design, col_idx)

    # Use stored unbalanced moment when available; fall back to Mu_x from frame analysis.
    Mub = if hasproperty(punching, :Mub) && !isnothing(punching.Mub)
        punching.Mub
    else
        abs(col_result.Mu_x)
    end

    # Build a duck-typed column object for check_punching_for_column.
    col_proxy = (c1 = new_c1, c2 = new_c2, position = position, shape = shape)

    result = StructuralSizer.check_punching_for_column(
        col_proxy, orig_Vu, Mub, d, new_h, fc;
        col_idx = col_idx,
    )

    orig_ratio = punching.ratio

    new_ratio = result.ratio
    delta = new_ratio - orig_ratio
    improved = new_ratio < orig_ratio

    # Sanity check: larger columns and thicker slabs should improve punching.
    # If the result contradicts this, flag it for the LLM.
    sanity_warning = nothing
    col_grew = ustrip(u"inch", new_c1) >= ustrip(u"inch", orig_c1) &&
               ustrip(u"inch", new_c2) >= ustrip(u"inch", orig_c2)
    slab_grew = ustrip(u"inch", new_h) >= ustrip(u"inch", orig_h)
    if col_grew && slab_grew && !improved && abs(delta) > 0.05
        sanity_warning = "WARNING: Increasing column size and/or slab thickness " *
            "worsened punching ratio. This is structurally unexpected. " *
            "Possible causes: (1) geometry mismatch between experiment and server cache, " *
            "(2) unbalanced moment Mub dominates over direct shear, " *
            "(3) edge/corner eccentricity correction. Verify with a full run_design."
    end

    out = Dict{String, Any}(
        "experiment" => "punching",
        "column_idx" => col_idx,
        "position" => string(position),
        "original" => Dict{String, Any}(
            "c1_in" => round(ustrip(u"inch", orig_c1); digits=1),
            "c2_in" => round(ustrip(u"inch", orig_c2); digits=1),
            "h_in" => round(ustrip(u"inch", orig_h); digits=1),
            "ratio" => round(orig_ratio; digits=3),
            "ok" => punching.ok,
            "Vu_kip" => round(ustrip(u"kip", orig_Vu); digits=2),
            "Mub_kipft" => round(ustrip(u"kip*ft", Mub); digits=2),
        ),
        "modified" => Dict{String, Any}(
            "c1_in" => round(ustrip(u"inch", new_c1); digits=1),
            "c2_in" => round(ustrip(u"inch", new_c2); digits=1),
            "h_in" => round(ustrip(u"inch", new_h); digits=1),
            "ratio" => round(new_ratio; digits=3),
            "ok" => result.ok,
            "vu_psi" => round(ustrip(u"psi", result.vu); digits=1),
            "φvc_psi" => round(ustrip(u"psi", result.φvc); digits=1),
            "b0_in" => round(ustrip(u"inch", result.b0); digits=1),
        ),
        "delta_ratio" => round(delta; digits=3),
        "improved" => improved,
    )

    !isnothing(sanity_warning) && (out["sanity_warning"] = sanity_warning)

    return out
end

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
    orig_ratio = max(col.axial_ratio, col.interaction_ratio)

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

    col_concrete = resolve_column_concrete(mats)
    col_rebar = resolve_column_rebar(mats)

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

    return Dict{String, Any}(
        "experiment" => "pm_column",
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
            "ratio" => round(orig_ratio; digits=3),
            "ok" => col.ok,
            "governing_check" => column_diagnostic_governing_check(col),
        ),
        "modified" => Dict{String, Any}(
            "section" => dim_str,
            "rebar" => "$(n_bars)-#$(bar_size)",
            "interaction_ratio" => round(new_ratio; digits=3),
            "governing_check" => expl.governing_check,
            "ok" => expl.passed,
            "checks" => [Dict(
                "name" => c.name,
                "passed" => c.passed,
                "ratio" => round(c.ratio; digits=3),
            ) for c in expl.checks],
        ),
        "delta_ratio" => round(new_ratio - orig_ratio; digits=3),
        "improved" => new_ratio < orig_ratio,
        "note" => "RC experiment uses $(n_bars)-#$(bar_size) bars (scaled to section size). Actual design may optimize rebar layout differently.",
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

    result = Dict{String, Any}(
        "experiment" => "pm_column",
        "column_idx" => col_idx,
        "column_type" => "steel",
        "demands" => Dict{String, Any}(
            "Pu_kip" => round(ustrip(u"kip", col.Pu); digits=1),
            "Mux_kipft" => round(ustrip(u"kip*ft", col.Mu_x); digits=1),
            "Muy_kipft" => round(ustrip(u"kip*ft", col.Mu_y); digits=1),
            "height_ft" => round(ustrip(u"ft", L); digits=1),
            "Kx" => round(Kx; digits=2),
            "Ky" => round(Ky; digits=2),
        ),
        "original" => Dict{String, Any}(
            "section" => col.section_size,
            "ratio" => round(orig_ratio; digits=3),
            "ok" => col.ok,
            "governing_check" => column_diagnostic_governing_check(col),
        ),
        "modified" => Dict{String, Any}(
            "section" => size_str,
            "weight_plf" => new_weight,
            "interaction_ratio" => round(new_ratio; digits=3),
            "governing_check" => expl.governing_check,
            "ok" => expl.passed,
            "checks" => [Dict(
                "name" => c.name,
                "passed" => c.passed,
                "ratio" => round(c.ratio; digits=3),
            ) for c in expl.checks],
        ),
        "delta_ratio" => round(new_ratio - orig_ratio; digits=3),
        "improved" => new_ratio < orig_ratio,
    )

    # Sanity check: heavier section should generally reduce ratio
    if !isnothing(new_weight)
        orig_weight = try
            m = match(r"X(\d+\.?\d*)", uppercase(col.section_size))
            isnothing(m) ? nothing : parse(Float64, m.captures[1])
        catch; nothing end
        if !isnothing(orig_weight) && new_weight > orig_weight && new_ratio > orig_ratio
            result["sanity_warning"] = "Heavier section $(size_str) ($(new_weight) plf) has worse ratio than $(col.section_size) ($(orig_weight) plf). This may indicate a slenderness or local buckling issue — check the governing_check field."
        end
    end

    return result
end

# ─── Deflection Experiments ───────────────────────────────────────────────────

"""
    experiment_deflection(design, slab_idx; deflection_limit) -> Dict

Test what happens to a slab's deflection check under a different limit
(L/240, L/360, L/480). Uses the stored deflection values from the design.
"""
function experiment_deflection(
    design::BuildingDesign,
    slab_idx::Int;
    deflection_limit::String = "L_360",
)::Dict{String, Any}
    slab = get(design.slabs, slab_idx, nothing)
    isnothing(slab) && return Dict{String, Any}(
        "error" => "slab_not_found",
        "message" => "Slab index $slab_idx not found. Available: $(sort(collect(keys(design.slabs))))",
    )

    orig_deflection = slab.deflection_in
    orig_limit = slab.deflection_limit_in
    orig_ok = slab.deflection_ok
    orig_ratio = slab.deflection_ratio

    if isnothing(orig_deflection) || orig_deflection == 0.0
        return Dict{String, Any}(
            "error" => "no_deflection_data",
            "message" => "Slab $slab_idx has no stored deflection data.",
        )
    end

    # Get span from the structure's Slab object if available
    struc = design.structure
    span_in = nothing
    span_ft = nothing
    if !isnothing(struc) && slab_idx >= 1 && slab_idx <= length(struc.slabs)
        slab_obj = struc.slabs[slab_idx]
        gov_span = max(slab_obj.spans.primary, slab_obj.spans.secondary)
        span_in = try ustrip(u"inch", gov_span) catch; nothing end
        span_ft = try ustrip(u"ft", gov_span) catch; nothing end
    end

    # No fallback: deflection limit checks require real span data.
    # Without the structure, we can't reliably back-compute span from stored ratios.

    new_divisor = if deflection_limit == "L_240"
        240.0
    elseif deflection_limit == "L_360"
        360.0
    elseif deflection_limit == "L_480"
        480.0
    else
        return Dict{String, Any}(
            "error" => "invalid_limit",
            "message" => "deflection_limit must be L_240, L_360, or L_480. Got: $deflection_limit",
        )
    end

    if isnothing(span_in)
        return Dict{String, Any}(
            "error" => "no_span_data",
            "message" => "Slab $slab_idx has deflection data but no span information. Run with a design that includes structure data.",
        )
    end

    new_limit = span_in / new_divisor
    new_ratio = orig_deflection / new_limit
    new_ok = new_ratio <= 1.0

    # Determine what the original divisor was
    orig_divisor_approx = if orig_limit > 0
        round(Int, span_in / orig_limit)
    else
        0
    end

    thickness_in = try round(ustrip(u"inch", slab.thickness); digits=2) catch; nothing end

    result = Dict{String, Any}(
        "experiment" => "deflection",
        "slab_idx" => slab_idx,
        "slab_context" => Dict{String, Any}(
            "span_ft" => isnothing(span_ft) ? nothing : round(span_ft; digits=1),
            "thickness_in" => thickness_in,
            "current_limit_criterion" => orig_divisor_approx > 0 ? "L/$(orig_divisor_approx)" : "unknown",
        ),
        "original" => Dict{String, Any}(
            "deflection_in" => round(orig_deflection; digits=3),
            "limit_in" => round(orig_limit; digits=3),
            "ratio" => round(orig_ratio; digits=3),
            "ok" => orig_ok,
        ),
        "modified" => Dict{String, Any}(
            "deflection_limit" => deflection_limit,
            "limit_in" => round(new_limit; digits=3),
            "ratio" => round(new_ratio; digits=3),
            "ok" => new_ok,
        ),
        "delta_ratio" => round(new_ratio - orig_ratio; digits=3),
        "improved" => new_ratio < orig_ratio,
    )

    if !new_ok && orig_ok
        result["warning"] = "Changing to $(deflection_limit) makes this slab FAIL deflection (ratio $(round(new_ratio; digits=2)) > 1.0). A thicker slab or higher-stiffness concrete would be needed."
    elseif new_ok && !orig_ok
        result["note"] = "Relaxing to $(deflection_limit) makes this slab PASS deflection. Current deflection $(round(orig_deflection; digits=3))\" < new limit $(round(new_limit; digits=3))\"."
    else
        result["note"] = "Actual deflection is unchanged at $(round(orig_deflection; digits=3))\". Only the allowable limit changes. To reduce actual deflection, increase slab thickness via run_design."
    end

    return result
end

# ─── Catalog Feasibility Screening ───────────────────────────────────────────

"""
    experiment_catalog_screen(design, col_idx; candidates) -> Dict

Screen a list of candidate sections against the stored demands for a column.
Returns a feasibility assessment for each candidate using the real checkers.

For RC columns, `candidates` is a vector of section dimensions (inches).
For steel columns, `candidates` is a vector of W-shape designation strings.
"""
function experiment_catalog_screen(
    design::BuildingDesign,
    col_idx::Int;
    candidates::Union{Vector{Float64}, Vector} = Float64[],
)::Dict{String, Any}
    col = get(design.columns, col_idx, nothing)
    isnothing(col) && return Dict{String, Any}(
        "error" => "column_not_found",
        "message" => "Column index $col_idx not found.",
    )

    isempty(candidates) && return Dict{String, Any}(
        "error" => "no_candidates",
        "message" => "Provide at least one candidate section size via `candidates`.",
    )

    orig_ratio = max(col.axial_ratio, col.interaction_ratio)
    is_rc = col.shape in (:rectangular, :circular, :rc_rect, :rc_circular)

    results = Dict{String, Any}[]
    for cand in candidates
        r = experiment_pm_column(design, col_idx; section_size=cand)
        if haskey(r, "error")
            push!(results, Dict{String, Any}("section" => string(cand), "error" => r["error"]))
        else
            mod = r["modified"]
            entry = Dict{String, Any}(
                "section" => mod["section"],
                "interaction_ratio" => mod["interaction_ratio"],
                "governing_check" => get(mod, "governing_check", ""),
                "ok" => mod["ok"],
                "improved" => get(r, "improved", false),
            )
            if haskey(mod, "weight_plf") && !isnothing(mod["weight_plf"])
                entry["weight_plf"] = mod["weight_plf"]
            end
            if haskey(mod, "rebar")
                entry["rebar"] = mod["rebar"]
            end
            push!(results, entry)
        end
    end

    sort!(results; by=r -> get(r, "interaction_ratio", Inf))

    feasible = filter(r -> get(r, "ok", false), results)

    # For steel, identify lightest feasible by weight
    lightest_feasible = nothing
    if !isempty(feasible) && !is_rc
        with_weight = filter(r -> haskey(r, "weight_plf"), feasible)
        if !isempty(with_weight)
            lightest_feasible = sort(with_weight; by=r -> r["weight_plf"])[1]["section"]
        end
    end

    return Dict{String, Any}(
        "experiment" => "catalog_screen",
        "column_idx" => col_idx,
        "column_type" => is_rc ? "RC" : "steel",
        "demands" => Dict{String, Any}(
            "Pu_kip" => round(ustrip(u"kip", col.Pu); digits=1),
            "Mux_kipft" => round(ustrip(u"kip*ft", col.Mu_x); digits=1),
            "Muy_kipft" => round(ustrip(u"kip*ft", col.Mu_y); digits=1),
        ),
        "original" => Dict{String, Any}(
            "section" => col.section_size,
            "ratio" => round(orig_ratio; digits=3),
            "ok" => col.ok,
            "governing_check" => column_diagnostic_governing_check(col),
        ),
        "n_candidates" => length(results),
        "n_feasible" => length(feasible),
        "candidates" => results,
        "best_feasible" => isempty(feasible) ? nothing : first(feasible)["section"],
        "lightest_feasible" => lightest_feasible,
        "note" => isempty(feasible) ?
            "No candidate section passes all checks. Consider larger sections or reviewing demands." :
            "$(length(feasible))/$(length(results)) candidates pass. Best ratio: $(first(feasible)["interaction_ratio"]).",
    )
end

# ─── Top-Level Dispatch ──────────────────────────────────────────────────────

"""
    list_experiments() -> Dict

Return metadata about available micro-experiment types.
"""
function list_experiments()::Dict{String, Any}
    Dict{String, Any}(
        "experiments" => [
            Dict{String, Any}(
                "name" => "punching",
                "description" => "Re-check punching shear with modified column size or slab thickness. " *
                    "Respects column position (interior/edge/corner) and unbalanced moment. " *
                    "Returns demand (Vu, Mub), capacity (φVc, b0), and ratio for both original and modified.",
                "args" => Dict(
                    "col_idx" => "required Int — column index from diagnose",
                    "c1_in" => "optional Float64 — new column c1 dimension (inches)",
                    "c2_in" => "optional Float64 — new column c2 dimension (inches)",
                    "h_in" => "optional Float64 — new slab thickness (inches)",
                ),
                "example" => "run_experiment(type=punching, args={col_idx=3, c1_in=20, c2_in=20})",
            ),
            Dict{String, Any}(
                "name" => "pm_column",
                "description" => "Test P-M interaction with a different section using the real checker. " *
                    "RC: scales rebar layout to column size. Steel: uses full AISC checker. " *
                    "Returns demands, original/modified ratios, and all individual check results.",
                "args" => Dict(
                    "col_idx" => "required Int — column index from diagnose",
                    "section_size" => "Float64 (inches, for RC square column) or String (W-shape, e.g. \"W14X82\")",
                ),
                "example" => "run_experiment(type=pm_column, args={col_idx=5, section_size=24})",
            ),
            Dict{String, Any}(
                "name" => "deflection",
                "description" => "Test a slab under a different deflection limit (L/240, L/360, L/480). " *
                    "Does NOT re-compute actual deflection — only changes the allowable limit. " *
                    "Use run_design to test a thicker slab.",
                "args" => Dict(
                    "slab_idx" => "required Int — slab index from diagnose",
                    "deflection_limit" => "L_240 | L_360 | L_480 (default L_360)",
                ),
                "example" => "run_experiment(type=deflection, args={slab_idx=1, deflection_limit=L_480})",
            ),
            Dict{String, Any}(
                "name" => "catalog_screen",
                "description" => "Screen multiple candidate column sizes against stored demands. " *
                    "Sorts by ratio, identifies best and lightest feasible. " *
                    "RC: pass Float64[] (inches). Steel: pass String[] (W-shapes).",
                "args" => Dict(
                    "col_idx" => "required Int — column index from diagnose",
                    "candidates" => "Float64[] for RC or String[] for steel — list of sizes to test",
                ),
                "example" => "run_experiment(type=catalog_screen, args={col_idx=5, candidates=[14,16,18,20,24]})",
            ),
        ],
        "note" => "Micro-experiments are INSTANT (~0.1s) — they use cached design data and real StructuralSizer checkers. " *
            "Use run_design only when you need to test a GLOBAL parameter change across all elements.",
    )
end

"""
    evaluate_experiment(design, experiment_type, args) -> Dict

Dispatch a micro-experiment by name.
"""
function evaluate_experiment(
    design::BuildingDesign,
    experiment_type::String,
    args::Dict{String, Any},
)::Dict{String, Any}
    if experiment_type == "punching"
        col_idx = _coerce_int(get(args, "col_idx", nothing))
        isnothing(col_idx) && return Dict("error" => "missing_col_idx", "message" => "punching experiment requires col_idx")
        c1_in = _coerce_float(get(args, "c1_in", nothing))
        c2_in = _coerce_float(get(args, "c2_in", nothing))
        h_in = _coerce_float(get(args, "h_in", nothing))
        return experiment_punching(design, col_idx;
            c1_in = c1_in,
            c2_in = c2_in,
            h_in = h_in,
        )
    elseif experiment_type == "pm_column"
        col_idx = _coerce_int(get(args, "col_idx", nothing))
        isnothing(col_idx) && return Dict("error" => "missing_col_idx", "message" => "pm_column experiment requires col_idx")
        return experiment_pm_column(design, col_idx;
            section_size = get(args, "section_size", nothing),
        )
    elseif experiment_type == "deflection"
        slab_idx = _coerce_int(get(args, "slab_idx", nothing))
        isnothing(slab_idx) && return Dict("error" => "missing_slab_idx", "message" => "deflection experiment requires slab_idx")
        return experiment_deflection(design, slab_idx;
            deflection_limit = string(get(args, "deflection_limit", "L_360")),
        )
    elseif experiment_type == "catalog_screen"
        col_idx = _coerce_int(get(args, "col_idx", nothing))
        isnothing(col_idx) && return Dict("error" => "missing_col_idx", "message" => "catalog_screen experiment requires col_idx")
        candidates_raw = get(args, "candidates", Any[])
        # Accept both numeric (RC) and string (steel) candidates.
        candidates = Any[]
        for c in candidates_raw
            if c isa AbstractString
                push!(candidates, strip(c))
            else
                v = _coerce_float(c)
                if isnothing(v)
                    return Dict(
                        "error" => "invalid_candidates",
                        "message" => "All candidates must be numeric inches (RC) or W-shape strings (steel). Got invalid value: $(repr(c))",
                    )
                end
                push!(candidates, v)
            end
        end
        return experiment_catalog_screen(design, col_idx; candidates)
    else
        return Dict{String, Any}(
            "error" => "unknown_experiment",
            "message" => "Unknown experiment type: \"$experiment_type\". Use list_experiments to see available types.",
        )
    end
end

"""
    batch_evaluate(design, experiments) -> Dict

Run multiple micro-experiments in one call. `experiments` is an array of
`{type, args}` dicts.
"""
function batch_evaluate(
    design::BuildingDesign,
    experiments::Vector,
)::Dict{String, Any}
    results = Dict{String, Any}[]
    for (i, exp) in enumerate(experiments)
        exp_type_str = (exp isa AbstractDict) ? string(get(exp, "type", "")) : ""
        r = try
            !(exp isa AbstractDict) && error("experiment entry must be an object with type and args")
            exp_args = Dict{String, Any}(string(k) => v for (k, v) in get(exp, "args", Dict()))
            evaluate_experiment(design, exp_type_str, exp_args)
        catch e
            Dict{String, Any}(
                "error"   => "experiment_failed",
                "message" => sprint(showerror, e),
                "type"    => exp_type_str,
            )
        end
        r["experiment_index"] = i
        r["type"] = exp_type_str
        push!(results, r)
    end
    return Dict{String, Any}(
        "n_experiments" => length(results),
        "results" => results,
    )
end
