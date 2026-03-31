# =============================================================================
# Micro-Experiments — Lightweight what-if checks using cached design data
#
# These functions re-run individual structural checks with modified parameters
# WITHOUT requiring a full design_building pass. They extract demands and
# geometry from a completed BuildingDesign and call StructuralSizer checker
# APIs directly.
#
# Experiment types:
#   - punching:                vary column size, slab thickness, or fc for punching check
#   - pm_column:               try alternative column sections against cached P-M demands
#   - beam:                    try alternative W-shapes against cached beam demands
#   - punching_reinforcement:  design studs/stirrups for a punching-failing column
#   - deflection:              test different deflection limits against stored slab data
#   - catalog_screen:          screen a section catalog against a single demand envelope
# =============================================================================

using Unitful

# ─── JSON safety ──────────────────────────────────────────────────────────────

"""
    _sanitize_for_json(x)

Recursively walk a Dict/Array structure and replace non-finite Float64 values
(`Inf`, `-Inf`, `NaN`) with `nothing` so the result is valid JSON.
"""
_sanitize_for_json(x::AbstractFloat) = isfinite(x) ? x : nothing
_sanitize_for_json(x::AbstractDict) = Dict(k => _sanitize_for_json(v) for (k, v) in x)
_sanitize_for_json(x::AbstractVector) = [_sanitize_for_json(v) for v in x]
_sanitize_for_json(x) = x

# ─── Experimental Setup Reporter ─────────────────────────────────────────────

"""
    _experimental_setup(; changed, held_constant, source, note=nothing) -> Dict

Build a structured `experimental_setup` block that documents what was varied,
what was held constant, and where the baseline data comes from.
"""
function _experimental_setup(;
    changed::Vector{String},
    held_constant::Vector{String},
    source::String,
    note::Union{String, Nothing} = nothing,
)::Dict{String, Any}
    out = Dict{String, Any}(
        "changed"       => changed,
        "held_constant" => held_constant,
        "source"        => source,
    )
    !isnothing(note) && (out["note"] = note)
    return out
end

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
    _punching_critical_area(c1, c2, d, position) → Area

