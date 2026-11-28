# ─── Punching Experiments ─────────────────────────────────────────────────────

"""
    _punching_critical_area(c1, c2, d, position) → Area

Area enclosed by the punching critical section, accounting for column position.
Interior uses full 4-sided perimeter; edge uses 3-sided; corner uses 2-sided.
"""
function _punching_critical_area(c1, c2, d, position::Symbol)
    if position == :interior
        return (c1 + d) * (c2 + d)
    elseif position == :edge
        # 3-sided: slab edge at exterior face, critical section at d/2 past interior face
        # b1 = c1 + d/2 (full column width + d/2 on interior side only)
        return (c1 + d / 2) * (c2 + d)
    else  # :corner
        # 2-sided: two slab edges at exterior faces
        return (c1 + d / 2) * (c2 + d / 2)
    end
end

"""
    _governing_vc_equation(fc, β, αs, b0, d; λ=1.0) → String

Return a label identifying which ACI 318-11 equation governs `vc`:
  "11-31" (aspect ratio), "11-32" (perimeter-to-depth), or "11-33" (upper bound).
"""
function _governing_vc_equation(fc, β::Float64, αs::Int, b0, d; λ::Float64 = 1.0)
    sqrt_fc = sqrt(ustrip(u"psi", fc))
    vc_a = (2 + 4 / β) * λ * sqrt_fc
    vc_b = (αs * ustrip(u"inch", d) / ustrip(u"inch", b0) + 2) * λ * sqrt_fc
    vc_c = 4 * λ * sqrt_fc
    vc_min = min(vc_a, vc_b, vc_c)
    vc_min ≈ vc_a && return "11-31"
    vc_min ≈ vc_b && return "11-32"
    return "11-33"
end

"""
    _resolve_punching_inputs(design, col_idx) → NamedTuple or Dict (error)

Extract and compute all punching-shear inputs from the cached design for a
given column.  Returns either an error Dict (caller should return it) or a
NamedTuple with fields used by both `experiment_punching` and
`experiment_punching_reinforcement`.
"""
function _resolve_punching_inputs(design::BuildingDesign, col_idx::Int)
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

    slab_concrete = resolve_slab_concrete(design.params.materials)
    fc = slab_concrete.fc′
    cover = 0.75u"inch"
    bar_d = 0.5u"inch"

    # First slab with a positive thickness (typical single-slab buildings).
    orig_h = nothing
    for (_, slab) in design.slabs
        if ustrip(u"m", slab.thickness) > 0
            orig_h = slab.thickness
            break
        end
    end

    isnothing(orig_h) && return Dict{String, Any}(
        "error" => "no_slab_thickness",
        "message" => "Cannot determine slab thickness from design.",
    )

    d_orig = orig_h - cover - bar_d
    if ustrip(u"inch", d_orig) <= 0
        return Dict{String, Any}(
            "error" => "invalid_slab_thickness",
            "message" => "Effective depth d = h − cover − bar_d is non-positive " *
                "(h ≈ $(round(ustrip(u"inch", orig_h); digits=2)) in). Slab may not be designed yet.",
        )
    end
    position = _resolve_column_position(design, col_idx)
    shape = _resolve_column_shape(design, col_idx)

    Mub = punching.Mub

    return (
        col_result = col_result,
        punching   = punching,
        orig_c1    = orig_c1,
        orig_c2    = orig_c2,
        orig_Vu    = orig_Vu,
        fc         = fc,
        orig_h     = orig_h,
        d_orig     = d_orig,
        position   = position,
        shape      = shape,
        Mub        = Mub,
        At         = punching.tributary_area,
        cover      = cover,
        bar_d      = bar_d,
    )
end

