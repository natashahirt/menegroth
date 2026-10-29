# ==============================================================================
# Flat Plate Analysis Method Comparison Study
# ==============================================================================
#
# Compares all five flat plate sizing methods on square & rectangular bays:
#   1. MDDM        — Modified DDM (simplified 0.65/0.35 coefficients)
#   2. DDM          — Full ACI 318-11 §13.6 coefficients
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

include(joinpath(@__DIR__, "run_details.jl"))

const SR = StructuralSizer
const SS = StructuralSynthesizer

@isdefined(FP_RESULTS_DIR) || (const FP_RESULTS_DIR = joinpath(@__DIR__, "results"))

# ==============================================================================
# Method definitions
# ==============================================================================

# Pattern loading (ACI 318-11 §13.7.6, corpus: aci-318-11, page 261) is on
# for EFM and FEA. The envelope keeps the full-load moments and raises any
# station the checkerboard or adjacent-span patterns govern, so moments
# never fall below the uniform-load case. Patterns run only when L/D > 0.75
# at the thickness being analyzed (ACI 318-11 §13.7.6). A 50 psf office
# load stays under that ratio. A 150 psf load does too once the slab is
# thick enough that self-weight dominates; the result column `pattern_loading`
# records whether the envelope actually ran.
# DDM has no switch: its coefficients already cover pattern loading.
# Patterned spans use three-quarters of the factored live load
# (ACI 318-11 §13.7.6.3, corpus: aci-318-11, page 261). The full-load
# case is kept as a lower bound (§13.7.6.4).
# FEA uses :efm_amp (1-D frame ratios applied to slab and column demands).
# `FEA_PATTERN_RESOLVE` re-solves the shell and is a validation subset only.
#
# `CORE_METHODS` is the canonical comparison. `SENSITIVITY_METHODS` are
# solver and stiffness variants, not part of the default sweep.
const CORE_METHODS = [
    (key=:rot,    name="ACI Min",     method=SR.RuleOfThumb()),
    (key=:ddm,    name="DDM (Full)",  method=SR.DDM(:full)),
    (key=:efm,    name="EFM (ASAP)",  method=SR.EFM(solver=:asap, pattern_loading=true)),
    (key=:fea,    name="FEA (frame)", method=SR.FEA(; pattern_loading=true, pattern_mode=:efm_amp, design_approach=:frame)),
    (key=:fea_d,  name="FEA (strip)", method=SR.FEA(; pattern_loading=true, pattern_mode=:efm_amp, design_approach=:strip)),
    # `:area` requires `moment_transform=:wood_armer` to envelope twisting
    # moments per element (StructuralSizer/.../helpers.jl §_check_fea_approach_applicability).
    (key=:fea_a,  name="FEA (area)",  method=SR.FEA(; pattern_loading=true, pattern_mode=:efm_amp,
                                                      design_approach=:area,
                                                      moment_transform=:wood_armer)),
]

const SENSITIVITY_METHODS = [
    (key=:mddm,   name="MDDM",        method=SR.DDM(:simplified)),
    (key=:efm_hc, name="EFM (HC)",    method=SR.EFM(solver=:hardy_cross, pattern_loading=true)),
    (key=:efm_kc, name="EFM (Kc)",    method=SR.EFM(solver=:asap, column_stiffness=:Kc, pattern_loading=true)),
]

const ALL_METHODS = vcat(CORE_METHODS, SENSITIVITY_METHODS)

# Numerical seed for the computed-deflection search. Not an ACI minimum.
# At the default cover (0.75 in) and bar diameter (0.5 in), h = 2 in gives
# d = 0.75 in. ACI 318-11 §9.5.3.4 (corpus: aci-318-11, page 135) permits
# thickness below Table 9.5(c) when computed deflections satisfy Table 9.5(b).
const COMPUTED_DEFLECTION_SEED = 2.0u"inch"

# ENGINEERING JUDGMENT: practical floor at the §9.5.3.2 absolute values
# (5 in without drop panels, 4 in with them; corpus: aci-318-11, page 134).
# This is a sensitivity. The computed-deflection regime is allowed to
# search below it.
const PRACTICAL_FLOOR_PLATE = 5.0u"inch"
const PRACTICAL_FLOOR_SLAB  = 4.0u"inch"

# ACI 318-11 Table 9.5(b) (corpus: aci-318-11, page 133). Label and
# construction category for each deflection limit, recorded on every row.
# The study default is L/240: deflection after attachment of nonstructural
# elements (long-term sustained plus immediate live load). L/360 checks
# immediate live load only and did not govern any design.
const DEFL_LIMITS = Dict(
    :L_240 => ("L/240", "ACI 318-11 Table 9.5(b): floors supporting or attached to nonstructural elements not likely to be damaged by large deflections; deflection after attachment"),
    :L_360 => ("L/360", "ACI 318-11 Table 9.5(b): floors not supporting or attached to nonstructural elements likely to be damaged by large deflections; immediate live-load deflection"),
    :L_480 => ("L/480", "ACI 318-11 Table 9.5(b): floors supporting or attached to nonstructural elements likely to be damaged by large deflections; deflection after attachment"),
)
const DEFAULT_DEFL_LIMIT = :L_240

"""Row label and Table 9.5(b) category for a deflection limit symbol."""
function _defl_label(limit::Symbol)
    haskey(DEFL_LIMITS, limit) ||
        error("deflection_limit must be one of $(collect(keys(DEFL_LIMITS))), got $(limit)")
    return DEFL_LIMITS[limit]
end

"""FEA frame with shell re-solves per pattern. Not part of `ALL_METHODS`."""
const FEA_PATTERN_RESOLVE = (
    key=:fea_res, name="FEA (frame, resolve)",
    method=SR.FEA(; pattern_loading=true, pattern_mode=:fea_resolve, design_approach=:frame),
)

# ==============================================================================
# Concrete preset axis (Section 1 sensitivity)
# ==============================================================================
# Each entry pairs a `Concrete` preset with its matching `ReinforcedConcreteMaterial`
# (concrete + Rebar_60). The label is the canonical name from the material
# registry (`material_name(c)`) and is what gets recorded in the result CSV's
# `concrete` column.
#
# To add a new concrete to the sweep:
#   1. Define the `Concrete` preset in StructuralSizer/src/materials/concrete.jl
#      (with grounded ρ, Ec, ECC, and the matching `RC_<…>_60` reinforced preset).
#   2. Append `(label, concrete, material)` to CONCRETE_PRESETS below.
#   3. Add the label to DEFAULT_CONCRETES if you want it in the default sweep.
const CONCRETE_PRESETS = (
    NWC_3000 = (concrete = SR.NWC_3000, material = SR.RC_3000_60),
    NWC_4000 = (concrete = SR.NWC_4000, material = SR.RC_4000_60),
    NWC_5000 = (concrete = SR.NWC_5000, material = SR.RC_5000_60),
    NWC_6000 = (concrete = SR.NWC_6000, material = SR.RC_6000_60),
    LWC_4000 = (concrete = SR.LWC_4000, material = SR.RC_LWC_4000_60),
)

"""Default concrete-preset axis for the Section 1 sweep — four NWC strengths
(3, 4, 5, 6 ksi) plus one sand-LWC at 4 ksi."""
const DEFAULT_CONCRETES = ["NWC_3000", "NWC_4000", "NWC_5000", "NWC_6000", "LWC_4000"]

"""Look up a concrete preset by label, with a clear error if missing."""
function _concrete_preset(label::AbstractString)
    sym = Symbol(label)
    haskey(CONCRETE_PRESETS, sym) ||
        error("Unknown concrete preset \"$label\". Known: $(collect(keys(CONCRETE_PRESETS)))")
    return CONCRETE_PRESETS[sym]
end

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
    (key=:hc_kec,         name="HC  Kec",          method=SR.EFM(solver=:hardy_cross, column_stiffness=:Kec, pattern_loading=true)),
    (key=:hc_kc,          name="HC  Kc",           method=SR.EFM(solver=:hardy_cross, column_stiffness=:Kc,  pattern_loading=true)),
    # ── ASAP (gross Ig) ─────────────────────────────────────────────────────
    (key=:asap_kec,       name="ASAP Kec",         method=SR.EFM(solver=:asap, column_stiffness=:Kec, pattern_loading=true)),
    (key=:asap_kc,        name="ASAP Kc",          method=SR.EFM(solver=:asap, column_stiffness=:Kc,  pattern_loading=true)),
    # ── ASAP (cracked 0.70 Ig) ──────────────────────────────────────────────
    (key=:asap_kec_crack, name="ASAP Kec cracked",  method=SR.EFM(solver=:asap, column_stiffness=:Kec, cracked_columns=true, pattern_loading=true)),
    (key=:asap_kc_crack,  name="ASAP Kc  cracked",  method=SR.EFM(solver=:asap, column_stiffness=:Kc,  cracked_columns=true, pattern_loading=true)),
]

