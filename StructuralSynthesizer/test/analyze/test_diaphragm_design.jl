# ASCE 7-22 §12.10.1.1 inertial force, and the shear and chord of a simple bay.

using Test
using StructuralSynthesizer

@testset "Diaphragm design force" begin
    # Levels bottom to top: forces 10, 20, 40; weights 100, 100, 50.
    Fi = [10.0, 20.0, 40.0]
    wi = [100.0, 100.0, 50.0]

    @testset "Eqs. 12.10-1 through 12.10-3" begin
        # Roof: ΣF = 40, Σw = 50, wpx = 50 → 40, capped at 0.4·1·1·50 = 20.
        # An analysis force of 25 is not capped by Eq. (12.10-3).
        roof = diaphragm_inertial_force(Fi[3:3], wi[3:3], 50.0, 1.0, 1.0; F_analysis = 25.0)
        @test roof.F_eq ≈ 40.0
        @test roof.F_min ≈ 10.0
        @test roof.F_max ≈ 20.0
        @test roof.F_code ≈ 20.0
        @test roof.F_design ≈ 25.0

        # Level 2: ΣF = 60, Σw = 150, wpx = 100 → 40, inside [20, 40].
        mid = diaphragm_inertial_force(Fi[2:3], wi[2:3], 100.0, 1.0, 1.0)
        @test mid.F_eq ≈ 40.0
        @test mid.F_code ≈ 40.0
        @test mid.F_design ≈ 40.0

        # Level 1: ΣF = 70, Σw = 250, wpx = 100 → 28, above the 20 floor.
        base = diaphragm_inertial_force(Fi, wi, 100.0, 1.0, 1.0)
        @test base.F_eq ≈ 28.0
        @test base.F_min ≈ 20.0
        @test base.F_code ≈ 28.0
    end

    @testset "a short Eq. 12.10-1 is raised to 0.2 SDS Ie wpx" begin
        low = diaphragm_inertial_force([5.0], [100.0], 100.0, 1.0, 1.0)
        @test low.F_eq ≈ 5.0
        @test low.F_code ≈ 20.0
    end

    @testset "one bay, shear and chord" begin
        # Fpx = 40 over 10 by 6. f = 4. End shear 20. M = 50. Chord = 50/6.
        bay = diaphragm_bay_actions(40.0, [10.0], 6.0)
        @test bay.load_per_length ≈ 4.0
        @test bay.line_shear ≈ [20.0, 20.0]
        @test bay.bay_moment ≈ [50.0]
        @test bay.bay_chord ≈ [50.0 / 6.0]
        @test sum(bay.line_shear) ≈ 40.0
    end

    @testset "two bays share the interior line" begin
        # Spans 4 and 6, Fpx = 20, depth = 5. f = 2.
        # End shears 4 and 6. Interior 4 + 6 = 10.
        # Moments 2·16/8 = 4 and 2·36/8 = 9. Chords 4/5 and 9/5.
        bay = diaphragm_bay_actions(20.0, [4.0, 6.0], 5.0)
        @test bay.line_shear ≈ [4.0, 10.0, 6.0]
        @test bay.bay_moment ≈ [4.0, 9.0]
        @test bay.bay_chord ≈ [0.8, 1.8]
        @test sum(bay.line_shear) ≈ 20.0
    end

    @testset "refuses an empty story list and a non-positive depth" begin
        @test_throws ArgumentError diaphragm_inertial_force(Float64[], Float64[], 1.0, 1.0, 1.0)
        @test_throws ArgumentError diaphragm_bay_actions(10.0, Float64[], 6.0)
        @test_throws ArgumentError diaphragm_bay_actions(10.0, [6.0], 0.0)
    end
end
