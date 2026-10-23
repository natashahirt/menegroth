# =============================================================================
# Runner: Section 3 — Whole-Building EC Cascade from Slab Thickness
# =============================================================================
#
# Drives the figures for Section 3 of the journal paper:
#
#   For each (span × method × concrete × n_stories) combination, run the full
#   design pipeline on a multi-story medium office and capture the per-system
#   embodied-carbon breakdown from `BuildingDesign.summary`. Compare:
#
#       1. ACI Min  (RuleOfThumb — ACI 8.3.1.1 minimum thickness)
#       2. DDM Full (Direct Design Method — ACI 318-11 §13.6 coefficients)
#       3. FEA frame (2D shell + ACI 318-11 §13.6.4/.6 strip fractions)
#
#   Slab thickness drops from method 1 → 3 as the analysis sophistication
#   removes prescriptive conservatism; the cascade plots quantify the
#   downstream savings in columns and foundations.
#
# Output figures (in StructuralStudies/src/flat_plate_methods/figs/):
#   30_building_ec_stacked_<n>st.png      — system stack by (span, concrete)
#   31_building_ec_cascade_<n>st.png      — Δ EC vs ACI Min baseline
#   32_building_ec_intensity_<n>st.png    — kgCO₂e/m² heatmap per method
#   33_slab_vs_building_ec_<n>st.png      — cascade amplification scatter
#
# Output CSV (timestamped, in StructuralStudies/src/flat_plate_methods/results/):
#   section3_building_sweep_<...>.csv     — per-building EC + size fingerprints
#
# Usage:
#   julia --project=StructuralStudies scripts/runners/run_building_scale_analysis.jl
#   julia --project=StructuralStudies scripts/runners/run_building_scale_analysis.jl quick
# =============================================================================

# ── Sweep parameters (default grid) ──────────────────────────────────────────

const SECTION3_SPANS_RUN     = [16.0, 22.0, 28.0]   # ft — bay span
const SECTION3_STORIES_RUN   = [3, 6, 10]            # heights — cascade vs height
const SECTION3_CONCRETES_RUN = ["NWC_4000", "NWC_6000", "LWC_4000"]

# Quick smoke variant (1×2 spans × 1 concrete × 1 story height = 4 runs).
const SECTION3_SPANS_QUICK   = [20.0, 28.0]
const SECTION3_STORIES_QUICK = [3]
const SECTION3_CONCRETES_QUICK = ["NWC_4000"]

# ── Load study code ──────────────────────────────────────────────────────────

include(joinpath(@__DIR__, "..", "..", "StructuralStudies", "src",
                 "flat_plate_methods", "building_scale_analysis.jl"))

# ── Run sweep ────────────────────────────────────────────────────────────────

mode = length(ARGS) > 0 ? lowercase(ARGS[1]) : "default"

df = if mode == "quick"
    println("\n=== SECTION 3 QUICK SMOKE ===\n")
    sweep_building(;
        spans     = SECTION3_SPANS_QUICK,
        methods   = [
            (key=:rot, name="ACI Min",     method=SR.RuleOfThumb()),
            (key=:fea, name="FEA (frame)", method=SR.FEA(; pattern_loading=false, design_approach=:frame)),
        ],
        concretes = SECTION3_CONCRETES_QUICK,
        stories   = SECTION3_STORIES_QUICK,
    )
else
    println("\n=== SECTION 3 FULL SWEEP " *
            "($(length(SECTION3_SPANS_RUN)) spans × $(length(SECTION3_METHODS)) methods × " *
            "$(length(SECTION3_CONCRETES_RUN)) concretes × $(length(SECTION3_STORIES_RUN)) story heights) ===\n")
    sweep_building(;
        spans     = SECTION3_SPANS_RUN,
        methods   = SECTION3_METHODS,
        concretes = SECTION3_CONCRETES_RUN,
        stories   = SECTION3_STORIES_RUN,
    )
end

# ── Generate figures ─────────────────────────────────────────────────────────

include(joinpath(@__DIR__, "..", "..", "StructuralStudies", "src",
                 "flat_plate_methods", "vis.jl"))
using CairoMakie
CairoMakie.activate!()

println("\n=== Section 3 figures ===\n")
Base.invokelatest(plot_section3_all, df)

println("\nDone. $(nrow(df)) building designs recorded.")
println("Figures saved to StructuralStudies/src/flat_plate_methods/figs/")