# ==============================================================================
# Adaptive helpers
# ==============================================================================

"""Scale story height with span (12 ft baseline, grows for long spans)."""
_adaptive_story_ht(span_ft::Float64) = max(12.0, round(span_ft / 3.0))

"""Max column constraint scaled to span — limits slab-loop column growth.

`ratio` is the span-to-column multiplier. The default 1.1 is then clamped
to 36–60 in, so a 20 ft bay still allows a 36 in column. That floor is
large for the span: a 20 ft bay more often lands near 16–24 in. Punching
demand goes into the column until this cap, and only then into slab
thickness, so the clamp is part of the thickness result.

This is the E5 sensitivity cap (`column_cap=:adaptive`). The main runs
use `span15_max_col`. `col_ratio` on the sweeps still passes through this
clamp.
"""
_adaptive_max_col(span_ft::Float64; ratio::Float64 = 1.1) =
    clamp(round(span_ft * ratio), 36.0, 60.0)

"""Column cap for the main runs, in inches: span/15.

0.8 × span in ft gives inches (span/15), clamped to 16–36 in. A 20 ft bay
is 16 in. It stands in for the practical column size, beyond which a
designer adds studs or drop panels rather than a larger column. A fixed
24 in cap is the sweeps' `max_col_in=24` argument. The generous
`_adaptive_max_col` is the E5 sensitivity case.
"""
span15_max_col(span_ft::Float64) = clamp(round(span_ft * 0.8), 16.0, 36.0)

"""Resolve the column cap for one span.

An explicit `max_col_in` wins, including a fixed 24 in. The default
`column_cap=:span15` uses `span15_max_col`. `column_cap=:adaptive` is the
E5 case, and `col_ratio` still passes through its 36 in floor.
"""
function _resolve_max_col(span_ft::Float64;
                          max_col_in::Union{Nothing, Real} = nothing,
                          col_ratio::Real = 1.1,
                          column_cap::Symbol = :span15,
                          uncap::Bool = false)
    !isnothing(max_col_in) && return Float64(max_col_in)
    uncap && return _uncapped_max_col(span_ft)
    column_cap === :span15 && return span15_max_col(span_ft)
    column_cap === :adaptive ||
        error("column_cap must be :span15 or :adaptive, got $(column_cap)")
    return _adaptive_max_col(span_ft; ratio = Float64(col_ratio))
end

"""Inches stored on a column side. `nothing` and a non-positive side are missing."""
function _dim_in(x)
    isnothing(x) && return NaN
    v = ustrip(u"inch", x)
    return v > 0 ? v : NaN
end

"""
    _story_column_sizes(columns, story; cap_in, increment_in) -> NamedTuple

Column section on one floor.

`story` is `Column.story`: the skeleton key of the floor at the top of the
column, which is the slab that column supports. Roof and ground columns
are left out.

`col_c1_in` and `col_c2_in` are the largest side on that floor. The
per-position fields are the largest side in `:corner`, `:edge`, and
`:interior`, so an enlarged edge column is not hidden inside one min/max.
`col_at_cap` is true when any column's larger side is within one size
increment of `cap_in`. The section could not take another increment
without passing the cap.
"""
function _story_column_sizes(columns, story; cap_in::Real = NaN, increment_in::Real = 0.5)
    blank = (
        col_c1_in = NaN, col_c2_in = NaN, col_at_cap = false,
        col_min_c1_in = NaN,
        col_c1_corner_in = NaN, col_c2_corner_in = NaN,
        col_c1_edge_in = NaN, col_c2_edge_in = NaN,
        col_c1_interior_in = NaN, col_c2_interior_in = NaN,
    )
    isnothing(story) && return blank
    c1s = Float64[]
    c2s = Float64[]
    by_pos = Dict{Symbol, Vector{Tuple{Float64, Float64}}}()
    at_cap = false
    for col in columns
        col.story == story || continue
        c1 = _dim_in(col.c1)
        c2 = _dim_in(col.c2)
        isfinite(c1) && push!(c1s, c1)
        isfinite(c2) && push!(c2s, c2)
        push!(get!(by_pos, col.position, Tuple{Float64, Float64}[]), (c1, c2))
        finite_sides = filter(isfinite, (c1, c2))
        side = isempty(finite_sides) ? NaN : maximum(finite_sides)
        if isfinite(cap_in) && isfinite(side) && side >= cap_in - increment_in - 1e-9
            at_cap = true
        end
    end
    pos_max(pos, idx) = begin
        pairs = get(by_pos, pos, Tuple{Float64, Float64}[])
        vals = [p[idx] for p in pairs if isfinite(p[idx])]
        isempty(vals) ? NaN : maximum(vals)
    end
    return (
        col_c1_in = isempty(c1s) ? NaN : maximum(c1s),
        col_c2_in = isempty(c2s) ? NaN : maximum(c2s),
        col_at_cap = at_cap,
        col_min_c1_in = isempty(c1s) ? NaN : minimum(c1s),
        col_c1_corner_in = pos_max(:corner, 1),
        col_c2_corner_in = pos_max(:corner, 2),
        col_c1_edge_in = pos_max(:edge, 1),
        col_c2_edge_in = pos_max(:edge, 2),
        col_c1_interior_in = pos_max(:interior, 1),
        col_c2_interior_in = pos_max(:interior, 2),
    )
end

"""Cap recorded on a sweep row, in inches, from the floor options actually used."""
function _params_max_col_in(params)
    floor = params.floor
    fp = floor isa SR.FlatSlabOptions ? floor.base : floor
    return ustrip(u"inch", fp.max_column_size)
end

"""Column size increment, in inches. One step short of the cap still counts as capped."""
function _params_col_increment_in(params)
    cols = params.columns
    hasproperty(cols, :size_increment) || return 0.5
    return ustrip(u"inch", cols.size_increment)
end

"""Punching strategy recorded on a sweep row, from the floor options actually used."""
function _params_punching_strategy(params)
    floor = params.floor
    fp = floor isa SR.FlatSlabOptions ? floor.base : floor
    return fp.punching_strategy
end

"""Deflection limit recorded on a sweep row, from the floor options actually used."""
function _params_defl_limit(params)
    floor = params.floor
    fp = floor isa SR.FlatSlabOptions ? floor.base : floor
    return fp.deflection_limit
end

"""
    _uncapped_max_col(span_ft) -> Float64

Generous max-column constraint scaled to span, intended for **failure-mode
diagnostics** rather than realistic design. Returns `clamp(round(span_ft × 2), 60, 240)`,
i.e. always at least 60″ (the conventional flat-plate practical limit) and
never beyond 240″ (20 ft, reserved for clearly impossible designs).

Use this with `dual_heatmap_sweep(...; uncap_columns = true)` to expose the
underlying engineering failure mode (punching, deflection, flexural)
instead of the parameter-bound "Max Column" failure that otherwise swamps
long-span cells in failure-mode heatmaps.
"""
_uncapped_max_col(span_ft::Float64) = clamp(round(span_ft * 2.0), 60.0, 240.0)

# ==============================================================================
# DesignParameters construction
# ==============================================================================

"""
    _make_params(; method, floor_type, concrete_label, ...)

Build `DesignParameters` for one sweep run.  The `method` kwarg selects
which analysis method the pipeline's `size_slabs!` stage will use, and
`concrete_label` selects which slab concrete (and matching reinforced
preset) is used — see `CONCRETE_PRESETS`.  Columns and foundations are
intentionally held at fixed presets (`NWC_6000` and `NWC_4000`
respectively) so that the concrete sensitivity isolates the slab.

Pipeline stages (handled automatically by `build_pipeline`):
  1. size_slabs!  (with selected method + slab concrete)
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
    punching_thickening::Bool = true,
    min_h               = nothing,
    max_iterations::Int = 150,
    deflection_limit::Symbol = DEFAULT_DEFL_LIMIT,
    column_strategy::Symbol = :catalog,
    concrete_label::AbstractString = "NWC_4000",
)
    preset = _concrete_preset(concrete_label)
    fp = SR.FlatPlateOptions(
        method           = method,
        material         = preset.material,
        shear_studs      = shear_studs,
        max_column_size  = max_col_in * u"inch",
        # Columns from axial load and P-M; punching grows them up to the cap.
        column_span_minimum = false,
        punching_thickening = punching_thickening,
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
        materials = MaterialOptions(
            concrete = preset.concrete,
            rebar = SR.Rebar_60,
            column = SR.RC_6000_60,
        ),
        columns   = SR.ConcreteColumnOptions(
            material        = SR.NWC_6000,
            # :all spans 8–72 in. :high_capacity starts at 18 in, which sits
            # above the span/15 cap at short spans and would override it.
            catalog         = :all,
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
                             live_psf::Float64;
                             min_h = :inherit)
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
        column_span_minimum = fp_base.column_span_minimum,
        punching_thickening = fp_base.punching_thickening,
        stud_material    = fp_base.stud_material,
        stud_diameter    = fp_base.stud_diameter,
        min_h            = min_h === :inherit ? fp_base.min_h : min_h,
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

"""Build a `BuildingSkeleton` for the given rectangular bay grid.

