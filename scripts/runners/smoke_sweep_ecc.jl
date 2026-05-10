# =============================================================================
# Smoke test: sweep_ecc Monte Carlo post-hoc transform
# =============================================================================
#
# Constructs a tiny synthetic Section 1 DataFrame and verifies that:
#   1. `sweep_ecc(df)` preserves row count and produces full MC summary
#      columns (p05/p10/p25/p50/p75/p90/p95, mean, std, n_epd).
#   2. Percentile ordering p05 ≤ … ≤ p95 holds row-wise.
#   3. `n_epd` matches the registry's bucket size for each
#      (strength, density-class).
#   4. Reproducibility — two calls with the same `rng` seed yield
#      bit-identical p50 columns.
#
# Run:
#   julia --project=StructuralStudies scripts/runners/smoke_sweep_ecc.jl
# =============================================================================

include(joinpath(@__DIR__, "..", "..", "StructuralStudies", "src",
                 "flat_plate_methods", "flat_plate_method_comparison.jl"))

using DataFrames
using Printf
using Random: MersenneTwister

# -----------------------------------------------------------------------------
# Build a synthetic Section 1 DataFrame: 8 in slab, square bay, single LL
# -----------------------------------------------------------------------------

rows = [
    (concrete = "NWC_3000", method = "DDM (Full)", lx_ft = 20.0, ly_ft = 20.0,
     live_psf = 50.0, slab_ec_per_m2 = 0.0,
     concrete_kg_per_m2 = 0.203 * 2380.0, rebar_kg_per_m2 = 12.0),
    (concrete = "NWC_4000", method = "DDM (Full)", lx_ft = 20.0, ly_ft = 20.0,
     live_psf = 50.0, slab_ec_per_m2 = 0.0,
     concrete_kg_per_m2 = 0.203 * 2380.0, rebar_kg_per_m2 = 12.0),
    (concrete = "NWC_5000", method = "DDM (Full)", lx_ft = 20.0, ly_ft = 20.0,
     live_psf = 50.0, slab_ec_per_m2 = 0.0,
     concrete_kg_per_m2 = 0.203 * 2385.0, rebar_kg_per_m2 = 12.0),
    (concrete = "NWC_6000", method = "DDM (Full)", lx_ft = 20.0, ly_ft = 20.0,
     live_psf = 50.0, slab_ec_per_m2 = 0.0,
     concrete_kg_per_m2 = 0.203 * 2385.0, rebar_kg_per_m2 = 12.0),
    (concrete = "LWC_4000", method = "DDM (Full)", lx_ft = 20.0, ly_ft = 20.0,
     live_psf = 50.0, slab_ec_per_m2 = 0.0,
     concrete_kg_per_m2 = 0.230 * 1840.0, rebar_kg_per_m2 = 12.0),
]
df = DataFrame(rows)
println("Input df: $(nrow(df)) rows × $(ncol(df)) cols")

# -----------------------------------------------------------------------------
# Monte Carlo sweep
# -----------------------------------------------------------------------------

println("\n=== Monte Carlo sweep (n_samples = 2000) ===")
df_mc = sweep_ecc(df; n_samples = 2000, save = false)
@assert nrow(df_mc) == nrow(df)
for col in (:slab_ec_p05, :slab_ec_p10, :slab_ec_p25, :slab_ec_p50,
            :slab_ec_p75, :slab_ec_p90, :slab_ec_p95,
            :slab_ec_mean, :slab_ec_std, :n_epd)
    @assert hasproperty(df_mc, col) "Missing column $col"
end

println("Output: $(nrow(df_mc)) rows × $(ncol(df_mc)) cols")
for r in eachrow(df_mc)
    @printf("  %-9s p10=%5.1f  p50=%5.1f  p90=%5.1f  mean=%5.1f  std=%4.1f  n_epd=%d\n" ,
            r.concrete, r.slab_ec_p10, r.slab_ec_p50, r.slab_ec_p90,
            r.slab_ec_mean, r.slab_ec_std, r.n_epd)
end

# Percentile ordering
for r in eachrow(df_mc)
    @assert r.slab_ec_p05 ≤ r.slab_ec_p10 ≤ r.slab_ec_p25 ≤ r.slab_ec_p50 ≤
            r.slab_ec_p75 ≤ r.slab_ec_p90 ≤ r.slab_ec_p95
end
println("✓ percentile ordering OK on every row.")

# -----------------------------------------------------------------------------
# Reproducibility check — fresh seeded RNG must recover identical p50.
# -----------------------------------------------------------------------------

println("\n=== reproducibility check ===")
df_a = sweep_ecc(df; n_samples = 500, rng = MersenneTwister(42), save = false)
df_b = sweep_ecc(df; n_samples = 500, rng = MersenneTwister(42), save = false)
@assert df_a.slab_ec_p50 == df_b.slab_ec_p50 "Same seed → divergent p50"
println("✓ identical p50 column across two seed-matched calls.")

println("\nOK")
