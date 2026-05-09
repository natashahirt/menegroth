# ==============================================================================
# Flat Plate Analysis Method Comparison Study
# ==============================================================================
#
# Compares all five flat plate sizing methods on square & rectangular bays:
#   1. MDDM        — Modified DDM (simplified 0.65/0.35 coefficients)
#   2. DDM          — Full ACI 318 Table 8.10 coefficients
#   3. EFM (HC)     — Equivalent Frame, Hardy Cross moment distribution
#   4. EFM (ASAP)   — Equivalent Frame, ASAP FEM stiffness solver
#   5. FEA          — 2D shell model with adaptive mesh
#
# Uses `build_pipeline` from the design API for the full pipeline:
#   prepare! → [size_slabs! → reconcile_columns! → size_foundations!]
# with `sync_asap!` between each stage automatically.
#
# Snapshot/restore efficiently reuses each geometry across methods and
# live-load variations.
#
# Usage (from Julia REPL at project root):
#
#   include("src/flat_plate_methods/flat_plate_method_comparison.jl")
#
#   df = sweep()                          # full factorial
#   df = sweep(spans=[20, 24])            # custom span subset
#   df = dual_heatmap_sweep()             # Lx × Ly heatmap
#
#   compare()                             # quick table for default 20 ft bay
#   compare(span=24.0, ll=80.0)           # custom quick table
#
# ==============================================================================

include(joinpath(@__DIR__, "..", "init.jl"))

using Printf
using Logging: NullLogger, with_logger

const SR = StructuralSizer
const SS = StructuralSynthesizer

@isdefined(FP_RESULTS_DIR) || (const FP_RESULTS_DIR = joinpath(@__DIR__, "results"))

# ==============================================================================
# Method definitions
# ==============================================================================

# NOTE: pattern_loading=false for EFM and FEA to enable fair comparison with DDM's
# fixed coefficients. Pattern loading can reduce EFM moments significantly,
# which causes EFM to converge to thinner slabs (lower self-weight → lower M0).
const ALL_METHODS = [
    (key=:rot,    name="ACI Min",     method=SR.RuleOfThumb()),
    (key=:mddm,   name="MDDM",       method=SR.DDM(:simplified)),
    (key=:ddm,    name="DDM (Full)",  method=SR.DDM(:full)),
    (key=:efm_hc, name="EFM (HC)",    method=SR.EFM(solver=:hardy_cross, pattern_loading=false)),
    (key=:efm,    name="EFM (ASAP)",  method=SR.EFM(solver=:asap, pattern_loading=false)),
    (key=:efm_kc, name="EFM (Kc)",    method=SR.EFM(solver=:asap, column_stiffness=:Kc, pattern_loading=false)),
    (key=:fea,    name="FEA (frame)", method=SR.FEA(; pattern_loading=false, design_approach=:frame)),
    (key=:fea_d,  name="FEA (strip)", method=SR.FEA(; pattern_loading=false, design_approach=:strip)),
]

# Full factorial of EFM options for side-by-side comparison:
#
#   Solver        × Column Stiffness × Cracked Columns
#   ─────────────   ─────────────────   ────────────────
#   :hardy_cross    :Kec (standard)     false (gross Ig)
#   :asap           :Kc  (raw)          true  (0.70 Ig)
#
# Note: cracked_columns only affects :asap stubs (Hardy Cross always uses gross Ig).
const ALL_EFM = [
    # ── Hardy Cross ──────────────────────────────────────────────────────────
    (key=:hc_kec,         name="HC  Kec",          method=SR.EFM(solver=:hardy_cross, column_stiffness=:Kec, pattern_loading=false)),
    (key=:hc_kc,          name="HC  Kc",           method=SR.EFM(solver=:hardy_cross, column_stiffness=:Kc,  pattern_loading=false)),
    # ── ASAP (gross Ig) ─────────────────────────────────────────────────────
    (key=:asap_kec,       name="ASAP Kec",         method=SR.EFM(solver=:asap, column_stiffness=:Kec, pattern_loading=false)),
    (key=:asap_kc,        name="ASAP Kc",          method=SR.EFM(solver=:asap, column_stiffness=:Kc,  pattern_loading=false)),
    # ── ASAP (cracked 0.70 Ig) ──────────────────────────────────────────────
    (key=:asap_kec_crack, name="ASAP Kec cracked",  method=SR.EFM(solver=:asap, column_stiffness=:Kec, cracked_columns=true, pattern_loading=false)),
    (key=:asap_kc_crack,  name="ASAP Kc  cracked",  method=SR.EFM(solver=:asap, column_stiffness=:Kc,  cracked_columns=true, pattern_loading=false)),
]

# ==============================================================================
# Adaptive helpers
# ==============================================================================

"""Scale story height with span (12 ft baseline, grows for long spans)."""
_adaptive_story_ht(span_ft::Float64) = max(12.0, round(span_ft / 3.0))

"""Max column constraint scaled to span — limits slab-loop column growth.
`ratio` is the span-to-column multiplier (default 1.1 → 36″–60″ range)."""
_adaptive_max_col(span_ft::Float64; ratio::Float64 = 1.1) =
    clamp(round(span_ft * ratio), 36.0, 60.0)

# ==============================================================================
# DesignParameters construction
# ==============================================================================