Defaults to a single-story skeleton (the slab-method comparison case).
Pass `n_stories > 1` to generate a multi-story building for full-pipeline
EC sweeps (Section 3)."""
function _build_skeleton(lx_ft::Float64, ly_ft::Float64,
                         story_ht_ft::Float64, n_bays::Int;
                         n_stories::Int = 1)
    total_x = lx_ft * n_bays * u"ft"
    total_y = ly_ft * n_bays * u"ft"
    ht      = story_ht_ft * u"ft"
    gen_medium_office(total_x, total_y, ht, n_bays, n_bays, n_stories)
end

"""Map each slab index to the story that owns most of its cells."""
function _slab_story_map(struc)
    face_to_story = Dict{Int, Int}()
    for (story_idx, story) in struc.skeleton.stories
        for face_idx in story.faces
            face_to_story[face_idx] = story_idx
        end
    end
    by_story = Dict{Int, Vector{Int}}()
    for (slab_idx, slab) in enumerate(struc.slabs)
        counts = Dict{Int, Int}()
        for ci in slab.cell_indices
            sid = get(face_to_story, struc.cells[ci].face_idx, nothing)
            isnothing(sid) && continue
            counts[sid] = get(counts, sid, 0) + 1
        end
        isempty(counts) && continue
        push!(get!(by_story, argmax(counts), Int[]), slab_idx)
    end
    return by_story
end

"""
Median story below the roof. A 3-story building reports story 2.
When two floors are equally central, the upper one is used.
"""
function _intermediate_story(by_story)
    stories = sort!(collect(keys(by_story)))
    isempty(stories) && return nothing
    floors = length(stories) == 1 ? stories : stories[1:end-1]
    return floors[cld(length(floors) + 1, 2)]
end

"""Slab reported by the study: the intermediate floor, or the only floor."""
function _select_study_slab(struc)
    by_story = _slab_story_map(struc)
    story = _intermediate_story(by_story)
    if isnothing(story) || !haskey(by_story, story) || isempty(by_story[story])
        return (slab = struc.slabs[1], slab_index = 1, story = 1, story_role = "only")
    end
    idx = first(by_story[story])
    role = length(by_story) == 1 ? "only" : "intermediate"
    return (slab = struc.slabs[idx], slab_index = idx, story = story, story_role = role)
end

"""First slab whose design did not converge, or `nothing`."""
function _first_failed_slab(struc)
    for slab in struc.slabs
        dd = slab.design_details
        if !isnothing(dd) && hasproperty(dd, :converged) && !dd.converged
            return dd
        end
    end
    return nothing
end

"""Method knobs recorded on every result row."""
function _option_fields(method=nothing; deflection_limit::Symbol = DEFAULT_DEFL_LIMIT)
    defl_label, defl_cat = _defl_label(deflection_limit)
    return (
        pattern_mode = method isa SR.FEA ? string(method.pattern_mode) : "",
        pattern_requested = (method isa SR.EFM || method isa SR.FEA) ? method.pattern_loading : false,
        design_approach = method isa SR.FEA ? string(method.design_approach) : "",
        averaging_width_factor = (method isa SR.FEA && method.averaging_width_factor !== nothing) ?
            method.averaging_width_factor : NaN,
        fea_moment_transform = method isa SR.FEA ? string(method.moment_transform) : "",
        fea_field_smoothing = method isa SR.FEA ? string(method.field_smoothing) : "",
        fea_torsion_discount = method isa SR.FEA ? method.concrete_torsion_discount : missing,
        fea_patch_stiffness = method isa SR.FEA ? method.patch_stiffness_factor : NaN,
        fea_target_edge_m = (method isa SR.FEA && !isnothing(method.target_edge)) ?
            ustrip(u"m", method.target_edge) : NaN,
        efm_solver = method isa SR.EFM ? string(method.solver) : "",
        column_stiffness = method isa SR.EFM ? string(method.column_stiffness) : "",
        shear_demand_source = "analytical",
        defl_limit = defl_label,
        defl_category = defl_cat,
    )
end

function _shear_fields(dd)
    empty = (Vu_kip = NaN, Vu_fea_kip = NaN, Vu_fea_ratio = NaN)
    (isnothing(dd) || !hasproperty(dd, :one_way_shear) || isnothing(dd.one_way_shear)) && return empty
    shear = dd.one_way_shear
    Vu_fea = hasproperty(shear, :Vu_fea) ? shear.Vu_fea : nothing
    return (
        Vu_kip = ustrip(kip, shear.Vu),
        Vu_fea_kip = isnothing(Vu_fea) ? NaN : ustrip(kip, Vu_fea),
        Vu_fea_ratio = hasproperty(shear, :fea_ratio) ? shear.fea_ratio : NaN,
    )
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
    _extract_slab_mui(volumes, floor_area_m2) -> NamedTuple

Split a slab's `MaterialVolumes` into concrete- vs rebar-side contributions
and normalize by floor area to produce Material Use Intensity metrics.

Concrete-side materials = `Concrete`, `ReinforcedConcreteMaterial`,
`FiberReinforcedConcrete`. Rebar-side materials = `RebarSteel`. This split
matches the material taxonomy in `StructuralSizer/src/materials/types.jl`.

Returns a NamedTuple with both volume (m³, m³/m²) and mass (kg, kg/m²)
breakdowns. `concrete_t_eq_m` is the equivalent uniform concrete thickness
(m³ concrete / m² floor) — useful as a method-agnostic mass proxy.

Returns NaNs when `volumes` is empty or `floor_area_m2 ≤ 0` (failed runs).
"""
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
        else  # Concrete, ReinforcedConcreteMaterial, FiberReinforcedConcrete, …
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

"""
    _defl_report(dc, dd) -> NamedTuple

Deflection columns beyond the governing check.

`defl_source` is `"fea_direct"` when the thickness was accepted on the FEA
nodal displacement, and `"crossing_beam"` for DDM, EFM, and ACI Min.
`defl_ratio_cb` / `defl_in_cb` are the crossing-beam values. For non-FEA
methods they equal the governing check. `governing_check` is the last
check that forced a thickness increase, `"table_minimum"` when the
Table 9.5(c) start thickness passed, or `"search_floor"` when a
caller-supplied floor passed on the first pass.
"""
function _defl_report(dc, dd)
    governing = "table_minimum"
    if !isnothing(dd) && hasproperty(dd, :governing_check)
        g = string(dd.governing_check)
        isempty(g) || (governing = g)
    end
    is_fea = !isnothing(dd) && hasproperty(dd, :method_used) && dd.method_used isa SR.FEA
    cb_ratio = dc.ratio
    cb_in = ustrip(u"inch", dc.Δ_check)
    if is_fea
        cb = hasproperty(dd, :deflection_check_crossing_beam) ?
             dd.deflection_check_crossing_beam : nothing
        if isnothing(cb)
            cb_ratio = NaN
            cb_in = NaN
        else
            lim = ustrip(u"inch", cb.Δ_limit)
            cb_in = ustrip(u"inch", cb.Δ_check)
            cb_ratio = lim == 0.0 ? NaN : cb_in / lim
        end
    end
    return (
        defl_source    = is_fea ? "fea_direct" : "crossing_beam",
        defl_ratio_cb  = cb_ratio,
        defl_in_cb     = cb_in,
        governing_check = governing,
    )
