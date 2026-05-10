# ==============================================================================
# Runner: Dual Heatmap Sweep (Flat Plate + Flat Slab)
# ==============================================================================
# Runs the full Lx × Ly × LL × method sweep for both floor types.
# Results saved to StructuralStudies/src/flat_plate_methods/results/
#
# Usage:
#   julia scripts/runners/run_heatmap_sweep.jl                # default (ACI, catalog columns)
#   julia scripts/runners/run_heatmap_sweep.jl quick          # 3×3 quick smoke test
#   julia scripts/runners/run_heatmap_sweep.jl full           # ACI + no-minimum
#   julia scripts/runners/run_heatmap_sweep.jl nlp            # default grid, NLP columns only
#   julia scripts/runners/run_heatmap_sweep.jl both           # default grid, catalog + NLP columns
#
#   `uncapped` is a composable flag: append it to any mode to bump the
#   per-cell column cap from clamp(1.1×span, 36, 60") → clamp(2×span, 60, 240"),
#   exposing the underlying punching / deflection / flexural failure modes
#   that would otherwise be masked by the conventional 36–60" Max-Column
#   cap. Failure heatmaps then get a black 60" contour drawn on `col_max_in`,
#   showing where the design would have been Max-Column-limited in practice.
#
#     julia scripts/runners/run_heatmap_sweep.jl uncapped         # default grid, uncapped
#     julia scripts/runners/run_heatmap_sweep.jl quick uncapped   # 3×3 smoke, uncapped
#     julia scripts/runners/run_heatmap_sweep.jl full uncapped    # ACI+nomin, uncapped
# ==============================================================================

# ── Sweep parameters (edit these) ────────────────────────────────────────────

const SPANS_X    = collect(16.0:4.0:52.0)   # ft — bay widths
const SPANS_Y    = collect(16.0:4.0:52.0)   # ft — bay depths
const LIVE_LOADS = [50.0, 150.0, 250.0]     # psf
const N_BAYS     = 3                        # bays per direction (3×3 grid)
const SDL        = 20.0                     # psf — superimposed dead load
const MAX_COL_IN = nothing                  # in — fixed max column size (nothing = use adaptive)
const COL_RATIO  = 1.1                      # adaptive multiplier: col = span_ft × ratio, clamped 36–60"
const DEFL_LIMIT = :L_360                   # :L_240, :L_360, or :L_480 (ACI Table 24.2.2)

# Column sizing strategies
const COL_CATALOG = [:catalog]              # MIP catalog-based (default)
const COL_NLP     = [:nlp]                  # NLP continuous optimization
const COL_BOTH    = [:catalog, :nlp]        # compare both

# Quick-test subset (used with `quick` CLI arg)
const SPANS_QUICK = [20.0, 32.0, 44.0]
const LL_QUICK    = [50.0]

# ── Load study code ──────────────────────────────────────────────────────────

include(joinpath(@__DIR__, "..", "..", "StructuralStudies", "src",
                 "flat_plate_methods", "flat_plate_method_comparison.jl"))
using Unitful

# ── Run sweep ────────────────────────────────────────────────────────────────

# `uncapped` is an order-insensitive flag; the remaining argument (if any)
# is the mode. So `quick uncapped` and `uncapped quick` both run a 3×3
# uncapped sweep.
const _ARGS = lowercase.(ARGS)
uncap_flag  = "uncapped" in _ARGS
_modes      = filter(!=("uncapped"), _ARGS)
mode        = isempty(_modes) ? "default" : _modes[1]

# Map mode → column strategies
col_strats = mode == "nlp"  ? COL_NLP  :
             mode == "both" ? COL_BOTH : COL_CATALOG

# Banner suffix for log output
_uncap_tag(flag::Bool) = flag ? " [uncapped, max col = clamp(2×span, 60–240\")]" : ""

