# ==============================================================================
# Punching Shear Strategy & Reinforcement Comparison Report
# ==============================================================================
#
# Compares six punching-shear reinforcement approaches and three resolution
# strategies on a range of square bay sizes, highlighting how each approach
# affects slab thickness, column sizes, reinforcement layout, and material
# quantities.
#
# Reinforcement Types:
#   1. Studs (Generic)     — Analytical π d²/4 headed studs (§11.11.5)
#   2. Studs (INCON)       — INCON ISS catalog headed studs (§11.11.5)
#   3. Studs (Ancon)       — Ancon Shearfix catalog headed studs (§11.11.5)
#   4. Closed Stirrups     — Bent bar stirrups (§11.11.3)
#   5. Shear Caps          — Localized slab thickening (§13.2.6)
#   6. Column Capitals     — Flared column heads (§13.1.2)
#
# Strategies:
#   1. :grow_columns    — Never reinforce; grow columns only
#   2. :reinforce_last  — Grow columns first, reinforce if maxed
#   3. :reinforce_first — Try reinforcement first, grow columns if fails
#
# Usage:
#   julia --project scripts/runners/run_stud_report.jl
# ==============================================================================

using Test
using Printf
using Dates
using Unitful
using Unitful: @u_str
using DataFrames
using CSV
using ProgressMeter
using Logging: NullLogger, with_logger

using StructuralSizer
using StructuralSynthesizer

const SR = StructuralSizer
const SS = StructuralSynthesizer

# ── Utility helpers ──────────────────────────────────────────────────────────

@isdefined(STUD_RESULTS_DIR) || (const STUD_RESULTS_DIR = joinpath(@__DIR__, "results"))

function _stud_output_filename(study_name::String, results_dir::String; ext::String="csv")
    mkpath(results_dir)
    timestamp = Dates.format(now(), "yyyymmdd_HHMMSS")
    joinpath(results_dir, "$(study_name)_$(timestamp).$(ext)")
end

function _stud_print_header(title::String)
    println("=" ^ 60)
    println(title)
    println("Started: $(now())")
    println("=" ^ 60)
    println()
end

function _stud_print_footer(n_created::Int, n_failed::Int, output_file)
    println()
    println("=" ^ 60)
    println("Study Complete!")
    println("=" ^ 60)
    println("Records created: $n_created")
    println("Records failed:  $n_failed")
    println("Output file:     $output_file")
    println()
end

# ==============================================================================
# Reinforcement × Strategy matrix
# ==============================================================================

# Each entry: (key, label, reinf, kind)
# kind ∈ {:studs, :stirrups, :shear_cap, :capital, :none}
const PUNCH_REINFORCEMENTS = [
    (key = :generic,   label = "Studs (Generic)",  reinf = :headed_studs_generic, kind = :studs),
    (key = :incon,     label = "Studs (INCON)",    reinf = :headed_studs_incon,   kind = :studs),
    (key = :ancon,     label = "Studs (Ancon)",    reinf = :headed_studs_ancon,   kind = :studs),
    (key = :stirrups,  label = "Closed Stirrups",  reinf = :closed_stirrups,      kind = :stirrups),
    (key = :shear_cap, label = "Shear Caps",       reinf = :shear_caps,           kind = :shear_cap),
    (key = :capitals,  label = "Col. Capitals",    reinf = :column_capitals,      kind = :capital),
]

# Backward-compatible alias
const STUD_CATALOGS = PUNCH_REINFORCEMENTS

# Stud-only subset (for stud catalog comparison section)
const STUD_ONLY = filter(r -> r.kind === :studs, PUNCH_REINFORCEMENTS)

# Each strategy entry: (key, label, punching_strategy)
const STUD_STRATEGIES = [
    (key = :grow,  label = "Grow Only",       strategy = :grow_columns),
    (key = :last,  label = "Reinforce Last",  strategy = :reinforce_last),
    (key = :first, label = "Reinforce First", strategy = :reinforce_first),
]

# ==============================================================================
# Helpers
# ==============================================================================

"""Scale story height with span (12 ft baseline, grows for long spans)."""
_sc_story_ht(span_ft::Float64) = max(12.0, round(span_ft / 3.0))

"""Max column constraint scaled to span."""
_sc_max_col(span_ft::Float64; ratio::Float64 = 1.1) =
    clamp(round(span_ft * ratio), 36.0, 72.0)

# Steel density for weight estimates (490 lb/ft³)
const _STEEL_DENSITY_LB_IN3 = 490.0 / 1728.0  # lb/in³

# ==============================================================================
# DesignParameters construction
# ==============================================================================