end

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
                          elapsed::Float64,
                          concrete_label::AbstractString = "NWC_4000",
                          method = nothing,
                          max_col_in::Float64 = NaN,
                          col_increment_in::Float64 = 0.5,
                          deflection_limit::Symbol = DEFAULT_DEFL_LIMIT)
    picked = _select_study_slab(struc)
    slab = picked.slab
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

    # ── Columns on the reported floor (pipeline Stage 2) ────────────
    # `col.story` is the floor at the top of the column. Roof and ground
    # sections are a different story and are not mixed into this row.
    col_sizes = _story_column_sizes(struc.columns, picked.story;
                                    cap_in = max_col_in, increment_in = col_increment_in)
    cols_in = Float64[]
    for col in struc.columns
        col.story == picked.story || continue
        c1 = _dim_in(col.c1)
        isfinite(c1) && push!(cols_in, c1)
    end
    if isempty(cols_in)
        cols_in = [_dim_in(c.c1) for c in struc.columns if isfinite(_dim_in(c.c1))]
    end

    # ── ACI minimum thickness ────────────────────────────────────────
    col_avg_ft = isempty(cols_in) ? 0.0 : sum(cols_in) / length(cols_in) / 12.0
    ln_ft = max(lx_ft, ly_ft) - col_avg_ft
    ft_tag = floor_type === :flat_slab ? SR.FlatSlab() : SR.FlatPlate()
    h_min = SR.min_thickness(ft_tag, ln_ft * u"ft")
    h_min_val = ustrip(u"inch", h_min)
    h_val = ustrip(u"inch", r.thickness)

    # ── Foundations (post-sizing — pipeline Stage 3) ──────────────────
    fdn = _extract_foundation_results(struc)

    # ── Embodied carbon + MUI (per-slab, A1–A3 product stage) ────────
    # element_ec uses slab.volumes (concrete + rebar), populated by the
    # pipeline via _compute_slab_volumes. Area sums struc.cells indexed
    # by slab.cell_indices (matches compute_building_ec's floor_area logic).
    # MUI splits volume / mass by material class so EC = MUI × ECC can
    # be decoupled from material assumptions in Section 2 sensitivity.
    #
    # `element_ec` returns a typed `kgCO₂e` quantity since the kgCO2e
    # refactor; this is the DataFrame / CSV boundary, so strip it once
    # here and keep the derived `slab_ec_per_m2` numeric.
    slab_ec_kgco2e = isempty(slab.volumes) ? NaN :
        ustrip(u"kgCO2e", element_ec(slab.volumes))
    slab_area_m2   = ustrip(u"m^2",
        sum(struc.cells[ci].area for ci in slab.cell_indices; init = 0.0u"m^2"))
    slab_ec_per_m2 = (isnan(slab_ec_kgco2e) || slab_area_m2 ≤ 0.0) ?
        NaN : slab_ec_kgco2e / slab_area_m2
    mui = _extract_slab_mui(slab.volumes, slab_area_m2)

    # ── Pattern loading flag ────────────────────────────────────────────
    _pattern = !isnothing(dd) && hasproperty(dd, :pattern_loading) ? dd.pattern_loading : false

    # ── RuleOfThumb failures ─────────────────────────────────────────
    _failures = if !isnothing(dd) && hasproperty(dd, :failures)
        join(dd.failures, ", ")
    else
        ""
    end

    defl = _defl_report(r.deflection_check, dd)
    shear = _shear_fields(dd)

    return merge((
        floor_type        = string(floor_type),
        concrete          = String(concrete_label),
        lx_ft             = lx_ft,
        ly_ft             = ly_ft,
        story             = picked.story,
        story_role        = picked.story_role,
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
        defl_source       = defl.defl_source,
        defl_ratio_cb     = defl.defl_ratio_cb,
        defl_in_cb        = defl.defl_in_cb,
        governing_check   = defl.governing_check,
        Vu_kip            = shear.Vu_kip,
        Vu_fea_kip        = shear.Vu_fea_kip,
        Vu_fea_ratio      = shear.Vu_fea_ratio,
        max_col_in        = max_col_in,
        col_min_in        = col_sizes.col_min_c1_in,
        col_max_in        = col_sizes.col_c1_in,
        col_c1_in         = col_sizes.col_c1_in,
        col_c2_in         = col_sizes.col_c2_in,
        col_at_cap        = col_sizes.col_at_cap,
        col_c1_corner_in  = col_sizes.col_c1_corner_in,
        col_c2_corner_in  = col_sizes.col_c2_corner_in,
        col_c1_edge_in    = col_sizes.col_c1_edge_in,
        col_c2_edge_in    = col_sizes.col_c2_edge_in,
        col_c1_interior_in = col_sizes.col_c1_interior_in,
        col_c2_interior_in = col_sizes.col_c2_interior_in,
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
        # Material Use Intensity (per-slab, normalized by floor area)
        concrete_vol_m3       = mui.concrete_vol_m3,
        rebar_vol_m3          = mui.rebar_vol_m3,
        concrete_mass_kg      = mui.concrete_mass_kg,
        rebar_mass_kg         = mui.rebar_mass_kg,
        slab_mass_kg          = mui.slab_mass_kg,
        mui_kg_per_m2         = mui.mui_kg_per_m2,
        concrete_kg_per_m2    = mui.concrete_kg_per_m2,
        rebar_kg_per_m2       = mui.rebar_kg_per_m2,
        concrete_t_eq_m       = mui.concrete_t_eq_m,
        rebar_vol_per_m2      = mui.rebar_vol_per_m2,
        failures          = _failures,
    ), fdn, _option_fields(method; deflection_limit))
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
    concrete_label::AbstractString = "NWC_4000",
    method = nothing,
    story::Int = -1,
    story_role::String = "",
    max_col_in::Float64 = NaN,
    deflection_limit::Symbol = DEFAULT_DEFL_LIMIT,
    h_in::Float64 = NaN,
)
    return merge((
        floor_type        = string(floor_type),
        concrete          = String(concrete_label),
        lx_ft             = lx_ft,
        ly_ft             = ly_ft,
        story             = story,
        story_role        = story_role,
        story_ht_ft       = story_ht_ft,
        live_psf          = live_psf,
        method            = method_name,
        h_in              = h_in,
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
        defl_source       = "",
        defl_ratio_cb     = NaN,
        defl_in_cb        = NaN,
        governing_check   = failing_check,
        Vu_kip            = NaN,
        Vu_fea_kip        = NaN,
        Vu_fea_ratio      = NaN,
        max_col_in        = max_col_in,
        col_min_in        = NaN,
        col_max_in        = NaN,
        col_c1_in         = NaN,
        col_c2_in         = NaN,
        col_at_cap        = false,
        col_c1_corner_in  = NaN,
        col_c2_corner_in  = NaN,
        col_c1_edge_in    = NaN,
        col_c2_edge_in    = NaN,
        col_c1_interior_in = NaN,
        col_c2_interior_in = NaN,
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
        concrete_vol_m3       = NaN,
        rebar_vol_m3          = NaN,
        concrete_mass_kg      = NaN,
        rebar_mass_kg         = NaN,
        slab_mass_kg          = NaN,
        mui_kg_per_m2         = NaN,
        concrete_kg_per_m2    = NaN,
        rebar_kg_per_m2       = NaN,
        concrete_t_eq_m       = NaN,
        rebar_vol_per_m2      = NaN,
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
    ), _option_fields(method; deflection_limit))
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
                              elapsed::Float64,
                              concrete_label::AbstractString = "NWC_4000",
                              method = nothing,
                              max_col_in::Float64 = NaN,
                              col_increment_in::Float64 = 0.5,
                              deflection_limit::Symbol = DEFAULT_DEFL_LIMIT)
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

    # Reported floor only. A failed table-minimum run may still have sized
    # the columns of that story inside the slab pass.
    picked = _select_study_slab(struc)
    col_sizes = _story_column_sizes(struc.columns, picked.story;
                                    cap_in = max_col_in, increment_in = col_increment_in)
    col_rho_max = 0.0
    if hasproperty(dd, :column_results) && !isnothing(dd.column_results)
        ρg_vals = [v.ρg for v in values(dd.column_results)]
        col_rho_max = isempty(ρg_vals) ? 0.0 : maximum(ρg_vals)
    end

    _failures = hasproperty(dd, :failures) ? join(dd.failures, ", ") : ""
    rot_defl = isnothing(sr) ? nothing : _defl_report(sr.deflection_check, dd)
    shear = _shear_fields(dd)
    governing = if hasproperty(dd, :governing_check) && !isempty(string(dd.governing_check))
        string(dd.governing_check)
    elseif isempty(_failures)
        "table_minimum"
    else
        _failures
    end

    return merge((
        floor_type        = string(floor_type),
        concrete          = String(concrete_label),
        lx_ft             = lx_ft,
        ly_ft             = ly_ft,
        story             = picked.story,
        story_role        = picked.story_role,
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
        defl_source       = isnothing(rot_defl) ? "" : rot_defl.defl_source,
        defl_ratio_cb     = isnothing(rot_defl) ? NaN : rot_defl.defl_ratio_cb,
        defl_in_cb        = isnothing(rot_defl) ? NaN : rot_defl.defl_in_cb,
        governing_check   = governing,
        Vu_kip            = shear.Vu_kip,
        Vu_fea_kip        = shear.Vu_fea_kip,
        Vu_fea_ratio      = shear.Vu_fea_ratio,
        max_col_in        = max_col_in,
        col_min_in        = col_sizes.col_min_c1_in,
        col_max_in        = col_sizes.col_c1_in,
        col_c1_in         = col_sizes.col_c1_in,
        col_c2_in         = col_sizes.col_c2_in,
        col_at_cap        = col_sizes.col_at_cap,
        col_c1_corner_in  = col_sizes.col_c1_corner_in,
        col_c2_corner_in  = col_sizes.col_c2_corner_in,
        col_c1_edge_in    = col_sizes.col_c1_edge_in,
        col_c2_edge_in    = col_sizes.col_c2_edge_in,
        col_c1_interior_in = col_sizes.col_c1_interior_in,
        col_c2_interior_in = col_sizes.col_c2_interior_in,
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
        concrete_vol_m3       = NaN,
        rebar_vol_m3          = NaN,
        concrete_mass_kg      = NaN,
        rebar_mass_kg         = NaN,
        slab_mass_kg          = NaN,
        mui_kg_per_m2         = NaN,
        concrete_kg_per_m2    = NaN,
        rebar_kg_per_m2       = NaN,
        concrete_t_eq_m       = NaN,
        rebar_vol_per_m2      = NaN,
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
    ), _option_fields(method; deflection_limit))
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
contain ACI code references like "§13.6.1.2: Panel aspect ratio l₂/l₁ = 2.5 > 2.0".
"""
function _check_applicability_detailed(struc, method)
    method isa SR.FEA && return (true, "")
    method isa SR.RuleOfThumb && return (true, "")
    slab = _select_study_slab(struc).slab
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

Every returned row carries a `run_id` and building / reported-floor summary
fields. With `details = _detail_sink()`, the run's per-column and per-slab
rows are appended to it under the same `run_id` (see `run_details.jl`).
"""
function _run_method(struc, base_params::DesignParameters, method_cfg;
                     details = nothing,
                     live_psf::Float64,
                     min_h = :inherit,
                     kw...)
    timings = Dict{Int, Float64}()
    row = _run_method_core(struc, base_params, method_cfg; live_psf, min_h, timings, kw...)
    isnothing(row) && return nothing
    run_id = _new_run_id()
    params = _with_method_and_ll(base_params, method_cfg.method, live_psf; min_h)
    t0 = time()
    summary = _attach_details!(details, struc, params, run_id;
                               cap_in = _params_max_col_in(base_params),
                               increment_in = _params_col_increment_in(base_params))
    # Wall time per pipeline stage (seconds; stage 1 slabs, 2 column
    # reconciliation, 3+ foundations), and for capture + detail collection.
    later = [t for (i, t) in timings if i >= 3]
    times = (t_slabs_s       = get(timings, 1, NaN),
             t_columns_s     = get(timings, 2, NaN),
             t_foundations_s = isempty(later) ? NaN : sum(later),
             t_details_s     = time() - t0)
    return merge(row, (run_id = run_id,), times, summary)
