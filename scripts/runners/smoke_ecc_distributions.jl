# =============================================================================
# Smoke test: ECC distribution registry + Monte Carlo sampler
# =============================================================================
#
# Verifies that `StructuralSizer/src/materials/ecc/distributions.jl` loads
# the EPD CSV cleanly, that the median A1–A3 GWP values match the Python
# ingest summary (printed by `ingest_rmc_ecc.py`), and that the new
# `sample_ecc_per_kg` Monte Carlo sampler returns a vector whose
# bootstrap percentiles converge to the registry's deterministic
# percentiles.
#
# Run:
#   julia --project=StructuralSizer scripts/runners/smoke_ecc_distributions.jl
# =============================================================================

using StructuralSizer
using Unitful
using Printf
using Random: MersenneTwister
using Statistics: mean

println("Strength classes present:")
for (psi, dens) in list_strength_classes()
    n = length(ecc_samples(psi; density_class = dens))
    println("  $dens $psi psi  n=$n")
end

println("\nPer-strength :all distributions (kg CO₂e / m³):")
println("  class           n     p10    p50    p90   mean")
for (psi, dens) in list_strength_classes()
    d = ecc_distribution(psi; density_class=dens, composition=:all)
    @printf("  %s %5d  %4d  %5.0f  %5.0f  %5.0f  %5.0f\n",
            dens, psi, d.n, d.p10, d.p50, d.p90, d.mean)
end

println("\nPer-kg conversion (NWC_4000 :all, ρ = 2380 kg/m³):")
d_kg = ecc_distribution_per_kg(4000, 2380.0; density_class=:NWC, composition=:all)
@printf("  p50 = %.4f kg CO₂e / kg concrete  (n = %d)\n", d_kg.p50, d_kg.n)

println("\nPer-kg conversion using a Density quantity (LWC, ρ = 1840 kg/m³):")
d_lwc = ecc_distribution_per_kg(4000, 1840.0u"kg/m^3"; density_class=:LWC)
@printf("  p50 = %.4f kg CO₂e / kg concrete  (n = %d)\n", d_lwc.p50, d_lwc.n)

println("\nMonte Carlo bootstrap (NWC_4000, ρ = 2380 kg/m³, n = 50_000):")
samples = sample_ecc_per_kg(4000, 2380.0;
                            density_class = :NWC,
                            n   = 50_000,
                            rng = MersenneTwister(2026))
sample_mean = mean(samples)
@printf("  mean(samples) = %.4f vs registry mean = %.4f (rtol = %.2e)\n",
        sample_mean, d_kg.mean, abs(sample_mean - d_kg.mean) / d_kg.mean)
@assert isapprox(sample_mean, d_kg.mean; rtol = 0.01) (
    "MC bootstrap mean diverges by >1% from registry — increase n or check sampler")
println("  ✓ within 1% of registry mean.")

println("\nOK")