"""
    _make_stud_params(; strategy, reinforcement, ...) -> DesignParameters

Build `DesignParameters` for one reinforcement × strategy combination.
Uses FEA for all runs (most general method, no applicability restrictions).
"""
function _make_stud_params(;
    strategy::Symbol        = :reinforce_last,
    reinforcement::Symbol   = :headed_studs_generic,
    sdl_psf::Float64        = 20.0,
    live_psf::Float64       = 50.0,
    max_col_in::Float64     = 36.0,
    stud_diameter::Float64  = 0.5,     # inches
    stirrup_bar_size::Int   = 4,
    max_iterations::Int     = 150,
)
    fp = SR.FlatPlateOptions(
        method                 = SR.FEA(; pattern_loading = false),
        material               = SR.RC_4000_60,
        punching_strategy      = strategy,
        punching_reinforcement = reinforcement,
        max_column_size        = max_col_in * u"inch",
        stud_diameter          = stud_diameter * u"inch",
        stirrup_bar_size       = stirrup_bar_size,
    )

    DesignParameters(
        loads = GravityLoads(
            floor_LL  = live_psf * psf,
            roof_LL   = live_psf * psf,
            floor_SDL = sdl_psf * psf,
            roof_SDL  = sdl_psf * psf,
        ),
        materials = MaterialOptions(concrete = SR.NWC_4000, rebar = SR.Rebar_60),
        columns   = SR.ConcreteColumnOptions(material = SR.NWC_6000, catalog = :high_capacity),
        floor     = fp,
        max_iterations = max_iterations,
        foundation_options = FoundationParameters(
            soil            = SR.medium_sand,
            options         = SR.FoundationOptions(strategy = :all_spread),
            concrete        = SR.NWC_4000,
            rebar           = SR.Rebar_60,
            pier_width      = 0.35u"m",
            min_depth       = 0.4u"m",
            group_tolerance = 0.15,
        ),
    )
end

# ==============================================================================
# Build & prepare
# ==============================================================================

function _sc_build_skeleton(lx_ft::Float64, ly_ft::Float64,
                            story_ht_ft::Float64, n_bays::Int)
    total_x = lx_ft * n_bays * u"ft"
    total_y = ly_ft * n_bays * u"ft"
    ht      = story_ht_ft * u"ft"
    gen_medium_office(total_x, total_y, ht, n_bays, n_bays, 1)
end

function _sc_set_live_load!(struc, live_psf::Float64)
    ll = uconvert(u"kN/m^2", live_psf * psf)
    for cell in struc.cells
        cell.live_load = ll
    end
    sync_asap!(struc)
end

# ==============================================================================
# Result extraction
# ==============================================================================

