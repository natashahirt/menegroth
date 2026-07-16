# =============================================================================
# Flat-Plate Speed-up Validation Harness
# =============================================================================
#
# This runner gates the flat-plate sizing speed-up work (plan-d72e497e).  Each
# optimization (cache reuse, phase merging, NLP, column grouping, …) is
# expected to leave the *engineering outputs* of `size_flat_plate!` and the
# downstream pipeline (column reconciliation, foundation sizing) bit-identical
# (within float roundoff).  Runtime is recorded but explicitly excluded from
# the diff so it is allowed to drop.
#
# The harness is intentionally self-contained: it activates the
# `StructuralSynthesizer` project (which has `Asap` as a direct path dep) and
# inlines the sweep helpers it needs from
# `StructuralStudies/src/flat_plate_methods/flat_plate_method_comparison.jl`
# rather than `include`-ing that file.  Including it would re-activate the
# `StructuralStudies` project mid-run (via `init.jl`) and pull `Asap` in through
# a second module identity — the cross-project precompile that hung a previous
# attempt at 22+ min.  It also avoids `DataFrames`/`CSV`, neither of which is a
# usable dependency of `StructuralSynthesizer`, by doing plain CSV I/O over
# `Vector{NamedTuple}`.
#
# Usage:
#
#   # Initial seed (no baseline yet) — the first run becomes the baseline:
#   SS_ENABLE_VISUALIZATION=false julia --project=StructuralSynthesizer \
#       scripts/runners/run_flat_plate_speedup_validation.jl
#
#   # After making a change — diff against baseline (exit 1 on mismatch):
#   SS_ENABLE_VISUALIZATION=false julia --project=StructuralSynthesizer \
#       scripts/runners/run_flat_plate_speedup_validation.jl
#
#   # Force-regenerate the baseline (only when an output change is intentional
#   # and reviewed):
#   SS_ENABLE_VISUALIZATION=false julia --project=StructuralSynthesizer \
#       scripts/runners/run_flat_plate_speedup_validation.jl --regenerate-baseline
#
# Output files (committed alongside the source so the baseline travels with
# the repo):
#
#   StructuralStudies/src/flat_plate_methods/results/speedup_baseline/
#     baseline.csv  — frozen reference outputs
#     latest.csv    — most recent run (overwritten every invocation)
# =============================================================================

# Match the project-activation pattern of
# `scripts/runners/run_smoke_medium_office_3storey.jl:9-14`: headless ENV guards
# first, then activate `StructuralSynthesizer` (Asap is a direct path dep here).
ENV["SS_ENABLE_VISUALIZATION"] = get(ENV, "SS_ENABLE_VISUALIZATION", "false")
ENV["SS_ENABLE_HEAVY_PRECOMPILE_WORKLOAD"] =
    get(ENV, "SS_ENABLE_HEAVY_PRECOMPILE_WORKLOAD", "false")

using Pkg
Pkg.activate(joinpath(@__DIR__, "..", "..", "StructuralSynthesizer"))
Pkg.instantiate()

# `Asap` is `using`-ed directly (not via `StructuralSizer.Asap`) so that
# Unitful's `@u_str` macro can resolve `u"kgCO2e"` at macro-expansion time in
# *this* module — the unit is registered by `Asap` and looked up only in
# modules the caller has `using`-ed.  This is the same identity `StructuralSizer`
# and `StructuralSynthesizer` load, so no second Asap module is created.
using Asap
using StructuralSizer
using StructuralSynthesizer
using Unitful
using Printf
using Logging: NullLogger, with_logger

const SR = StructuralSizer
const SS = StructuralSynthesizer

# -----------------------------------------------------------------------------
# Smoke matrix
# -----------------------------------------------------------------------------
# Three spans (small/medium/large) × four representative methods × 1 LL × 1
# concrete = 12 design runs.  The matrix spans the four code paths we care
# about: DDM, EFM (ASAP), FEA (frame), and FEA (strip).  RuleOfThumb is excluded
# because it short-circuits the whole pipeline; MDDM and EFM(HC) duplicate the
# DDM/EFM(ASAP) flow numerically.  Square bays, 3×3 grid, single story.

# WAVE 1B SMOKE: single 28' span keeps RAM under the runaway-GC threshold observed on Julia 1.12.1 patch (see plan-d72e497e for GC trace).
const SMOKE_SPANS    = [28.0]                            # ft
const SMOKE_LIVE_PSF = 50.0                              # psf
const SMOKE_CONCRETE = "NWC_4000"
const SMOKE_N_BAYS   = 3

