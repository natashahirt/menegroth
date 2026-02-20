# ==============================================================================
# Runner: Replot from existing CSV
# ==============================================================================
# Regenerates all figures from a previously saved dual_heatmap_sweep CSV.
# Uses CairoMakie (no display/GPU required).
#
# Usage:
#   julia --project=StructuralStudies scripts/runners/replot_from_csv.jl <path.csv>
# ==============================================================================

using Pkg
Pkg.activate(joinpath(@__DIR__, "..", "..", "StructuralStudies"))

# Ensure CairoMakie is available
if !haskey(Pkg.project().dependencies, "CairoMakie")
    println("Adding CairoMakie to StructuralStudies…")
    Pkg.add("CairoMakie")
end

# Load vis.jl (pulls in StructuralPlots → GLMakie, DataFrames, CSV, etc.)
include(joinpath(@__DIR__, "..", "..", "StructuralStudies", "src",
                 "flat_plate_methods", "vis.jl"))

# Switch to CairoMakie for headless saving
using CairoMakie
CairoMakie.activate!()

# ---------- locate CSV ----------
csv_path = if length(ARGS) > 0
    ARGS[1]
else
    # Default: latest dual_heatmap CSV in the results folder
    results_dir = joinpath(@__DIR__, "..", "..", "StructuralStudies", "src",
                           "flat_plate_methods", "results")
    csvs = filter(readdir(results_dir; join=true)) do f
        b = basename(f)
        startswith(b, "dual_heatmap") && endswith(b, ".csv") &&
            !contains(b, "failure")
    end
    isempty(csvs) && error("No dual_heatmap CSV files found in $results_dir")
    sort(csvs)[end]   # latest by filename (timestamped)
end

println("\n=== Replotting from CSV ===")
println("  File: $csv_path\n")
df = Base.invokelatest(load_results, csv_path)

# ---------- line plots (01–08) ----------
println("\n=== Generating line plots (01–08) ===\n")
Base.invokelatest(generate_all, df)

# ---------- heatmap plots (09–10) ----------
println("\n=== Generating heatmap plots ===\n")
valid_h = filter(!isnan, df.h_in)
if isempty(valid_h)
    println("  Skipping heatmaps — no valid h_in values")
else
h_lo = 0.0
h_hi = ceil(maximum(valid_h))
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
end  # end if isempty(valid_h)

println("\nDone — $(nrow(df)) records replotted.")