"""
    _sc_extract(struc; lx_ft, ly_ft, live_psf, reinf_label, strategy_label,
                reinf_kind, elapsed)

Extract result row from a completed pipeline run, including reinforcement
details for all types and approximate material quantities.
"""
function _sc_extract(struc;
                     lx_ft, ly_ft, live_psf,
                     catalog_label,   # kept for backward compat
                     strategy_label,
                     reinf_kind::Symbol = :studs,
                     elapsed)
    slab = struc.slabs[1]
    r = slab.result
    isnothing(r) && return nothing
    dd = slab.design_details

    # ── Punching ──
    pc    = r.punching_check
    punch = pc.details

    # Helper predicates
    _has(v, f) = hasproperty(v, f) && !isnothing(getproperty(v, f))
    _has_stud(v)    = _has(v, :studs)
    _has_stirrup(v) = _has(v, :stirrups)
    _has_cap(v)     = _has(v, :shear_cap)
    _has_capital(v) = _has(v, :capital)

    # ── Stud details ──
    has_studs      = any(_has_stud(v) for v in values(punch))
    n_stud_cols    = count(_has_stud, values(punch))
    stud_rails_max = 0; stud_per_rail_max = 0; stud_diam_in = 0.0
    catalog_used   = "—"
    stud_s0_in     = 0.0; stud_s_in = 0.0
    for v in values(punch)
        _has_stud(v) || continue
        s = v.studs
        if s.n_rails > stud_rails_max
            stud_rails_max    = s.n_rails
            stud_per_rail_max = s.n_studs_per_rail
            stud_diam_in      = ustrip(u"inch", s.stud_diameter)
            catalog_used      = string(s.catalog_name)
            stud_s0_in        = ustrip(u"inch", s.s0)
            stud_s_in         = ustrip(u"inch", s.s)
        end
    end

    # ── Stirrup details ──
    has_stirrups    = any(_has_stirrup(v) for v in values(punch))
    n_stirrup_cols  = count(_has_stirrup, values(punch))
    stirrup_bar     = 0; stirrup_legs = 0; stirrup_lines = 0
    stirrup_s_in    = 0.0; stirrup_Av_in2 = 0.0
    for v in values(punch)
        _has_stirrup(v) || continue
        st = v.stirrups
        if st.n_legs > stirrup_legs
            stirrup_bar    = st.bar_size
            stirrup_legs   = st.n_legs
            stirrup_lines  = st.n_lines
            stirrup_s_in   = ustrip(u"inch", st.s)
            stirrup_Av_in2 = ustrip(u"inch^2", st.Av_per_line)
        end
    end

    # ── Shear cap details ──
    has_shear_cap   = any(_has_cap(v) for v in values(punch))
    n_cap_cols      = count(_has_cap, values(punch))
    cap_h_in        = 0.0; cap_extent_in = 0.0
    for v in values(punch)
        _has_cap(v) || continue
        sc = v.shear_cap
        if ustrip(u"inch", sc.h_cap) > cap_h_in
            cap_h_in      = ustrip(u"inch", sc.h_cap)
            cap_extent_in = ustrip(u"inch", sc.extent)
        end
    end

    # ── Column capital details ──
    has_capital     = any(_has_capital(v) for v in values(punch))
    n_capital_cols  = count(_has_capital, values(punch))
    capital_h_in    = 0.0; capital_c1_eff_in = 0.0; capital_c2_eff_in = 0.0
    for v in values(punch)
        _has_capital(v) || continue
        cc = v.capital
        if ustrip(u"inch", cc.h_cap) > capital_h_in
            capital_h_in      = ustrip(u"inch", cc.h_cap)
            capital_c1_eff_in = ustrip(u"inch", cc.c1_eff)
            capital_c2_eff_in = ustrip(u"inch", cc.c2_eff)
        end
    end

    vu_max_psi = maximum(ustrip(u"psi", v.vu) for v in values(punch); init = 0.0)

    # ── Reinforcement ──
    As_cs = sum(sr.As_provided for sr in r.column_strip_reinf; init = 0.0u"inch^2")
    As_ms = sum(sr.As_provided for sr in r.middle_strip_reinf; init = 0.0u"inch^2")
    As_total = As_cs + As_ms

    # ── Columns ──
    cols_in = [ustrip(u"inch", c.c1) for c in struc.columns]

    # ── Deflection ──
    dc = r.deflection_check

    # ── Material quantities (approximate, per bay) ──
    bay_area_ft2 = lx_ft * ly_ft
    bay_area_in2 = bay_area_ft2 * 144.0
    h_in = ustrip(u"inch", r.thickness)

    # Slab concrete: h × bay_area (in³ → ft³)
    conc_slab_ft3 = h_in * bay_area_in2 / 1728.0

    # Slab rebar: As_total is per strip width; approximate as total for bay
    # As_total × span_length × steel_density → lb (rough per-bay estimate)
    # This is a rough estimate — the actual As varies per strip
    As_total_in2 = ustrip(u"inch^2", As_total)
    avg_span_in = (lx_ft + ly_ft) / 2.0 * 12.0
    rebar_lb = As_total_in2 * avg_span_in * _STEEL_DENSITY_LB_IN3

    # Extra concrete from shear caps (per column that has one)
    extra_conc_cap_ft3 = 0.0
    if has_shear_cap
        for v in values(punch)
            _has_cap(v) || continue
            sc = v.shear_cap
            h_cap = ustrip(u"inch", sc.h_cap)
            ext   = ustrip(u"inch", sc.extent)
            # Cap footprint: (c1 + 2·extent) × (c2 + 2·extent) × h_cap
            # Use average column dims as proxy
            c_avg = (cols_in[1] + (length(cols_in) > 1 ? cols_in[end] : cols_in[1])) / 2.0
            cap_vol_in3 = (c_avg + 2*ext) * (c_avg + 2*ext) * h_cap
            extra_conc_cap_ft3 += cap_vol_in3 / 1728.0
        end
    end

    # Extra concrete from column capitals (per column that has one)
    extra_conc_capital_ft3 = 0.0
    if has_capital
        for v in values(punch)
            _has_capital(v) || continue
            cc = v.capital
            h_cap = ustrip(u"inch", cc.h_cap)
            c1e   = ustrip(u"inch", cc.c1_eff)
            c2e   = ustrip(u"inch", cc.c2_eff)
            # Approximate capital as truncated pyramid; use average cross-section
            c_orig = (cols_in[1] + (length(cols_in) > 1 ? cols_in[end] : cols_in[1])) / 2.0
            A_top = c1e * c2e
            A_bot = c_orig * c_orig
            vol_in3 = h_cap * (A_top + A_bot + sqrt(A_top * A_bot)) / 3.0
            extra_conc_capital_ft3 += vol_in3 / 1728.0
        end
    end

    # Extra steel from studs (per column that has studs)
    extra_steel_stud_lb = 0.0
    if has_studs
        for v in values(punch)
            _has_stud(v) || continue
            s = v.studs
            Av = ustrip(u"inch^2", s.Av_per_line)
            n_studs_total = s.n_rails * s.n_studs_per_rail
            # Each stud: length ≈ d (effective depth) — approximate
            stud_len_in = h_in - 2.0  # rough: h minus covers
            extra_steel_stud_lb += n_studs_total * Av / s.n_rails * stud_len_in * _STEEL_DENSITY_LB_IN3
        end
    end

    # Extra steel from stirrups (per column that has stirrups)
    extra_steel_stirrup_lb = 0.0
    if has_stirrups
        for v in values(punch)
            _has_stirrup(v) || continue
            st = v.stirrups
            Av_line = ustrip(u"inch^2", st.Av_per_line)
            # Each line of stirrups: total bar length ≈ perimeter of critical section
            # Approximate perimeter as 4 × (c_avg + d)
            c_avg = (cols_in[1] + (length(cols_in) > 1 ? cols_in[end] : cols_in[1])) / 2.0
            d_approx = h_in - 2.0
            perim_in = 4.0 * (c_avg + d_approx)
            # n_lines of stirrups, each with n_legs, bar length ≈ perim + hooks
            Ab = ustrip(u"inch^2", SR.bar_area(st.bar_size))
            bar_len_per_stirrup = perim_in / (st.n_legs / 2)  # each stirrup has 2 legs
            n_stirrups_per_line = st.n_legs ÷ 2
            total_bar_len = n_stirrups_per_line * bar_len_per_stirrup * st.n_lines
            extra_steel_stirrup_lb += Ab * total_bar_len * _STEEL_DENSITY_LB_IN3
        end
    end

    # Determine the active reinforcement description
    reinf_type = if has_studs;     "studs"
    elseif has_stirrups;           "stirrups"
    elseif has_shear_cap;          "shear_cap"
    elseif has_capital;            "capital"
    else;                          "none"
    end

    extra_conc_ft3  = extra_conc_cap_ft3 + extra_conc_capital_ft3
    extra_steel_lb  = extra_steel_stud_lb + extra_steel_stirrup_lb

    return (
        lx_ft             = lx_ft,
        ly_ft             = ly_ft,
        live_psf          = live_psf,
        catalog           = catalog_label,
        strategy          = strategy_label,
        h_in              = h_in,
        sw_psf            = ustrip(psf, r.self_weight),
        punch_ratio       = round(pc.max_ratio; digits = 3),
        punch_ok          = pc.ok,
        vu_max_psi        = round(vu_max_psi; digits = 1),
        # ── Stud fields ──
        has_studs         = has_studs,
        n_stud_cols       = n_stud_cols,
        stud_rails        = stud_rails_max,
        studs_per_rail    = stud_per_rail_max,
        stud_diam_in      = round(stud_diam_in; digits = 3),
        stud_s0_in        = round(stud_s0_in; digits = 2),
        stud_s_in         = round(stud_s_in; digits = 2),
        catalog_used      = catalog_used,
        # ── Stirrup fields ──
        has_stirrups      = has_stirrups,
        n_stirrup_cols    = n_stirrup_cols,
        stirrup_bar       = stirrup_bar,
        stirrup_legs      = stirrup_legs,
        stirrup_lines     = stirrup_lines,
        stirrup_s_in      = round(stirrup_s_in; digits = 2),
        stirrup_Av_in2    = round(stirrup_Av_in2; digits = 3),
        # ── Shear cap fields ──
        has_shear_cap     = has_shear_cap,
        n_cap_cols        = n_cap_cols,
        cap_h_in          = round(cap_h_in; digits = 2),
        cap_extent_in     = round(cap_extent_in; digits = 2),
        # ── Column capital fields ──
        has_capital       = has_capital,
        n_capital_cols    = n_capital_cols,
        capital_h_in      = round(capital_h_in; digits = 2),
        capital_c1_eff_in = round(capital_c1_eff_in; digits = 1),
        capital_c2_eff_in = round(capital_c2_eff_in; digits = 1),
        # ── Common ──
        reinf_type        = reinf_type,
        defl_ratio        = round(dc.ratio; digits = 3),
        defl_ok           = dc.ok,
        col_min_in        = minimum(cols_in),
        col_max_in        = maximum(cols_in),
        As_total_in2      = round(As_total_in2; digits = 2),
        # ── Material quantities (per bay, approximate) ──
        conc_slab_ft3     = round(conc_slab_ft3; digits = 1),
        extra_conc_ft3    = round(extra_conc_ft3; digits = 2),
        rebar_lb          = round(rebar_lb; digits = 1),
        extra_steel_lb    = round(extra_steel_lb; digits = 2),
        runtime_s         = round(elapsed; digits = 2),
        converged         = true,
        failure_reason    = "",
    )