"""
    experiment_punching(design, col_idx; c1_in, c2_in, h_in, fc_in) -> Dict

Re-run the ACI punching shear check for column `col_idx` with modified column
dimensions, slab thickness, or concrete strength. Uses `check_punching_for_column`
from StructuralSizer, respecting column position (interior/edge/corner) and
stored unbalanced moment.

When column size or slab thickness changes, `Vu` is adjusted to account for
the change in the area enclosed by the critical perimeter (ACI §11.11.1.2):
the factored load per unit area `qu` is held constant while the net tributary
area outside the critical section is updated.
"""
function experiment_punching(
    design::BuildingDesign,
    col_idx::Int;
    c1_in::Union{Float64, Nothing} = nothing,
    c2_in::Union{Float64, Nothing} = nothing,
    h_in::Union{Float64, Nothing} = nothing,
    fc_in::Union{Float64, Nothing} = nothing,
)::Dict{String, Any}
    inp = _resolve_punching_inputs(design, col_idx)
    inp isa Dict && return inp  # error dict

    new_c1 = isnothing(c1_in) ? inp.orig_c1 : c1_in * u"inch"
    new_c2 = isnothing(c2_in) ? inp.orig_c2 : c2_in * u"inch"
    new_h  = isnothing(h_in)  ? inp.orig_h  : h_in * u"inch"
    d = new_h - inp.cover - inp.bar_d
    if ustrip(u"inch", d) <= 0
        return Dict{String, Any}(
            "error" => "invalid_slab_thickness",
            "message" => "Effective depth d = h − cover − bar_d must be positive. " *
                "Got h ≈ $(round(ustrip(u"inch", new_h); digits=2)) in.",
        )
    end

    # Concrete strength override: build a new Concrete with ACI Ec = 57000√f'c (ACI 318-11 §8.5.1)
    orig_fc = inp.fc
    fc = if !isnothing(fc_in)
        fc_in ≤ 0 && return Dict{String, Any}(
            "error" => "invalid_fc_in",
            "message" => "fc_in must be positive (psi). Got: $fc_in",
        )
        fc_new = fc_in * u"psi"
        Ec_new = 57000 * sqrt(fc_in) * u"psi"
        StructuralSizer.Concrete(Ec_new, fc_new, 2380.0u"kg/m^3", 0.20, 0.138).fc′
    else
        orig_fc
    end

    # ── Adjust Vu for the change in critical-section enclosed area ──
    Ac_orig = _punching_critical_area(inp.orig_c1, inp.orig_c2, inp.d_orig, inp.position)
    Ac_new  = _punching_critical_area(new_c1,  new_c2,  d, inp.position)
    net_orig = inp.At - Ac_orig
    Vu_adjusted = if ustrip(u"m^2", net_orig) > 0
        qu = inp.orig_Vu / net_orig
        net_new = inp.At - Ac_new
        max(qu * net_new, 0.0u"kN")
    else
        inp.orig_Vu
    end

    col_proxy = (c1 = new_c1, c2 = new_c2, position = inp.position, shape = inp.shape)

    result = StructuralSizer.check_punching_for_column(
        col_proxy, Vu_adjusted, inp.Mub, d, new_h, fc;
        col_idx = col_idx,
    )

    orig_ratio = inp.punching.ratio
    new_ratio = result.ratio
    delta = new_ratio - orig_ratio
    improved = new_ratio < orig_ratio

    # ── Stress decomposition for diagnostic clarity ──
    b0 = result.b0
    vu_direct   = Vu_adjusted / (b0 * d)
    vu_eccentric = result.vu - vu_direct

    c1_eff = new_c1
    c2_eff = new_c2
    if inp.shape == :circular && inp.position != :interior
        side = StructuralSizer.equivalent_square_column(new_c1)
        c1_eff = side
        c2_eff = side
    end
    β = inp.shape == :circular && inp.position == :interior ? 1.0 :
        max(ustrip(u"inch", c1_eff), ustrip(u"inch", c2_eff)) /
        max(min(ustrip(u"inch", c1_eff), ustrip(u"inch", c2_eff)), 1.0)
    αs = StructuralSizer.punching_αs(inp.position)
    governing_eq = _governing_vc_equation(fc, β, αs, b0, d)

    # ── Sanity warning (now rare with Vu adjustment) ──
    sanity_warning = nothing
    col_grew = ustrip(u"inch", new_c1) >= ustrip(u"inch", inp.orig_c1) &&
               ustrip(u"inch", new_c2) >= ustrip(u"inch", inp.orig_c2)
    slab_grew = ustrip(u"inch", new_h) >= ustrip(u"inch", inp.orig_h)
    if col_grew && slab_grew && !improved && abs(delta) > 0.05
        sanity_warning = "NOTE: Ratio increased despite larger column/slab. " *
            "Eccentric stress = $(round(ustrip(u"psi", vu_eccentric); digits=1)) psi, " *
            "direct stress = $(round(ustrip(u"psi", vu_direct); digits=1)) psi. " *
            "Run run_design for the full system check."
    end

    # ── f'c coupling caveat: column size held constant in this experiment ──
    fc_only_change = !isnothing(fc_in) && isnothing(c1_in) && isnothing(c2_in) && isnothing(h_in)
    if fc_only_change
        dir = improved ? "decreased" : (delta == 0 ? "unchanged" : "increased")
        coupling_caveat =
            "ISOLATED RESULT: Column size held constant. Ratio $dir " *
            "from $(round(orig_ratio; digits=3)) to $(round(new_ratio; digits=3)) " *
            "(f'c: $(round(ustrip(u"psi", orig_fc); digits=0)) → $(round(ustrip(u"psi", fc); digits=0)) psi). " *
            "NOT TESTED HERE: A full redesign re-sizes columns for axial P-M at the new f'c, " *
            "which changes b₀. Run run_design to see the net system effect."
    else
        coupling_caveat = nothing
    end

    # ── Build experimental_setup ──
    changed = String[]
    held = String[]
    !isnothing(c1_in) ? push!(changed, "c1 (column dim 1): $(round(ustrip(u"inch", inp.orig_c1); digits=1)) → $(c1_in) in") :
                         push!(held, "c1 = $(round(ustrip(u"inch", inp.orig_c1); digits=1)) in")
    !isnothing(c2_in) ? push!(changed, "c2 (column dim 2): $(round(ustrip(u"inch", inp.orig_c2); digits=1)) → $(c2_in) in") :
                         push!(held, "c2 = $(round(ustrip(u"inch", inp.orig_c2); digits=1)) in")
    !isnothing(h_in)  ? push!(changed, "h (slab thickness): $(round(ustrip(u"inch", inp.orig_h); digits=1)) → $(h_in) in") :
                         push!(held, "h = $(round(ustrip(u"inch", inp.orig_h); digits=1)) in")
    !isnothing(fc_in) ? push!(changed, "f'c: $(round(ustrip(u"psi", orig_fc); digits=0)) → $(fc_in) psi") :
                         push!(held, "f'c = $(round(ustrip(u"psi", orig_fc); digits=0)) psi")
    push!(held, "Vu (factored shear, adjusted for critical-area change)", "Mub (unbalanced moment)", "tributary area", "column position ($(inp.position))")

    setup = _experimental_setup(;
        changed = changed,
        held_constant = held,
        source = "Cached design — column $col_idx",
        note = isempty(changed) ? "Baseline re-check with no modifications." : nothing,
    )

    dir_word = improved ? "decreased" : (delta == 0.0 ? "unchanged" : "increased")
    ok_word  = result.ok ? "PASS" : "FAIL"

    out = Dict{String, Any}(
        "experiment" => "punching",
        "result_summary" => "Ratio $dir_word from $(round(orig_ratio; digits=3)) to " *
            "$(round(new_ratio; digits=3)) ($(ok_word)). " *
            "Delta = $(round(delta; digits=3)).",
        "experimental_setup" => setup,
        "column_idx" => col_idx,
        "position" => string(inp.position),
        "original" => Dict{String, Any}(
            "c1_in" => round(ustrip(u"inch", inp.orig_c1); digits=1),
            "c2_in" => round(ustrip(u"inch", inp.orig_c2); digits=1),
            "h_in" => round(ustrip(u"inch", inp.orig_h); digits=1),
            "fc_psi" => round(ustrip(u"psi", orig_fc); digits=0),
            "ratio" => round(orig_ratio; digits=3),
            "ok" => inp.punching.ok,
            "Vu_kip" => round(ustrip(u"kip", inp.orig_Vu); digits=2),
            "Mub_kipft" => round(ustrip(u"kip*ft", inp.Mub); digits=2),
        ),
        "modified" => Dict{String, Any}(
            "c1_in" => round(ustrip(u"inch", new_c1); digits=1),
            "c2_in" => round(ustrip(u"inch", new_c2); digits=1),
            "h_in" => round(ustrip(u"inch", new_h); digits=1),
            "fc_psi" => round(ustrip(u"psi", fc); digits=0),
            "ratio" => round(new_ratio; digits=3),
            "ok" => result.ok,
            "vu_psi" => round(ustrip(u"psi", result.vu); digits=1),
            "φvc_psi" => round(ustrip(u"psi", result.φvc); digits=1),
            "b0_in" => round(ustrip(u"inch", b0); digits=1),
            "Vu_adjusted_kip" => round(ustrip(u"kip", Vu_adjusted); digits=2),
        ),
        "stress_decomposition" => Dict{String, Any}(
            "vu_direct_psi" => round(ustrip(u"psi", vu_direct); digits=1),
            "vu_eccentric_psi" => round(ustrip(u"psi", vu_eccentric); digits=1),
            "governing_vc_eq" => governing_eq,
            "β" => round(β; digits=2),
            "αs" => αs,
        ),
        "Vu_note" => "Vu adjusted from $(round(ustrip(u"kip", inp.orig_Vu); digits=2)) kip " *
                      "to $(round(ustrip(u"kip", Vu_adjusted); digits=2)) kip " *
                      "for critical-area change (At=$(round(ustrip(u"ft^2", inp.At); digits=1)) ft²).",
        "delta_ratio" => round(delta; digits=3),
        "improved" => improved,
    )

    !isnothing(sanity_warning) && (out["sanity_warning"] = sanity_warning)
    !isnothing(coupling_caveat) && (out["coupling_caveat"] = coupling_caveat)

    out["cross_check_caveat"] =
        "SCOPE: Punching shear only. P-M interaction, slab flexure, and foundation sizing " *
        "are NOT re-checked. Use pm_column to test the same column size against P-M demands, " *
        "or run_design for all checks together."

    return out