"""
    _make_params(; method, floor_type, sdl_psf, live_psf, max_col_in, ...)

Build `DesignParameters` for one sweep run.  The `method` kwarg selects
which analysis method the pipeline's `size_slabs!` stage will use. 

Pipeline stages (handled automatically by `build_pipeline`):
  1. size_slabs!  (with selected method)
  2. reconcile_columns!  (flat plate / flat slab)
  3. size_foundations!  (spread footings on medium sand)
"""
function _make_params(;
    method::SR.FlatPlateAnalysisMethod = SR.DDM(),
    floor_type::Symbol  = :flat_plate,
    sdl_psf::Float64    = 20.0,
    live_psf::Float64   = 50.0,
    max_col_in::Float64 = 36.0,
    shear_studs::Symbol = :if_needed,
    min_h               = nothing,
    max_iterations::Int = 150,
    deflection_limit::Symbol = :L_360,
    column_strategy::Symbol = :catalog,
)
    fp = SR.FlatPlateOptions(
        method           = method,
        material         = SR.RC_4000_60,
        shear_studs      = shear_studs,
        max_column_size  = max_col_in * u"inch",
        min_h            = min_h,
        deflection_limit = deflection_limit,
    )
    floor = floor_type === :flat_slab ? SR.FlatSlabOptions(base = fp) : fp

    DesignParameters(
        loads = GravityLoads(
            floor_LL  = live_psf * psf,
            roof_LL   = live_psf * psf,   # single-story: treat as floor
            floor_SDL = sdl_psf * psf,
            roof_SDL  = sdl_psf * psf,
        ),
        materials = MaterialOptions(concrete = SR.NWC_4000, rebar = SR.Rebar_60),
        columns   = SR.ConcreteColumnOptions(
            grade           = SR.NWC_6000,
            catalog         = :high_capacity,
            sizing_strategy = column_strategy,
        ),
        floor     = floor,
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

"""
    _with_method_and_ll(base_params, method, live_psf) -> DesignParameters

Derive run-specific `DesignParameters` from `base_params`, swapping only the
analysis method and live load.  All other settings (deflection limit, material,
shear studs, min_h, etc.) are inherited from `base_params` automatically.
"""
function _with_method_and_ll(base_params::DesignParameters,
                             method::SR.FlatPlateAnalysisMethod,
                             live_psf::Float64)
    # Swap method on the floor options
    bp_floor = base_params.floor
    fp_base = bp_floor isa SR.FlatSlabOptions ? bp_floor.base : bp_floor
    new_fp = SR.FlatPlateOptions(
        method           = method,
        material         = fp_base.material,
        cover            = fp_base.cover,
        bar_size         = fp_base.bar_size,
        has_edge_beam    = fp_base.has_edge_beam,
        edge_beam_βt     = fp_base.edge_beam_βt,
        grouping         = fp_base.grouping,
        φ_flexure        = fp_base.φ_flexure,
        φ_shear          = fp_base.φ_shear,
        λ                = fp_base.λ,
        deflection_limit = fp_base.deflection_limit,
        shear_studs      = fp_base.shear_studs,
        max_column_size  = fp_base.max_column_size,
        stud_material    = fp_base.stud_material,
        stud_diameter    = fp_base.stud_diameter,
        min_h            = fp_base.min_h,
        objective        = fp_base.objective,
        col_I_factor     = fp_base.col_I_factor,
    )
    new_floor = bp_floor isa SR.FlatSlabOptions ?
        SR.FlatSlabOptions(; h_drop = bp_floor.h_drop,
                             a_drop_ratio = bp_floor.a_drop_ratio,
                             base = new_fp) : new_fp

    # Swap live load
    bl = base_params.loads
    new_loads = GravityLoads(
        floor_LL  = live_psf * psf,
        roof_LL   = live_psf * psf,
        floor_SDL = bl.floor_SDL,
        roof_SDL  = bl.roof_SDL,
    )

    # Copy base_params, override floor + loads
    p = deepcopy(base_params)
    p.floor = new_floor
    p.loads = new_loads
    return p
end

# ==============================================================================
# Build & prepare helpers
# ==============================================================================

"""Build a `BuildingSkeleton` for the given rectangular bay grid."""
function _build_skeleton(lx_ft::Float64, ly_ft::Float64,
                         story_ht_ft::Float64, n_bays::Int)
    total_x = lx_ft * n_bays * u"ft"
    total_y = ly_ft * n_bays * u"ft"
    ht      = story_ht_ft * u"ft"
    gen_medium_office(total_x, total_y, ht, n_bays, n_bays, 1)
end

"""Override every cell's live load and re-sync the Asap model."""
function _set_live_load!(struc, live_psf::Float64)
    ll = uconvert(u"kN/m^2", live_psf * psf)
    for cell in struc.cells
        cell.live_load = ll
    end
    sync_asap!(struc)
end

# ==============================================================================
# Result extraction  (reads from slab.result + slab.design_details + struc)
# ==============================================================================

"""
    _extract_results(struc; kw...) -> NamedTuple or nothing

Extract a flat result row from the current (post-pipeline) state of `struc`.

Slab geometry and reinforcement come from `slab.result` (FlatPlatePanelResult).
Column P-M, integrity, transfer, and ρ′ come from `slab.design_details`
(the full NamedTuple stored by `_size_slab!`).
Foundation results come from `struc.foundations`.
"""
function _extract_results(struc;
                          lx_ft::Float64, ly_ft::Float64,
                          live_psf::Float64,
                          floor_type::Symbol,
                          method_name::String,
                          elapsed::Float64)
    slab = struc.slabs[1]
    r = slab.result
    isnothing(r) && return nothing
    dd = slab.design_details   # rich NamedTuple from size_flat_plate!

    # ── Slab reinforcement ───────────────────────────────────────────
    As_cs = sum(sr.As_provided for sr in r.column_strip_reinf; init = 0.0u"inch^2")
    As_ms = sum(sr.As_provided for sr in r.middle_strip_reinf; init = 0.0u"inch^2")

    zs = struc.skeleton.stories_z
    ht_ft = length(zs) >= 2 ? ustrip(u"ft", zs[2] - zs[1]) : NaN

    # ── Punching (from slab.result) ──────────────────────────────────
    pc = r.punching_check
    punch = pc.details
    _has_stud(v) = hasproperty(v, :studs) && !isnothing(v.studs)
    has_studs     = any(_has_stud(v) for v in values(punch))
    n_stud_cols   = count(_has_stud, values(punch))
    stud_rails_max = 0; stud_per_rail_max = 0
    for v in values(punch)
        _has_stud(v) || continue
        s = v.studs
        if s.n_rails > stud_rails_max
            stud_rails_max    = s.n_rails
            stud_per_rail_max = s.n_studs_per_rail
        end
    end
    vu_max_psi = maximum(ustrip(u"psi", v.vu) for v in values(punch); init = 0.0)

    # ── Rich details (from slab.design_details) ──────────────────────
    col_rho_max    = 0.0
    integrity_ok   = true
    n_transfer_add = 0
    h_drop_in      = 0.0
    a_drop1_ft     = 0.0
    a_drop2_ft     = 0.0

    if !isnothing(dd)
        if hasproperty(dd, :column_results)
            ρg_vals = [v.ρg for v in values(dd.column_results)]
            col_rho_max = isempty(ρg_vals) ? 0.0 : maximum(ρg_vals)
        end
        hasproperty(dd, :integrity_check) && (integrity_ok = dd.integrity_check.ok)
        if hasproperty(dd, :transfer_results)
            n_transfer_add = sum(
                isnothing(tr) ? 0 : tr.n_bars_additional
                for tr in dd.transfer_results; init = 0)
        end
        dp = hasproperty(dd, :drop_panel) ? dd.drop_panel : nothing
        if !isnothing(dp)
            h_drop_in  = ustrip(u"inch", dp.h_drop)
            a_drop1_ft = ustrip(u"ft",   dp.a_drop_1)
            a_drop2_ft = ustrip(u"ft",   dp.a_drop_2)
        end
    end

    # ── Columns (post-reconciliation — pipeline Stage 2) ─────────────
    cols_in = [ustrip(u"inch", c.c1) for c in struc.columns]

    # ── ACI minimum thickness ────────────────────────────────────────
    col_avg_ft = sum(cols_in) / length(cols_in) / 12.0
    ln_ft = max(lx_ft, ly_ft) - col_avg_ft
    ft_tag = floor_type === :flat_slab ? SR.FlatSlab() : SR.FlatPlate()
    h_min = SR.min_thickness(ft_tag, ln_ft * u"ft")
    h_min_val = ustrip(u"inch", h_min)
    h_val = ustrip(u"inch", r.thickness)

    # ── Foundations (post-sizing — pipeline Stage 3) ──────────────────
    fdn = _extract_foundation_results(struc)

    # ── Embodied carbon (per-slab, A1–A3 product stage) ──────────────
    # element_ec uses slab.volumes (concrete + rebar), populated by the
    # pipeline via _compute_slab_volumes. Area sums struc.cells indexed by
    # slab.cell_indices (matches compute_building_ec's floor_area logic).
    slab_ec_kgco2e = isempty(slab.volumes) ? NaN : element_ec(slab.volumes)
    slab_area_m2   = ustrip(u"m^2",
        sum(struc.cells[ci].area for ci in slab.cell_indices; init = 0.0u"m^2"))
    slab_ec_per_m2 = (isnan(slab_ec_kgco2e) || slab_area_m2 ≤ 0.0) ?
        NaN : slab_ec_kgco2e / slab_area_m2

    # ── Pattern loading flag ────────────────────────────────────────────
    _pattern = !isnothing(dd) && hasproperty(dd, :pattern_loading) ? dd.pattern_loading : false

    # ── RuleOfThumb failures ─────────────────────────────────────────
    _failures = if !isnothing(dd) && hasproperty(dd, :failures)
        join(dd.failures, ", ")
    else
        ""
    end

    return merge((
        floor_type        = string(floor_type),
        lx_ft             = lx_ft,
        ly_ft             = ly_ft,
        story_ht_ft       = ht_ft,
        live_psf          = live_psf,
        method            = method_name,
        h_in              = h_val,
        h_min_in          = round(h_min_val; digits = 2),
        h_over_h_min      = round(h_val / h_min_val; digits = 3),
        sw_psf            = ustrip(psf, r.self_weight),
        vol_per_area_in   = ustrip(u"inch", r.volume_per_area),
        M0_kipft          = to_kipft(r.M0),
        qu_psf            = ustrip(psf, r.qu),
        punch_ratio       = pc.max_ratio,
        punch_ok          = pc.ok,
        vu_max_psi        = vu_max_psi,
        has_studs         = has_studs,
        n_stud_cols       = n_stud_cols,
        stud_rails_max    = stud_rails_max,
        stud_per_rail_max = stud_per_rail_max,
        defl_ratio        = r.deflection_check.ratio,
        defl_ok           = r.deflection_check.ok,
        defl_in           = ustrip(u"inch", r.deflection_check.Δ_check),
        defl_limit_in     = ustrip(u"inch", r.deflection_check.Δ_limit),
        col_min_in        = minimum(cols_in),
        col_max_in        = maximum(cols_in),
        col_rho_max       = col_rho_max,
        As_cs_in2         = ustrip(u"inch^2", As_cs),
        As_ms_in2         = ustrip(u"inch^2", As_ms),
        As_total_in2      = ustrip(u"inch^2", As_cs + As_ms),
        integrity_ok      = integrity_ok,
        n_transfer_bars   = n_transfer_add,
        pattern_loading   = _pattern,
        runtime_s         = round(elapsed; digits = 3),
        h_drop_in         = h_drop_in,
        a_drop1_ft        = a_drop1_ft,
        a_drop2_ft        = a_drop2_ft,
        slab_ec_kgco2e    = slab_ec_kgco2e,
        slab_area_m2      = slab_area_m2,
        slab_ec_per_m2    = slab_ec_per_m2,
        failures          = _failures,
    ), fdn)
end

"""Extract foundation summary from sized foundations."""
function _extract_foundation_results(struc)
    n_groups = length(unique(filter(!isnothing, [f.group_id for f in struc.foundations])))
    max_B = 0.0;  max_L = 0.0;  max_D = 0.0;  max_util = 0.0
    total_conc  = 0.0u"ft^3"
    total_steel = 0.0u"inch^3"
    all_ok = true;  n_sized = 0

    for fdn in struc.foundations
        r = fdn.result
        isnothing(r) && continue
        n_sized += 1
        B_ft = ustrip(u"ft",   SR.footing_width(r))
        L_ft = ustrip(u"ft",   SR.footing_length(r))
        D_in = ustrip(u"inch", r.D)
        util = SR.utilization(r)
        max_B    = max(max_B, B_ft)
        max_L    = max(max_L, L_ft)
        max_D    = max(max_D, D_in)
        max_util = max(max_util, util)
        total_conc  += uconvert(u"ft^3",   SR.concrete_volume(r))
        total_steel += uconvert(u"inch^3", SR.steel_volume(r))
        util > 1.0 && (all_ok = false)
    end

    return (
        fdn_n_sized       = n_sized,
        fdn_n_groups      = n_groups,
        fdn_max_B_ft      = round(max_B;  digits = 2),
        fdn_max_L_ft      = round(max_L;  digits = 2),
        fdn_max_D_in      = round(max_D;  digits = 1),
        fdn_max_util      = round(max_util; digits = 3),
        fdn_conc_vol_ft3  = round(ustrip(u"ft^3",   total_conc);  digits = 1),
        fdn_steel_vol_in3 = round(ustrip(u"inch^3", total_steel); digits = 1),
        fdn_ok            = all_ok,
    )
end

"""
    _blank_failure_row(; floor_type, lx_ft, ly_ft, live_psf, method_name,
                         elapsed, failure_reason, failing_check) -> NamedTuple

Full-schema failure row with NaN / default values for every field so that
success and failure rows can coexist in the same DataFrame without schema
mismatches.
"""
function _blank_failure_row(;
    floor_type::Symbol,
    lx_ft::Float64,
    ly_ft::Float64,
    story_ht_ft::Float64 = NaN,
    live_psf::Float64,
    method_name::String,
    elapsed::Float64,
    failure_reason::String = "",
    failing_check::String  = "",
)
    return (
        floor_type        = string(floor_type),
        lx_ft             = lx_ft,
        ly_ft             = ly_ft,
        story_ht_ft       = story_ht_ft,
        live_psf          = live_psf,
        method            = method_name,
        h_in              = NaN,
        h_min_in          = NaN,
        h_over_h_min      = NaN,
        sw_psf            = NaN,
        vol_per_area_in   = NaN,
        M0_kipft          = NaN,
        qu_psf            = NaN,
        punch_ratio       = NaN,
        punch_ok          = false,
        vu_max_psi        = NaN,
        has_studs         = false,
        n_stud_cols       = 0,
        stud_rails_max    = 0,
        stud_per_rail_max = 0,
        defl_ratio        = NaN,
        defl_ok           = false,
        defl_in           = NaN,
        defl_limit_in     = NaN,
        col_min_in        = NaN,
        col_max_in        = NaN,
        col_rho_max       = NaN,
        As_cs_in2         = NaN,
        As_ms_in2         = NaN,
        As_total_in2      = NaN,
        integrity_ok      = false,
        n_transfer_bars   = 0,
        pattern_loading   = false,
        runtime_s         = round(elapsed; digits=3),
        h_drop_in         = 0.0,
        a_drop1_ft        = 0.0,
        a_drop2_ft        = 0.0,
        slab_ec_kgco2e    = NaN,
        slab_area_m2      = NaN,
        slab_ec_per_m2    = NaN,
        failures          = failure_reason,
        fdn_n_sized       = 0,
        fdn_n_groups      = 0,
        fdn_max_B_ft      = NaN,
        fdn_max_L_ft      = NaN,
        fdn_max_D_in      = NaN,
        fdn_max_util      = NaN,
        fdn_conc_vol_ft3  = NaN,
        fdn_steel_vol_in3 = NaN,
        fdn_ok            = false,
        converged         = false,
        failure_reason    = failure_reason,
        failing_check     = failing_check,
    )
end

"""
    _extract_rot_failure(struc, dd; ...) -> NamedTuple

Extract a partial result row for a RuleOfThumb run whose checks failed.

Slab-level fields (h, M₀, punch ratio, etc.) are populated from
`design_details`; column and foundation fields are NaN because those
stages were intentionally skipped (the geometry is invalid).
"""
function _extract_rot_failure(struc, dd;
                              lx_ft::Float64, ly_ft::Float64,
                              live_psf::Float64,
                              floor_type::Symbol,
                              method_name::String,
                              elapsed::Float64)
    zs = struc.skeleton.stories_z
    ht_ft = length(zs) >= 2 ? ustrip(u"ft", zs[2] - zs[1]) : NaN

    # Slab-level data from design_details
    h_in = ustrip(u"inch", dd.h_final)
    h_min_in = h_in  # RuleOfThumb sets h = h_min by definition

    # Moment data from slab_result if available
    sr = dd.slab_result
    M0_kipft   = !isnothing(sr) ? to_kipft(sr.M0)             : NaN
    qu_psf     = !isnothing(sr) ? ustrip(psf, sr.qu)          : NaN
    sw_psf     = !isnothing(sr) ? ustrip(psf, sr.self_weight) : NaN
    vol_in     = !isnothing(sr) ? ustrip(u"inch", sr.volume_per_area) : NaN

    # Punching / deflection from slab_result if available
    punch_ratio = NaN; punch_ok = false
    defl_ratio  = NaN; defl_ok  = false; defl_in = NaN; defl_limit_in = NaN
    vu_max_psi  = NaN
    As_cs_in2 = NaN; As_ms_in2 = NaN; As_total_in2 = NaN
    if !isnothing(sr)
        pc = sr.punching_check
        punch_ratio = pc.max_ratio
        punch_ok    = pc.ok
        vu_max_psi  = maximum(ustrip(u"psi", v.vu) for v in values(pc.details); init=0.0)
        dc = sr.deflection_check
        defl_ratio    = dc.ratio
        defl_ok       = dc.ok
        defl_in       = ustrip(u"inch", dc.Δ_check)
        defl_limit_in = ustrip(u"inch", dc.Δ_limit)
        As_cs = sum(s.As_provided for s in sr.column_strip_reinf; init=0.0u"inch^2")
        As_ms = sum(s.As_provided for s in sr.middle_strip_reinf; init=0.0u"inch^2")
        As_cs_in2    = ustrip(u"inch^2", As_cs)
        As_ms_in2    = ustrip(u"inch^2", As_ms)
        As_total_in2 = As_cs_in2 + As_ms_in2
    end

    # Column data — from columns sized within the single pass (best-effort)
    cols_in = [ustrip(u"inch", c.c1) for c in struc.columns
               if !isnothing(c.c1) && c.c1 > 0u"inch"]
    col_min_in = isempty(cols_in) ? NaN : minimum(cols_in)
    col_max_in = isempty(cols_in) ? NaN : maximum(cols_in)
    col_rho_max = 0.0
    if hasproperty(dd, :column_results) && !isnothing(dd.column_results)
        ρg_vals = [v.ρg for v in values(dd.column_results)]
        col_rho_max = isempty(ρg_vals) ? 0.0 : maximum(ρg_vals)
    end

    _failures = hasproperty(dd, :failures) ? join(dd.failures, ", ") : ""

    return (
        floor_type        = string(floor_type),
        lx_ft             = lx_ft,
        ly_ft             = ly_ft,
        story_ht_ft       = ht_ft,
        live_psf          = live_psf,
        method            = method_name,
        h_in              = h_in,
        h_min_in          = round(h_min_in; digits=2),
        h_over_h_min      = 1.0,
        sw_psf            = sw_psf,
        vol_per_area_in   = vol_in,
        M0_kipft          = M0_kipft,
        qu_psf            = qu_psf,
        punch_ratio       = punch_ratio,
        punch_ok          = punch_ok,
        vu_max_psi        = vu_max_psi,
        has_studs         = false,
        n_stud_cols       = 0,
        stud_rails_max    = 0,
        stud_per_rail_max = 0,
        defl_ratio        = defl_ratio,
        defl_ok           = defl_ok,
        defl_in           = defl_in,
        defl_limit_in     = defl_limit_in,
        col_min_in        = col_min_in,
        col_max_in        = col_max_in,
        col_rho_max       = col_rho_max,
        As_cs_in2         = As_cs_in2,
        As_ms_in2         = As_ms_in2,
        As_total_in2      = As_total_in2,
        integrity_ok      = true,
        n_transfer_bars   = 0,
        pattern_loading   = false,
        runtime_s         = round(elapsed; digits=3),
        h_drop_in         = 0.0,
        a_drop1_ft        = 0.0,
        a_drop2_ft        = 0.0,
        slab_ec_kgco2e    = NaN,
        slab_area_m2      = NaN,
        slab_ec_per_m2    = NaN,
        failures          = _failures,
        # Foundation fields — not sized for invalid geometry
        fdn_n_sized       = 0,
        fdn_n_groups      = 0,
        fdn_max_B_ft      = NaN,
        fdn_max_L_ft      = NaN,
        fdn_max_D_in      = NaN,
        fdn_max_util      = NaN,
        fdn_conc_vol_ft3  = NaN,
        fdn_steel_vol_in3 = NaN,
        fdn_ok            = false,
        # Convergence
        converged         = false,
        failure_reason    = _failures,
        failing_check     = dd.failing_check,
    )
end

# ==============================================================================
# Run one method using the design pipeline
# ==============================================================================

"""
    _check_applicability(struc, method) -> Bool

Pre-check DDM/EFM applicability so we can skip inapplicable methods
instead of letting the pipeline silently fall back to FEA.
FEA is always applicable (returns `true`).
"""
function _check_applicability(struc, method)
    ok, _ = _check_applicability_detailed(struc, method)
    return ok
end

"""
    _check_applicability_detailed(struc, method) -> (ok::Bool, reason::String)

Check DDM/EFM applicability and return detailed reason if inapplicable.

The check returns `(ok=Bool, violations=Vector{String})` where violations
contain ACI code references like "§8.10.2.2: Aspect ratio l₂/l₁ = 2.5 > 2.0".
"""
function _check_applicability_detailed(struc, method)
    method isa SR.FEA && return (true, "")
    method isa SR.RuleOfThumb && return (true, "")
    slab = struc.slabs[1]
    columns = SR.find_supporting_columns(struc, Set(slab.cell_indices))
    chk = if method isa SR.DDM
        SR.check_ddm_applicability(struc, slab, columns; throw_on_failure = false)
    else
        SR.check_efm_applicability(struc, slab, columns; throw_on_failure = false)
    end
    if chk.ok
        return (true, "")
    else
        # chk.violations is a Vector{String} with detailed ACI code references
        reason = isempty(chk.violations) ? "DDM/EFM not applicable" : join(chk.violations, "; ")
        return (false, reason)
    end
end

"""
    _run_method(struc, base_params, method_cfg; lx_ft, ly_ft, live_psf, floor_type)

Run the full design pipeline for one method:

    restore → set LL → check applicability → build_pipeline → extract

DDM/EFM are pre-checked for applicability.  If inapplicable, returns
`nothing` immediately — FEA will run when its turn comes in the sweep loop,
avoiding silent fallbacks and duplicate FEA runs.

All sizing stages — slab, column reconciliation, foundations — are handled
by `build_pipeline`.  Returns a result NamedTuple, or `nothing` on failure.
"""
function _run_method(struc, base_params::DesignParameters, method_cfg;
                     lx_ft::Float64, ly_ft::Float64,
                     live_psf::Float64,
                     floor_type::Symbol = :flat_plate)
    restore!(struc)
    _set_live_load!(struc, live_psf)

    # Check high aspect ratio (Ly/Lx > 2.0 is outside DDM limits and generally
    # impractical for flat plate design)
    aspect = max(lx_ft, ly_ft) / min(lx_ft, ly_ft)
    if aspect > 2.0
        return _blank_failure_row(;
            floor_type, lx_ft, ly_ft, live_psf,
            method_name = method_cfg.name, elapsed = 0.0,
            failure_reason = "high_aspect_ratio",
            failing_check = "Aspect ratio $(round(aspect; digits=2)) > 2.0")
    end

    # Pre-check applicability (DDM/EFM only; FEA always passes)
    applicable, reason = _check_applicability_detailed(struc, method_cfg.method)
    if !applicable
        return _blank_failure_row(;
            floor_type, lx_ft, ly_ft, live_psf,
            method_name = method_cfg.name, elapsed = 0.0,
            failure_reason = "ddm_ineligible",
            failing_check = reason)
    end

    # Derive run params from base — swap method + live load, keep everything else
    method_params = _with_method_and_ll(base_params, method_cfg.method, live_psf)

    is_rot = method_cfg.method isa SR.RuleOfThumb

    t0 = time()
    failure_reason = ""
    failing_check  = ""
    try
        with_logger(NullLogger()) do
            stages = build_pipeline(method_params)
            for (i, stage) in enumerate(stages)
                stage.fn(struc)
                stage.needs_sync && sync_asap!(struc; params = method_params)

                # After slab sizing (stage 1), check for non-convergence.
                # If the slab failed, skip columns & foundations entirely.
                if i == 1
                    dd_early = struc.slabs[1].design_details
                    if !isnothing(dd_early) && hasproperty(dd_early, :converged) && !dd_early.converged
                        break
                    end
                end
            end
        end
    catch e
        elapsed = time() - t0
        failure_reason = string(typeof(e))
        failing_check  = sprint(showerror, e)
        @warn "$(method_cfg.name) exception ($(round(elapsed; digits=1))s)" lx=lx_ft ly=ly_ft live=live_psf err=failing_check
        return _blank_failure_row(;
            floor_type, lx_ft, ly_ft, live_psf,
            method_name = method_cfg.name, elapsed,
            failure_reason, failing_check)
    end
    elapsed = time() - t0

    # Check for non-convergence (structured failure from pipeline)
    slab = struc.slabs[1]
    dd = slab.design_details

    if !isnothing(dd) && hasproperty(dd, :converged) && !dd.converged
        # For RuleOfThumb: extract what we can from design_details (slab-level
        # data only — columns/foundations were intentionally skipped).
        # For other methods: return a minimal failure row.
        if is_rot
            return _extract_rot_failure(struc, dd;
                lx_ft, ly_ft, live_psf, floor_type,
                method_name = method_cfg.name, elapsed)
        else
            return _blank_failure_row(;
                floor_type, lx_ft, ly_ft, live_psf,
                method_name = method_cfg.name, elapsed,
                failure_reason = "non_convergence",
                failing_check = dd.failing_check)
        end
    end

    row = _extract_results(struc;
        lx_ft, ly_ft, live_psf, floor_type,
        method_name = method_cfg.name, elapsed)
    isnothing(row) && return nothing
    return merge(row, (converged = true, failure_reason = "", failing_check = ""))
end

# ==============================================================================
# Main sweep
# ==============================================================================

"""
    sweep(; spans, live_loads, n_bays, sdl, save, floor_type)

Run all method × span × live-load combinations.

Each span prepares the structure once via `prepare!`; all (LL, method)
combinations reuse it via snapshot/restore + `build_pipeline`.
"""
function sweep(;
    spans::Vector{Float64}     = [16.0, 20.0, 24.0, 28.0, 32.0, 36.0, 40.0, 44.0, 48.0, 52.0],
    live_loads::Vector{Float64} = [50.0, 150.0, 250.0],
    n_bays::Int                = 3,
    sdl::Float64               = 20.0,
    save::Bool                 = true,
    floor_type::Symbol         = :flat_plate,
)
    ft_label  = floor_type === :flat_slab ? "Flat Slab" : "Flat Plate"
    n_methods = length(ALL_METHODS)
    n_total   = length(spans) * length(live_loads) * n_methods

    print_header("$(ft_label) Method Comparison — Full Pipeline")
    println("  Floor type:  $(ft_label)")
    println("  Spans:       $(spans) ft")
    println("  Story hts:   $([_adaptive_story_ht(s) for s in spans]) ft")
    println("  Live loads:  $(live_loads) psf")
    println("  Methods:     $n_methods")
    println("  Pipeline:    slab → columns → spread foundations")
    println("  Geometries:  $(length(spans))  (prepared once each)")
    println("  Total runs:  $n_total")
    println()

    rows      = NamedTuple[]
    fail_rows = NamedTuple[]
    n_fail    = 0
    p         = Progress(n_total; desc = "Sweep ($(ft_label)): ")

    n_runs = length(live_loads) * n_methods
    for span in spans
        ht      = _adaptive_story_ht(span)
        max_col = _adaptive_max_col(span)

        local struc, base_params
        try
            base_params = _make_params(; floor_type, sdl_psf = sdl, max_col_in = max_col)
            skel   = _build_skeleton(span, span, ht, n_bays)
            struc  = BuildingStructure(skel)
            prepare!(struc, base_params)
        catch e
            @warn "Geometry build failed — skipping" span floor_type exception=e
            n_fail += n_runs
            for _ in 1:n_runs; next!(p); end
            continue
        end

        for ll in live_loads, mcfg in ALL_METHODS
            row = _run_method(struc, base_params, mcfg;
                              lx_ft = span, ly_ft = span, live_psf = ll,
                              floor_type = floor_type)
            if isnothing(row)
                n_fail += 1
            elseif hasproperty(row, :converged) && !row.converged
                n_fail += 1
                push!(fail_rows, row)
            else
                push!(rows, row)
            end
            next!(p)
        end
    end

    df = DataFrame(rows)
    df_fail = isempty(fail_rows) ? DataFrame() : DataFrame(fail_rows)
    outfile = nothing
    if save && !isempty(df)
        tag = floor_type === :flat_slab ? "flat_slab_methods" : "flat_plate_methods"
        outfile = output_filename(tag, FP_RESULTS_DIR)
        CSV.write(outfile, df)
    end
    if save && !isempty(df_fail)
        tag_fail = floor_type === :flat_slab ? "flat_slab_failures" : "flat_plate_failures"
        fail_file = output_filename(tag_fail, FP_RESULTS_DIR)
        CSV.write(fail_file, df_fail)
        println("  Failures:    $fail_file")
    end
    print_footer(nrow(df), n_fail, outfile)
    return df
end

# ==============================================================================
# Convenience sweeps
# ==============================================================================

span_sweep(; ll = 50.0, kw...) = sweep(; live_loads = [ll], kw...)
load_sweep(; span = 20.0, kw...) = sweep(; spans = [span], kw...)

function dual_sweep(; kw...)
    df_fp = sweep(; floor_type = :flat_plate, kw...)
    df_fs = sweep(; floor_type = :flat_slab,  kw...)
    return vcat(df_fp, df_fs)
end

"""
    dual_heatmap_sweep(; spans_x, spans_y, live_loads, min_h_variants, ...)

Sweep Lx × Ly × LL × method for both flat plate and flat slab.

Each (Lx, Ly) skeleton is built once; a fresh structure is prepared for
every (floor_type, min_h) combination.  Each run uses `build_pipeline`
for the full slab → column → foundation pipeline.
"""

function dual_heatmap_sweep(;
    spans_x::Vector{Float64}    = [16.0, 20.0, 24.0, 28.0, 32.0, 36.0, 40.0, 44.0, 48.0, 52.0],
    spans_y::Vector{Float64}    = [16.0, 20.0, 24.0, 28.0, 32.0, 36.0, 40.0, 44.0, 48.0, 52.0],
    live_loads::Vector{Float64} = [50.0, 150.0, 250.0],
    n_bays::Int                 = 3,
    sdl::Float64                = 20.0,
    save::Bool                  = true,
    min_h                       = nothing,
    min_h_variants::Vector{<:Tuple{String, Any}} = Tuple{String,Any}[],
    max_col_in::Union{Nothing, Float64} = nothing,
    col_ratio::Float64                  = 1.1,
    deflection_limit::Symbol            = :L_360,
    column_strategies::Vector{Symbol}   = [:catalog],
)
    if isempty(min_h_variants)
        label = isnothing(min_h) ? "ACI" : "override"
        min_h_variants = [(label, min_h)]
    end

    floor_types = [:flat_plate, :flat_slab]
    n_methods   = length(ALL_METHODS)
    n_geom      = length(spans_x) * length(spans_y)
    n_strats    = length(column_strategies)
    n_runs_per  = length(live_loads) * n_methods
    n_variants  = length(min_h_variants) * length(floor_types) * n_strats
    n_total     = n_geom * n_runs_per * n_variants

    print_header("Dual Heatmap — Full Pipeline")
    println("  Floor types:  $(floor_types)")
    println("  Lx spans:     $(spans_x) ft")
    println("  Ly spans:     $(spans_y) ft")
    println("  Live loads:   $(live_loads) psf")
    println("  Methods:      $n_methods")
    println("  Col strategy: $(column_strategies)")
    println("  Pipeline:     slab → columns → spread foundations")
    println("  Geometries:   $n_geom  (skeleton shared per variant)")
    println("  Total runs:   $n_total")
    println()

    rows      = NamedTuple[]
    fail_rows = NamedTuple[]
    n_fail    = 0
    p         = Progress(n_total; desc="Dual heatmap: ")

    for lx in spans_x, ly in spans_y
        ht      = _adaptive_story_ht(max(lx, ly))
        max_col = isnothing(max_col_in) ? _adaptive_max_col(max(lx, ly); ratio = col_ratio) : max_col_in

        local skel
        try
            skel = _build_skeleton(lx, ly, ht, n_bays)
        catch e
            @warn "Skeleton build failed — skipping" lx ly exception=e
            for (mh_label, _) in min_h_variants, ft in floor_types, cs in column_strategies, ll in live_loads, mcfg in ALL_METHODS
                row = _blank_failure_row(;
                    floor_type=ft, lx_ft=lx, ly_ft=ly, live_psf=ll,
                    method_name=mcfg.name, elapsed=0.0,
                    failure_reason="skeleton_build_failed",
                    failing_check=string(e),
                    story_ht_ft=ht)
                push!(fail_rows, merge(row, (min_h_rule = mh_label, column_strategy = string(cs))))
            end
            n_skip = n_runs_per * n_variants
            n_fail += n_skip
            for _ in 1:n_skip; next!(p); end
            continue
        end

        for (mh_label, mh_val) in min_h_variants
            for ft in floor_types, cs in column_strategies
                local struc, base_params
                try
                    base_params = _make_params(; floor_type = ft, sdl_psf = sdl,
                                                  max_col_in = max_col, min_h = mh_val,
                                                  deflection_limit = deflection_limit,
                                                  column_strategy = cs)
                    struc = BuildingStructure(skel)
                    prepare!(struc, base_params)
                catch e
                    ft_label = ft === :flat_slab ? "Flat Slab" : "Flat Plate"
                    strat_label = cs == :nlp ? " [NLP]" : ""
                    @warn "$(ft_label)$(strat_label) [$(mh_label)] prepare failed" lx ly exception=e
                    n_fail += n_runs_per
                    for _ in 1:n_runs_per; next!(p); end
                    continue
                end

                for ll in live_loads, mcfg in ALL_METHODS
                    row = _run_method(struc, base_params, mcfg;
                                      lx_ft = lx, ly_ft = ly, live_psf = ll,
                                      floor_type = ft)
                    if isnothing(row)
                        n_fail += 1
                    elseif hasproperty(row, :converged) && !row.converged
                        n_fail += 1
                        push!(fail_rows, merge(row, (min_h_rule = mh_label, column_strategy = string(cs))))
                    else
                        row = merge(row, (min_h_rule = mh_label, column_strategy = string(cs)))
                        push!(rows, row)
                    end
                    next!(p)
                end
            end
        end
    end

    df = DataFrame(rows)
    df_fail = isempty(fail_rows) ? DataFrame() : DataFrame(fail_rows)
    
    if save
        outfile = nothing
        if !isempty(df)
            for (mh_label, _) in min_h_variants
                for ft in ["flat_plate", "flat_slab"]
                    sub = filter(r -> r.floor_type == ft && r.min_h_rule == mh_label, df)
                    isempty(sub) && continue
                    CSV.write(output_filename("$(ft)_heatmap_$(mh_label)", FP_RESULTS_DIR), sub)
                end
            end
            outfile = output_filename("dual_heatmap", FP_RESULTS_DIR)
            CSV.write(outfile, df)
        end

        if !isempty(df_fail)
            fail_file = output_filename("dual_heatmap_failures", FP_RESULTS_DIR)
            CSV.write(fail_file, df_fail)
            println("  Failures:    $fail_file")
            
            # Also save a 'latest' version without timestamp for easier access
            latest_fail = joinpath(FP_RESULTS_DIR, "dual_heatmap_failures_latest.csv")
            CSV.write(latest_fail, df_fail)
        end
        print_footer(nrow(df), n_fail, outfile)
    else
        print_footer(nrow(df), n_fail, nothing)
    end
    return df
end

# ==============================================================================
# Pretty-print comparison table
# ==============================================================================

function compare(; span = 20.0, ll = 50.0, n_bays = 3, sdl = 20.0)
    ht      = _adaptive_story_ht(span)
    max_col = _adaptive_max_col(span)
    base_params = _make_params(; sdl_psf = sdl, live_psf = ll, max_col_in = max_col)
    skel    = _build_skeleton(span, span, ht, n_bays)
    struc   = BuildingStructure(skel)
    prepare!(struc, base_params)

    println()
    @printf("  Flat plate: %.0f ft × %.0f ft bays  |  LL = %.0f psf  |  %d×%d grid\n",
            span, span, ll, n_bays, n_bays)
    bar = "─" ^ 130
    println("  $bar")
    @printf("  %-16s │ h (in) │ h_min │ h/h_min │ M₀ (k-ft) │ Punch │ Defl  │ Columns    │ Ftg B(ft) │  Time  │ Failures\n", "Method")
    println("  $bar")

    for mcfg in ALL_METHODS
        row = _run_method(struc, base_params, mcfg;
                          lx_ft = span, ly_ft = span, live_psf = ll)
        if isnothing(row)
            @printf("  %-16s │  FAIL\n", mcfg.name)
        elseif hasproperty(row, :h_in)
            col_str = row.col_min_in ≈ row.col_max_in ?
                @sprintf("%.0f\"", row.col_min_in) :
                @sprintf("%.0f\"–%.0f\"", row.col_min_in, row.col_max_in)
            fail_str = hasproperty(row, :failures) && !isempty(row.failures) ? row.failures : "—"
            @printf("  %-16s │ %5.1f  │ %5.1f │ %5.3f   │  %7.2f  │ %5.3f │ %5.3f │ %-10s │ %6.1f    │ %5.2fs │ %s\n",
                    mcfg.name, row.h_in, row.h_min_in, row.h_over_h_min,
                    row.M0_kipft, row.punch_ratio,
                    row.defl_ratio, col_str, row.fdn_max_B_ft, row.runtime_s, fail_str)
        else
            # Minimal failure row (no extracted results)
            @printf("  %-16s │  FAIL  │       │         │           │       │       │            │           │        │ %s\n",
                    mcfg.name, hasproperty(row, :failure_reason) ? row.failure_reason : "unknown")
        end
    end
    println("  $bar\n")
end

# ==============================================================================
# Save / load helpers
# ==============================================================================

save_results(df, name = "flat_plate_methods") =
    CSV.write(output_filename(name, FP_RESULTS_DIR), df)

function load_results(dir = FP_RESULTS_DIR)
    csvs = filter(f -> endswith(f, ".csv"), readdir(dir; join = true))
    isempty(csvs) && error("No CSV files in $dir")
    latest = sort(csvs; by = mtime, rev = true)[1]
    println("Loading: $latest")
    return CSV.read(latest, DataFrame)
end

# ==============================================================================
# Shear stud comparison sweep
# ==============================================================================

function stud_sweep(;
    spans::Vector{Float64}      = [16.0, 20.0, 24.0, 28.0, 32.0, 36.0, 40.0, 44.0, 48.0, 52.0],
    live_loads::Vector{Float64}  = [50.0],
    studs_list::Vector{Symbol}   = [:never, :if_needed, :always],
    floor_type::Symbol           = :flat_plate,
    n_bays::Int                  = 3,
    sdl::Float64                 = 20.0,
    save::Bool                   = true,
)
    ft_label = floor_type === :flat_slab ? "Flat Slab" : "Flat Plate"
    n_total  = length(spans) * length(live_loads) * length(studs_list)

    print_header("$(ft_label) Shear Stud Comparison — FEA Only")
    println("  Spans:       $(spans) ft")
    println("  Stud modes:  $(studs_list)")
    println("  Total runs:  $n_total")
    println()

    rows   = NamedTuple[]
    n_fail = 0
    p      = Progress(n_total; desc = "Stud sweep: ")

    n_ll = length(live_loads)
    for stud_mode in studs_list
        for span in spans
            ht      = _adaptive_story_ht(span)
            max_col = _adaptive_max_col(span)

            local struc, base_params
            try
                base_params = _make_params(; floor_type, sdl_psf = sdl,
                                              max_col_in = max_col,
                                              shear_studs = stud_mode,
                                              method = SR.FEA())
                skel  = _build_skeleton(span, span, ht, n_bays)
                struc = BuildingStructure(skel)
                prepare!(struc, base_params)
            catch e
                @warn "Prepare failed" span stud_mode exception=e
                n_fail += n_ll
                for _ in 1:n_ll; next!(p); end
                continue
            end

            fea_cfg = (key = :fea, name = "FEA (studs=$(stud_mode))", method = SR.FEA())
            for ll in live_loads
                row = _run_method(struc, base_params, fea_cfg;
                                  lx_ft = span, ly_ft = span, live_psf = ll,
                                  floor_type = floor_type)
                if isnothing(row)
                    n_fail += 1
                else
                    row = merge(row, (stud_strategy = string(stud_mode),))
                    push!(rows, row)
                end
                next!(p)
            end
        end
    end

    df = DataFrame(rows)
    outfile = nothing
    if save && !isempty(df)
        outfile = output_filename("stud_comparison_$(floor_type)", FP_RESULTS_DIR)
        CSV.write(outfile, df)
    end
    print_footer(nrow(df), n_fail, outfile)
    return df
end

function dual_stud_sweep(; kw...)
    df_fp = stud_sweep(; floor_type = :flat_plate, kw...)
    df_fs = stud_sweep(; floor_type = :flat_slab,  kw...)
    return vcat(df_fp, df_fs)
end

# ==============================================================================
# Column sizing strategy comparison sweep (MIP catalog vs NLP continuous)
# ==============================================================================

"""
    column_strategy_sweep(; spans, live_loads, methods, strategies, ...)

Compare MIP (catalog) vs NLP (continuous) column sizing across span × LL × method.

Each (span, LL, method, strategy) combination is a full pipeline run because
column sizes affect punching shear, stiffness, and moments — the slab result
is not independent of the column sizing strategy.

The structure is prepared once per (span, strategy) pair; all (LL, method)
combinations reuse it via snapshot/restore.

# Example
```julia
df = column_strategy_sweep()                          # default spans, FEA only
df = column_strategy_sweep(spans=[20.0, 28.0, 36.0])  # custom spans
df = column_strategy_sweep(methods=ALL_METHODS)        # all slab methods
```
"""
function column_strategy_sweep(;
    spans::Vector{Float64}      = [16.0, 20.0, 24.0, 28.0, 32.0, 36.0, 40.0],
    live_loads::Vector{Float64}  = [50.0, 150.0],
    methods                      = [(key=:fea, name="FEA", method=SR.FEA(; pattern_loading=false))],
    strategies::Vector{Symbol}   = [:catalog, :nlp],
    floor_type::Symbol           = :flat_plate,
    n_bays::Int                  = 3,
    sdl::Float64                 = 20.0,
    save::Bool                   = true,
)
    ft_label  = floor_type === :flat_slab ? "Flat Slab" : "Flat Plate"
    n_methods = length(methods)
    n_strats  = length(strategies)
    n_total   = length(spans) * length(live_loads) * n_methods * n_strats

    print_header("$(ft_label) Column Strategy Comparison")
    println("  Floor type:  $(ft_label)")
    println("  Spans:       $(spans) ft")
    println("  Live loads:  $(live_loads) psf")
    println("  Methods:     $(n_methods)")
    println("  Strategies:  $(strategies)")
    println("  Total runs:  $n_total")
    println()

    rows      = NamedTuple[]
    fail_rows = NamedTuple[]
    n_fail    = 0
    p         = Progress(n_total; desc = "Col strategy: ")

    n_runs_per_strat = length(live_loads) * n_methods
    for span in spans
        ht      = _adaptive_story_ht(span)
        max_col = _adaptive_max_col(span)

        for strat in strategies
            local struc, base_params
            try
                base_params = _make_params(; floor_type, sdl_psf = sdl,
                                              max_col_in = max_col,
                                              column_strategy = strat)
                skel  = _build_skeleton(span, span, ht, n_bays)
                struc = BuildingStructure(skel)
                prepare!(struc, base_params)
            catch e
                @warn "Prepare failed" span strat exception=e
                n_fail += n_runs_per_strat
                for _ in 1:n_runs_per_strat; next!(p); end
                continue
            end

            for ll in live_loads, mcfg in methods
                row = _run_method(struc, base_params, mcfg;
                                  lx_ft = span, ly_ft = span, live_psf = ll,
                                  floor_type = floor_type)
                if isnothing(row)
                    n_fail += 1
                elseif hasproperty(row, :converged) && !row.converged
                    n_fail += 1
                    push!(fail_rows, merge(row, (col_strategy = string(strat),)))
                else
                    row = merge(row, (col_strategy = string(strat),))
                    push!(rows, row)
                end
                next!(p)
            end
        end
    end

    df = DataFrame(rows)
    df_fail = isempty(fail_rows) ? DataFrame() : DataFrame(fail_rows)
    outfile = nothing
    if save && !isempty(df)
        outfile = output_filename("col_strategy_$(floor_type)", FP_RESULTS_DIR)
        CSV.write(outfile, df)
    end
    if save && !isempty(df_fail)
        fail_file = output_filename("col_strategy_failures_$(floor_type)", FP_RESULTS_DIR)
        CSV.write(fail_file, df_fail)
        println("  Failures:    $fail_file")
    end
    print_footer(nrow(df), n_fail, outfile)
    return df
end

function dual_column_strategy_sweep(; kw...)
    df_fp = column_strategy_sweep(; floor_type = :flat_plate, kw...)
    df_fs = column_strategy_sweep(; floor_type = :flat_slab,  kw...)
    return vcat(df_fp, df_fs)
end