end

"""Blank failure row matching the success schema."""
function _sc_failure_row(; lx_ft, ly_ft, live_psf,
                           catalog_label, strategy_label,
                           elapsed, reason = "")
    return (
        lx_ft             = lx_ft,
        ly_ft             = ly_ft,
        live_psf          = live_psf,
        catalog           = catalog_label,
        strategy          = strategy_label,
        h_in              = NaN,
        sw_psf            = NaN,
        punch_ratio       = NaN,
        punch_ok          = false,
        vu_max_psi        = NaN,
        has_studs         = false,
        n_stud_cols       = 0,
        stud_rails        = 0,
        studs_per_rail    = 0,
        stud_diam_in      = NaN,
        stud_s0_in        = NaN,
        stud_s_in         = NaN,
        catalog_used      = "—",
        has_stirrups      = false,
        n_stirrup_cols    = 0,
        stirrup_bar       = 0,
        stirrup_legs      = 0,
        stirrup_lines     = 0,
        stirrup_s_in      = NaN,
        stirrup_Av_in2    = NaN,
        has_shear_cap     = false,
        n_cap_cols        = 0,
        cap_h_in          = NaN,
        cap_extent_in     = NaN,
        has_capital       = false,
        n_capital_cols    = 0,
        capital_h_in      = NaN,
        capital_c1_eff_in = NaN,
        capital_c2_eff_in = NaN,
        reinf_type        = "none",
        defl_ratio        = NaN,
        defl_ok           = false,
        col_min_in        = NaN,
        col_max_in        = NaN,
        As_total_in2      = NaN,
        conc_slab_ft3     = NaN,
        extra_conc_ft3    = NaN,
        rebar_lb          = NaN,
        extra_steel_lb    = NaN,
        runtime_s         = round(elapsed; digits = 2),
        converged         = false,
        failure_reason    = reason,
    )
end

# ==============================================================================
# Run one combination
# ==============================================================================

