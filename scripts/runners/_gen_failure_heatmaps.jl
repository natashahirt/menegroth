# Generate failure mode heatmaps for flat plate / flat slab
# Split by ACI vs nomin min_h_rule
# Combines successful runs with failures to show complete picture

using CSV, DataFrames

# Load vis module
include(joinpath(@__DIR__, "..", "..", "StructuralStudies", "src", "flat_plate_methods", "vis.jl"))

# Find latest dual_heatmap CSV
results_dir = joinpath(@__DIR__, "..", "..", "StructuralStudies", "src",
                       "flat_plate_methods", "results")

success_files = filter(f -> startswith(f, "dual_heatmap_") && 
                            !contains(f, "failures") && endswith(f, ".csv"),
                       readdir(results_dir))
isempty(success_files) && error("No dual_heatmap CSVs found")
latest_success = joinpath(results_dir, sort(success_files)[end])

# Try to find matching failures file
fail_files = filter(f -> startswith(f, "dual_heatmap_failures") && endswith(f, ".csv"),
                    readdir(results_dir))
latest_fail = isempty(fail_files) ? nothing : joinpath(results_dir, sort(fail_files)[end])

println("Loading: $(basename(latest_success))")
df_success = CSV.read(latest_success, DataFrame)

df_fail = if !isnothing(latest_fail)
    println("Loading: $(basename(latest_fail))")
    CSV.read(latest_fail, DataFrame)
else
    println("No failures CSV found")
    DataFrame()
end

println("Loaded data:")
println("  Successful runs: $(nrow(df_success))")
println("  Failed runs: $(nrow(df_fail))")

# Combine both dataframes - successful runs have empty failures column
df = vcat(df_success, df_fail)
println("  Combined: $(nrow(df))")

# Split by min_h_rule
df_aci = filter(r -> r.min_h_rule == "ACI", df)
df_nomin = filter(r -> r.min_h_rule == "nomin", df)

println("\nGenerating failure heatmaps...")
println("  ACI rows: $(nrow(df_aci))")
println("  nomin rows: $(nrow(df_nomin))")

# Generate ACI heatmaps
plot_dual_failure_heatmaps(df_aci;
    title_suffix = " — ACI Minimum Thickness",
    file_suffix = "_ACI")

# Generate nomin heatmaps
plot_dual_failure_heatmaps(df_nomin;
    title_suffix = " — No Minimum Thickness",
    file_suffix = "_nomin")

println("\nDone!")
