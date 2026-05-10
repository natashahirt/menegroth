# =============================================================================
# Runner: Sections 1 + 2 — per-slab embodied-carbon sweep + ECC band
# =============================================================================
#
# Drives the figures for Sections 1 and 2 of the journal paper:
#
#   Section 1 — EC variation and failure modes of individual slabs.
#     1. `sweep` over (concrete × span × method × LL) — square bays only.
#        Produces the line plots (slab EC / MUI / t_eq vs span) including
#        the `*_by_concrete` overlays that contrast NWC vs LWC across
#        analysis methods.
#     2. `dual_heatmap_sweep` over (Lx × Ly × method × LL) at the default
#        NWC_4000 — produces the bay-shape EC and depth heatmaps.
#
#   Section 2 — Procurement (ECC) sensitivity at fixed sizing.
#     3. `sweep_ecc(df_section1)` — pure post-hoc Monte Carlo transform.
#        Each row is paired with `n_samples` slab-EC realizations drawn
#        (with replacement) from the empirical RMC EPD distribution for
#        that strength × density class. The figure shows the resulting
#        p10–p90 procurement band per method. No re-sizing.
#
# Concrete presets used for axis (1) come from `DEFAULT_CONCRETES` in
# `flat_plate_method_comparison.jl`. EC source: empirical median of the
# RMC EPD dataset (n = 1078 NRMCA-listed plants, 2021–2025, A1–A3) — see
# `StructuralSizer/src/materials/ecc/data/README.md`.
#
# Usage:
#   julia --project=StructuralStudies scripts/runners/run_ec_sweep.jl          # default grid
#   julia --project=StructuralStudies scripts/runners/run_ec_sweep.jl quick    # 3-span smoke
# =============================================================================

# ── Sweep parameters (Section 1 scope) ───────────────────────────────────────

const SPANS_LINE = collect(16.0:4.0:36.0)   # ft — square-bay line-plot grid
const SPANS_HEAT = collect(16.0:4.0:36.0)   # ft — Lx and Ly axes for heatmaps
const LIVE_LOADS = [50.0, 100.0]            # psf (office + assembly)
const N_BAYS     = 3
const SDL        = 20.0                     # psf
const COL_RATIO  = 1.1
const DEFL_LIMIT = :L_360                   # ACI 318-19 Table 24.2.2

const SPANS_QUICK = [20.0, 28.0, 36.0]
const LL_QUICK    = [50.0]

# ── Load study code ──────────────────────────────────────────────────────────

include(joinpath(@__DIR__, "..", "..", "StructuralStudies", "src",
                 "flat_plate_methods", "flat_plate_method_comparison.jl"))

# ── Run sweeps ───────────────────────────────────────────────────────────────

mode = length(ARGS) > 0 ? ARGS[1] : "default"

spans_line = mode == "quick" ? SPANS_QUICK : SPANS_LINE
spans_heat = mode == "quick" ? SPANS_QUICK : SPANS_HEAT
live_loads = mode == "quick" ? LL_QUICK    : LIVE_LOADS

println("\n=== EC SWEEP (line: $(length(spans_line)) spans × " *
        "$(length(DEFAULT_CONCRETES)) concretes; " *
        "heatmap: $(length(spans_heat))×$(length(spans_heat)) NWC_4000-only) ===\n")

println("--- (1/3) Concrete-axis line sweep ---")
df_line = sweep(;
    spans      = spans_line,
    live_loads = live_loads,
    concretes  = DEFAULT_CONCRETES,
    n_bays     = N_BAYS,
    sdl        = SDL,
    floor_type = :flat_plate,
)

println("\n--- (2/3) Bay-shape heatmap sweep (NWC_4000) ---")
df_heat = dual_heatmap_sweep(;
    spans_x          = spans_heat,
    spans_y          = spans_heat,
    live_loads       = live_loads,
    concretes        = ["NWC_4000"],
    n_bays           = N_BAYS,
    sdl              = SDL,
    col_ratio        = COL_RATIO,
    deflection_limit = DEFL_LIMIT,
)

println("\n--- (3/3) Section 2 ECC Monte Carlo sweep (post-hoc) ---")
df_band = sweep_ecc(df_line; n_samples = 2000)

# ── Generate figures ─────────────────────────────────────────────────────────

include(joinpath(@__DIR__, "..", "..", "StructuralStudies", "src",
                 "flat_plate_methods", "vis.jl"))
using CairoMakie
CairoMakie.activate!()

println("\n=== Section 1 figures ===\n")

if !hasproperty(df_line, :slab_ec_per_m2)
    error("Line sweep is missing :slab_ec_per_m2 — re-run with the updated " *
          "_extract_results in flat_plate_method_comparison.jl.")
end

# Line plots driven by the concrete-axis sweep (square bays only).
println("--- Concrete-axis line plots ---")
Base.invokelatest(plot_slab_ec, df_line)
Base.invokelatest(plot_slab_mui, df_line)
Base.invokelatest(plot_slab_t_eq, df_line)
Base.invokelatest(plot_slab_ec_by_concrete, df_line)
Base.invokelatest(plot_slab_mui_by_concrete, df_line)
Base.invokelatest(plot_slab_t_eq_by_concrete, df_line)

# Heatmaps driven by the bay-shape sweep (Lx × Ly grid, NWC_4000 only).
println("\n--- Bay-shape heatmaps ---")
Base.invokelatest(plot_dual_ec_heatmaps, df_heat)
Base.invokelatest(plot_dual_heatmaps,    df_heat)

println("\n=== Section 2 figures (ECC Monte Carlo band) ===\n")
Base.invokelatest(plot_slab_ec_band, df_band)

println("\nDone. Line: $(nrow(df_line)) records.  Heatmap: $(nrow(df_heat)) records.")
println("       Section 2 MC band: $(nrow(df_band)) rows.")
println("Figures saved to StructuralStudies/src/flat_plate_methods/figs/")