"""Run the full pipeline for one reinforcement × strategy on a prepared structure."""
function _sc_run(struc, params;
                 lx_ft, ly_ft, live_psf,
                 catalog_label, strategy_label,
                 reinf_kind::Symbol = :studs)
    restore!(struc)
    _sc_set_live_load!(struc, live_psf)

    t0 = time()
    try
        with_logger(NullLogger()) do
            stages = build_pipeline(params)
            for (i, stage) in enumerate(stages)
                stage.fn(struc)
                stage.needs_sync && sync_asap!(struc; params)

                # Bail early on non-convergence after slab stage
                if i == 1
                    dd = struc.slabs[1].design_details
                    if !isnothing(dd) && hasproperty(dd, :converged) && !dd.converged
                        break
                    end
                end
            end
        end
    catch e
        elapsed = time() - t0
        reason  = sprint(showerror, e)
        @warn "$(catalog_label)/$(strategy_label) failed ($(round(elapsed; digits=1))s)" lx=lx_ft ly=ly_ft err=reason
        return _sc_failure_row(; lx_ft, ly_ft, live_psf,
                                 catalog_label, strategy_label,
                                 elapsed, reason)
    end
    elapsed = time() - t0

    # Check non-convergence
    dd = struc.slabs[1].design_details
    if !isnothing(dd) && hasproperty(dd, :converged) && !dd.converged
        reason = hasproperty(dd, :failing_check) ? dd.failing_check : "non_convergence"
        return _sc_failure_row(; lx_ft, ly_ft, live_psf,
                                 catalog_label, strategy_label,
                                 elapsed, reason)
    end

    row = _sc_extract(struc; lx_ft, ly_ft, live_psf,
                      catalog_label, strategy_label,
                      reinf_kind, elapsed)
    isnothing(row) && return _sc_failure_row(; lx_ft, ly_ft, live_psf,
                                               catalog_label, strategy_label,
                                               elapsed, reason = "no_result")
    return row
end

# ==============================================================================
# Reinforcement detail string (compact, for tables)
# ==============================================================================

"""Return a short description of the active reinforcement for a result row."""
function _reinf_summary(row)
    if row.has_studs
        return @sprintf("%dR×%d", row.stud_rails, row.studs_per_rail)
    elseif row.has_stirrups
        return @sprintf("#%d %dL×%d", row.stirrup_bar, row.stirrup_legs, row.stirrup_lines)
    elseif row.has_shear_cap
        return @sprintf("cap %.1f\"", row.cap_h_in)
    elseif row.has_capital
        return @sprintf("cap %.1f\"", row.capital_h_in)
    else
        return "  --"
    end
end

# ==============================================================================
# Report generation (saved .txt file)
# ==============================================================================

