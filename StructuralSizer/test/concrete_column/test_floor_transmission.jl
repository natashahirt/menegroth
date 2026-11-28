# ==============================================================================
# ACI 318-11 §10.12 — column strength through a weaker floor system
# ==============================================================================

using Test
using StructuralSizer
using Unitful

@testset "§10.12 joint concrete strength" begin
    jcs = StructuralSizer.joint_concrete_strength
    psi = u"psi"
    # Within 1.4× the floor: no provision.
    @test jcs(5600.0psi, 4000.0psi; restrained_four_sides = true) === nothing
    @test jcs(5600.0psi, 4000.0psi; restrained_four_sides = false) === nothing
    # §10.12.3: 0.75·6000 + 0.35·4000 = 5900 psi.
    @test jcs(6000.0psi, 4000.0psi; restrained_four_sides = true) ≈ 5900.0psi
    # §10.12.3 with fc_col / fc_floor capped at 2.5: 0.75·(2.5·3000) + 0.35·3000.
    @test jcs(10000.0psi, 3000.0psi; restrained_four_sides = true) ≈ 6675.0psi
    # §10.12.2: edge and corner columns use the floor strength.
    @test jcs(6000.0psi, 4000.0psi; restrained_four_sides = false) == 4000.0psi

    c = StructuralSizer.with_compressive_strength(NWC_6000, 4000.0psi)
    @test c.fc′ == 4000.0psi
    @test c.E == NWC_6000.E && c.ρ == NWC_6000.ρ && c.εcu == NWC_6000.εcu
end