end

# ─── Punching Reinforcement Experiments ──────────────────────────────────────

"""
    experiment_punching_reinforcement(design, col_idx; reinforcement_type, ...) -> Dict

Design shear studs or closed stirrups for a column that fails punching shear,
using the cached design demands.  Returns the reinforcement layout and whether
it makes the column pass.
"""
function experiment_punching_reinforcement(
    design::BuildingDesign,
    col_idx::Int;
    reinforcement_type::String = "studs",
    stud_diameter_in::Union{Float64, Nothing} = nothing,
    bar_size::Union{Int, Nothing} = nothing,
    fyt_psi::Union{Float64, Nothing} = nothing,
)::Dict{String, Any}
    inp = _resolve_punching_inputs(design, col_idx)
    inp isa Dict && return inp

    rt_key = lowercase(strip(reinforcement_type))
    if rt_key ∉ ("studs", "stud", "stirrups", "stirrup")
        return Dict{String, Any}(
            "error" => "invalid_reinforcement_type",
            "message" => "reinforcement_type must be \"studs\" or \"stirrups\". Got: $(repr(reinforcement_type))",
        )
    end
    use_stirrups = rt_key in ("stirrups", "stirrup")

    d = inp.d_orig
    fc = inp.fc
    position = inp.position
    shape = inp.shape

    # Recompute vu from the stored check (using current dimensions)
    col_proxy = (c1 = inp.orig_c1, c2 = inp.orig_c2, position = position, shape = shape)
    check = StructuralSizer.check_punching_for_column(
        col_proxy, inp.orig_Vu, inp.Mub, d, inp.orig_h, fc;
        col_idx = col_idx,
    )
    vu = check.vu

    # Compute geometry parameters for the design functions
    c1_eff = inp.orig_c1
    c2_eff = inp.orig_c2
    if shape == :circular && position != :interior
        side = StructuralSizer.equivalent_square_column(inp.orig_c1)
        c1_eff = side
        c2_eff = side
    end
    β = shape == :circular && position == :interior ? 1.0 :
        max(ustrip(u"inch", c1_eff), ustrip(u"inch", c2_eff)) /
        max(min(ustrip(u"inch", c1_eff), ustrip(u"inch", c2_eff)), 1.0)
    αs = StructuralSizer.punching_αs(position)
    b0 = check.b0

    unreinforced_ratio = check.ratio
    unreinforced_ok = check.ok

    # Common held-constant items for both reinforcement types
    reinf_held = [
        "column size = $(round(ustrip(u"inch", inp.orig_c1); digits=1))×$(round(ustrip(u"inch", inp.orig_c2); digits=1)) in",
        "slab thickness = $(round(ustrip(u"inch", inp.orig_h); digits=1)) in",
        "f'c = $(round(ustrip(u"psi", fc); digits=0)) psi",
        "Vu (factored shear)", "Mub (unbalanced moment)", "column position ($(position))",
    ]

    if use_stirrups
        bs = isnothing(bar_size) ? 4 : bar_size
        fyt = isnothing(fyt_psi) ? 60_000.0u"psi" : fyt_psi * u"psi"

        design_result = try
            StructuralSizer.design_closed_stirrups(
                vu, fc, β, αs, b0, d, position, fyt, bs;
                c1 = inp.orig_c1, c2 = inp.orig_c2,
            )
        catch e
            return Dict{String, Any}(
                "error" => "stirrup_design_failed",
                "message" => "Could not design stirrups: $(sprint(showerror, e))",
            )
        end

        reinforced_check = StructuralSizer.check_punching_with_stirrups(vu, design_result)

        setup = _experimental_setup(;
            changed = ["adding closed stirrups (#$(bs) bars, fyt=$(round(ustrip(u"psi", fyt); digits=0)) psi)"],
            held_constant = reinf_held,
            source = "Cached design — column $col_idx",
            note = "Column dimensions unchanged. Stirrups add Vs to Vc on the capacity side; demand is unchanged.",
        )

        r_ratio = reinforced_check.ratio
        r_ratio_safe = _json_safe(round(r_ratio; digits=3))
        _dir_st = r_ratio < unreinforced_ratio ? "decreased" :
                  (r_ratio == unreinforced_ratio ? "unchanged" : "increased")
        _ok_st  = reinforced_check.ok ? "PASS" : "FAIL"

        out_st = Dict{String, Any}(
            "experiment" => "punching_reinforcement",
            "result_summary" => "Ratio $_dir_st from $(round(unreinforced_ratio; digits=3)) to " *
                "$(isfinite(r_ratio) ? string(round(r_ratio; digits=3)) : "∞ (exceeds ACI limits)") ($_ok_st). " *
                "Delta = $(isfinite(r_ratio) ? string(round(r_ratio - unreinforced_ratio; digits=3)) : "N/A").",
            "experimental_setup" => setup,
            "column_idx" => col_idx,
            "position" => string(position),
            "reinforcement_type" => "stirrups",
            "unreinforced" => Dict{String, Any}(
                "ratio" => round(unreinforced_ratio; digits=3),
                "ok" => unreinforced_ok,
                "vu_psi" => round(ustrip(u"psi", vu); digits=1),
                "φvc_psi" => round(ustrip(u"psi", check.φvc); digits=1),
            ),
            "reinforced" => Dict{String, Any}(
                "ratio" => r_ratio_safe,
                "ok" => reinforced_check.ok,
                "required" => design_result.required,
            ),
            "layout" => Dict{String, Any}(
                "bar_size" => bs,
                "n_legs" => design_result.n_legs,
                "n_lines" => design_result.n_lines,
                "s0_in" => round(ustrip(u"inch", design_result.s0); digits=2),
                "s_in" => round(ustrip(u"inch", design_result.s); digits=2),
                "fyt_psi" => round(ustrip(u"psi", fyt); digits=0),
                "vs_psi" => round(ustrip(u"psi", design_result.vs); digits=1),
                "vcs_psi" => round(ustrip(u"psi", design_result.vcs); digits=1),
                "outer_ok" => design_result.outer_ok,
            ),
            "improved" => isfinite(r_ratio) && r_ratio < unreinforced_ratio,
            "delta_ratio" => _json_safe(round(r_ratio - unreinforced_ratio; digits=3)),
        )
        if !design_result.required || design_result.n_legs == 0
            out_st["note"] = "Stirrups not required or layout is empty (n_legs=0). " *
                "Check unreinforced ratio and φVc vs vu above."
        elseif !isfinite(r_ratio)
            out_st["note"] = "Reinforced ratio is non-finite — demand exceeds ACI maximum capacity with stirrups."
        end
        out_st["cross_check_caveat"] =
            "SCOPE: Punching shear capacity with stirrup reinforcement only. Column size, " *
            "slab thickness, P-M interaction, and foundation sizing are NOT re-checked. " *
            "Run run_design for all checks together."
        return out_st
    else  # studs (default)
        sd = isnothing(stud_diameter_in) ? 0.5u"inch" : stud_diameter_in * u"inch"
        fyt = isnothing(fyt_psi) ? 51_000.0u"psi" : fyt_psi * u"psi"

        design_result = try
            StructuralSizer.design_shear_studs(
                vu, fc, β, αs, b0, d, position, fyt, sd;
                c1 = inp.orig_c1, c2 = inp.orig_c2,
            )
        catch e
            return Dict{String, Any}(
                "error" => "stud_design_failed",
                "message" => "Could not design studs: $(sprint(showerror, e))",
            )
        end

        reinforced_check = StructuralSizer.check_punching_with_studs(vu, design_result)

        setup = _experimental_setup(;
            changed = ["adding shear studs (ø$(round(ustrip(u"inch", sd); digits=3))\" studs, fyt=$(round(ustrip(u"psi", fyt); digits=0)) psi)"],
            held_constant = reinf_held,
            source = "Cached design — column $col_idx",
            note = "Column dimensions unchanged. Studs add Vs to Vc on the capacity side; demand is unchanged.",
        )

        r_ratio_sd = reinforced_check.ratio
        r_ratio_sd_safe = _json_safe(round(r_ratio_sd; digits=3))
        _dir_sd = r_ratio_sd < unreinforced_ratio ? "decreased" :
                  (r_ratio_sd == unreinforced_ratio ? "unchanged" : "increased")
        _ok_sd  = reinforced_check.ok ? "PASS" : "FAIL"

        out_sd = Dict{String, Any}(
            "experiment" => "punching_reinforcement",
            "result_summary" => "Ratio $_dir_sd from $(round(unreinforced_ratio; digits=3)) to " *
                "$(isfinite(r_ratio_sd) ? string(round(r_ratio_sd; digits=3)) : "∞ (exceeds ACI limits)") ($_ok_sd). " *
                "Delta = $(isfinite(r_ratio_sd) ? string(round(r_ratio_sd - unreinforced_ratio; digits=3)) : "N/A").",
            "experimental_setup" => setup,
            "column_idx" => col_idx,
            "position" => string(position),
            "reinforcement_type" => "studs",
            "unreinforced" => Dict{String, Any}(
                "ratio" => round(unreinforced_ratio; digits=3),
                "ok" => unreinforced_ok,
                "vu_psi" => round(ustrip(u"psi", vu); digits=1),
                "φvc_psi" => round(ustrip(u"psi", check.φvc); digits=1),
            ),
            "reinforced" => Dict{String, Any}(
                "ratio" => r_ratio_sd_safe,
                "ok" => reinforced_check.ok,
                "required" => design_result.required,
            ),
            "layout" => Dict{String, Any}(
                "stud_diameter_in" => round(ustrip(u"inch", sd); digits=3),
                "n_rails" => design_result.n_rails,
                "n_studs_per_rail" => design_result.n_studs_per_rail,
                "s0_in" => round(ustrip(u"inch", design_result.s0); digits=2),
                "s_in" => round(ustrip(u"inch", design_result.s); digits=2),
                "fyt_psi" => round(ustrip(u"psi", fyt); digits=0),
                "vs_psi" => round(ustrip(u"psi", design_result.vs); digits=1),
                "vcs_psi" => round(ustrip(u"psi", design_result.vcs); digits=1),
                "outer_ok" => design_result.outer_ok,
            ),
            "improved" => isfinite(r_ratio_sd) && r_ratio_sd < unreinforced_ratio,
            "delta_ratio" => _json_safe(round(r_ratio_sd - unreinforced_ratio; digits=3)),
        )
        if !design_result.required || design_result.n_rails == 0
            out_sd["note"] = "Studs not laid out (n_rails=0). " *
                "Check unreinforced ratio and φVc vs vu above."
        elseif !isfinite(r_ratio_sd)
            out_sd["note"] = "Reinforced ratio is non-finite — demand exceeds ACI maximum capacity with studs."
        end
        out_sd["cross_check_caveat"] =
            "SCOPE: Punching shear capacity with stud reinforcement only. Column size, " *
            "slab thickness, P-M interaction, and foundation sizing are NOT re-checked. " *
            "Run run_design for all checks together."
        return out_sd
    end