# Method configurations — copied verbatim from the study's `ALL_METHODS`
# (StructuralStudies/src/flat_plate_methods/flat_plate_method_comparison.jl:52-57).
# `pattern_loading=false` for EFM and FEA keeps them comparable to DDM's fixed
# coefficients (see the note at :46-48 of the source).
# WAVE 1B SMOKE: DDM (control, A1 has no path) + FEA frame (A1 exercised).
const SMOKE_METHODS = [
    (key=:ddm,    name="DDM (Full)",  method=SR.DDM(:full)),
    (key=:fea,    name="FEA (frame)", method=SR.FEA(; pattern_loading=false, design_approach=:frame)),
]

# -----------------------------------------------------------------------------
# Invariant columns — these MUST match across optimization changes.
# -----------------------------------------------------------------------------
# Each entry is a column name (Symbol) on the extracted result row.  These
# cover:
#   - slab geometry / weight                  (h_in, sw_psf, vol_per_area_in)
#   - moments / loads                          (M0_kipft, qu_psf)
#   - shear / deflection checks                (punch_ratio, defl_ratio,
#                                               vu_max_psi, defl_in)
#   - column outcomes                          (col_min_in, col_max_in,
#                                               col_rho_max)
#   - reinforcement totals                     (As_cs_in2, As_ms_in2,
#                                               As_total_in2)
#   - embodied carbon                          (slab_ec_kgco2e, slab_ec_per_m2,
#                                               concrete_kg_per_m2,
#                                               rebar_kg_per_m2)
#   - foundation outcomes (post-pipeline)      (fdn_max_B_ft, fdn_max_L_ft,
#                                               fdn_max_D_in, fdn_max_util)
#
# `runtime_s` is intentionally NOT here; the whole point of the harness is to
# allow that to drop while keeping the rest fixed.
const INVARIANT_COLS = [
    :h_in, :sw_psf, :vol_per_area_in,
    :M0_kipft, :qu_psf,
    :punch_ratio, :defl_ratio, :vu_max_psi, :defl_in,
    :col_min_in, :col_max_in, :col_rho_max,
    :As_cs_in2, :As_ms_in2, :As_total_in2,
    :slab_ec_kgco2e, :slab_ec_per_m2,
    :concrete_kg_per_m2, :rebar_kg_per_m2,
    :fdn_max_B_ft, :fdn_max_L_ft, :fdn_max_D_in, :fdn_max_util,
]

# Key columns used to align (join) `latest` with `baseline` rows.
const KEY_COLS = [:method, :lx_ft, :ly_ft, :live_psf, :concrete]

# Column layout written to / read from CSV: keys, then invariants, then the
# (non-diffed) runtime.  Fixed schema for every row so the CSV round-trips
# without a DataFrame.
const OUTPUT_COLS  = vcat(KEY_COLS, INVARIANT_COLS, [:runtime_s])
const STRING_COLS  = Set([:method, :concrete])

# -----------------------------------------------------------------------------
# Output paths
# -----------------------------------------------------------------------------

const _SPEEDUP_DIR = joinpath(@__DIR__, "..", "..",
                              "StructuralStudies", "src", "flat_plate_methods",
                              "results", "speedup_baseline")
const BASELINE_CSV = joinpath(_SPEEDUP_DIR, "baseline.csv")
const LATEST_CSV   = joinpath(_SPEEDUP_DIR, "latest.csv")

# =============================================================================
# Inlined sweep helpers
# -----------------------------------------------------------------------------
# All copied ~verbatim from
# `StructuralStudies/src/flat_plate_methods/flat_plate_method_comparison.jl`
# (line refs noted per function) so the extracted invariants are provenance-
# identical to the study.  No engineering factor, load combination, or clause
# is re-derived here — every check is delegated to the library.
# =============================================================================

# adapted from flat_plate_method_comparison.jl:123 — story height scaled with span.
_adaptive_story_ht(span_ft::Float64) = max(12.0, round(span_ft / 3.0))

# adapted from flat_plate_method_comparison.jl:127-128 — max column constraint
# scaled to span (clamped to a 36″–60″ range at the default 1.1 ratio).
_adaptive_max_col(span_ft::Float64; ratio::Float64 = 1.1) =
    clamp(round(span_ft * ratio), 36.0, 60.0)

