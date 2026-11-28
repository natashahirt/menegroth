# ACI 318-19 slab provisions: hand-calculated values.
#   §22.5.5.1.3 size effect, Table 22.5.5.1(c) one-way Vc, Table 22.6.5.2 vc,
#   Eq. (8.6.1.2) top steel at columns, Table 24.2.3.5 Ie, Table 21.2.2 εt.

using Test
using Unitful
using Asap
using StructuralSizer

const SS = StructuralSizer

@testset "ACI 318-19 slab provisions" begin
    @testset "size effect λs (Eq. 22.5.5.1.3)" begin
        @test SS.size_effect_factor(6.0u"inch") == 1.0
        @test SS.size_effect_factor(10.0u"inch") ≈ 1.0
        @test SS.size_effect_factor(20.0u"inch") ≈ sqrt(2 / 3)   # 0.8165
    end

    @testset "√f'c ≤ 100 psi in shear (§22.6.3.1)" begin
        vc_10 = SS.punching_capacity_stress(10_000.0u"psi", 1.0, 40, 100.0u"inch", 6.0u"inch")
        vc_12 = SS.punching_capacity_stress(12_000.0u"psi", 1.0, 40, 100.0u"inch", 6.0u"inch")
        @test ustrip(u"psi", vc_12) ≈ ustrip(u"psi", vc_10) ≈ 400.0
    end

    @testset "punching vc carries λs (Table 22.6.5.2)" begin
        d = 20.0u"inch"
        λs = SS.size_effect_factor(d)
        # αs d/b0 + 2 = 4.67 > 4 → (a) governs
        vc = SS.punching_capacity_stress(4000.0u"psi", 1.0, 40, 300.0u"inch", d; λs = λs)
        @test ustrip(u"psi", vc) ≈ 4 * sqrt(2 / 3) * sqrt(4000) rtol = 1e-10
        # αs d/b0 + 2 = 2.8 → (c) governs
        vc_c = SS.punching_capacity_stress(4000.0u"psi", 1.0, 40, 1000.0u"inch", d; λs = λs)
        @test ustrip(u"psi", vc_c) ≈ 2.8 * sqrt(2 / 3) * sqrt(4000) rtol = 1e-10
    end

    @testset "one-way Vc without Av (Table 22.5.5.1(c))" begin
        # ρw = 0.2/72; 8·ρw^(1/3)·√4000·12·6 = 5120.96 lb
        Vc = SS.one_way_shear_capacity_without_Av(4000.0u"psi", 12.0u"inch", 6.0u"inch",
                                               0.2u"inch^2")
        @test ustrip(u"lbf", Vc) ≈ 5120.963 rtol = 1e-6
        # §22.5.5.1.1 cap: 5√f'c bw d = 22,768 lb
        Vc_cap = SS.one_way_shear_capacity_without_Av(4000.0u"psi", 12.0u"inch", 6.0u"inch",
                                                   72.0u"inch^2")
        @test ustrip(u"lbf", Vc_cap) ≈ 22768.399 rtol = 1e-6
    end

    @testset "column top steel (Eq. 8.6.1.2)" begin
        # 5·200·40·80 / (0.75·40·60000) = 1.7778 in²
        As = SS.punching_minimum_top_steel(200.0u"psi", 40.0u"inch", 80.0u"inch",
                                           4000.0u"psi", 60_000.0u"psi", 40)
        @test ustrip(u"inch^2", As) ≈ 1.77778 rtol = 1e-5
        # vuv below φ·2·√f'c = 94.9 psi → not required
        As0 = SS.punching_minimum_top_steel(90.0u"psi", 40.0u"inch", 80.0u"inch",
                                            4000.0u"psi", 60_000.0u"psi", 40)
        @test ustrip(u"inch^2", As0) == 0.0
    end

    @testset "Ie (Table 24.2.3.5)" begin
        Ig = 1000.0u"inch^4"
        Icr = 200.0u"inch^4"
        Mcr = 10.0u"kip*ft"
        # 200 / (1 − (6.667/20)²·0.8) = 219.51 in⁴
        Ie = SS.effective_moment_of_inertia_aci318_19(Mcr, 20.0u"kip*ft", Ig, Icr)
        @test ustrip(u"inch^4", Ie) ≈ 219.512 rtol = 1e-5
        # Ma ≤ (2/3)Mcr → Ig
        @test SS.effective_moment_of_inertia_aci318_19(Mcr, 6.0u"kip*ft", Ig, Icr) == Ig
        @test SS.effective_moment_of_inertia_function(:aci318_19) === SS.effective_moment_of_inertia_aci318_19
        @test_throws ArgumentError SS.effective_moment_of_inertia_function(:other)
    end

    @testset "tension-controlled strain (Table 21.2.2)" begin
        @test SS.tension_controlled_strain(60.0u"ksi") == 0.005
        @test SS.tension_controlled_strain(80.0u"ksi") ≈ 80 / 29000 + 0.003
    end

    @testset "slab As,min (§8.6.1.1)" begin
        @test ustrip(u"inch^2", SS.minimum_reinforcement(12.0u"inch", 8.0u"inch", 80.0u"ksi")) ≈
              0.0018 * 12 * 8
    end
end
