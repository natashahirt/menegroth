# Quick re-plot: regenerate heatmap PNGs from existing CSV data
# Usage:
#   julia scripts/runners/replot_heatmaps.jl                   # latest dual_heatmap CSV
#   julia scripts/runners/replot_heatmaps.jl path/to/file.csv  # specific CSV

include(joinpath(@__DIR__, "..", "..", "StructuralStudies", "src",
                 "flat_plate_methods", "vis.jl"))

csv = if length(ARGS) > 0
    ARGS[1]
else
    dir = joinpath(@__DIR__, "..", "..", "StructuralStudies", "src",
                   "flat_plate_methods", "results")
    # Exclude failures files
    files = filter(f -> startswith(f, "dual_heatmap_") && 
                        !contains(f, "failures") && 
                        endswith(f, ".csv"),
                   readdir(dir))
    isempty(files) && error("No dual_heatmap CSVs found in $dir")
    joinpath(dir, sort(files)[end])
end

println("Re-plotting from: $csv")
df = load_results(csv)

# Shared color range across ALL data for comparability
h_lo = 0.0
h_hi = ceil(maximum(df.h_in))
h_range = (h_lo, h_hi)
println("Shared color range: $(h_range) in  (0–$(h_range[2]*25.4) mm)")

# If min_h_rule column exists, plot each variant separately
if hasproperty(df, :min_h_rule)
    variants = sort(unique(df.min_h_rule))
    println("Found $(length(variants)) min_h variants: $variants")

    for v in variants
        sub = filter(r -> r.min_h_rule == v, df)
        println("\n── Variant: $v ($(nrow(sub)) rows) ──")

        # Imperial
        plot_depth_heatmap(sub; floor_type = "flat_plate", h_range,
                           title_suffix = " [$v]", file_suffix = "_$v")
        plot_depth_heatmap(sub; floor_type = "flat_slab", h_range,
                           title_suffix = " [$v]", file_suffix = "_$v")

        # Metric
        plot_depth_heatmap(sub; floor_type = "flat_plate", h_range,
                           title_suffix = " [$v]", file_suffix = "_$(v)_metric",
                           metric = true)
        plot_depth_heatmap(sub; floor_type = "flat_slab", h_range,
                           title_suffix = " [$v]", file_suffix = "_$(v)_metric",
                           metric = true)
    end
else
    # No variants — just plot imperial + metric
    plot_dual_heatmaps(df)
    plot_dual_heatmaps(df; file_suffix = "_metric", metric = true)
end

println("\nDone.")
