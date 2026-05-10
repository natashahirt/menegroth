# =============================================================================
# Smoke test: Section 2 ECC Monte Carlo band figure
# =============================================================================
#
# Builds a synthetic Section 1 DataFrame (mimicking `sweep` output with the
# columns `sweep_ecc` / `vis.jl` care about), runs the new Monte Carlo
# `sweep_ecc`, and verifies that
#
#   1. the percentile / mean / std summary columns are populated,
#   2. p10 ≤ p25 ≤ p50 ≤ p75 ≤ p90 row-wise (sanity ordering),
#   3. `keep_samples = true` round-trips the raw realizations,
#   4. `plot_slab_ec_band` renders without error.
#
# Avoids the cost of the real structural sizing pipeline.
#
# Run:
#   julia --project=StructuralStudies scripts/runners/smoke_section2_figs.jl
# =============================================================================

include(joinpath(@__DIR__, "..", "..", "StructuralStudies", "src",
                 "flat_plate_methods", "flat_plate_method_comparison.jl"))
include(joinpath(@__DIR__, "..", "..", "StructuralStudies", "src",
                 "flat_plate_methods", "vis.jl"))

using DataFrames
using Statistics: mean, std
using CairoMakie
CairoMakie.activate!(type = "png")

# ---------------------------------------------------------------------------
# Synthetic Section 1 DataFrame
# ---------------------------------------------------------------------------
# (concrete, span, LL, method) factorial. MUI is a deterministic function of
# (concrete strength, span, LL, method) so the bands are visually meaningful.

const CONCRETES = ["NWC_3000", "NWC_4000", "NWC_5000", "NWC_6000", "LWC_4000"]
const SPANS     = collect(16.0:4.0:36.0)
const LLS       = [50.0, 100.0]
const METHODS   = ["MDDM", "DDM (Full)", "EFM (HC)", "EFM (ASAP)", "FEA"]

function _density(label)
    label == "LWC_4000" && return 1840.0
    label in ("NWC_5000", "NWC_6000") ? 2385.0 : 2380.0
end
function _strength(label)
    label == "LWC_4000" && return 4000
    return parse(Int, split(label, "_")[2])
end

rows = NamedTuple[]
for c in CONCRETES, span in SPANS, ll in LLS, m in METHODS
    fc = _strength(c)
    ρ  = _density(c)
    h_in = 5.0 + 0.20*span + 0.005*ll - 0.0005*fc
    h_in *= (m == "FEA") ? 0.92 : 1.0
    t_eq_m = 0.0254 * h_in
    conc_kg = t_eq_m * ρ
    rebar_kg = 0.005 * t_eq_m * 7850.0
    nominal_ecc = ρ == 1840.0 ? 0.243 :
                  fc == 3000  ? 0.111 :
                  fc == 4000  ? 0.127 :
                  fc == 5000  ? 0.142 : 0.130
    push!(rows, (
        concrete            = c,
        method              = m,
        floor_type          = "flat_plate",
        lx_ft               = span,
        ly_ft               = span,
        live_psf            = ll,
        slab_ec_per_m2      = conc_kg * nominal_ecc + rebar_kg * 1.72,
        concrete_kg_per_m2  = conc_kg,
        rebar_kg_per_m2     = rebar_kg,
        mui_kg_per_m2       = conc_kg + rebar_kg,
        concrete_t_eq_m     = t_eq_m,
    ))
end

df = DataFrame(rows)
println("Synthetic Section 1 df: $(nrow(df)) rows × $(ncol(df)) cols")

# ---------------------------------------------------------------------------
# Monte Carlo sweep
# ---------------------------------------------------------------------------

println("\n--- sweep_ecc (Monte Carlo, n_samples = 2000) ---")
df_band = sweep_ecc(df; n_samples = 2000, save = false)
println("df_band: $(nrow(df_band)) rows × $(ncol(df_band)) cols")

# ---------------------------------------------------------------------------
# Sanity assertions
# ---------------------------------------------------------------------------

required_cols = (:slab_ec_p05, :slab_ec_p10, :slab_ec_p25, :slab_ec_p50,
                 :slab_ec_p75, :slab_ec_p90, :slab_ec_p95,
                 :slab_ec_mean, :slab_ec_std, :n_epd)
for col in required_cols
    @assert col in propertynames(df_band) "Missing column $col"
end
println("✓ All summary columns present.")

@assert nrow(df_band) == nrow(df) "MC pooled sweep should preserve row count"

# Row-wise percentile ordering
for r in eachrow(df_band)
    @assert r.slab_ec_p05 ≤ r.slab_ec_p10 ≤ r.slab_ec_p25 ≤ r.slab_ec_p50 ≤
            r.slab_ec_p75 ≤ r.slab_ec_p90 ≤ r.slab_ec_p95 (
        "Percentile ordering violated for row: " * string(r))
end
println("✓ p05 ≤ p10 ≤ p25 ≤ p50 ≤ p75 ≤ p90 ≤ p95 holds for every row.")

# `n_epd` should be uniform within a (concrete, density) bucket and > 0
for c in CONCRETES
    sub = filter(r -> r.concrete == c, df_band)
    @assert all(sub.n_epd .> 0) "$c: zero EPDs found in registry"
    @assert length(unique(sub.n_epd)) == 1 "$c: n_epd inconsistent across rows"
end
println("✓ n_epd uniform within each concrete preset.")

# ---------------------------------------------------------------------------
# keep_samples round-trip
# ---------------------------------------------------------------------------

println("\n--- sweep_ecc (Monte Carlo, keep_samples = true) ---")
df_keep = sweep_ecc(df; n_samples = 500, save = false, keep_samples = true)
@assert :slab_ec_samples in propertynames(df_keep)
@assert all(length.(df_keep.slab_ec_samples) .== 500)
# p50 from the summary should match the median of the realized samples
let mismatches = 0
    for r in eachrow(df_keep)
        s = sort(r.slab_ec_samples)
        p50_from_samples = s[ceil(Int, 0.50 * length(s))]
        isapprox(p50_from_samples, r.slab_ec_p50; rtol = 1e-9) || (mismatches += 1)
    end
    @assert mismatches == 0 "p50 mismatch with realized samples in $mismatches rows"
end
println("✓ keep_samples round-trip clean.")

# ---------------------------------------------------------------------------
# Plot rendering
# ---------------------------------------------------------------------------

println("\n--- plot_slab_ec_band ---")
fig = Base.invokelatest(plot_slab_ec_band, df_band)
@assert fig !== nothing "plot_slab_ec_band returned nothing"
println("✓ figure rendered.")

println("\nAll Section 2 MC checks passed.")
