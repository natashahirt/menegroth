# ─── Per-element serializers ──────────────────────────────────────────────────

"""
    _column_code_clauses(cr::ColumnDesignResult) -> (axial::String, pm::String)

Select the governing design-code provisions for a column's axial-compression and
P-M interaction checks by the member's MATERIAL (from the designed `section_obj`),
never by string position — the exact P0-A safety fix already applied to beams via
[`_beam_code_clauses`](@ref). A steel column must never be cited to a concrete
(ACI) clause and vice versa.

The capacity ratios these clauses annotate are computed in `design_workflow.jl`:
steel columns use AISC 360-16 §E3 (axial — the GOVERNING flexural-buckling limit
state, computed via `StructuralSizer.get_ϕPn`, φc = 0.90) and §H1 (P-M
interaction, H1-1a/b); RC columns use ACI 318-19 §22.4.2 (axial) / §22.4
(combined flexure-axial). So the emitted clauses match the code that produced
each ratio — the axial clause is §E3, not §E1, because the ratio reflects
flexural buckling, not §E1's general provisions / gross-yield.

Note: `StructuralSizer.get_ϕPn` returns Pn = Fcr·Ae, i.e. it also applies the
§E7 effective-area reduction on top of the §E3/§E4 buckling stress. §E3 is cited
as the PRIMARY (flexural-buckling) limit state because it governs the common
non-slender case (Ae = Ag); §E7 governs only slender-element / thin-HSS-wall
cases and is not separately wired (see `corpus_grounding.jl`).

Section tokens follow the AISC 360-16 / ACI 318-19 chapter organization
(corpus: aisc-360-16 — E3 p.35, H1 p.77 confirmed via corpus.get_clause;
aci-318-19 — §22.4 p.400 confirmed):
- ISymm / rectangular HSS / round HSS (steel): axial §E3, P-M §H1. Chapter E3
  (flexural buckling) and Chapter H1 (combined forces) are not shape-specific,
  so all steel column shapes share these tokens. §E3 grounds to a confirmed page;
  if it were not in the corpus `ground_check` would leave it explicitly UNRESOLVED
  rather than mis-cite (never a concrete clause).
- RC (rectangular / circular): axial §22.4.2, P-M §22.4.
- PixelFrame / unsized / unsupported: empty strings so `ground_check` leaves the
  citation UNRESOLVED rather than mis-attributing it to the wrong code family.

Punching (`§22.6`) is intentionally NOT selected here: two-way (punching) shear
is a concrete slab phenomenon at the column and stays ACI even for a steel column
supporting a concrete slab (handled inline in `_diagnose_column`).
"""
function _column_code_clauses(cr::ColumnDesignResult)::Tuple{String, String}
    so = cr.section_obj
    if so isa StructuralSizer.ISymmSection ||
       so isa StructuralSizer.HSSRectSection ||
       so isa StructuralSizer.HSSRoundSection
        return ("AISC 360-16 E3", "AISC 360-16 H1")
    elseif so isa StructuralSizer.RCColumnSection || so isa StructuralSizer.RCCircularSection
        return ("ACI 318-19 §22.4.2", "ACI 318-19 §22.4")
    else
        # PixelFrame / unsized / unsupported: no single confirmed code family.
        return ("", "")
    end
end