df = if mode == "quick"
    println("\n=== QUICK TEST ($(length(SPANS_QUICK))×$(length(SPANS_QUICK)) grid, $(length(LL_QUICK)) LL, cols=$(col_strats))$(_uncap_tag(uncap_flag)) ===\n")
    dual_heatmap_sweep(;
        spans_x           = SPANS_QUICK,
        spans_y           = SPANS_QUICK,
        live_loads        = LL_QUICK,
        n_bays            = N_BAYS,
        sdl               = SDL,
        max_col_in        = uncap_flag ? nothing : MAX_COL_IN,
        uncap_columns     = uncap_flag,
        col_ratio         = COL_RATIO,
        deflection_limit  = DEFL_LIMIT,
        column_strategies = col_strats,
    )
elseif mode == "full"
    println("\n=== FULL SWEEP ($(length(SPANS_X))×$(length(SPANS_Y)) grid, ACI + no-minimum, cols=$(col_strats))$(_uncap_tag(uncap_flag)) ===\n")
    dual_heatmap_sweep(;
        spans_x           = SPANS_X,
        spans_y           = SPANS_Y,
        live_loads        = LIVE_LOADS,
        n_bays            = N_BAYS,
        sdl               = SDL,
        max_col_in        = uncap_flag ? nothing : MAX_COL_IN,
        uncap_columns     = uncap_flag,
        col_ratio         = COL_RATIO,
        deflection_limit  = DEFL_LIMIT,
        column_strategies = col_strats,
        min_h_variants    = [
            ("ACI",   nothing),       # ACI Table 8.3.1.1 minimum thickness
            ("nomin", 1.0u"inch"),     # strength/serviceability governs
        ],
    )
else  # "default", "nlp", "both"
    label = mode == "nlp"  ? "NLP columns only" :
            mode == "both" ? "catalog + NLP columns" : "catalog columns"
    println("\n=== SWEEP ($(length(SPANS_X))×$(length(SPANS_Y)) grid, $(label))$(_uncap_tag(uncap_flag)) ===\n")
    dual_heatmap_sweep(;
        spans_x           = SPANS_X,
        spans_y           = SPANS_Y,
        live_loads        = LIVE_LOADS,
        n_bays            = N_BAYS,
        sdl               = SDL,
        max_col_in        = uncap_flag ? nothing : MAX_COL_IN,
        uncap_columns     = uncap_flag,
        col_ratio         = COL_RATIO,
        deflection_limit  = DEFL_LIMIT,
        column_strategies = col_strats,
    )
end

# ── Generate figures ─────────────────────────────────────────────────────────

include(joinpath(@__DIR__, "..", "..", "StructuralStudies", "src",
                 "flat_plate_methods", "vis.jl"))
using CairoMakie
CairoMakie.activate!()

println("\n=== Generating line plots (01–08) ===\n")
Base.invokelatest(generate_all, df)

println("\n=== Generating heatmap plots (per variant, imperial + metric) ===\n")
valid_h = filter(!isnan, df.h_in)
if isempty(valid_h)
    println("  Skipping heatmaps — no valid h_in values")
else
    h_range = (0.0, ceil(maximum(valid_h)))

    # Determine column strategy groups (split heatmaps when comparing strategies)
    col_groups = hasproperty(df, :column_strategy) ? sort(unique(df.column_strategy)) : ["catalog"]

    if hasproperty(df, :min_h_rule)
        for v in sort(unique(df.min_h_rule)), cg in col_groups
            sub = if hasproperty(df, :column_strategy)
                filter(r -> r.min_h_rule == v && r.column_strategy == cg, df)
            else
                filter(r -> r.min_h_rule == v, df)
            end
            isempty(sub) && continue
            cs_tag = length(col_groups) > 1 ? "_$(cg)" : ""
            for metric in (false, true)
                sfx = metric ? "_$(v)$(cs_tag)_metric" : "_$(v)$(cs_tag)"
                title_sfx = length(col_groups) > 1 ? " [$v, $cg]" : " [$v]"
                Base.invokelatest(plot_depth_heatmap, sub; floor_type="flat_plate",
                                  h_range, title_suffix=title_sfx, file_suffix=sfx, metric)
                Base.invokelatest(plot_depth_heatmap, sub; floor_type="flat_slab",
                                  h_range, title_suffix=title_sfx, file_suffix=sfx, metric)
            end
        end
    else
        for cg in col_groups
            sub = if hasproperty(df, :column_strategy)
                filter(r -> r.column_strategy == cg, df)
            else
                df
            end
            isempty(sub) && continue
            cs_tag = length(col_groups) > 1 ? "_$(cg)" : ""
            Base.invokelatest(plot_dual_heatmaps, sub; file_suffix=cs_tag)
            Base.invokelatest(plot_dual_heatmaps, sub; file_suffix="$(cs_tag)_metric", metric=true)
        end
    end
