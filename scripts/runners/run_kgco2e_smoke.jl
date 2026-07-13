# =============================================================================
# kgCO₂e Unit Smoke Test
# =============================================================================
# Validates that the new Unitful dimension `𝐗` (carbon-equivalent) and its
# ref-unit `kgCO2e` survive precompilation → runtime transition and that
# arithmetic / dimension-checking behave as expected.
#
# Run with:
#   julia --project=StructuralSizer scripts/runners/run_kgco2e_smoke.jl
# =============================================================================

using StructuralSizer
# `Asap` must be loaded into the caller's module for `@u_str` to resolve our
# custom `kgCO2e` ref-unit. StructuralSizer re-exports the unit *value*, but
# Unitful's `u"..."` macro looks only in modules `using`-ed by the caller.
using Asap
using Unitful

println("kgCO2e smoke test")
println("=" ^ 60)

q1 = 1.0u"kgCO2e"
q2 = 2.0u"kgCO2e"
ecc = 0.127u"kgCO2e/kg"
rho = 2400.0u"kg/m^3"
vol = 0.5u"m^3"

println("Quantity literal  :  $(q1)")
println("Dimension         :  $(dimension(q1))")
println("Sum               :  $(q1 + q2)")
println("ECC × mass        :  $(ecc * 10.0u"kg")")
println("ECC × ρ × volume  :  $(vol * rho * ecc)")
println()

# Distinct dimension
@assert dimension(1.0u"kgCO2e") != dimension(1.0u"kg") "kgCO2e dimension collides with mass"

# Arithmetic stays typed
@assert q1 + q2 == 3.0u"kgCO2e" "kgCO2e + kgCO2e arithmetic broken"

# ECC factor × mass → kgCO2e
@assert (1.0u"kgCO2e/kg") * (10.0u"kg") == 10.0u"kgCO2e" "kgCO2e/kg × kg ≠ kgCO2e"

# Mass × density × ECC → kgCO2e (the typical EC pipeline)
ec = vol * rho * ecc
@assert dimension(ec) == dimension(1.0u"kgCO2e") "vol·ρ·ecc does not reduce to 𝐗"

# Refuses to silently add to mass
function _refuses_to_add_kg_to_kgco2e()
    try
        _ = 1.0u"kgCO2e" + 1.0u"kg"
        return false
    catch e
        return e isa Unitful.DimensionError
    end
end
@assert _refuses_to_add_kg_to_kgco2e() "kgCO2e + kg should throw Unitful.DimensionError"

# Concrete-typeof aliases resolve correctly (used in struct field annotations)
@assert StructuralSizer.CarbonMassQuantity     === typeof(1.0u"kgCO2e")
@assert StructuralSizer.CarbonPerMassQuantity  === typeof(1.0u"kgCO2e/kg")
@assert StructuralSizer.CarbonPerAreaQuantity  === typeof(1.0u"kgCO2e/m^2")
@assert StructuralSizer.CarbonPerVolQuantity   === typeof(1.0u"kgCO2e/m^3")

println("All assertions passed.")
