using Test
using StructuralSizer

# ASCE 7-22 §26.11 (corpus: asce-7-22, PDF pages 338–340). The expected
# values are hand calculations of the printed equations.
@testset "§26.11 gust effects" begin
    @testset "Table 26.11-1" begin
        tc = wind_terrain_constants(:C)
        @test (tc.c, tc.ℓ_ft, tc.ε̄, tc.zmin_ft, tc.b̄, tc.ᾱ) == (0.20, 500.0, 1 / 5.0, 15.0, 0.66, 1 / 6.4)
        @test wind_terrain_constants(:B).zmin_ft == 30.0
        @test wind_terrain_constants(:D).ℓ_ft == 650.0
        @test_throws ArgumentError wind_terrain_constants(:A)
    end

    @testset "natural frequency and its limits" begin
        # Eq. 26.11-1: (10·100 + 20·80) / 30.
        @test wind_effective_length([10.0, 20.0], [100.0, 80.0]) ≈ 2600 / 30
        @test approximate_frequency_permitted(262.0, 100.0)
        @test !approximate_frequency_permitted(301.0, 100.0)
        @test !approximate_frequency_permitted(400.0, 100.0)
        @test approximate_natural_frequency(262.0; system=:other) ≈ 75 / 262
        @test approximate_natural_frequency(100.0; system=:concrete_moment_frame) ≈ 43.5 / 100^0.9
        @test approximate_natural_frequency(100.0; system=:steel_moment_frame) ≈ 22.2 / 100^0.8
        # Eq. 26.11-5: two 30 ft walls, 1 ft thick, full height, AB = 10,000 ft².
        Cw = 100 / 10_000 * 2 * 30 / (1 + 0.83 * (262 / 30)^2)
        @test shear_wall_natural_frequency(262.0, 10_000.0, [(30.0, 30.0, 262.0), (30.0, 30.0, 262.0)]) ≈
              385 * sqrt(Cw) / 262
        @test wind_low_rise(60.0, 60.0)
        @test !wind_low_rise(61.0, 100.0)
        @test !wind_low_rise(50.0, 40.0)
    end

    @testset "rigid and flexible gust-effect factors" begin
        # h = 262 ft, B = L = 100 ft, exposure C. z̄ = 157.2 ft.
        rigid = gust_effect_factor_rigid(262.0, 100.0; exposure=:C)
        @test rigid.z̄ ≈ 157.2
        @test rigid.Iz ≈ 0.20 * (33 / 157.2)^(1 / 6)
        @test rigid.Lz ≈ 500 * (157.2 / 33)^(1 / 5)
        @test rigid.Q ≈ 0.838521 rtol = 1e-5
        @test rigid.G ≈ 0.854613 rtol = 1e-5
        # V = 115 mi/h, n1 = 0.29 Hz, β = 0.02.
        flex = gust_effect_factor_flexible(262.0, 100.0, 100.0; exposure=:C, V_mph=115.0,
                                           n1=0.29, β=0.02)
        @test flex.gR ≈ 3.883243 rtol = 1e-5
        @test flex.Vz_fps ≈ 142.0696 rtol = 1e-5
        @test flex.N1 ≈ 1.394616 rtol = 1e-5
        @test flex.R ≈ 0.826042 rtol = 1e-5
        @test flex.Gf ≈ 1.039301 rtol = 1e-5
        @test_throws ArgumentError gust_effect_factor_flexible(262.0, 100.0, 100.0; exposure=:C,
                                                               V_mph=115.0, n1=0.29, β=2.0)
    end
end