end

function _run_method_core(struc, base_params::DesignParameters, method_cfg;
                          lx_ft::Float64, ly_ft::Float64,
                          live_psf::Float64,
                          floor_type::Symbol = :flat_plate,
                          concrete_label::AbstractString = "NWC_4000",
                          min_h = :inherit,
                          timings::Union{Nothing, Dict{Int, Float64}} = nothing)
    restore!(struc)
    _set_live_load!(struc, live_psf)
    cap_in = _params_max_col_in(base_params)
    cap_inc = _params_col_increment_in(base_params)
    defl_limit = _params_defl_limit(base_params)

    # Check high aspect ratio (Ly/Lx > 2.0 is outside DDM limits and generally
    # impractical for flat plate design)
    aspect = max(lx_ft, ly_ft) / min(lx_ft, ly_ft)
    if aspect > 2.0
        return _blank_failure_row(;
            floor_type, lx_ft, ly_ft, live_psf, concrete_label,
            method_name = method_cfg.name, method = method_cfg.method, elapsed = 0.0,
            failure_reason = "high_aspect_ratio",
            failing_check = "Aspect ratio $(round(aspect; digits=2)) > 2.0",
            max_col_in = cap_in, deflection_limit = defl_limit)
    end

    # Pre-check applicability (DDM/EFM only; FEA always passes)
    applicable, reason = _check_applicability_detailed(struc, method_cfg.method)
    if !applicable
        return _blank_failure_row(;
            floor_type, lx_ft, ly_ft, live_psf, concrete_label,
            method_name = method_cfg.name, method = method_cfg.method, elapsed = 0.0,
            failure_reason = "ddm_ineligible",
            failing_check = reason,
            max_col_in = cap_in, deflection_limit = defl_limit)
    end

    # Derive run params from base — swap method + live load, keep everything else
    method_params = _with_method_and_ll(base_params, method_cfg.method, live_psf;
                                        min_h = min_h)

    is_rot = method_cfg.method isa SR.RuleOfThumb

    t0 = time()
    failure_reason = ""
    failing_check  = ""
    try
        with_logger(NullLogger()) do
            stages = build_pipeline(method_params)
            for (i, stage) in enumerate(stages)
                t_stage = time()
                stage.fn(struc)
                stage.needs_sync && sync_asap!(struc; params = method_params)
                isnothing(timings) || (timings[i] = time() - t_stage)

                # After slab sizing (stage 1), check for non-convergence.
                # If the slab failed, skip columns & foundations entirely.
                if i == 1
                    dd_early = _first_failed_slab(struc)
                    if !isnothing(dd_early)
                        break
                    end
                end
            end
        end
    catch e
        elapsed = time() - t0
        failure_reason = string(typeof(e))
        failing_check  = sprint(showerror, e)
        @warn "$(method_cfg.name) exception ($(round(elapsed; digits=1))s)" lx=lx_ft ly=ly_ft live=live_psf concrete=concrete_label err=failing_check
        return _blank_failure_row(;
            floor_type, lx_ft, ly_ft, live_psf, concrete_label,
            method_name = method_cfg.name, method = method_cfg.method, elapsed,
            failure_reason, failing_check,
            max_col_in = cap_in, deflection_limit = defl_limit)
    end
    elapsed = time() - t0

    # Check for non-convergence (structured failure from pipeline)
    dd = _first_failed_slab(struc)
    isnothing(dd) && (dd = _select_study_slab(struc).slab.design_details)

    if !isnothing(dd) && hasproperty(dd, :converged) && !dd.converged
        # For RuleOfThumb: extract what we can from design_details (slab-level
        # data only — columns/foundations were intentionally skipped).
        # For other methods: return a minimal failure row.
        if is_rot
            return _extract_rot_failure(struc, dd;
                lx_ft, ly_ft, live_psf, floor_type, concrete_label,
                method_name = method_cfg.name, method = method_cfg.method, elapsed,
                max_col_in = cap_in, col_increment_in = cap_inc,
                deflection_limit = defl_limit)
        else
            selected = _select_study_slab(struc)
            return _blank_failure_row(;
                floor_type, lx_ft, ly_ft, live_psf, concrete_label,
                method_name = method_cfg.name, method = method_cfg.method, elapsed,
                failure_reason = hasproperty(dd, :failure_reason) ? string(dd.failure_reason) : "non_convergence",
                failing_check = dd.failing_check,
                # Thickness when the design stopped (for a punching-lever failure,
                # the thickness at which the allowed levers ran out)
                h_in = hasproperty(dd, :h_final) && !isnothing(dd.h_final) ?
                    Float64(ustrip(u"inch", dd.h_final)) : NaN,
                story = selected.story, story_role = selected.story_role,
                max_col_in = cap_in, deflection_limit = defl_limit)
        end
    end

    row = _extract_results(struc;
        lx_ft, ly_ft, live_psf, floor_type, concrete_label,
        method_name = method_cfg.name, method = method_cfg.method, elapsed,
        max_col_in = cap_in, col_increment_in = cap_inc,
        deflection_limit = defl_limit)
    isnothing(row) && return nothing
    return merge(row, (converged = true, failure_reason = "", failing_check = ""))
end

# ==============================================================================
# Main sweep
# ==============================================================================

