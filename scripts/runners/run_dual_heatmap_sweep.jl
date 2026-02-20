# Runner: dual heatmap sweep (Lx × Ly) + all visualizations
include(joinpath(@__DIR__, "..", "..", "StructuralStudies", "src",
                 "flat_plate_methods", "flat_plate_method_comparison.jl"))
include(joinpath(@__DIR__, "..", "..", "StructuralStudies", "src",
                 "flat_plate_methods", "vis.jl"))

println("\n=== Dual heatmap sweep (16–52 ft, flat plate + flat slab, ACI + nomin) ===\n")
t0 = time()
df = dual_heatmap_sweep(
    spans_x = collect(16.0:4.0:52.0),
    spans_y = collect(16.0:4.0:52.0),
    live_loads = [30., 50., 100., 150., 200., 250.],
    min_h_variants = [("ACI", nothing), ("nomin", 5.0u"inch")],
)
elapsed = time() - t0
println("\nSweep wall-clock: $(round(elapsed; digits=1))s  |  Rows: $(nrow(df))")

if nrow(df) == 0
    @warn "No successful design records were created. Skipping plots."
else
    println("\n=== Generating all plots ===\n")
    # Use invokelatest to avoid Julia 1.12 world-age warnings when running in REPL
    Base.invokelatest(generate_all, df)

    # Also generate metric heatmaps
    Base.invokelatest(plot_dual_heatmaps, df; metric=true, file_suffix="_metric")
end

println("\nAll done!")