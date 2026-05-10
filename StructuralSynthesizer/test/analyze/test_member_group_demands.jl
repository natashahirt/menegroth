# Unit tests for the FEM → ACI 318-19 end-moment sign-convention helper used
# by `member_group_demands` to populate `MemberDemand.M1x/M2x/M1y/M2y` for
# columns from the Asap analysis.
#
# Reference: ACI 318-19 §6.6.4.5.3 (Cm) and §6.2.5.1 (slenderness limit) —
# `M1/M2 > 0` ⇔ double curvature, `M1/M2 < 0` ⇔ single curvature. AISC
# 360-16 Appendix 8 uses the same sign convention.

using Test
using StructuralSynthesizer

@testset "_fem_to_aci_endmoments — ACI 318-19 sign convention" begin
    f = StructuralSynthesizer._fem_to_aci_endmoments

    @testset "Cantilever-like (one end zero)" begin
        # M_start = 0, M_end ≠ 0 → only one moment, ratio is 0.
        M1, M2 = f(0.0, 100.0)
        @test M2 ≈ 100.0
        @test M1 ≈ 0.0

        # Symmetric: M_start ≠ 0, M_end = 0
        M1, M2 = f(100.0, 0.0)
        @test M2 ≈ 100.0
        @test M1 ≈ 0.0
    end

    @testset "Single curvature (FEM signs opposite) → ACI M1/M2 < 0" begin
        # Equal magnitudes, opposite FEM signs (single curvature).
        M1, M2 = f(+100.0, -100.0)
        @test M2 ≈ 100.0
        @test M1 ≈ -100.0
        @test M1 / M2 ≈ -1.0  # ACI 318-19: -1.0 = pure single curvature

        # Unequal magnitudes, opposite signs.
        M1, M2 = f(+50.0, -100.0)
        @test M2 ≈ 100.0
        @test M1 ≈ -50.0
        @test M1 / M2 ≈ -0.5
    end

    @testset "Double curvature (FEM signs same) → ACI M1/M2 > 0" begin
        # Equal magnitudes, same FEM sign (double curvature S-shape).
        M1, M2 = f(+100.0, +100.0)
        @test M2 ≈ 100.0
        @test M1 ≈ +100.0
        @test M1 / M2 ≈ +1.0  # ACI 318-19: +1.0 = pure double curvature

        # Unequal magnitudes, same sign.
        M1, M2 = f(-50.0, -100.0)
        @test M2 ≈ 100.0
        @test M1 ≈ +50.0
        @test M1 / M2 ≈ +0.5
    end

    @testset "|M2| ≥ |M1| ordering enforced" begin
        # Larger magnitude is at start.
        M1, M2 = f(-150.0, +75.0)
        @test M2 ≈ 150.0
        @test abs(M1) ≤ M2

        # Larger at end.
        M1, M2 = f(+75.0, -150.0)
        @test M2 ≈ 150.0
        @test abs(M1) ≤ M2
    end

    @testset "Zero moments" begin
        M1, M2 = f(0.0, 0.0)
        @test M1 == 0.0
        @test M2 == 0.0
    end

    @testset "ACI 318-19 limits sanity checks" begin
        # In single curvature (M1/M2 < 0), the slenderness limit
        # (34 + 12·M1/M2) is *smaller* than 34 — more conservative.
        M1, M2 = f(+100.0, -100.0)
        @test 34 + 12 * M1 / M2 ≈ 22.0  # = 34 - 12·1 = 22

        # In double curvature (M1/M2 > 0), the limit is larger (capped at 40).
        M1, M2 = f(+100.0, +100.0)
        @test 34 + 12 * M1 / M2 ≈ 46.0  # raw value before min(., 40) clamp
    end
end