"""
    sweep(; spans, live_loads, concretes, n_bays, sdl, save, floor_type, min_h_variants)

Run all concrete × span × thickness-floor × method × live-load combinations.

For each (concrete, span) pair the structure is prepared once via
`prepare!`; all (thickness floor, LL, method) combinations reuse it via
snapshot/restore + `build_pipeline`. Different concretes require fresh
`prepare!` because the slab self-weight, ECC, and Ec all change.

`min_h_variants` defaults to two regimes:
* `("table_minimum", nothing)` — ACI 318-11 Table 9.5(c)
* `("computed_deflection", 2 in)` — search seed, not a code minimum.
  ACI 318-11 §9.5.3.4 (corpus: aci-318-11, page 135) permits a thinner
  slab when computed deflections satisfy Table 9.5(b).

`RuleOfThumb` runs only in `table_minimum`. It is the table baseline,
not an iterative design at the search seed. Each row records `min_h_rule`.
`n_stories` defaults to 3 and the reported slab is the intermediate floor.
"""
function sweep(;
    spans::Vector{Float64}     = [16.0, 20.0, 24.0, 28.0, 32.0, 36.0, 40.0, 44.0, 48.0, 52.0],
    live_loads::Vector{Float64} = [50.0, 100.0, 150.0, 250.0],
    concretes::Vector{String}  = DEFAULT_CONCRETES,
    methods                    = CORE_METHODS,
    n_bays::Int                = 3,
    n_stories::Int             = 3,
    sdl::Float64               = 20.0,
    save::Bool                 = true,
    floor_type::Symbol         = :flat_plate,
    min_h_variants             = nothing,
    max_col_in::Union{Nothing, Float64} = nothing,
    col_ratio::Float64         = 1.1,
    column_cap::Symbol         = :span15,
)
    foreach(_concrete_preset, concretes)  # validate up-front

    if isnothing(min_h_variants)
        min_h_variants = [
            ("table_minimum", nothing),
            ("computed_deflection", COMPUTED_DEFLECTION_SEED),
        ]
    end
    isempty(min_h_variants) && error("sweep: min_h_variants is empty")
    isempty(methods) && error("sweep: methods is empty")

    ft_label  = floor_type === :flat_slab ? "Flat Slab" : "Flat Plate"
    n_methods = length(methods)
    n_floors  = length(min_h_variants)
    n_total   = length(concretes) * length(spans) * n_floors * length(live_loads) * n_methods

    print_header("$(ft_label) Method Comparison — Full Pipeline")
    println("  Floor type:  $(ft_label)")
    println("  Concretes:   $(concretes)")
    println("  Spans:       $(spans) ft")
    println("  Story hts:   $([_adaptive_story_ht(s) for s in spans]) ft")
    println("  Live loads:  $(live_loads) psf")
    println("  Thickness:   $([v[1] for v in min_h_variants])")
    println("  Methods:     $n_methods")
    println("  Pipeline:    slab → columns → spread foundations")
    println("  Geometries:  $(length(concretes) * length(spans))  (concrete × span; prepared once each)")
    println("  Total runs:  $n_total")
    println()

    rows      = NamedTuple[]
    fail_rows = NamedTuple[]
    details   = _detail_sink()
    n_fail    = 0
    p         = Progress(n_total; desc = "Sweep ($(ft_label)): ")

    n_runs = n_floors * length(live_loads) * n_methods
    for concrete_label in concretes, span in spans
        ht      = _adaptive_story_ht(span)
        max_col = _resolve_max_col(span; max_col_in, col_ratio, column_cap)

        local struc, base_params
        try
            base_params = _make_params(; floor_type, sdl_psf = sdl,
                                          max_col_in = max_col,
                                          concrete_label = concrete_label)
            skel   = _build_skeleton(span, span, ht, n_bays; n_stories)
            struc  = BuildingStructure(skel)
            prepare!(struc, base_params)
        catch e
            @warn "Geometry build failed — skipping" concrete=concrete_label span floor_type exception=e
            n_fail += n_runs
            for _ in 1:n_runs; next!(p); end
            continue
        end

        for (mh_label, mh_val) in min_h_variants, ll in live_loads, mcfg in methods
            if mcfg.method isa SR.RuleOfThumb && !isnothing(mh_val)
                next!(p)
                continue
            end
            row = _run_method(struc, base_params, mcfg;
                              lx_ft = span, ly_ft = span, live_psf = ll,
                              floor_type = floor_type,
                              concrete_label = concrete_label,
                              min_h = mh_val,
                              details = details)
            if isnothing(row)
                n_fail += 1
            else
                row = merge(row, (min_h_rule = String(mh_label),))
                if hasproperty(row, :converged) && !row.converged
                    n_fail += 1
                    push!(fail_rows, row)
                else
                    push!(rows, row)
                end
            end
            next!(p)
        end
    end

    df = DataFrame(rows)
    df_fail = _rows_df(fail_rows)
    outfile = nothing
    if save && !isempty(df)
        tag = floor_type === :flat_slab ? "flat_slab_methods" : "flat_plate_methods"
        outfile = output_filename(tag, FP_RESULTS_DIR)
        CSV.write(outfile, df)
        for path in _write_details(outfile, details)
            println("  Details:     $path")
        end
        write_run_meta(outfile; note = "sweep spans=$(spans) ll=$(live_loads) concretes=$(concretes) methods=$([m.name for m in methods]) n_stories=$(n_stories) regimes=$([v[1] for v in min_h_variants])")
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
# Section 2 — ECC Monte Carlo sweep (post-hoc, no re-sizing)
# ==============================================================================
#
# `sweep_ecc(df_section1)` reuses the Material Use Intensity columns
# (`concrete_kg_per_m2`, `rebar_kg_per_m2`) populated by `sweep` and
# Monte-Carlo-samples the empirical RMC EPD distribution (per
# strength × density class, pooled across mix compositions) from
# `StructuralSizer/src/materials/ecc/distributions.jl` via
# `sample_ecc_per_kg`. Each Section 1 row is paired with `n_samples`
# slab-EC realizations:
#
#     slab_ec_i = concrete_kg_per_m2 * ecc_concrete_i + rebar_kg_per_m2 * ecc_rebar
#
# Sampling is non-parametric bootstrap (rand-with-replacement) — no
# Gaussian / log-normal fit is assumed, so tail mass is preserved.
#
# Pure post-processing: sizing is not re-run because ECC does not enter
# any structural calculation. Boundary system is A1–A3 cradle-to-gate
# per the EPD dataset.
#
# `concrete` label → (strength_psi, density_class, ρ) is read off the
# `Concrete` preset for the label; rebar ECC defaults to `Rebar_60`'s
# value from `materials/steel.jl` (1.72 kgCO₂e/kg, ICE DB v4.1) and is
# treated as a single point value (no distributional rebar EPD in the
# corpus yet).

using Random: AbstractRNG, MersenneTwister
import Statistics: mean, std

"""Resolve a `concrete` label (e.g. `"NWC_4000"`) to the lookup args
needed by `sample_ecc_per_kg` / `ecc_distribution_per_kg`."""
function _ecc_lookup_args(label::AbstractString)
    sym = Symbol(label)
    haskey(CONCRETE_PRESETS, sym) ||
        error("sweep_ecc: unknown concrete label \"$label\". " *
              "Known: $(collect(keys(CONCRETE_PRESETS)))")
    c = CONCRETE_PRESETS[sym].concrete
    fc_psi = round(Int, ustrip(u"psi", c.fc′))
    dens = (c.aggregate_type === SR.sand_lightweight ||
            c.aggregate_type === SR.lightweight) ? :LWC : :NWC
    return fc_psi, c.ρ, dens
end

"""Nearest-rank percentile on a presorted vector. Falls back to NaN on
empty input. Matches numpy's default `interpolation='lower'` for direct
comparison with `_summarize` in `distributions.jl`."""
@inline function _q_sorted(sorted_vals::Vector{Float64}, p::Float64)
    n = length(sorted_vals)
    n == 0 && return NaN
    n == 1 && return sorted_vals[1]
    idx = max(1, min(n, ceil(Int, p * n)))
    return sorted_vals[idx]
end