"""
    stud_catalog_report(; spans, live_loads, n_bays, sdl, report_dir)

Run all reinforcement × strategy × span × live-load combinations and write a
formatted text report to `report_dir/stud_catalog_report.txt`.

The report includes:
- Strategy comparison (all strategies, Generic studs)
- Stud catalog comparison (all stud catalogs, reinforce_first)
- Reinforcement type comparison (all 6 types, reinforce_first)
- Material quantities table
- Full detail table
"""
function stud_catalog_report(;
    spans::Vector{Float64}      = [20.0, 24.0, 28.0, 32.0, 36.0, 40.0],
    live_loads::Vector{Float64}  = [50.0, 150.0],
    n_bays::Int                  = 3,
    sdl::Float64                 = 20.0,
    report_dir::String           = joinpath(@__DIR__, "..", "reports"),
)
    mkpath(report_dir)
    report_path = joinpath(report_dir, "stud_catalog_report.txt")

    # ── Collect all results ──────────────────────────────────────────────
    results = Dict{Tuple{Float64,Float64,String,String}, NamedTuple}()
    n_total = length(spans) * length(live_loads) * length(PUNCH_REINFORCEMENTS) * length(STUD_STRATEGIES)
    p = Progress(n_total; desc = "Stud report: ")

    for span in spans, ll in live_loads
        ht      = _sc_story_ht(span)
        max_col = _sc_max_col(span)

        for rtype in PUNCH_REINFORCEMENTS, strat in STUD_STRATEGIES
            local row
            try
                params = _make_stud_params(;
                    strategy      = strat.strategy,
                    reinforcement = rtype.reinf,
                    sdl_psf       = sdl,
                    live_psf      = ll,
                    max_col_in    = max_col,
                )
                skel  = _sc_build_skeleton(span, span, ht, n_bays)
                struc = BuildingStructure(skel)
                prepare!(struc, params)
                row = _sc_run(struc, params;
                              lx_ft = span, ly_ft = span, live_psf = ll,
                              catalog_label  = rtype.label,
                              strategy_label = strat.label,
                              reinf_kind     = rtype.kind)
            catch e
                row = _sc_failure_row(; lx_ft = span, ly_ft = span, live_psf = ll,
                                        catalog_label = rtype.label,
                                        strategy_label = strat.label,
                                        elapsed = 0.0,
                                        reason = sprint(showerror, e))
            end
            results[(span, ll, rtype.label, strat.label)] = row
            next!(p)
        end
    end

    # ── Write report ─────────────────────────────────────────────────────
    open(report_path, "w") do io
        W = 90
        dline = "═"^W
        hline = "─"^W

        wr(s::String) = write(io, s)
        pl(s::String = "") = println(io, s)

        pl()
        pl(dline)
        pl("  PUNCHING SHEAR STRATEGY & REINFORCEMENT COMPARISON REPORT")
        pl(dline)
        pl(@sprintf("  Generated: %s", Dates.format(now(), "yyyy-mm-dd HH:MM")))
        pl("  Ref: ACI 318-11 §11.11 (Shear Reinforcement), §13.1.2, §13.2.6")
        pl()
        pl("  $hline")
        pl("  INPUT SUMMARY")
        pl("  $hline")
        pl(@sprintf("    Grid:         %d × %d bays (single story)", n_bays, n_bays))
        pl(@sprintf("    Spans:        %s ft", join([@sprintf("%.0f", s) for s in spans], ", ")))
        pl(@sprintf("    Live loads:   %s psf", join([@sprintf("%.0f", l) for l in live_loads], ", ")))
        pl(@sprintf("    SDL:          %.0f psf", sdl))
        pl("    Materials:    f'c=4000 psi, fy=60 ksi, fyt=51 ksi (studs/stirrups)")
        pl("    Stud dia:     1/2\" (default)")
        pl("    Stirrup bar:  #4 (default)")
        pl("    Method:       FEA (shell model, no pattern loading)")
        pl()
        pl("  Reinforcement Types:")
        for rtype in PUNCH_REINFORCEMENTS
            pl(@sprintf("    %-18s  (%s)", rtype.label, string(rtype.reinf)))
        end
        pl()
        pl("  Strategies:")
        for strat in STUD_STRATEGIES
            pl(@sprintf("    %-18s  (%s)", strat.label, string(strat.strategy)))
        end
        pl()

        # ── Per-LL sections ──────────────────────────────────────────────
        for ll in live_loads
            pl(dline)
            pl(@sprintf("  RESULTS — LL = %.0f psf", ll))
            pl(dline)

            # ──────────────────────────────────────────────────────────────
            # SECTION 1: Strategy comparison (Generic studs)
            # ──────────────────────────────────────────────────────────────
            pl()
            pl("  $hline")
            pl(@sprintf("  STRATEGY COMPARISON (Generic studs, LL = %.0f psf)", ll))
            pl("  $hline")
            wr(@sprintf("    %-14s", "Span"))
            for strat in STUD_STRATEGIES
                wr(@sprintf(" | %-22s", strat.label))
            end
            pl()
            wr(@sprintf("    %-14s", ""))
            for _ in STUD_STRATEGIES
                wr(@sprintf(" | %5s %5s %8s", "h\"", "col\"", "reinf"))
            end
            pl()
            pl("    $hline")

            for span in spans
                wr(@sprintf("    %-14s", @sprintf("%.0f ft × %.0f ft", span, span)))
                for strat in STUD_STRATEGIES
                    r = results[(span, ll, "Studs (Generic)", strat.label)]
                    if r.converged
                        h_s   = @sprintf("%4.1f", r.h_in)
                        col_s = @sprintf("%4.0f", r.col_max_in)
                        rn_s  = _reinf_summary(r)
                        wr(@sprintf(" | %5s %5s %8s", h_s, col_s, rn_s))
                    else
                        wr(@sprintf(" | %22s", "FAIL"))
                    end
                end
                pl()
            end
            pl()

            # ──────────────────────────────────────────────────────────────
            # SECTION 2: Stud catalog comparison (reinforce_first)
            # ──────────────────────────────────────────────────────────────
            pl("  $hline")
            pl(@sprintf("  STUD CATALOG COMPARISON (reinforce_first, LL = %.0f psf)", ll))
            pl("  $hline")
            wr(@sprintf("    %-14s", "Span"))
            for cat in STUD_ONLY
                wr(@sprintf(" | %-22s", cat.label))
            end
            pl()
            wr(@sprintf("    %-14s", ""))
            for _ in STUD_ONLY
                wr(@sprintf(" | %5s %5s %8s", "h\"", "col\"", "reinf"))
            end
            pl()
            pl("    $hline")

            for span in spans
                wr(@sprintf("    %-14s", @sprintf("%.0f ft × %.0f ft", span, span)))
                for cat in STUD_ONLY
                    r = results[(span, ll, cat.label, "Reinforce First")]
                    if r.converged
                        h_s   = @sprintf("%4.1f", r.h_in)
                        col_s = @sprintf("%4.0f", r.col_max_in)
                        rn_s  = _reinf_summary(r)
                        wr(@sprintf(" | %5s %5s %8s", h_s, col_s, rn_s))
                    else
                        wr(@sprintf(" | %22s", "FAIL"))
                    end
                end
                pl()
            end
            pl()

            # ──────────────────────────────────────────────────────────────
            # SECTION 3: Reinforcement type comparison (reinforce_first)
            # ──────────────────────────────────────────────────────────────
            pl("  $hline")
            pl(@sprintf("  REINFORCEMENT TYPE COMPARISON (reinforce_first, LL = %.0f psf)", ll))
            pl("  $hline")
            pl("    Shows all six punching shear approaches with the reinforce_first strategy.")
            pl()
            wr(@sprintf("    %-14s", "Span"))
            for rtype in PUNCH_REINFORCEMENTS
                wr(@sprintf(" | %-18s", rtype.label))
            end
            pl()
            wr(@sprintf("    %-14s", ""))
            for _ in PUNCH_REINFORCEMENTS
                wr(@sprintf(" | %5s %4s %6s", "h\"", "col", "reinf"))
            end
            pl()
            pl("    $hline")

            for span in spans
                wr(@sprintf("    %-14s", @sprintf("%.0f × %.0f ft", span, span)))
                for rtype in PUNCH_REINFORCEMENTS
                    r = results[(span, ll, rtype.label, "Reinforce First")]
                    if r.converged
                        h_s   = @sprintf("%4.1f", r.h_in)
                        col_s = @sprintf("%3.0f\"", r.col_max_in)
                        rn_s  = _reinf_summary(r)
                        wr(@sprintf(" | %5s %4s %6s", h_s, col_s, rn_s))
                    else
                        wr(@sprintf(" | %18s", "FAIL"))
                    end
                end
                pl()
            end
            pl()

            # ──────────────────────────────────────────────────────────────
            # SECTION 4: Material quantities (reinforce_first, per bay)
            # ──────────────────────────────────────────────────────────────
            pl("  $hline")
            pl(@sprintf("  MATERIAL QUANTITIES (reinforce_first, LL = %.0f psf, per bay)", ll))
            pl("  $hline")
            pl("    Conc = slab concrete (ft³/bay), +Conc = extra from caps/capitals (ft³)")
            pl("    Rebar = slab flexural rebar (lb/bay), +Steel = extra from studs/stirrups (lb)")
            pl()
            wr(@sprintf("    %-14s %-18s | %7s | %6s | %7s | %7s | %5s",
               "Span", "Reinf. Type", "Conc", "+Conc", "Rebar", "+Steel", "h\""))
            pl()
            pl("    $hline")

            for span in spans
                first_in_span = true
                for rtype in PUNCH_REINFORCEMENTS
                    r = results[(span, ll, rtype.label, "Reinforce First")]
                    span_str = first_in_span ? @sprintf("%-14s", @sprintf("%.0f × %.0f ft", span, span)) : "              "
                    first_in_span = false

                    if r.converged
                        pl(@sprintf("    %s %-18s | %7.1f | %6.2f | %7.1f | %7.2f | %5.1f",
                           span_str, rtype.label,
                           r.conc_slab_ft3, r.extra_conc_ft3,
                           r.rebar_lb, r.extra_steel_lb,
                           r.h_in))
                    else
                        pl(@sprintf("    %s %-18s |    FAIL |   --   |    FAIL |   --   |  --",
                           span_str, rtype.label))
                    end
                end
                pl("    " * "·"^(length(hline)-4))
            end
            pl()

            # ──────────────────────────────────────────────────────────────
            # SECTION 5: Full detail table
            # ──────────────────────────────────────────────────────────────
            pl("  $hline")
            pl(@sprintf("  FULL DETAIL (LL = %.0f psf)", ll))
            pl("  $hline")
            pl(@sprintf("    %-10s %-18s %-18s | %5s | %5s | %6s | %8s | %-10s | %5s | %7s | %7s",
               "Span", "Reinf. Type", "Strategy", "h\"", "Punch", "vu_max", "Reinf.", "Columns", "Defl",
               "Conc", "+Steel"))
            pl("    $hline")

            for span in spans
                first_in_span = true
                for rtype in PUNCH_REINFORCEMENTS, strat in STUD_STRATEGIES
                    r = results[(span, ll, rtype.label, strat.label)]
                    span_str = first_in_span ? @sprintf("%-10s", @sprintf("%.0f ft", span)) : "          "
                    first_in_span = false

                    if r.converged
                        rn_s = _reinf_summary(r)
                        col_str = r.col_min_in ≈ r.col_max_in ?
                            @sprintf("%.0f\"", r.col_min_in) :
                            @sprintf("%.0f\"–%.0f\"", r.col_min_in, r.col_max_in)
                        pl(@sprintf("    %s %-18s %-18s | %5.1f | %5.3f | %6.1f | %8s | %-10s | %5.3f | %7.1f | %7.2f",
                           span_str, rtype.label, strat.label,
                           r.h_in, r.punch_ratio, r.vu_max_psi,
                           rn_s, col_str, r.defl_ratio,
                           r.conc_slab_ft3, r.extra_steel_lb))
                    else
                        reason = isempty(r.failure_reason) ? "non-convergence" :
                                 (length(r.failure_reason) > 40 ? r.failure_reason[1:40]*"..." : r.failure_reason)
                        pl(@sprintf("    %s %-18s %-18s |  FAIL -- %s",
                           span_str, rtype.label, strat.label, reason))
                    end
                end
                pl("    " * "·"^(length(hline)-4))
            end
            pl()
        end

        # ── Summary / observations ───────────────────────────────────────
        pl(dline)
        pl("  OBSERVATIONS")
        pl(dline)
        pl()
        pl("  1. STRATEGY EFFECTS")
        pl("     * :grow_columns — Largest final column sizes; no reinforcement placed.")
        pl("       Fails if columns hit max_column_size before punching is resolved.")
        pl("     * :reinforce_last — Same as grow_columns until columns max out,")
        pl("       then deploys reinforcement. Balanced approach for practical designs.")
        pl("     * :reinforce_first — Smallest columns (reinforcement absorbs shear first).")
        pl("       May require more reinforcement but keeps columns architecturally slim.")
        pl()
        pl("  2. HEADED SHEAR STUDS (ACI 318-11 §11.11.5)")
        pl("     * Generic — Analytical π d²/4 areas; baseline reference.")
        pl("     * INCON ISS — Published Av values slightly larger than π d²/4.")
        pl("     * Ancon Shearfix — Metric sizes; 14mm stud for 1/2\" request → larger area.")
        pl("     * Max Vn = 8√f'c·b0·d; concrete contribution capped at 3λ√f'c.")
        pl("     * Spacing: s ≤ 0.75d (low shear) or s ≤ 0.5d (high shear > 6φ√f'c).")
        pl()
        pl("  3. CLOSED STIRRUPS (ACI 318-11 §11.11.3)")
        pl("     * Concrete contribution capped at 2λ√f'c (lower than studs' 3λ√f'c).")
        pl("     * Max Vn = 6√f'c·b0·d (lower than studs' 8√f'c).")
        pl("     * Requires d ≥ 6 in. AND d ≥ 16·d_b (limits thin slab applicability).")
        pl("     * Spacing: s ≤ d/2 (tighter than studs' 0.75d at low shear).")
        pl("     * Practical for moderate shear; anchorage difficult in thin slabs.")
        pl()
        pl("  4. SHEAR CAPS (ACI 318-11 §13.2.6)")
        pl("     * Localized slab thickening below the slab at the column.")
        pl("     * Increases effective depth d and moves critical section outward.")
        pl("     * No additional steel required — solution is purely geometric (concrete).")
        pl("     * Adds extra concrete volume at each column location.")
        pl("     * Minimum extent from column face ≥ cap projection depth.")
        pl()
        pl("  5. COLUMN CAPITALS (ACI 318-11 §13.1.2)")
        pl("     * Flared enlargement at column head; 45° rule for effective dimensions.")
        pl("     * Effective column: c_eff = c + 2·h_cap (one h_cap per side).")
        pl("     * Does NOT increase slab d — only enlarges effective support area.")
        pl("     * Adds extra concrete volume (truncated pyramid at each column).")
        pl("     * Architectural impact: visible flared column heads.")
        pl()
        pl("  6. MATERIAL QUANTITY NOTES")
        pl("     * 'Conc' = slab concrete per bay (h × bay_area). Dominates total volume.")
        pl("     * '+Conc' = additional concrete from shear caps or column capitals.")
        pl("     * 'Rebar' = approximate slab flexural rebar per bay.")
        pl("     * '+Steel' = additional steel from shear studs or stirrups.")
        pl("     * Quantities are approximate — actual values depend on full detailing.")
        pl("     * Slab thickness (h) is the primary driver of concrete quantity;")
        pl("       reinforcement type mainly affects the steel/concrete additions.")
        pl()

        pl(dline)
        pl("  END OF REPORT")
        pl(dline)
    end

    println("\n  Report saved: $report_path")
    return report_path