# adapted from flat_plate_method_comparison.jl:164-213 — build the run's
# DesignParameters.  Fixed study presets (SDL, deflection limit, column/
# foundation materials, footing geometry) are copied verbatim, not invented.
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
    concrete_label::AbstractString = "NWC_4000",
)
    preset = _concrete_preset(concrete_label)
    fp = SR.FlatPlateOptions(
        method           = method,
        material         = preset.material,
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
        materials = MaterialOptions(concrete = preset.concrete, rebar = SR.Rebar_60),
        columns   = SR.ConcreteColumnOptions(
            material        = SR.NWC_6000,
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

# adapted from flat_plate_method_comparison.jl:78-96 — concrete preset lookup.
const _CONCRETE_PRESETS = (
    NWC_3000 = (concrete = SR.NWC_3000, material = SR.RC_3000_60),
    NWC_4000 = (concrete = SR.NWC_4000, material = SR.RC_4000_60),
    NWC_5000 = (concrete = SR.NWC_5000, material = SR.RC_5000_60),
    NWC_6000 = (concrete = SR.NWC_6000, material = SR.RC_6000_60),
    LWC_4000 = (concrete = SR.LWC_4000, material = SR.RC_LWC_4000_60),
)

function _concrete_preset(label::AbstractString)
    sym = Symbol(label)
    haskey(_CONCRETE_PRESETS, sym) ||
        error("Unknown concrete preset \"$label\". Known: $(collect(keys(_CONCRETE_PRESETS)))")
    return _CONCRETE_PRESETS[sym]
end

# adapted from flat_plate_method_comparison.jl:222-267 — derive run params from a
# prepared base, swapping only method + live load (everything else inherited).
function _with_method_and_ll(base_params::DesignParameters,
                             method::SR.FlatPlateAnalysisMethod,
                             live_psf::Float64)
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

    bl = base_params.loads
    new_loads = GravityLoads(
        floor_LL  = live_psf * psf,
        roof_LL   = live_psf * psf,
        floor_SDL = bl.floor_SDL,
        roof_SDL  = bl.roof_SDL,
    )

    p = deepcopy(base_params)
    p.floor = new_floor
    p.loads = new_loads
    return p
end

# adapted from flat_plate_method_comparison.jl:278-285 — build a single-story
# rectangular-bay skeleton.
function _build_skeleton(lx_ft::Float64, ly_ft::Float64,
                         story_ht_ft::Float64, n_bays::Int;
                         n_stories::Int = 1)
    total_x = lx_ft * n_bays * u"ft"
    total_y = ly_ft * n_bays * u"ft"
    ht      = story_ht_ft * u"ft"
    gen_medium_office(total_x, total_y, ht, n_bays, n_bays, n_stories)
end

# adapted from flat_plate_method_comparison.jl:288-294 — override live load and
# re-sync the Asap model.
function _set_live_load!(struc, live_psf::Float64)
    ll = uconvert(u"kN/m^2", live_psf * psf)
    for cell in struc.cells
        cell.live_load = ll
    end
    sync_asap!(struc)
end

# adapted from flat_plate_method_comparison.jl:316-352 — split slab volumes into
# concrete- vs rebar-side mass and normalize by floor area (MUI).
function _extract_slab_mui(volumes, floor_area_m2::Float64)
    nan_result = (
        concrete_vol_m3    = NaN, rebar_vol_m3       = NaN,
        concrete_mass_kg   = NaN, rebar_mass_kg      = NaN,
        slab_mass_kg       = NaN, mui_kg_per_m2      = NaN,
        concrete_kg_per_m2 = NaN, rebar_kg_per_m2    = NaN,
        concrete_t_eq_m    = NaN, rebar_vol_per_m2   = NaN,
    )
    (isempty(volumes) || floor_area_m2 ≤ 0.0) && return nan_result

    c_vol_m3 = 0.0;  c_mass_kg = 0.0
    r_vol_m3 = 0.0;  r_mass_kg = 0.0
    for (mat, vol) in volumes
        v_m3   = ustrip(u"m^3", vol)
        mass_kg = ustrip(u"kg", vol * mat.ρ)
        if mat isa StructuralSizer.RebarSteel
            r_vol_m3  += v_m3
            r_mass_kg += mass_kg
        else
            c_vol_m3  += v_m3
            c_mass_kg += mass_kg
        end
    end
    slab_mass_kg = c_mass_kg + r_mass_kg
    return (
        concrete_vol_m3    = c_vol_m3,
        rebar_vol_m3       = r_vol_m3,
        concrete_mass_kg   = c_mass_kg,
        rebar_mass_kg      = r_mass_kg,
        slab_mass_kg       = slab_mass_kg,
        mui_kg_per_m2      = slab_mass_kg / floor_area_m2,
        concrete_kg_per_m2 = c_mass_kg   / floor_area_m2,
        rebar_kg_per_m2    = r_mass_kg   / floor_area_m2,
        concrete_t_eq_m    = c_vol_m3    / floor_area_m2,
        rebar_vol_per_m2   = r_vol_m3    / floor_area_m2,
    )
end

# adapted from flat_plate_method_comparison.jl:527-561 — foundation summary.
function _extract_foundation_results(struc)
    n_groups = length(unique(filter(!isnothing, [f.group_id for f in struc.foundations])))
    max_B = 0.0;  max_L = 0.0;  max_D = 0.0;  max_util = 0.0
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
        util > 1.0 && (all_ok = false)
    end

    return (
        fdn_n_sized  = n_sized,
        fdn_n_groups = n_groups,
        fdn_max_B_ft = round(max_B;    digits = 2),
        fdn_max_L_ft = round(max_L;    digits = 2),
        fdn_max_D_in = round(max_D;    digits = 1),
        fdn_max_util = round(max_util; digits = 3),
        fdn_ok       = all_ok,
    )
end

# adapted from flat_plate_method_comparison.jl:364-524 — extract the result row
# from the post-pipeline state of `struc`.  Only the fields the harness diffs
# (plus the keys and runtime) are kept; optional MUI/stud/drop-panel columns are
# dropped since they are not in the invariant set.
function _extract_results(struc;
                          lx_ft::Float64, ly_ft::Float64,
                          live_psf::Float64,
                          floor_type::Symbol,
                          method_name::String,
                          elapsed::Float64,
                          concrete_label::AbstractString = "NWC_4000")
    slab = struc.slabs[1]
    r = slab.result
    isnothing(r) && return nothing
    dd = slab.design_details   # rich NamedTuple from size_flat_plate!

    As_cs = sum(sr.As_provided for sr in r.column_strip_reinf; init = 0.0u"inch^2")
    As_ms = sum(sr.As_provided for sr in r.middle_strip_reinf; init = 0.0u"inch^2")

    # ── Punching (from slab.result) ──────────────────────────────────
    pc = r.punching_check
    punch = pc.details
    vu_max_psi = maximum(ustrip(u"psi", v.vu) for v in values(punch); init = 0.0)

    # ── Column ρg (from slab.design_details) ─────────────────────────
    col_rho_max = 0.0
    if !isnothing(dd) && hasproperty(dd, :column_results)
        ρg_vals = [v.ρg for v in values(dd.column_results)]
        col_rho_max = isempty(ρg_vals) ? 0.0 : maximum(ρg_vals)
    end

    # ── Columns (post-reconciliation — pipeline Stage 2) ─────────────
    cols_in = [ustrip(u"inch", c.c1) for c in struc.columns]

    h_val = ustrip(u"inch", r.thickness)

    # ── Foundations (post-sizing — pipeline Stage 3) ─────────────────
    fdn = _extract_foundation_results(struc)

    # ── Embodied carbon + MUI (per-slab, A1–A3 product stage) ────────
    # `element_ec` returns a typed kgCO₂e quantity; strip once here at the CSV
    # boundary.  `u"kgCO2e"` resolves because `Asap` is `using`-ed above.
    slab_ec_kgco2e = isempty(slab.volumes) ? NaN :
        ustrip(u"kgCO2e", element_ec(slab.volumes))
    slab_area_m2   = ustrip(u"m^2",
        sum(struc.cells[ci].area for ci in slab.cell_indices; init = 0.0u"m^2"))
    slab_ec_per_m2 = (isnan(slab_ec_kgco2e) || slab_area_m2 ≤ 0.0) ?
        NaN : slab_ec_kgco2e / slab_area_m2
    mui = _extract_slab_mui(slab.volumes, slab_area_m2)

    return (
        floor_type      = string(floor_type),
        concrete        = String(concrete_label),
        lx_ft           = lx_ft,
        ly_ft           = ly_ft,
        live_psf        = live_psf,
        method          = method_name,
        h_in            = h_val,
        sw_psf          = ustrip(psf, r.self_weight),
        vol_per_area_in = ustrip(u"inch", r.volume_per_area),
        M0_kipft        = to_kipft(r.M0),
        qu_psf          = ustrip(psf, r.qu),
        punch_ratio     = pc.max_ratio,
        vu_max_psi      = vu_max_psi,
        defl_ratio      = r.deflection_check.ratio,
        defl_in         = ustrip(u"inch", r.deflection_check.Δ_check),
        col_min_in      = minimum(cols_in),
        col_max_in      = maximum(cols_in),
        col_rho_max     = col_rho_max,
        As_cs_in2       = ustrip(u"inch^2", As_cs),
        As_ms_in2       = ustrip(u"inch^2", As_ms),
        As_total_in2    = ustrip(u"inch^2", As_cs + As_ms),
        runtime_s       = round(elapsed; digits = 3),
        slab_ec_kgco2e  = slab_ec_kgco2e,
        slab_ec_per_m2  = slab_ec_per_m2,
        concrete_kg_per_m2 = mui.concrete_kg_per_m2,
        rebar_kg_per_m2    = mui.rebar_kg_per_m2,
        fdn_max_B_ft    = fdn.fdn_max_B_ft,
        fdn_max_L_ft    = fdn.fdn_max_L_ft,
        fdn_max_D_in    = fdn.fdn_max_D_in,
        fdn_max_util    = fdn.fdn_max_util,
    )
end

# adapted from flat_plate_method_comparison.jl:572-650 — full-schema NaN row so
# a failed run still carries every invariant column (all NaN) plus the keys.
function _blank_failure_row(;
    floor_type::Symbol,
    lx_ft::Float64,
    ly_ft::Float64,
    live_psf::Float64,
    method_name::String,
    elapsed::Float64,
    failure_reason::String = "",
    failing_check::String  = "",
    concrete_label::AbstractString = "NWC_4000",
)
    return (
        floor_type      = string(floor_type),
        concrete        = String(concrete_label),
        lx_ft           = lx_ft,
        ly_ft           = ly_ft,
        live_psf        = live_psf,
        method          = method_name,
        h_in            = NaN,
        sw_psf          = NaN,
        vol_per_area_in = NaN,
        M0_kipft        = NaN,
        qu_psf          = NaN,
        punch_ratio     = NaN,
        vu_max_psi      = NaN,
        defl_ratio      = NaN,
        defl_in         = NaN,
        col_min_in      = NaN,
        col_max_in      = NaN,
        col_rho_max     = NaN,
        As_cs_in2       = NaN,
        As_ms_in2       = NaN,
        As_total_in2    = NaN,
        runtime_s       = round(elapsed; digits = 3),
        slab_ec_kgco2e  = NaN,
        slab_ec_per_m2  = NaN,
        concrete_kg_per_m2 = NaN,
        rebar_kg_per_m2    = NaN,
        fdn_max_B_ft    = NaN,
        fdn_max_L_ft    = NaN,
        fdn_max_D_in    = NaN,
        fdn_max_util    = NaN,
        converged       = false,
        failure_reason  = failure_reason,
        failing_check   = failing_check,
    )
end

# adapted from flat_plate_method_comparison.jl:811-828 — DDM/EFM applicability
# pre-check (FEA always applicable).  Delegates entirely to the library checks.
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
    chk.ok && return (true, "")
    reason = isempty(chk.violations) ? "DDM/EFM not applicable" : join(chk.violations, "; ")
    return (false, reason)
end

# adapted from flat_plate_method_comparison.jl:844-936 — run the full design
# pipeline for one method (restore → set LL → applicability → build_pipeline →
# extract).  The RuleOfThumb branch is dropped (never exercised by the smoke
# matrix).  All sizing is delegated to `build_pipeline`.
function _run_method(struc, base_params::DesignParameters, method_cfg;
                     lx_ft::Float64, ly_ft::Float64,
                     live_psf::Float64,
                     floor_type::Symbol = :flat_plate,
                     concrete_label::AbstractString = "NWC_4000")
    restore!(struc)
    _set_live_load!(struc, live_psf)

    aspect = max(lx_ft, ly_ft) / min(lx_ft, ly_ft)
    if aspect > 2.0
        return _blank_failure_row(;
            floor_type, lx_ft, ly_ft, live_psf, concrete_label,
            method_name = method_cfg.name, elapsed = 0.0,
            failure_reason = "high_aspect_ratio",
            failing_check = "Aspect ratio $(round(aspect; digits=2)) > 2.0")
    end

    applicable, reason = _check_applicability_detailed(struc, method_cfg.method)
    if !applicable
        return _blank_failure_row(;
            floor_type, lx_ft, ly_ft, live_psf, concrete_label,
            method_name = method_cfg.name, elapsed = 0.0,
            failure_reason = "ddm_ineligible",
            failing_check = reason)
    end

    method_params = _with_method_and_ll(base_params, method_cfg.method, live_psf)

    t0 = time()
    try
        with_logger(NullLogger()) do
            stages = build_pipeline(method_params)
            for (i, stage) in enumerate(stages)
                stage.fn(struc)
                stage.needs_sync && sync_asap!(struc; params = method_params)
                # After slab sizing (stage 1): if the slab failed, skip the rest.
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
        failing_check = sprint(showerror, e)
        @warn "$(method_cfg.name) exception ($(round(elapsed; digits=1))s)" lx=lx_ft ly=ly_ft live=live_psf concrete=concrete_label err=failing_check
        return _blank_failure_row(;
            floor_type, lx_ft, ly_ft, live_psf, concrete_label,
            method_name = method_cfg.name, elapsed,
            failure_reason = string(typeof(e)), failing_check)
    end
    elapsed = time() - t0

    slab = struc.slabs[1]
    dd = slab.design_details
    if !isnothing(dd) && hasproperty(dd, :converged) && !dd.converged
        return _blank_failure_row(;
            floor_type, lx_ft, ly_ft, live_psf, concrete_label,
            method_name = method_cfg.name, elapsed,
            failure_reason = "non_convergence",
            failing_check = hasproperty(dd, :failing_check) ? string(dd.failing_check) : "")
    end

    row = _extract_results(struc;
        lx_ft, ly_ft, live_psf, floor_type, concrete_label,
        method_name = method_cfg.name, elapsed)
    isnothing(row) && return nothing
    return merge(row, (converged = true, failure_reason = "", failing_check = ""))
end

# -----------------------------------------------------------------------------
# Row projection — reduce a (success or failure) row to the fixed OUTPUT_COLS
# schema so every row that reaches the CSV has identical fields.
# -----------------------------------------------------------------------------
function _uniform_row(full)
    return NamedTuple{Tuple(OUTPUT_COLS)}(
        Tuple(hasproperty(full, c) ? getproperty(full, c) : NaN for c in OUTPUT_COLS))
end

# -----------------------------------------------------------------------------
# Run the smoke matrix
# -----------------------------------------------------------------------------

"""
    run_smoke() -> Vector{NamedTuple}

Run the fixed flat-plate smoke matrix and return the result rows (one per
(span, method)).  The structure is prepared once per span and reused across
methods via snapshot/restore — same pattern as the study's `sweep`.
"""
function run_smoke()
    rows = NamedTuple[]
    _print_header("Flat-Plate Speed-up Validation Smoke")
    println("  Spans:       $(SMOKE_SPANS) ft")
    println("  Live load:   $(SMOKE_LIVE_PSF) psf")
    println("  Concrete:    $(SMOKE_CONCRETE)")
    println("  Methods:     $(length(SMOKE_METHODS))")
    println("  Total runs:  $(length(SMOKE_SPANS) * length(SMOKE_METHODS))")
    println()

    for span in SMOKE_SPANS
        ht      = _adaptive_story_ht(span)
        max_col = _adaptive_max_col(span)

        local struc, base_params
        try
            base_params = _make_params(; sdl_psf = 20.0, max_col_in = max_col,
                                          concrete_label = SMOKE_CONCRETE)
            skel  = _build_skeleton(span, span, ht, SMOKE_N_BAYS)
            struc = BuildingStructure(skel)
            prepare!(struc, base_params)
        catch e
            @warn "Skeleton build / prepare failed — skipping span" span exception=e
            continue
        end

        for mcfg in SMOKE_METHODS
            full = _run_method(struc, base_params, mcfg;
                               lx_ft = span, ly_ft = span, live_psf = SMOKE_LIVE_PSF,
                               floor_type = :flat_plate,
                               concrete_label = SMOKE_CONCRETE)
            isnothing(full) && (@warn "Run returned nothing" span method=mcfg.name; continue)
            if hasproperty(full, :converged) && !full.converged
                @warn "Run did not converge — recording with NaNs" span method=mcfg.name reason=full.failure_reason
            end
            push!(rows, _uniform_row(full))
        end
    end
    return rows
end

# -----------------------------------------------------------------------------
# Minimal CSV I/O (no DataFrames / CSV dependency)
# -----------------------------------------------------------------------------

_csv_cell(x::AbstractString) =
    (occursin(',', x) || occursin('"', x) || occursin('\n', x)) ?
        '"' * replace(x, '"' => "\"\"") * '"' : String(x)
_csv_cell(x::Bool)          = string(x)
_csv_cell(x::Integer)       = string(x)
_csv_cell(x::AbstractFloat) = string(x)   # round-trippable shortest repr; NaN/Inf ok
_csv_cell(x)                = string(x)

"""Write `rows` (uniform `OUTPUT_COLS` schema) to `path` as CSV."""
function _write_csv(path::AbstractString, rows::Vector{<:NamedTuple})
    open(path, "w") do io
        println(io, join(String.(OUTPUT_COLS), ","))
        for r in rows
            println(io, join((_csv_cell(getproperty(r, c)) for c in OUTPUT_COLS), ","))
        end
    end
    return path
end

"""Split one CSV line, honoring double-quoted fields (RFC4180-ish)."""
function _split_csv_line(line::AbstractString)
    fields = String[]
    buf = IOBuffer()
    in_quotes = false
    i = firstindex(line)
    n = lastindex(line)
    while i <= n
        c = line[i]
        if in_quotes
            if c == '"'
                if i < n && line[nextind(line, i)] == '"'
                    write(buf, '"'); i = nextind(line, i)
                else
                    in_quotes = false
                end
            else
                write(buf, c)
            end
        else
            if c == '"'
                in_quotes = true
            elseif c == ','
                push!(fields, String(take!(buf)))
            else
                write(buf, c)
            end
        end
        i = nextind(line, i)
    end
    push!(fields, String(take!(buf)))
    return fields
end

"""Read a CSV written by `_write_csv` back into a `Vector{NamedTuple}`.
String columns (`STRING_COLS`) stay strings; everything else parses as Float64."""
function _read_csv(path::AbstractString)
    lines = readlines(path)
    isempty(lines) && return NamedTuple[]
    header = Symbol.(_split_csv_line(lines[1]))
    rows = NamedTuple[]
    for ln in Iterators.drop(lines, 1)
        isempty(strip(ln)) && continue
        cells = _split_csv_line(ln)
        vals = Any[]
        for (col, cell) in zip(header, cells)
            if col in STRING_COLS
                push!(vals, cell)
            else
                push!(vals, parse(Float64, cell))
            end
        end
        push!(rows, NamedTuple{Tuple(header)}(Tuple(vals)))
    end
    return rows
end

# -----------------------------------------------------------------------------
# Diff helpers
# -----------------------------------------------------------------------------

"""
    _close(a, b; rtol, atol) -> Bool

Numeric closeness with NaN-aware semantics: two NaNs compare equal (the
baseline records NaN for non-converged rows; a non-converged optimization run
should still match a non-converged baseline for the same row).  Strings, Bools,
and Ints compare with `isequal`.
"""
function _close(a, b; rtol::Float64 = 1e-8, atol::Float64 = 1e-10)
    if a isa AbstractFloat && b isa AbstractFloat
        (isnan(a) && isnan(b)) && return true
        return isapprox(a, b; rtol = rtol, atol = atol)
    end
    return isequal(a, b)
end

_row_key(row) =
    NamedTuple{Tuple(KEY_COLS)}(Tuple(getproperty(row, k) for k in KEY_COLS))

"""
    diff_against_baseline(now_rows, base_rows; rtol, atol) -> Vector{NamedTuple}

Align rows by `KEY_COLS` and report any invariant-column mismatches.  Returns a
vector of mismatch records (key, column, baseline value, latest value, abs
diff).  An empty vector means the smoke run is bit-equivalent (within `rtol`)
to the baseline.  Rows present on only one side are flagged as a structural
mismatch.
"""
function diff_against_baseline(now_rows::Vector{<:NamedTuple},
                               base_rows::Vector{<:NamedTuple};
                               rtol::Float64 = 1e-8,
                               atol::Float64 = 1e-10)
    mismatches = NamedTuple[]

    now_by_key  = Dict(_row_key(r) => r for r in now_rows)
    base_by_key = Dict(_row_key(r) => r for r in base_rows)

    for k in setdiff(keys(now_by_key), keys(base_by_key))
        push!(mismatches, (key = k, column = :_row_presence, baseline = missing,
                           latest = "row only in latest", diff = NaN))
    end
    for k in setdiff(keys(base_by_key), keys(now_by_key))
        push!(mismatches, (key = k, column = :_row_presence, baseline = "row only in baseline",
                           latest = missing, diff = NaN))
    end

    for k in intersect(keys(now_by_key), keys(base_by_key))
        rn = now_by_key[k]
        rb = base_by_key[k]
        for col in INVARIANT_COLS
            (hasproperty(rn, col) && hasproperty(rb, col)) || continue
            vn = getproperty(rn, col)
            vb = getproperty(rb, col)
            if !_close(vn, vb; rtol = rtol, atol = atol)
                d = (vn isa AbstractFloat && vb isa AbstractFloat) ? abs(vn - vb) : NaN
                push!(mismatches, (key = k, column = col, baseline = vb, latest = vn, diff = d))
            end
        end
    end
    return mismatches
end

"""
    _print_runtime_delta(now_rows, base_rows)

Print a side-by-side runtime comparison (per-row and total).  Purely
informational — runtime is not gated by the harness.
"""
function _print_runtime_delta(now_rows::Vector{<:NamedTuple},
                              base_rows::Vector{<:NamedTuple})
    now_by_key  = Dict(_row_key(r) => r for r in now_rows)
    base_by_key = Dict(_row_key(r) => r for r in base_rows)

    println()
    println("Runtime delta (per row, baseline vs latest):")
    @printf("  %-16s | %6s | %8s → %8s | %+8s\n",
            "method", "span", "base (s)", "new (s)", "Δ (%)")
    println("  " * "─"^65)

    total_base = 0.0
    total_now  = 0.0
    for k in sort(collect(intersect(keys(now_by_key), keys(base_by_key)));
                  by = x -> (x.lx_ft, x.method))
        rb = base_by_key[k]
        rn = now_by_key[k]
        b = rb.runtime_s; n = rn.runtime_s
        pct = b > 0 ? 100.0 * (n - b) / b : NaN
        @printf("  %-16s | %5.0f' | %7.2f → %7.2f | %+7.1f\n",
                k.method, k.lx_ft, b, n, pct)
        total_base += b
        total_now  += n
    end
    println("  " * "─"^65)
    pct_total = total_base > 0 ? 100.0 * (total_now - total_base) / total_base : NaN
    @printf("  %-16s | %5s | %7.2f → %7.2f | %+7.1f\n",
            "TOTAL", "", total_base, total_now, pct_total)
end

# -----------------------------------------------------------------------------
# Small study-utility shims (inlined from StructuralStudies/src/init.jl:42-73)
# -----------------------------------------------------------------------------

function _ensure_dir(dir::AbstractString)
    isdir(dir) || mkpath(dir)
    return dir
end

function _print_header(title::AbstractString)
    println("=" ^ 60)
    println(title)
    println("=" ^ 60)
    println()
end

function _print_footer(n_rows::Int, n_diffs::Int, output_file)
    println()
    println("=" ^ 60)
    println("Validation Complete")
    println("=" ^ 60)
    println("Rows:        $n_rows")
    println("Mismatches:  $n_diffs")
    println("Output file: $output_file")
    println()
end

# -----------------------------------------------------------------------------
# Entry point
# -----------------------------------------------------------------------------

function main(args::Vector{String} = String[])
    _ensure_dir(_SPEEDUP_DIR)

    regenerate = ("--regenerate-baseline" in args)

    rows = run_smoke()
    isempty(rows) && error("Smoke produced no rows — every span failed in `prepare!`.")

    _write_csv(LATEST_CSV, rows)
    println("Latest results → $(LATEST_CSV)  ($(length(rows)) rows)")

    # First-run / explicit regeneration: write baseline and stop. No diff.
    if regenerate || !isfile(BASELINE_CSV)
        _write_csv(BASELINE_CSV, rows)
        if regenerate
            println("Baseline regenerated → $(BASELINE_CSV)")
        else
            println("No baseline existed — saved current run as baseline → $(BASELINE_CSV)")
        end
        _print_footer(length(rows), 0, BASELINE_CSV)
        return rows
    end

    base_rows = _read_csv(BASELINE_CSV)
    diffs = diff_against_baseline(rows, base_rows)

    println()
    if isempty(diffs)
        println("✓ All $(length(INVARIANT_COLS)) invariant columns match baseline ($(length(rows)) rows).")
    else
        println("✗ $(length(diffs)) invariant mismatch(es) vs baseline:")
        for d in first(diffs, 30)
            key_str = join(("$(k)=$(v)" for (k, v) in pairs(d.key)), ", ")
            @printf("  [%s] %-22s baseline=%s latest=%s diff=%s\n",
                    key_str, String(d.column), repr(d.baseline), repr(d.latest), repr(d.diff))
        end
        length(diffs) > 30 && println("  … ($(length(diffs) - 30) more)")
    end

    _print_runtime_delta(rows, base_rows)
    _print_footer(length(rows), length(diffs), LATEST_CSV)

    if !isempty(diffs)
        @error "Speed-up validation FAILED — see mismatches above."
        exit(1)
    end
    return rows
end

# Allow `include` (REPL exploration) without auto-running by gating on
# `abspath(PROGRAM_FILE) == @__FILE__`.
if abspath(PROGRAM_FILE) == @__FILE__
    main(copy(ARGS))
end