end

println("\n=== Generating slab EC heatmaps (per variant) ===\n")
if !hasproperty(df, :slab_ec_per_m2)
    println("  Skipping EC heatmaps — no slab_ec_per_m2 column (older sweep CSV?)")
else
    valid_ec = filter(!isnan, df.slab_ec_per_m2)
    if isempty(valid_ec)
        println("  Skipping EC heatmaps — no valid slab_ec_per_m2 values")
    else
        ec_range = (0.0, ceil(maximum(valid_ec)))
        col_groups = hasproperty(df, :column_strategy) ? sort(unique(df.column_strategy)) : ["catalog"]
        if hasproperty(df, :min_h_rule)
            for v in sort(unique(df.min_h_rule)), cg in col_groups
                sub = if hasproperty(df, :column_strategy)
                    filter(r -> r.min_h_rule == v && r.column_strategy == cg, df)
                else
                    filter(r -> r.min_h_rule == v, df)
                end
                isempty(sub) && continue
                cs_tag    = length(col_groups) > 1 ? "_$(cg)" : ""
                title_sfx = length(col_groups) > 1 ? " [$v, $cg]" : " [$v]"
                file_sfx  = "_$(v)$(cs_tag)"
                Base.invokelatest(plot_ec_heatmap, sub; floor_type = "flat_plate",
                                  ec_range, title_suffix = title_sfx, file_suffix = file_sfx)
                Base.invokelatest(plot_ec_heatmap, sub; floor_type = "flat_slab",
                                  ec_range, title_suffix = title_sfx, file_suffix = file_sfx)
            end
        else
            for cg in col_groups
                sub = if hasproperty(df, :column_strategy)
                    filter(r -> r.column_strategy == cg, df)
                else
                    df
                end
                isempty(sub) && continue
                cs_tag = length(col_groups) > 1 ? "_$(cg)" : ""
                Base.invokelatest(plot_dual_ec_heatmaps, sub; file_suffix = cs_tag)
            end
        end
    end
end

# ── Failure-mode heatmaps (with practical-column contour when uncapped) ──
println("\n=== Generating failure-mode heatmaps ===\n")
overlay = uncap_flag ? 60.0 : nothing
col_groups = hasproperty(df, :column_strategy) ? sort(unique(df.column_strategy)) : ["catalog"]
if hasproperty(df, :min_h_rule)
    for v in sort(unique(df.min_h_rule)), cg in col_groups
        sub = if hasproperty(df, :column_strategy)
            filter(r -> r.min_h_rule == v && r.column_strategy == cg, df)
        else
            filter(r -> r.min_h_rule == v, df)
        end
        isempty(sub) && continue
        cs_tag    = length(col_groups) > 1 ? "_$(cg)" : ""
        title_sfx = length(col_groups) > 1 ? " — $v, $cg" : " — $v"
        Base.invokelatest(plot_dual_failure_heatmaps, sub;
                          title_suffix = title_sfx,
                          file_suffix  = "_$(v)$(cs_tag)",
                          col_overlay_threshold = overlay)
    end
else
    for cg in col_groups
        sub = if hasproperty(df, :column_strategy)
            filter(r -> r.column_strategy == cg, df)
        else
            df
        end
        isempty(sub) && continue
        cs_tag = length(col_groups) > 1 ? "_$(cg)" : ""
        Base.invokelatest(plot_dual_failure_heatmaps, sub;
                          file_suffix = cs_tag,
                          col_overlay_threshold = overlay)
    end
end

println("\nDone. $(nrow(df)) records written.")