end

# ─── Punching: min column with reinforcement at constant Vu ───────────────────

"""
    _punching_reinforced_ok_at_scale(inp, scale, use_stirrups; stud_diameter_in, bar_size, fyt_psi) -> (ok, ratio, err)

`Vu` and `Mub` are held at the cached design values (no tributary-area adjustment).
`scale` multiplies both column plan dimensions relative to the cached section.
"""
function _punching_reinforced_ok_at_scale(
    inp,
    col_idx::Int,
    scale::Float64,
    use_stirrups::Bool;
    stud_diameter_in::Union{Float64, Nothing} = nothing,
    bar_size::Union{Int, Nothing} = nothing,
    fyt_psi::Union{Float64, Nothing} = nothing,
)::Tuple{Bool, Float64, Union{Nothing, String}}
    scale <= 0 && return (false, Inf, "invalid_scale")

    new_c1 = inp.orig_c1 * scale
    new_c2 = inp.orig_c2 * scale
    col_proxy = (c1 = new_c1, c2 = new_c2, position = inp.position, shape = inp.shape)
    d = inp.d_orig
    fc = inp.fc
    h = inp.orig_h

    local check
    try
        check = StructuralSizer.check_punching_for_column(
            col_proxy, inp.orig_Vu, inp.Mub, d, h, fc;
            col_idx = col_idx,
        )
    catch e
        return (false, Inf, sprint(showerror, e))
    end
    vu = check.vu
    b0 = check.b0

    c1_eff = new_c1
    c2_eff = new_c2
    if inp.shape == :circular && inp.position != :interior
        side = StructuralSizer.equivalent_square_column(new_c1)
        c1_eff = side
        c2_eff = side
    end
    β = inp.shape == :circular && inp.position == :interior ? 1.0 :
        max(ustrip(u"inch", c1_eff), ustrip(u"inch", c2_eff)) /
        max(min(ustrip(u"inch", c1_eff), ustrip(u"inch", c2_eff)), 1.0)
    αs = StructuralSizer.punching_αs(inp.position)

    if use_stirrups
        bs = isnothing(bar_size) ? 4 : bar_size
        fyt = isnothing(fyt_psi) ? 60_000.0u"psi" : fyt_psi * u"psi"
        design_result = try
            StructuralSizer.design_closed_stirrups(
                vu, fc, β, αs, b0, d, inp.position, fyt, bs;
                c1 = new_c1, c2 = new_c2,
            )
        catch e
            return (false, Inf, sprint(showerror, e))
        end
        reinforced = try
            StructuralSizer.check_punching_with_stirrups(vu, design_result)
        catch e
            return (false, Inf, sprint(showerror, e))
        end
        return (reinforced.ok, reinforced.ratio, nothing)
    else
        sd = isnothing(stud_diameter_in) ? 0.5u"inch" : stud_diameter_in * u"inch"
        fyt = isnothing(fyt_psi) ? 51_000.0u"psi" : fyt_psi * u"psi"
        design_result = try
            StructuralSizer.design_shear_studs(
                vu, fc, β, αs, b0, d, inp.position, fyt, sd;
                c1 = new_c1, c2 = new_c2,
            )
        catch e
            return (false, Inf, sprint(showerror, e))
        end
        reinforced = try
            StructuralSizer.check_punching_with_studs(vu, design_result)
        catch e
            return (false, Inf, sprint(showerror, e))
        end
        return (reinforced.ok, reinforced.ratio, nothing)
    end