Area enclosed by the punching critical section, accounting for column position.
Interior uses full 4-sided perimeter; edge uses 3-sided; corner uses 2-sided.
"""
function _punching_critical_area(c1, c2, d, position::Symbol)
    if position == :interior
        return (c1 + d) * (c2 + d)
    elseif position == :edge
        return (c1 + d / 2) * (c2 + d)
    else  # :corner
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

    # First slab with a thickness (typical single-slab buildings; multi-slab is rare in this path).
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

    d_orig = orig_h - cover - bar_d
    position = _resolve_column_position(design, col_idx)
    shape = _resolve_column_shape(design, col_idx)

    # PunchingDesignResult does not store Mub; use |Mu_x| from the column result as unbalanced-moment proxy.
    Mub = abs(col_result.Mu_x)

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
        sanity_warning = "WARNING: Ratio worsened despite larger column/slab. " *
            "With Vu adjusted for critical-area change this is unusual. " *
            "Likely cause: unbalanced moment dominates (eccentric stress = " *
            "$(round(ustrip(u"psi", vu_eccentric); digits=1)) psi vs direct = " *
            "$(round(ustrip(u"psi", vu_direct); digits=1)) psi). " *
            "Consider verifying with a full run_design."
    end

    # ── f'c coupling caveat: column size held constant in this experiment ──
    fc_only_change = !isnothing(fc_in) && isnothing(c1_in) && isnothing(c2_in) && isnothing(h_in)
    if fc_only_change
        coupling_caveat = "IMPORTANT: This experiment holds column size constant while " *
            "changing f'c. In a full redesign, higher f'c allows the column sizer to " *
            "select SMALLER columns (less area needed for axial P-M), which would SHRINK " *
            "b₀ and potentially WORSEN punching despite the higher Vc. This result shows " *
            "only the isolated Vc improvement. Run a full run_design to see the net system effect."
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

    out = Dict{String, Any}(
        "experiment" => "punching",
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

    # Cross-check coupling: punching experiment does not re-check P-M or foundations
    out["cross_check_caveat"] =
        "This experiment isolates punching shear only. Changing column size here does NOT " *
        "update the P-M interaction check (axial + bending capacity), slab flexural design, " *
        "or foundation sizing. A column that passes punching at a new size may still fail " *
        "P-M or require a different foundation. Run a full run_design to see all checks together, " *
        "or use pm_column experiment to test the same column size against P-M demands."

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

    setup = _experimental_setup(;
        changed = ["section size: $(col.section_size) → $(dim_str) in", "rebar layout: scaled to $(n_bars)-#$(bar_size)"],
        held_constant = ["Pu = $(round(Pu_kip; digits=1)) kip", "Mux = $(round(Mux_kipft; digits=1)) kip·ft",
                         "Muy = $(round(Muy_kipft; digits=1)) kip·ft", "height = $(round(ustrip(u"ft", L); digits=1)) ft",
                         "Ky = $(round(Ky; digits=2))", "f'c, rebar grade, cover, slenderness parameters"],
        source = "Cached design — column $col_idx",
        note = "Rebar count/size scaled heuristically to section dimension. Actual optimizer may choose differently.",
    )

    return Dict{String, Any}(
        "experiment" => "pm_column",
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
        "cross_check_caveat" =>
            "This experiment isolates P-M interaction only. Changing column section size " *
            "directly affects punching shear (b₀ changes with column dimensions) and may " *
            "alter foundation demands. A column that passes P-M at a new size may worsen or " *
            "improve punching. Run a full run_design to see all checks together, or use the " *
            "punching experiment to test the same column size against punching demands.",
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

    result = Dict{String, Any}(
        "experiment" => "pm_column",
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

    result["cross_check_caveat"] =
        "This experiment isolates P-M interaction only. Changing column section affects " *
        "punching shear (b₀ scales with flange/web dimensions) and may alter foundation " *
        "demands. Run a full run_design to see all checks together."

    return result
end

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

    result = Dict{String, Any}(
        "experiment" => "beam",
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
            "flexure_ratio" => round(beam.flexure_ratio; digits=3),
            "shear_ratio" => round(beam.shear_ratio; digits=3),
            "governing_ratio" => round(orig_ratio; digits=3),
            "ok" => beam.ok,
            "governing_check" => beam_diagnostic_governing_check(beam),
        ),
        "modified" => Dict{String, Any}(
            "section" => size_str,
            "weight_plf" => new_weight,
            "governing_ratio" => round(new_ratio; digits=3),
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

    if !isnothing(new_weight)
        orig_weight = try
            m = match(r"X(\d+\.?\d*)", uppercase(beam.section_size))
            isnothing(m) ? nothing : parse(Float64, m.captures[1])
        catch; nothing end
        if !isnothing(orig_weight) && new_weight > orig_weight && new_ratio > orig_ratio
            result["sanity_warning"] = "Heavier section $(size_str) ($(new_weight) plf) " *
                "has worse ratio than $(beam.section_size) ($(orig_weight) plf). " *
                "Check governing_check — may indicate LTB, depth, or local buckling issue."
        end
    end

    result["cross_check_caveat"] =
        "This experiment isolates beam flexure/shear only. Beam depth affects floor-to-floor " *
        "height and connection demands. Slab tributary loads and deflections are held constant. " *
        "Run a full run_design to see all checks together."

    return result
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
            note = "Column dimensions unchanged — this tests capacity-side improvement only (adds Vs to Vc).",
        )

        out_st = Dict{String, Any}(
            "experiment" => "punching_reinforcement",
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
                "ratio" => round(reinforced_check.ratio; digits=3),
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
            "improved" => reinforced_check.ratio < unreinforced_ratio,
            "delta_ratio" => round(reinforced_check.ratio - unreinforced_ratio; digits=3),
        )
        if !design_result.required || design_result.n_legs == 0
            out_st["note"] = "Stirrups were not required by the design routine, or layout is empty — " *
                "demand may be within φVc or exceed code limits for closed stirrups."
        elseif !isfinite(reinforced_check.ratio)
            out_st["note"] = "Reinforced check ratio is not finite — verify demand vs ACI limits for stirrup-reinforced punching."
        end
        out_st["cross_check_caveat"] =
            "This experiment isolates punching shear capacity with reinforcement. Column size, " *
            "slab thickness, and P-M interaction are held constant. Adding shear reinforcement " *
            "does not change column axial/bending capacity or foundation demands. Run a full " *
            "run_design to verify all checks together."
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
            note = "Column dimensions unchanged — this tests capacity-side improvement only (adds Vs to Vc).",
        )

        out_sd = Dict{String, Any}(
            "experiment" => "punching_reinforcement",
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
                "ratio" => round(reinforced_check.ratio; digits=3),
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
            "improved" => reinforced_check.ratio < unreinforced_ratio,
            "delta_ratio" => round(reinforced_check.ratio - unreinforced_ratio; digits=3),
        )
        if !design_result.required || design_result.n_rails == 0
            out_sd["note"] = "Studs were not laid out (n_rails = 0) — demand may exceed code limits for headed stud reinforcement, or φVc already suffices."
        elseif !isfinite(reinforced_check.ratio)
            out_sd["note"] = "Reinforced check ratio is not finite — verify demand vs ACI stress limits for stud-reinforced punching."
        end
        out_sd["cross_check_caveat"] =
            "This experiment isolates punching shear capacity with reinforcement. Column size, " *
            "slab thickness, and P-M interaction are held constant. Adding shear reinforcement " *
            "does not change column axial/bending capacity or foundation demands. Run a full " *
            "run_design to verify all checks together."
        return out_sd
    end
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

    orig_criterion = orig_divisor_approx > 0 ? "L/$(orig_divisor_approx)" : "unknown"

    setup = _experimental_setup(;
        changed = ["deflection limit: $(orig_criterion) → $(deflection_limit)"],
        held_constant = ["actual deflection = $(round(orig_deflection; digits=3)) in (not recomputed)",
                         "slab thickness = $(isnothing(thickness_in) ? "N/A" : "$(thickness_in) in")",
                         "span = $(isnothing(span_ft) ? "N/A" : "$(round(span_ft; digits=1)) ft")",
                         "concrete properties, loading, reinforcement"],
        source = "Cached design — slab $slab_idx",
        note = "Only the allowable limit changes. Actual deflection stays fixed. To reduce actual deflection, increase slab thickness via run_design.",
    )

    result = Dict{String, Any}(
        "experiment" => "deflection",
        "experimental_setup" => setup,
        "slab_idx" => slab_idx,
        "slab_context" => Dict{String, Any}(
            "span_ft" => isnothing(span_ft) ? nothing : round(span_ft; digits=1),
            "thickness_in" => thickness_in,
            "current_limit_criterion" => orig_criterion,
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

    Pu_kip_val = round(ustrip(u"kip", col.Pu); digits=1)
    Mux_kipft_val = round(ustrip(u"kip*ft", col.Mu_x); digits=1)
    Muy_kipft_val = round(ustrip(u"kip*ft", col.Mu_y); digits=1)
    cand_strs = [string(c) for c in candidates]

    setup = _experimental_setup(;
        changed = ["section — screening $(length(candidates)) candidates: $(join(cand_strs[1:min(end, 5)], ", "))$(length(cand_strs) > 5 ? "…" : "")"],
        held_constant = ["Pu = $(Pu_kip_val) kip", "Mux = $(Mux_kipft_val) kip·ft",
                         "Muy = $(Muy_kipft_val) kip·ft", "height, K-factors, material properties"],
        source = "Cached design — column $col_idx",
    )

    return Dict{String, Any}(
        "experiment" => "catalog_screen",
        "experimental_setup" => setup,
        "column_idx" => col_idx,
        "column_type" => is_rc ? "RC" : "steel",
        "demands" => Dict{String, Any}(
            "Pu_kip" => Pu_kip_val,
            "Mux_kipft" => Mux_kipft_val,
            "Muy_kipft" => Muy_kipft_val,
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
                "description" => "Re-check punching shear with modified column size, slab thickness, or concrete strength. " *
                    "Respects column position (interior/edge/corner) and unbalanced moment. " *
                    "Adjusts Vu for critical-area change. Returns demand, capacity, stress decomposition.",
                "args" => Dict(
                    "col_idx" => "required Int — column index from diagnose",
                    "c1_in" => "optional Float64 — new column c1 dimension (inches)",
                    "c2_in" => "optional Float64 — new column c2 dimension (inches)",
                    "h_in" => "optional Float64 — new slab thickness (inches)",
                    "fc_in" => "optional Float64 — new concrete compressive strength (psi, e.g. 5000)",
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
                "name" => "beam",
                "description" => "Steel beams only: test cached Mu/Vu against a different AISC W-shape. " *
                    "Uses full AISC checker (flexure, shear, LTB, etc.). " *
                    "RC or other section types return beam_not_steel_w — use run_design for those.",
                "args" => Dict(
                    "beam_idx" => "required Int — beam index from diagnose",
                    "section_size" => "required String — W-shape designation (e.g. \"W16X40\")",
                ),
                "example" => "run_experiment(type=beam, args={beam_idx=1, section_size=\"W16X40\"})",
            ),
            Dict{String, Any}(
                "name" => "punching_reinforcement",
                "description" => "Design shear studs or closed stirrups for a column failing punching shear. " *
                    "Uses cached demands to run the full stud/stirrup design algorithm. " *
                    "Returns reinforcement layout and whether the column now passes.",
                "args" => Dict(
                    "col_idx" => "required Int — column index from diagnose",
                    "reinforcement_type" => "optional String — \"studs\" (default) or \"stirrups\"",
                    "stud_diameter_in" => "optional Float64 — stud diameter in inches (default 0.5, studs only)",
                    "bar_size" => "optional Int — stirrup bar designation: 3, 4, or 5 (default 4, stirrups only)",
                    "fyt_psi" => "optional Float64 — reinforcement yield strength in psi (default 51000 studs / 60000 stirrups)",
                ),
                "example" => "run_experiment(type=punching_reinforcement, args={col_idx=3, reinforcement_type=\"studs\"})",
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
        fc_in = _coerce_float(get(args, "fc_in", nothing))
        return experiment_punching(design, col_idx;
            c1_in = c1_in,
            c2_in = c2_in,
            h_in = h_in,
            fc_in = fc_in,
        )
    elseif experiment_type == "beam"
        beam_idx = _coerce_int(get(args, "beam_idx", nothing))
        isnothing(beam_idx) && return Dict("error" => "missing_beam_idx", "message" => "beam experiment requires beam_idx")
        return experiment_beam(design, beam_idx;
            section_size = get(args, "section_size", nothing),
        )
    elseif experiment_type == "punching_reinforcement"
        col_idx = _coerce_int(get(args, "col_idx", nothing))
        isnothing(col_idx) && return Dict("error" => "missing_col_idx", "message" => "punching_reinforcement experiment requires col_idx")
        rt = string(get(args, "reinforcement_type", "studs"))
        sd_in = _coerce_float(get(args, "stud_diameter_in", nothing))
        bs = _coerce_int(get(args, "bar_size", nothing))
        fyt = _coerce_float(get(args, "fyt_psi", nothing))
        return experiment_punching_reinforcement(design, col_idx;
            reinforcement_type = rt,
            stud_diameter_in = sd_in,
            bar_size = bs,
            fyt_psi = fyt,
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
            _sanitize_for_json(evaluate_experiment(design, exp_type_str, exp_args))
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
