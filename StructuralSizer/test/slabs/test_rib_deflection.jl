# Rib deflection from a grillage frame.
#
# ACI 318-11 §9.5.2.3 Eq. (9-8) and §9.5.2.5 Eq. (9-11). The frame supplies
# the elastic deflection. These tests scale that number; they do not call the
# simply-supported beam formula or the strength-model inertia factor.

using Test
using Unitful
using StructuralSizer

const SS = StructuralSizer

@testset "a grillage deflection scales by the service inertia" begin
    L = 6.0u"m"
    Ie = 1.0e-3u"m^4"
    ΔD = 1.0u"mm"
    ΔDL = 2.0u"mm"
    # ξ = 2 and ρ′ = 0 give λΔ = 2. Dead is the sustained load.
    out = SS.scale_rib_deflection(ΔD, ΔD, ΔDL, Ie, Ie, Ie, Ie, L; ξ = 2.0, ρ_prime = 0.0)
    @test out.λΔ == 2.0
    @test out.Δ_D ≈ ΔD
    @test out.Δ_LL ≈ 1.0u"mm"
    @test out.Δ_total ≈ 3.0u"mm"
    @test out.checks[:immediate_ll].limit ≈ L / 360
    @test out.checks[:total].limit ≈ L / 240
    @test out.ok

    # A cracked service section is softer than the frame, so the deflection grows.
    cracked = SS.scale_rib_deflection(ΔD, ΔD, ΔDL, Ie, Ie / 2, Ie / 2, Ie / 2, L)
    @test cracked.Δ_D ≈ 2.0u"mm"
    @test cracked.Δ_total ≈ 6.0u"mm"

    @test_throws ArgumentError SS.scale_rib_deflection(ΔD, ΔD, ΔDL, Ie, Ie, Ie, Ie, L;
                                                       limits = [:unknown])
    @test_throws ArgumentError SS.scale_rib_deflection(ΔD, ΔD, ΔDL, 0.0u"m^4", Ie, Ie, Ie, L)
    @test_throws ArgumentError SS.scale_rib_deflection(-ΔD, ΔD, ΔDL, Ie, Ie, Ie, Ie, L)
end
