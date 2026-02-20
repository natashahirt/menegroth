# ==============================================================================
# Runner: Dual Heatmap Sweep (Flat Plate + Flat Slab)
# ==============================================================================
# Runs the full Lx × Ly × LL × method sweep for both floor types.
# Results saved to StructuralStudies/src/flat_plate_methods/results/
#
# Usage:
#   julia scripts/runners/run_heatmap_sweep.jl           # 10×10 ACI-only (3,000 runs)
#   julia scripts/runners/run_heatmap_sweep.jl quick      # 3×3 quick test  (90 runs)
#   julia scripts/runners/run_heatmap_sweep.jl full       # 10×10 ACI + nomin (6,000 runs)
# ==============================================================================

include(joinpath(@__DIR__, "..", "..", "StructuralStudies", "src",
                 "flat_plate_methods", "flat_plate_method_comparison.jl"))

using Unitful

mode = length(ARGS) > 0 ? ARGS[1] : "default"

if mode == "quick"
    println("\n=== QUICK TEST (3×3 grid, single LL, ACI only) ===")
    println("=== ~90 runs ===\n")
    df = dual_heatmap_sweep(
        spans_x    = [20.0, 32.0, 44.0],
        spans_y    = [20.0, 32.0, 44.0],
        live_loads = [50.0],
    )

elseif mode == "full"
    println("\n=== FULL SWEEP (10×10 grid, ACI + no-minimum) ===")
    println("=== ~6,000 runs ===\n")
    df = dual_heatmap_sweep(
        min_h_variants = [
            ("ACI",   nothing),       # ACI Table 8.3.1.1 minimum thickness
            ("nomin", 1.0u"inch"),     # no minimum — strength/serviceability governs
        ],
    )

else
    println("\n=== DEFAULT SWEEP (10×10 grid, ACI only) ===")
    println("=== ~3,000 runs ===\n")
    df = dual_heatmap_sweep()
end

# Generate all line plots (01–08) + heatmaps (09–10)
include(joinpath(@__DIR__, "..", "..", "StructuralStudies", "src",
                 "flat_plate_methods", "vis.jl"))

# Use CairoMakie for headless/batch figure saving (no GPU/display required)
using CairoMakie
CairoMakie.activate!()

println("\n=== Generating line plots (01–08) ===\n")
Base.invokelatest(generate_all, df)

println("\n=== Generating heatmap plots (per variant, imperial + metric) ===\n")
h_lo = 0.0
h_hi = ceil(maximum(df.h_in))
h_range = (h_lo, h_hi)

if hasproperty(df, :min_h_rule)
    for v in sort(unique(df.min_h_rule))
        sub = filter(r -> r.min_h_rule == v, df)
        for metric in (false, true)
            sfx = metric ? "_$(v)_metric" : "_$v"
            Base.invokelatest(plot_depth_heatmap, sub; floor_type="flat_plate",
                              h_range, title_suffix=" [$v]", file_suffix=sfx, metric)
            Base.invokelatest(plot_depth_heatmap, sub; floor_type="flat_slab",
                              h_range, title_suffix=" [$v]", file_suffix=sfx, metric)
        end
    end
else
    Base.invokelatest(plot_dual_heatmaps, df; file_suffix="")
    Base.invokelatest(plot_dual_heatmaps, df; file_suffix="_metric", metric=true)
end

println("\nDone. $(nrow(df)) records written.")
