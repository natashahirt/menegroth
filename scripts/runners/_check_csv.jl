using Pkg
Pkg.activate(joinpath(@__DIR__, "..", "..", "StructuralStudies"))

using CSV, DataFrames

csv = joinpath(@__DIR__, "..", "..", "StructuralStudies", "src",
               "flat_plate_methods", "results", "dual_heatmap_20260213_064653.csv")

df = CSV.read(csv, DataFrame)
println("File: ", basename(csv))
println("Rows: ", nrow(df))
println("Columns: ", names(df))
println()

println("=== Methods ===")
for m in sort(unique(df.method))
    sub = filter(r -> r.method == m, df)
    valid_h = filter(!isnan, sub.h_in)
    println("  $m: $(nrow(sub)) rows, $(length(valid_h)) with valid h_in")
end

println("\n=== Floor types ===")
for ft in sort(unique(df.floor_type))
    sub = filter(r -> r.floor_type == ft, df)
    println("  $ft: $(nrow(sub)) rows")
end

println("\n=== Spans (lx_ft) ===")
println("  ", sort(unique(df.lx_ft)))

println("\n=== Live loads ===")
println("  ", sort(unique(df.live_psf)))

if hasproperty(df, :min_h_rule)
    println("\n=== min_h_rule ===")
    println("  ", sort(unique(df.min_h_rule)))
end

# Show a few rows where method != ACI Min and h_in is valid
non_aci = filter(r -> r.method != "ACI Min" && !isnan(r.h_in), df)
println("\n=== Non-ACI-Min rows with valid h_in: $(nrow(non_aci)) ===")
if nrow(non_aci) > 0
    show(first(non_aci, 5); allcols=true)
    println()
end

# Check what square-bay data exists (lx == ly) for LL=50
sq50 = filter(r -> r.lx_ft == r.ly_ft && r.live_psf ≈ 50.0, df)
println("\n=== Square-bay LL=50 data ===")
for m in sort(unique(sq50.method))
    sub = filter(r -> r.method == m, sq50)
    valid = filter(!isnan, sub.h_in)
    println("  $m: $(nrow(sub)) rows, $(length(valid)) valid h_in")
end
