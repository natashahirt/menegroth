# Regenerate all plots (square + rectangular bays)

const PROJECT_ROOT = dirname(dirname(@__DIR__))
cd(PROJECT_ROOT)

include(joinpath(PROJECT_ROOT, "StructuralStudies/src/flat_plate_methods/vis.jl"))

# Load the most recent dual_heatmap file
results_dir = joinpath(PROJECT_ROOT, "StructuralStudies/src/flat_plate_methods/results")
files = filter(f -> startswith(f, "dual_heatmap_") && 
                    !contains(f, "failures") && 
                    endswith(f, ".csv"),
               readdir(results_dir))
isempty(files) && error("No dual_heatmap CSVs found in $results_dir")
csv_path = joinpath(results_dir, sort(files)[end])
df = load_results(csv_path)

println("\nData summary:")
println("  Total rows:  ", nrow(df))

# Check bay counts
square_df = filter(r -> isapprox(r.lx_ft, r.ly_ft; rtol=0.01), df)
rect_df = filter(r -> !isapprox(r.lx_ft, r.ly_ft; rtol=0.01), df)
println("  Square bays: ", nrow(square_df), " (spans: ", sort(unique(square_df.lx_ft)), ")")
println("  Rect bays:   ", nrow(rect_df), " (short spans: ", sort(unique(min.(rect_df.lx_ft, rect_df.ly_ft))), ")")

# Generate all plots
generate_all(df; include_rect = true)