end

function _binary_search_min_punching_scale(feasible, lo::Float64, hi::Float64; tol::Float64 = 0.002, maxiter::Int = 50)::Union{Float64, Nothing}
    feasible(hi) || return nothing
    feasible(lo) && return lo
    for _ in 1:maxiter
        if hi - lo < tol
            return hi
        end
        mid = (lo + hi) / 2
        if feasible(mid)
            hi = mid
        else
            lo = mid
        end
    end
    return hi
end

"""
    experiment_punching_column_downsize(design, col_idx; ...) -> Dict

With **factored shear `Vu` and unbalanced moment `Mub` fixed** to the cached design values,
search for the **smallest uniform scale** of the column footprint (c1×c2) for which
punching can be made to pass using **shear studs or closed stirrups** (same detailing
model as `punching_reinforcement`).

Compares that plan to the as-designed section and optionally runs `pm_column` at the
downsized square size (max side) to flag P-M infeasibility — punching-only minima can be
smaller than axial/bending would allow in a full redesign.
"""
function experiment_punching_column_downsize(
    design::BuildingDesign,
    col_idx::Int;
    reinforcement_type::String = "studs",
    min_column_dim_in::Float64 = 8.0,
    stud_diameter_in::Union{Float64, Nothing} = nothing,
    bar_size::Union{Int, Nothing} = nothing,
    fyt_psi::Union{Float64, Nothing} = nothing,
    check_pm::Bool = true,
)::Dict{String, Any}
    inp = _resolve_punching_inputs(design, col_idx)
    inp isa Dict && return inp

    rt_key = lowercase(strip(reinforcement_type))
    if rt_key ∉ ("studs", "stud", "stirrups", "stirrup")
        return Dict{String, Any}(
            "error" => "invalid_reinforcement_type",
            "message" => "reinforcement_type must be \"studs\" or \"stirrups\". Got: $(repr(reinforcement_type))",
        )
    end
    use_stirrups = rt_key in ("stirrups", "stirrup")

    c1_in = ustrip(u"inch", inp.orig_c1)
    c2_in = ustrip(u"inch", inp.orig_c2)
    min_c = min(c1_in, c2_in)
    min_c <= 0 && return Dict{String, Any}("error" => "invalid_column_dims", "message" => "Column dimensions must be positive.")

    lo_scale = max(min_column_dim_in / min_c, 0.05)
    if lo_scale >= 1.0
        return Dict{String, Any}(
            "error" => "min_column_dim_in_not_downsizing",
            "message" => "min_column_dim_in ($min_column_dim_in in) is not smaller than the current smaller plan dimension ($min_c in). Lower min_column_dim_in or pick a different column.",
        )
    end

    feasible(s) = begin
        ok, _, _ = _punching_reinforced_ok_at_scale(inp, col_idx, s, use_stirrups;
            stud_diameter_in = stud_diameter_in,
            bar_size = bar_size,
            fyt_psi = fyt_psi,
        )
        ok
    end

    if !feasible(1.0)
        return Dict{String, Any}(
            "error" => "reinforced_punching_infeasible_at_design_size",
            "message" => "Even at the as-designed column size, stud/stirrup-reinforced punching does not pass at the cached Vu/Mub. " *
                "Try punching_reinforcement on this column for details, or run_design with different slab/column parameters.",
        )
    end

    best_scale = _binary_search_min_punching_scale(feasible, lo_scale, 1.0)
    isnothing(best_scale) && return Dict{String, Any}(
        "error" => "search_failed",
        "message" => "Could not bracket a feasible reinforced punching solution.",
    )

    ok_b, ratio_b, err_b = _punching_reinforced_ok_at_scale(inp, col_idx, best_scale, use_stirrups;
        stud_diameter_in = stud_diameter_in,
        bar_size = bar_size,
        fyt_psi = fyt_psi,
    )
    !ok_b && return Dict{String, Any}(
        "error" => "numeric_inconsistency",
        "message" => "Binary search reported feasible scale $(round(best_scale; digits=4)) but recheck failed. $(something(err_b, ""))",
    )

    new_c1_in = round(c1_in * best_scale; digits=2)
    new_c2_in = round(c2_in * best_scale; digits=2)
    orig_area = c1_in * c2_in
    new_area = new_c1_in * new_c2_in
    area_ratio = orig_area > 0 ? new_area / orig_area : nothing

    setup = _experimental_setup(;
        changed = ["uniform column plan scale (c1,c2) × $(round(best_scale; digits=4)) with $(use_stirrups ? "closed stirrups" : "shear studs")"],
        held_constant = [
            "Vu (factored shear from cached design)",
            "Mub (unbalanced moment from cached design)",
            "slab thickness h and effective depth d",
            "f'c (slab concrete)",
            "column position ($(inp.position))",
        ],
        source = "Cached design — column $col_idx",
        note = "Demand-side Vu/Mub are NOT recomputed from tributary area when the column shrinks — this isolates capacity vs footprint at fixed shear/moment transfer.",
    )

    _smaller = best_scale < 1.0 - 1e-6
    _area_pct = isnothing(area_ratio) ? "" : " ($(round(area_ratio * 100; digits=1))% of original area)"

    out = Dict{String, Any}(
        "experiment" => "punching_column_downsize",
        "result_summary" => "Min feasible column $(new_c1_in)×$(new_c2_in) in " *
            "(scale=$(round(best_scale; digits=4)))$(_area_pct). " *
            "Punching ratio = $(round(ratio_b; digits=3)), $(ok_b ? "PASS" : "FAIL"). " *
            "$(_smaller ? "Column CAN be reduced." : "Column cannot be reduced further.")",
        "experimental_setup" => setup,
        "column_idx" => col_idx,
        "reinforcement_type" => use_stirrups ? "stirrups" : "studs",
        "original" => Dict{String, Any}(
            "c1_in" => round(c1_in; digits=2),
            "c2_in" => round(c2_in; digits=2),
            "plan_area_in2" => round(orig_area; digits=1),
        ),
        "min_with_reinforcement" => Dict{String, Any}(
            "scale" => round(best_scale; digits=4),
            "c1_in" => new_c1_in,
            "c2_in" => new_c2_in,
            "plan_area_in2" => round(new_area; digits=1),
            "punching_ratio" => round(ratio_b; digits=3),
            "ok" => ok_b,
        ),
        "plan_area_fraction_of_original" => isnothing(area_ratio) ? nothing : round(area_ratio; digits=3),
        "column_smaller_than_design" => _smaller,
    )

    if check_pm
        col_res = get(design.columns, col_idx, nothing)
        is_rc = !isnothing(col_res) && col_res.shape in (:rectangular, :circular, :rc_rect, :rc_circular)
        if is_rc
            sq = max(new_c1_in, new_c2_in)
            pmr = experiment_pm_column(design, col_idx; section_size = sq)
            out["pm_at_downsized_square"] = Dict{String, Any}(
                "section_side_in" => sq,
                "pm_ok" => get(get(pmr, "modified", Dict()), "ok", nothing),
                "pm_interaction_ratio" => get(get(pmr, "modified", Dict()), "interaction_ratio", nothing),
            )
            out["cross_check_caveat"] =
                "P-M check uses a heuristic square RC section with side = max(c1,c2) at the downsized footprint. " *
                "Rectangular detailing and other limit states are NOT tested. Run run_design for confirmation."
        else
            out["pm_at_downsized_square"] = Dict{String, Any}(
                "note" => "pm_column downsize cross-check skipped — not an RC column in cached results.",
            )
        end
    end

    if !haskey(out, "cross_check_caveat")
        out["cross_check_caveat"] =
            "SCOPE: Punching capacity at frozen Vu/Mub only. Stiffness, load distribution, " *
            "and other limit states are NOT re-checked. Run run_design for confirmation."
    end

    return out
end

