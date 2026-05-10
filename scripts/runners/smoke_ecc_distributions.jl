# =============================================================================
# Smoke test: ECC distribution registry
# =============================================================================
#
# Verifies that `StructuralSizer/src/materials/ecc/distributions.jl` loads
# the EPD CSV cleanly and that the median A1–A3 GWP values match the
# Python ingest summary (printed by `ingest_rmc_ecc.py`).
#
# Run:
#   julia --project=StructuralSizer scripts/runners/smoke_ecc_distributions.jl
# =============================================================================

using StructuralSizer
using Unitful
using Printf

println("Strength classes present:")
for (psi, dens) in list_strength_classes()
    comps = list_compositions(psi, dens)
    println("  $dens $psi psi  compositions=$comps")
end

println("\nPer-strength :all distributions (kg CO₂e / m³):")
println("  class           n     p10    p50    p90   mean")
for (psi, dens) in list_strength_classes()
    d = ecc_distribution(psi; density_class=dens, composition=:all)
    @printf "  %s %5d  %4d  %5.0f  %5.0f  %5.0f  %5.0f\n" dens psi d.n d.p10 d.p50 d.p90 d.mean
end

println("\nNWC 4000 by composition (kg CO₂e / m³):")
println("  comp        n     p10    p50    p90")
for comp in (:plain, :fa, :slag, :slag_fa)
    d = ecc_distribution(4000; density_class=:NWC, composition=comp)
    @printf "  %-9s  %4d  %5.0f  %5.0f  %5.0f\n" String(comp) d.n d.p10 d.p50 d.p90
end

println("\nPer-kg conversion (NWC_4000 :all, ρ = 2380 kg/m³):")
d_kg = ecc_distribution_per_kg(4000, 2380.0; density_class=:NWC, composition=:all)
@printf "  p50 = %.4f kg CO₂e / kg concrete  (n = %d)\n" d_kg.p50 d_kg.n

println("\nPer-kg conversion using a Density quantity (LWC, ρ = 1840 kg/m³):")
d_lwc = ecc_distribution_per_kg(4000, 1840.0u"kg/m^3"; density_class=:LWC)
@printf "  p50 = %.4f kg CO₂e / kg concrete  (n = %d)\n" d_lwc.p50 d_lwc.n

println("\nOK")