"""
Build a Dict representing one column's full diagnostic data.
"""
function _diagnose_column(
    idx::Int,
    cr::ColumnDesignResult,
    col_obj::Column,
    struc::BuildingStructure,
    du::DisplayUnits,
)
    funit = _force_unit_str(du)
    munit = _moment_unit_str(du)
    thick_unit = _thickness_unit_string(du)

    governing = _column_governing_check(cr)
    punch_ratio = isnothing(cr.punching) ? 0.0 : cr.punching.ratio
    # An UNVERIFIED column carries the NaN axial/interaction sentinel (§E3/§E4 buckling
    # capacity unavailable — see `_populate_column_results!`). Exclude NaN terms from the
    # numeric aggregate so `governing_ratio` never serializes to `nothing` (which would poison
    # every downstream max/argmax that reads it), then force a failing ratio ≥ 1.0, mirroring
    # `_compute_design_summary!`. The per-check `ratio`/`headroom` fields stay null (honest:
    # the ratio truly is unverified), but the element-level `governing_ratio` is always finite.
    #
    # LABEL/LEVER PRIORITY (intentional, not a bug): when a column is BOTH unverified-axial
    # AND punching-failing, `column_diagnostic_governing_check` returns
    # `"axial_compression_unverified"`, so `governing` (and hence the `LEVER_MAP` levers below)
    # prioritizes resize-and-re-verify over `"punching_strategy"`. That ordering is defensible —
    # you cannot trust a punching design around a column whose own axial capacity is unverified;
    # fix the section first, then re-check punching. Crucially, `punch_ratio` is kept in
    # `finite_ratios`, so `governing_ratio` below still carries the REAL punching failure
    # magnitude (finite, ≥ 1.0) even though the label points at the unverified axial state — the
    # failure severity is never understated.
    finite_ratios = filter(!isnan, (cr.axial_ratio, cr.interaction_ratio, punch_ratio, cr.shear_ratio))
    max_ratio   = isempty(finite_ratios) ? 0.0 : maximum(finite_ratios)
    if !cr.ok && max_ratio < 1.0
        max_ratio = 1.0
    end

    # Section dimensions in display (thickness) units
    c1_disp = _to_display(du, :thickness, cr.c1)
    c2_disp = _to_display(du, :thickness, cr.c2)

    # Demand values in display force/moment units
    pu_disp  = _to_display(du, :force, cr.Pu)
    mux_disp = _to_display(du, :moment, cr.Mu_x)
    muy_disp = _to_display(du, :moment, cr.Mu_y)

    # Column height
    h_disp = _to_display(du, :length, cr.height)

    # Tributary area: prefer punching result (exact), fall back to structure accessor
    trib_area_m2 = if !isnothing(cr.punching)
        ustrip(u"m^2", cr.punching.tributary_area)
    else
        try column_tributary_area(struc, col_obj) catch; 0.0 end
    end
    trib_area_disp = _to_display(du, :area, trib_area_m2 * u"m^2")

    # Material-correct governing provisions (steel → AISC 360-16, RC → ACI 318-19),
    # selected from the designed section object — NOT by string position. This is
    # the P0-A safety fix for columns: a steel column must never be cited to a
    # concrete (ACI) clause and vice versa (see `_column_code_clauses` /
    # `ground_check`). Punching stays ACI §22.6 below (concrete slab phenomenon).
    axial_clause, pm_clause = _column_code_clauses(cr)

    checks = Dict{String, Any}[
        Dict{String, Any}(
            "name"         => "axial_compression",
            "code_clause"  => axial_clause,
            "demand"       => _round_val(pu_disp),
            "demand_unit"  => funit,
            "ratio"        => _round_val(cr.axial_ratio),
            "headroom"     => _round_val(1.0 - cr.axial_ratio),
            "governing"    => governing == "axial_compression",
        ),
        Dict{String, Any}(
            "name"         => "pm_interaction",
            "code_clause"  => pm_clause,
            "demand_Mu_x"  => _round_val(mux_disp),
            "demand_Mu_y"  => _round_val(muy_disp),
            "demand_unit"  => munit,
            "ratio"        => _round_val(cr.interaction_ratio),
            "headroom"     => _round_val(1.0 - cr.interaction_ratio),
            "governing"    => governing == "pm_interaction",
        ),
    ]

    # One-way shear is reported only when the column was actually checked.
    # Steel columns leave `shear_clause` empty.
    if !isempty(cr.shear_clause)
        vux = _to_display(du, :force, cr.Vu_x)
        vuy = _to_display(du, :force, cr.Vu_y)
        push!(checks, Dict{String, Any}(
            "name"          => "column_shear",
            "code_clause"   => cr.shear_clause,
            "demand_Vu_x"   => _round_val(vux),
            "demand_Vu_y"   => _round_val(vuy),
            "demand_unit"   => funit,
            "ratio"         => _round_val(cr.shear_ratio),
            "headroom"      => _round_val(1.0 - cr.shear_ratio),
            "governing"     => governing == "column_shear",
            "tie_bar"       => cr.tie_bar_size,
            "tie_spacing"   => _round_val(_to_display(du, :thickness, cr.tie_spacing)),
        ))
    end

    # Add punching check only if the column supports a slab with punching data.
    # AUDIT (P0-B): punching is two-way shear in the CONCRETE SLAB around the
    # column (ACI 318-19 §22.6, computed by the ACI punching check), so it stays
    # ACI even for a steel column — the code family matches the ratio's origin.
    if !isnothing(cr.punching)
        p = cr.punching
        vu_disp  = _to_display(du, :force, p.Vu)
        phvc_disp = _to_display(du, :force, p.φVc)
        push!(checks, Dict{String, Any}(
            "name"          => "punching_shear_col",
            "code_clause"   => "ACI 318-19 §22.6",
            "demand_Vu"     => _round_val(vu_disp),
            "capacity_phiVc" => _round_val(phvc_disp),
            "demand_unit"   => funit,
            "ratio"         => _round_val(p.ratio),
            "headroom"      => _round_val(1.0 - p.ratio),
            "governing"     => governing == "punching_shear_col",
        ))
    end

    # Attach live corpus citations (explanation-layer only; ratios untouched).
    _ground_checks!(checks)

    return Dict{String, Any}(
        "id"             => idx,
        "story"          => col_obj.story,
        "position"       => string(col_obj.position),
        "section"        => cr.section_size,
        "shape"          => string(cr.shape),
        "c1"             => _round_val(c1_disp),
        "c2"             => _round_val(c2_disp),
        "section_unit"   => thick_unit,
        "height"         => _round_val(h_disp),
        "height_unit"    => _length_unit_string(du),
        "rho_g"          => _round_val(cr.rho_g; digits=4),
        "tributary_area" => _round_val(trib_area_disp),
        "area_unit"      => _area_unit_str(du),
        "Pu"             => _round_val(pu_disp),
        "Mu_x"           => _round_val(mux_disp),
        "Mu_y"           => _round_val(muy_disp),
        "axial_ratio"    => _round_val(cr.axial_ratio),
        "interaction_ratio" => _round_val(cr.interaction_ratio),
        "force_unit"     => funit,
        "moment_unit"    => munit,
        "governing_check" => governing,
        "governing_ratio" => _round_val(max_ratio),
        "governing_mode"  => _governing_mode(max_ratio),
        "ok"             => cr.ok,
        "checks"         => checks,
        "levers"         => get(LEVER_MAP, governing, String[]),
        "limit_state_description" => get(LIMIT_STATE_DESCRIPTIONS, governing, ""),
        "ec_kgco2e"      => _round_or_nothing(_col_ec_kgco2e(struc, idx); digits=1),
    )
end

# ─── Collection serializers ───────────────────────────────────────────────────

function _diagnose_columns(design::BuildingDesign, struc::BuildingStructure, du::DisplayUnits)
    isempty(design.columns) && return Dict{String, Any}[]
    [_diagnose_column(idx, design.columns[idx], struc.columns[idx], struc, du)
     for idx in _sorted_indices(design.columns)]
end