"""
    sweep_ecc(df;
              n_samples = 2000,
              rng       = MersenneTwister(0x_EC_C_5_E_E_D),
              rebar_ecc = SR.Rebar_60.ecc,
              save      = true,
              keep_samples = false)

Monte-Carlo apply the empirical RMC EPD distribution to the Section 1
sweep result `df`, producing per-row slab-EC summary columns:

* `slab_ec_p05`, `slab_ec_p10`, `slab_ec_p25`, `slab_ec_p50`,
  `slab_ec_p75`, `slab_ec_p90`, `slab_ec_p95` — bootstrap percentiles.
* `slab_ec_mean`, `slab_ec_std` — sample mean / std deviation.
* `n_epd` — number of EPD records backing each strength bucket.

If `keep_samples = true` the raw `n_samples`-long vector is also stored
in column `slab_ec_samples` (a `Vector{Vector{Float64}}` column), which
is useful for KDE / violin diagnostics but not written to CSV.

# Sampling design
For each unique concrete label in `df`, a single `n_samples`-length
realization of concrete ECC is drawn from the empirical EPD population
for that `(strength_psi, density_class)` and reused across every row of
that label. This keeps method-vs-method comparisons within a strength
internally consistent (the same procurement realization is applied to
all spans / live loads / methods), so spread between methods reflects
structural variability, while the band envelope reflects procurement
variability.

`rng` is seeded by default for reproducibility; pass a fresh
`MersenneTwister(seed)` if you need an independent realization.
"""
function sweep_ecc(df::DataFrame;
                   n_samples::Integer = 2000,
                   rng::AbstractRNG = MersenneTwister(0xECC_5EED),
                   rebar_ecc::Float64 = ustrip(u"kgCO2e/kg", SR.Rebar_60.ecc),
                   save::Bool = true,
                   keep_samples::Bool = false)
    n_samples > 0 || error("sweep_ecc: n_samples must be positive, got $n_samples")
    for col in (:concrete, :concrete_kg_per_m2, :rebar_kg_per_m2)
        col in propertynames(df) || error(
            "sweep_ecc: input DataFrame missing required column `$col` " *
            "(produce it via `sweep(...)` first).")
    end

    # Per-label cache of (samples vector, n_epd backing the bucket).
    # One realization is drawn per unique concrete label (see docstring).
    # `sample_ecc_per_kg` now returns typed `Vector{CarbonPerMassQuantity}`;
    # `sweep_ecc` lives at the DataFrame / CSV boundary, so we strip to
    # `Vector{Float64}` once here and keep the per-row arithmetic numeric.
    cache = Dict{String, Tuple{Vector{Float64}, Int}}()
    function _ecc_for(label::AbstractString)
        key = String(label)
        haskey(cache, key) && return cache[key]
        fc_psi, ρ, dens = _ecc_lookup_args(label)
        ecc_q = SR.sample_ecc_per_kg(fc_psi, ρ;
                                     density_class = dens,
                                     n             = n_samples,
                                     rng           = rng)
        ecc_vec = ustrip.(u"kgCO2e/kg", ecc_q)
        n_epd = length(SR.ecc_samples(fc_psi; density_class = dens))
        cache[key] = (ecc_vec, n_epd)
        return cache[key]
    end

    # Pre-allocate one realization per row and build NamedTuples.
    out_rows = NamedTuple[]
    sizehint!(out_rows, nrow(df))
    samples_buf = keep_samples ? Vector{Vector{Float64}}() : nothing

    for row in eachrow(df)
        c_kg = row.concrete_kg_per_m2
        r_kg = row.rebar_kg_per_m2
        rebar_term = isnan(r_kg) ? NaN : r_kg * rebar_ecc

        # Default NaN summary for non-converged rows / unknown buckets.
        summary = (
            slab_ec_p05 = NaN, slab_ec_p10 = NaN, slab_ec_p25 = NaN,
            slab_ec_p50 = NaN, slab_ec_p75 = NaN, slab_ec_p90 = NaN,
            slab_ec_p95 = NaN,
            slab_ec_mean = NaN, slab_ec_std = NaN,
            n_epd = 0,
        )
        row_samples = Float64[]

        if !isnan(c_kg) && !isnan(r_kg)
            try
                ecc_vec, n_epd = _ecc_for(row.concrete)
                # slab_ec_i = c_kg * ecc_i + rebar_term  (vectorized)
                row_samples = @. c_kg * ecc_vec + rebar_term
                sorted_samples = sort(row_samples)
                summary = (
                    slab_ec_p05 = _q_sorted(sorted_samples, 0.05),
                    slab_ec_p10 = _q_sorted(sorted_samples, 0.10),
                    slab_ec_p25 = _q_sorted(sorted_samples, 0.25),
                    slab_ec_p50 = _q_sorted(sorted_samples, 0.50),
                    slab_ec_p75 = _q_sorted(sorted_samples, 0.75),
                    slab_ec_p90 = _q_sorted(sorted_samples, 0.90),
                    slab_ec_p95 = _q_sorted(sorted_samples, 0.95),
                    slab_ec_mean = mean(row_samples),
                    slab_ec_std  = std(row_samples; corrected = true),
                    n_epd        = n_epd,
                )
            catch e
                @debug "sweep_ecc bucket missing" concrete=row.concrete exception=e
            end
        end

        push!(out_rows, merge(NamedTuple(row), summary))
        keep_samples && push!(samples_buf, row_samples)
    end

    df_out = DataFrame(out_rows)
    if keep_samples
        df_out.slab_ec_samples = samples_buf
    end
    if save && !isempty(df_out)
        outfile = output_filename("flat_plate_ecc_mc", FP_RESULTS_DIR)
        # Drop the samples column for CSV — vector-of-vector is awkward
        # to round-trip and not what downstream consumers want.
        df_csv = "slab_ec_samples" in names(df_out) ?
                 select(df_out, Not(:slab_ec_samples)) : df_out
        CSV.write(outfile, df_csv)
        write_run_meta(outfile; note = "sweep_ecc n_samples=$n_samples rows=$(nrow(df_csv))")
        println("  ECC sweep:   $outfile  ($(nrow(df_csv)) rows, n_samples=$n_samples)")
    end
    return df_out
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

"""Smallest column cap used by the single-lever punching variants, in inches."""
const PUNCHING_MIN_COL_IN = 14.0

"""
Punching-resolution variants: which levers the slab loop may use for
punching. `cap` is `:sweep` (the sweep's own cap), `:unbounded` (half the
bay, which punching growth never reaches in practice), or `:min`
(`PUNCHING_MIN_COL_IN`, so punching cannot grow the column). `thicken = false`
makes the design fail punching when its levers run out, instead of thickening
the slab, so a single lever is tested on its own. Axial growth is never capped,
and the slab still thickens for deflection, flexure and one-way shear.
"""
const PUNCHING_VARIANTS = Dict(
    :all_levers     => (shear_studs = :if_needed, cap = :sweep,    thicken = true),   # columns → studs → thickness
    :columns_only   => (shear_studs = :never,     cap = :unbounded, thicken = false), # columns only
    :studs_only     => (shear_studs = :always,    cap = :min,      thicken = false),  # studs, else fail
    :studs_then_thickness => (shear_studs = :always, cap = :min,   thicken = true),   # studs → thickness
    :thickness_only => (shear_studs = :never,     cap = :min,      thicken = true),   # thickness
    :no_studs       => (shear_studs = :never,     cap = :sweep,    thicken = true),   # columns → thickness (E5)
)

"""Column cap (in) for a punching variant at one span."""
function _variant_cap(variant::Symbol, sweep_cap::Float64, span_ft::Float64)
    haskey(PUNCHING_VARIANTS, variant) ||
        error("punching variant must be one of $(collect(keys(PUNCHING_VARIANTS))), got $(variant)")
    cap = PUNCHING_VARIANTS[variant].cap
    cap === :sweep    && return sweep_cap
    # Half the bay in inches (span_ft × 12 / 2); past that it is no longer a column
    cap === :unbounded && return 6.0 * span_ft
    return PUNCHING_MIN_COL_IN
end

"""
    dual_heatmap_sweep(; spans_x, spans_y, live_loads, min_h_variants, ...)

Sweep Lx × Ly × LL × method for both flat plate and flat slab.

Each (Lx, Ly) skeleton is built once; a fresh structure is prepared for
every (floor_type, min_h) combination.  Each run uses `build_pipeline`
for the full slab → column → foundation pipeline.

`punching_variants` (keys of `PUNCHING_VARIANTS`) repeats the grid with
different punching levers. Saving writes the main CSV plus
`<name>_columns.csv` and `<name>_slabs.csv`, joined on `run_id`.

With `run_name`, files go to `results_dir` as `<run_name>.csv`,
`<run_name>_columns.csv`, `<run_name>_slabs.csv` and `<run_name>_failures.csv`
(no timestamp, no per-floor-type split), as a cluster array task needs.
"""