end

# ==============================================================================
# @testset — Quick validation (single span, all reinforcement × strategy combos)
# ==============================================================================

@testset "Punching Shear Strategy & Reinforcement Comparison" begin
    span = 24.0
    ll   = 50.0
    ht   = _sc_story_ht(span)
    max_col = _sc_max_col(span)

    # Test a representative subset to keep test time reasonable:
    # - All strategies with Generic studs
    # - All reinforcement types with reinforce_first
    test_combos = [
        # Strategy sweep (Generic studs)
        (rtype = PUNCH_REINFORCEMENTS[1], strat = STUD_STRATEGIES[1]),  # Generic / Grow
        (rtype = PUNCH_REINFORCEMENTS[1], strat = STUD_STRATEGIES[2]),  # Generic / Last
        (rtype = PUNCH_REINFORCEMENTS[1], strat = STUD_STRATEGIES[3]),  # Generic / First
        # Reinforcement type sweep (reinforce_first)
        (rtype = PUNCH_REINFORCEMENTS[2], strat = STUD_STRATEGIES[3]),  # INCON / First
        (rtype = PUNCH_REINFORCEMENTS[3], strat = STUD_STRATEGIES[3]),  # Ancon / First
        (rtype = PUNCH_REINFORCEMENTS[4], strat = STUD_STRATEGIES[3]),  # Stirrups / First
        (rtype = PUNCH_REINFORCEMENTS[5], strat = STUD_STRATEGIES[3]),  # Shear Caps / First
        (rtype = PUNCH_REINFORCEMENTS[6], strat = STUD_STRATEGIES[3]),  # Capitals / First
    ]

    for combo in test_combos
        rtype = combo.rtype
        strat = combo.strat
        @testset "$(rtype.label) / $(strat.label)" begin
            params = _make_stud_params(;
                strategy      = strat.strategy,
                reinforcement = rtype.reinf,
                sdl_psf       = 20.0,
                live_psf      = ll,
                max_col_in    = max_col,
            )
            skel  = _sc_build_skeleton(span, span, ht, 3)
            struc = BuildingStructure(skel)
            prepare!(struc, params)

            row = _sc_run(struc, params;
                          lx_ft = span, ly_ft = span, live_psf = ll,
                          catalog_label  = rtype.label,
                          strategy_label = strat.label,
                          reinf_kind     = rtype.kind)

            @test row.converged
            @test row.h_in > 0
            @test row.punch_ratio > 0
            @test row.punch_ratio ≤ 1.0
            @test row.defl_ratio > 0
            @test row.defl_ratio ≤ 1.0
            # Material quantities should be positive for converged results
            @test row.conc_slab_ft3 > 0
            @test row.rebar_lb > 0
        end
    end
end