function dual_heatmap_sweep(;
    spans_x::Vector{Float64}    = [16.0, 20.0, 24.0, 28.0, 32.0, 36.0, 40.0, 44.0, 48.0, 52.0],
    spans_y::Vector{Float64}    = [16.0, 20.0, 24.0, 28.0, 32.0, 36.0, 40.0, 44.0, 48.0, 52.0],
    live_loads::Vector{Float64} = [50.0, 100.0, 150.0, 250.0],
    concretes::Vector{String}   = ["NWC_4000"],
    methods                     = CORE_METHODS,
    n_bays::Int                 = 3,
    n_stories::Int              = 3,
    half_grid::Bool             = false,
    sdl::Float64                = 20.0,
    save::Bool                  = true,
    min_h                       = nothing,
    min_h_variants::Vector{<:Tuple{String, Any}} = Tuple{String,Any}[],
    max_col_in::Union{Nothing, Float64} = nothing,
    col_ratio::Float64                  = 1.1,
    column_cap::Symbol                  = :span15,
    uncap_columns::Bool                 = false,
    deflection_limit::Symbol            = DEFAULT_DEFL_LIMIT,
    column_strategies::Vector{Symbol}   = [:catalog],
    punching_variants::Vector{Symbol}   = [:all_levers],
    results_dir::AbstractString         = FP_RESULTS_DIR,
    run_name::Union{Nothing, AbstractString} = nothing,
)
    foreach(v -> _variant_cap(v, 0.0, 0.0), punching_variants)  # validate up-front
    foreach(_concrete_preset, concretes)  # validate up-front
    if isempty(min_h_variants)
        label = isnothing(min_h) ? "ACI" : "override"
        min_h_variants = [(label, min_h)]
    end
    # `uncap_columns = true` overrides the per-cell max-column derivation
    # with `_uncapped_max_col` — see its docstring. An explicit `max_col_in`
    # still wins (caller knows what they want).
    if uncap_columns && !isnothing(max_col_in)
        @info "uncap_columns=true ignored because max_col_in=$(max_col_in) is explicitly set"
    end

    floor_types = [:flat_plate, :flat_slab]
    isempty(methods) && error("dual_heatmap_sweep: methods is empty")
    n_methods   = length(methods)
    geom_pairs  = [(lx, ly) for lx in spans_x for ly in spans_y if !half_grid || ly <= lx]
    n_geom      = length(geom_pairs)
    n_strats    = length(column_strategies)
    n_runs_per  = length(live_loads) * n_methods
    n_concretes = length(concretes)
    n_variants  = length(min_h_variants) * length(floor_types) * n_strats * n_concretes *
                  length(punching_variants)
    n_total     = n_geom * n_runs_per * n_variants

    print_header("Dual Heatmap — Full Pipeline")
    println("  Floor types:  $(floor_types)")
    println("  Concretes:    $(concretes)")
    println("  Lx spans:     $(spans_x) ft")
    println("  Ly spans:     $(spans_y) ft")
    println("  Live loads:   $(live_loads) psf")
    println("  Methods:      $n_methods")
    println("  Col strategy: $(column_strategies)")
    println("  Punching:     $(punching_variants)")
    println("  Pipeline:     slab → columns → spread foundations")
    println("  Geometries:   $n_geom  (skeleton shared per variant)")
    println("  Total runs:   $n_total")
    println()

    rows      = NamedTuple[]
    fail_rows = NamedTuple[]
    details   = _detail_sink()
    n_fail    = 0
    p         = Progress(n_total; desc="Dual heatmap: ")

    for (lx, ly) in geom_pairs
        ht      = _adaptive_story_ht(max(lx, ly))
        max_col = _resolve_max_col(max(lx, ly); max_col_in, col_ratio, column_cap,
                                   uncap = uncap_columns)

        local skel
        try
            skel = _build_skeleton(lx, ly, ht, n_bays; n_stories)
        catch e
            @warn "Skeleton build failed — skipping" lx ly exception=e
            for (mh_label, _) in min_h_variants, ft in floor_types, cs in column_strategies, conc in concretes, pv in punching_variants, ll in live_loads, mcfg in methods
                row = _blank_failure_row(;
                    floor_type=ft, lx_ft=lx, ly_ft=ly, live_psf=ll,
                    concrete_label = conc,
                    method_name=mcfg.name, elapsed=0.0,
                    failure_reason="skeleton_build_failed",
                    failing_check=string(e),
                    story_ht_ft=ht,
                    max_col_in=max_col)
                push!(fail_rows, merge(row, (min_h_rule = mh_label, column_strategy = string(cs),
                                             punching_variant = string(pv))))
            end
            n_skip = n_runs_per * n_variants
            n_fail += n_skip
            for _ in 1:n_skip; next!(p); end
            continue
        end

        for (mh_label, mh_val) in min_h_variants
            for ft in floor_types, cs in column_strategies, conc in concretes, pv in punching_variants
                local struc, base_params
                try
                    base_params = _make_params(; floor_type = ft, sdl_psf = sdl,
                                                  max_col_in = _variant_cap(pv, max_col, max(lx, ly)),
                                                  shear_studs = PUNCHING_VARIANTS[pv].shear_studs,
                                                  punching_thickening = PUNCHING_VARIANTS[pv].thicken,
                                                  min_h = mh_val,
                                                  deflection_limit = deflection_limit,
                                                  column_strategy = cs,
                                                  concrete_label = conc)
                    struc = BuildingStructure(skel)
                    prepare!(struc, base_params)
                catch e
                    ft_label = ft === :flat_slab ? "Flat Slab" : "Flat Plate"
                    strat_label = cs == :nlp ? " [NLP]" : ""
                    @warn "$(ft_label)$(strat_label) [$(mh_label)] [$(conc)] prepare failed" lx ly exception=e
                    n_fail += n_runs_per
                    for _ in 1:n_runs_per; next!(p); end
                    continue
                end

                for ll in live_loads, mcfg in methods
                    if mcfg.method isa SR.RuleOfThumb && !isnothing(mh_val)
                        next!(p)
                        continue
                    end
                    row = _run_method(struc, base_params, mcfg;
                                      lx_ft = lx, ly_ft = ly, live_psf = ll,
                                      floor_type = ft,
                                      concrete_label = conc,
                                      details = details)
                    tags = (min_h_rule = mh_label, column_strategy = string(cs),
                            punching_variant = string(pv),
                            punching_strategy = string(_params_punching_strategy(base_params)),
                            punching_thickening = PUNCHING_VARIANTS[pv].thicken)
                    if isnothing(row)
                        n_fail += 1
                    elseif hasproperty(row, :converged) && !row.converged
                        n_fail += 1
                        push!(fail_rows, merge(row, tags))
                    else
                        push!(rows, merge(row, tags))
                    end
                    next!(p)
                end
            end
        end
    end

    df = isempty(rows) ? DataFrame() : DataFrame(rows)
    df_fail = _rows_df(fail_rows)

    if save && !isnothing(run_name)
        ensure_dir(String(results_dir))
        outfile = joinpath(results_dir, "$(run_name).csv")
        CSV.write(outfile, df)
        _write_details(outfile, details)
        isempty(df_fail) || CSV.write(joinpath(results_dir, "$(run_name)_failures.csv"), df_fail)
        write_run_meta(outfile; note = "dual_heatmap spans_x=$(spans_x) spans_y=$(spans_y) ll=$(live_loads) concretes=$(concretes) methods=$([m.name for m in methods]) n_stories=$(n_stories) n_bays=$(n_bays) regimes=$([v[1] for v in min_h_variants]) punching=$(punching_variants) defl=$(deflection_limit) cap=$(column_cap)")
        print_footer(nrow(df), n_fail, outfile)
    elseif save
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
            for path in _write_details(outfile, details)
                println("  Details:     $path")
            end
            write_run_meta(outfile; note = "dual_heatmap spans_x=$(spans_x) spans_y=$(spans_y) ll=$(live_loads) concretes=$(concretes) methods=$([m.name for m in methods]) n_stories=$(n_stories) n_bays=$(n_bays) half_grid=$(half_grid) regimes=$([v[1] for v in min_h_variants]) punching=$(punching_variants)")
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

function compare(; span = 20.0, ll = 50.0, n_bays = 3, sdl = 20.0,
                   concrete::AbstractString = "NWC_4000")
    ht      = _adaptive_story_ht(span)
    max_col = _resolve_max_col(span)
    base_params = _make_params(; sdl_psf = sdl, live_psf = ll, max_col_in = max_col,
                                  concrete_label = concrete)
    skel    = _build_skeleton(span, span, ht, n_bays)
    struc   = BuildingStructure(skel)
    prepare!(struc, base_params)

    println()
    @printf("  Flat plate: %.0f ft × %.0f ft bays  |  LL = %.0f psf  |  Concrete: %s  |  %d×%d grid\n",
            span, span, ll, concrete, n_bays, n_bays)
    bar = "─" ^ 130
    println("  $bar")
    @printf("  %-16s │ h (in) │ h_min │ h/h_min │ M₀ (k-ft) │ Punch │ Defl  │ Columns    │ Ftg B(ft) │  Time  │ Failures\n", "Method")
    println("  $bar")

    for mcfg in ALL_METHODS
        row = _run_method(struc, base_params, mcfg;
                          lx_ft = span, ly_ft = span, live_psf = ll,
                          concrete_label = concrete)
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
            max_col = _resolve_max_col(span)

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
    methods                      = [(key=:fea, name="FEA", method=SR.FEA(; pattern_loading=true, pattern_mode=:efm_amp, design_approach=:frame))],
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
    details   = _detail_sink()
    n_fail    = 0
    p         = Progress(n_total; desc = "Col strategy: ")

    n_runs_per_strat = length(live_loads) * n_methods
    for span in spans
        ht      = _adaptive_story_ht(span)
        max_col = _resolve_max_col(span)

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
    df_fail = _rows_df(fail_rows)
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
