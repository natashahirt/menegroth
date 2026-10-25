# =============================================================================
# ASCE 7-22 §12.8 equivalent lateral force demand — hand checks
# =============================================================================
# Every case below is a HAND CHECK, computed from the cited equation.
# None of these cases is a published example.

using Test
using StructuralSizer

const _ATOL = 1e-12
const _RTOL = 1e-12

@testset "ASCE 7-22 ELF seismic demand" begin

    @testset "seismic response coefficient and base shear" begin
        # HAND CHECK, computed from ASCE 7-22 Eq. 12.8-3 and Eq. 12.8-4.
        # Not a published example. The cap equals the basic value.
        # Cs = 1.0 / (8/1) = 0.125, and 0.4 / (0.4 * 8) = 0.125.
        Cs = seismic_response_coefficient(;
            method=:sds, SDS=1.0, SD1=0.4, S1=0.3, T=0.4, TL=12.0, R=8.0, Ie=1.0)
        @test Cs ≈ 0.125 atol=_ATOL rtol=_RTOL
        # HAND CHECK, computed from ASCE 7-22 Eq. 12.8-1. Not a published example.
        # V = 0.125 * 2000 = 250. W = 0 is allowed and gives V = 0.
        @test seismic_base_shear(Cs, 2000.0) ≈ 250.0 atol=_ATOL rtol=_RTOL
        @test seismic_base_shear(Cs, 0.0) ≈ 0.0 atol=_ATOL rtol=_RTOL

        # HAND CHECK, computed from ASCE 7-22 Eq. 12.8-4. Not a published example.
        # Basic Cs = 1.5/8 = 0.1875. Cap = 0.6/(1.0*8) = 0.075, which governs.
        @test seismic_response_coefficient(;
            method=:sds, SDS=1.5, SD1=0.6, S1=0.25, T=1.0, TL=8.0, R=8.0, Ie=1.0
        ) ≈ 0.075 atol=_ATOL rtol=_RTOL

        # HAND CHECK, computed from ASCE 7-22 Eq. 12.8-5 and Eq. 12.8-6.
        # Not a published example. T = 10 > TL = 8, so the long-period cap is
        # 0.6*8/(10^2*8) = 0.006, which falls under the floor max(0.044*1.0*1, 0.01).
        @test seismic_response_coefficient(;
            method=:sds, SDS=1.0, SD1=0.6, S1=0.2, T=10.0, TL=8.0, R=8.0, Ie=1.0
        ) ≈ 0.044 atol=_ATOL rtol=_RTOL

        # HAND CHECK, computed from ASCE 7-22 Eq. 12.8-7. Not a published example.
        # S1 = 0.7 >= 0.6, so Cs = 0.5*0.7/(8/1) = 0.04375, above the 0.025 basic value.
        @test seismic_response_coefficient(;
            method=:sds, SDS=0.2, SD1=0.1, S1=0.7, T=0.2, TL=8.0, R=8.0, Ie=1.0
        ) ≈ 0.04375 atol=_ATOL rtol=_RTOL
        # HAND CHECK, computed from ASCE 7-22 Eq. 12.8-7. Not a published example.
        # S1 exactly 0.6 triggers the floor: 0.5*0.6/8 = 0.0375.
        @test seismic_response_coefficient(;
            method=:sds, SDS=0.2, SD1=0.1, S1=0.6, T=0.2, TL=8.0, R=8.0, Ie=1.0
        ) ≈ 0.0375 atol=_ATOL rtol=_RTOL
        # HAND CHECK, computed from ASCE 7-22 Eq. 12.8-3. Not a published example.
        # S1 just below 0.6 does not trigger Eq. 12.8-7. Cs stays at the basic 0.025.
        @test seismic_response_coefficient(;
            method=:sds, SDS=0.2, SD1=0.1, S1=prevfloat(0.6), T=0.2, TL=8.0, R=8.0, Ie=1.0
        ) ≈ 0.025 atol=_ATOL rtol=_RTOL

        # HAND CHECK, computed from ASCE 7-22 Eq. 12.8-4. Not a published example.
        # T exactly equal to TL uses Eq. 12.8-4, not Eq. 12.8-5.
        # Cs = 0.6/(4*4) = 0.0375. At T = TL the two caps are algebraically equal.
        # The following case, T just above TL, checks that Eq. 12.8-5 is the value used.
        @test seismic_response_coefficient(;
            method=:sds, SDS=0.2, SD1=0.6, S1=0.2, T=4.0, TL=4.0, R=4.0, Ie=1.0
        ) ≈ 0.0375 atol=_ATOL rtol=_RTOL
        # HAND CHECK, computed from ASCE 7-22 Eq. 12.8-5. Not a published example.
        # T = 5 > TL = 4: Cs = 0.6*4/(5^2*4) = 0.024.
        # Eq. 12.8-4 at this period would be 0.6/(5*4) = 0.03, which is not used.
        @test seismic_response_coefficient(;
            method=:sds, SDS=0.2, SD1=0.6, S1=0.2, T=5.0, TL=4.0, R=4.0, Ie=1.0
        ) ≈ 0.024 atol=_ATOL rtol=_RTOL

        # HAND CHECK, computed from ASCE 7-22 Eq. 12.8-2. Not a published example.
        # Cs = 1.2 / (6/1.5) = 0.3. Eqs. 12.8-4 and 12.8-5 do not apply to
        # Eq. 12.8-2. The floor max(0.044*1.0*1.5, 0.01) = 0.066 does not
        # govern. S1 = 0.2 < 0.6, so Eq. 12.8-7 does not apply.
        @test seismic_response_coefficient(;
            method=:sa, Sa=1.2, R=6.0, Ie=1.5, SDS=1.0, SD1=0.5, S1=0.2, T=0.6, TL=8.0
        ) ≈ 0.3 atol=_ATOL rtol=_RTOL
        # HAND CHECK, computed from ASCE 7-22 Eq. 12.8-2. Not a published example.
        # SD1, T, and TL are inputs of Eqs. 12.8-4 and 12.8-5, which cap only
        # Eq. 12.8-3. Omitting them does not change Cs = 0.3.
        @test seismic_response_coefficient(;
            method=:sa, Sa=1.2, R=6.0, Ie=1.5, SDS=1.0, S1=0.2
        ) ≈ 0.3 atol=_ATOL rtol=_RTOL
        # HAND CHECK, computed from ASCE 7-22 Eq. 12.8-6. Not a published example.
        # SDS is an input to the lower bound for both methods.
        @test_throws ArgumentError seismic_response_coefficient(;
            method=:sa, Sa=1.2, R=6.0, Ie=1.5, S1=0.2)
        # HAND CHECK, computed from ASCE 7-22 Eq. 12.8-7. Not a published example.
        # S1 decides whether the additional lower bound applies, for both methods.
        @test_throws ArgumentError seismic_response_coefficient(;
            method=:sa, Sa=1.2, R=6.0, Ie=1.5, SDS=1.0)
        # HAND CHECK, computed from ASCE 7-22 Eq. 12.8-4. Not a published example.
        # The short-period method still requires the cap inputs.
        @test_throws ArgumentError seismic_response_coefficient(;
            method=:sds, SDS=1.0, S1=0.3, T=0.4, TL=12.0, R=8.0, Ie=1.0)

        # HAND CHECK, computed from ASCE 7-22 Eq. 12.8-3. Not a published example.
        # SDS is an input to the equation, so a missing SDS is rejected.
        @test_throws ArgumentError seismic_response_coefficient(;
            method=:sds, SD1=0.4, S1=0.3, T=0.4, TL=12.0, R=8.0, Ie=1.0)
        # HAND CHECK, computed from ASCE 7-22 Eq. 12.8-2. Not a published example.
        # R = 0 makes R/Ie undefined, so it is rejected.
        @test_throws ArgumentError seismic_response_coefficient(;
            method=:sds, SDS=1.0, SD1=0.4, S1=0.3, T=0.4, TL=12.0, R=0.0, Ie=1.0)
        # HAND CHECK, computed from ASCE 7-22 Eq. 12.8-4. Not a published example.
        # T = 0 makes the period cap undefined, so it is rejected.
        @test_throws ArgumentError seismic_response_coefficient(;
            method=:sds, SDS=1.0, SD1=0.4, S1=0.3, T=0.0, TL=12.0, R=8.0, Ie=1.0)
        # HAND CHECK, computed from ASCE 7-22 Eq. 12.8-1. Not a published example.
        # A negative seismic weight is rejected.
        @test_throws ArgumentError seismic_base_shear(0.125, -1.0)
    end

    @testset "drift seismic response coefficient" begin
        # HAND CHECK, computed from ASCE 7-22 Eqs. 12.8-5 and 12.8-6 and the
        # §12.8.6.1 Exception. Not a published example. Method 2, T = 10 > TL = 8:
        # cap 0.6*8/(10^2*8) = 0.006. For strength Eq. 12.8-6 governs at 0.044.
        # For drift Eq. 12.8-6 is not applied, and S1 = 0.2 < 0.6, so Cs = 0.006.
        sds_6 = (method=:sds, SDS=1.0, SD1=0.6, S1=0.2, T=10.0, TL=8.0, R=8.0, Ie=1.0)
        @test seismic_response_coefficient(; sds_6...) ≈ 0.044 atol=_ATOL rtol=_RTOL
        @test seismic_response_coefficient(; sds_6..., for_drift=false) ≈ 0.044 atol=_ATOL rtol=_RTOL
        @test seismic_response_coefficient(; sds_6..., for_drift=true) ≈ 0.006 atol=_ATOL rtol=_RTOL

        # HAND CHECK, computed from ASCE 7-22 Eqs. 12.8-2 and 12.8-6 and the
        # §12.8.6.1 Exception. Not a published example. Method 1: Sa/(R/Ie) =
        # 0.2/8 = 0.025. Strength: Eq. 12.8-6 floor 0.044 governs. Drift: 0.025.
        sa_6 = (method=:sa, Sa=0.2, SDS=1.0, S1=0.2, R=8.0, Ie=1.0)
        @test seismic_response_coefficient(; sa_6...) ≈ 0.044 atol=_ATOL rtol=_RTOL
        @test seismic_response_coefficient(; sa_6..., for_drift=true) ≈ 0.025 atol=_ATOL rtol=_RTOL

        # HAND CHECK, computed from ASCE 7-22 Eq. 12.8-7 and Commentary C12.8.6.1.
        # Not a published example. Same Method 2 case with S1 = 0.7 >= 0.6.
        # Strength: max(0.006, 0.044, 0.5*0.7/8 = 0.04375) = 0.044 (Eq. 12.8-6).
        # Drift: Eq. 12.8-6 is skipped but Eq. 12.8-7 still applies, so 0.04375.
        sds_7 = (method=:sds, SDS=1.0, SD1=0.6, S1=0.7, T=10.0, TL=8.0, R=8.0, Ie=1.0)
        @test seismic_response_coefficient(; sds_7...) ≈ 0.044 atol=_ATOL rtol=_RTOL
        @test seismic_response_coefficient(; sds_7..., for_drift=true) ≈ 0.04375 atol=_ATOL rtol=_RTOL

        # HAND CHECK, computed from ASCE 7-22 Eq. 12.8-7 and Commentary C12.8.6.1.
        # Not a published example. Method 1, Sa/(R/Ie) = 0.025, S1 = 0.7.
        # Strength 0.044 (Eq. 12.8-6). Drift 0.5*0.7/8 = 0.04375 (Eq. 12.8-7).
        sa_7 = (method=:sa, Sa=0.2, SDS=1.0, S1=0.7, R=8.0, Ie=1.0)
        @test seismic_response_coefficient(; sa_7...) ≈ 0.044 atol=_ATOL rtol=_RTOL
        @test seismic_response_coefficient(; sa_7..., for_drift=true) ≈ 0.04375 atol=_ATOL rtol=_RTOL

        # HAND CHECK, computed from ASCE 7-22 Eq. 12.8-3. Not a published example.
        # Where neither lower bound governs, the drift value equals the strength
        # value: the first case of the previous testset, 0.125.
        @test seismic_response_coefficient(;
            method=:sds, SDS=1.0, SD1=0.4, S1=0.3, T=0.4, TL=12.0, R=8.0, Ie=1.0,
            for_drift=true) ≈ 0.125 atol=_ATOL rtol=_RTOL
    end

    @testset "vertical distribution" begin
        # HAND CHECK, computed from ASCE 7-22 §12.8.3. Not a published example.
        # T = 0.5 s is k = 1. T = 2.5 s is k = 2. Neither needs `between`.
        @test vertical_distribution_exponent(0.5) ≈ 1.0 atol=_ATOL rtol=_RTOL
        @test vertical_distribution_exponent(2.5) ≈ 2.0 atol=_ATOL rtol=_RTOL
        # HAND CHECK, computed from ASCE 7-22 §12.8.3. Not a published example.
        # Linear interpolation at T = 1.5 s: k = 1 + (1.5-0.5)/(2.5-0.5) = 1.5.
        @test vertical_distribution_exponent(1.5; between=:interpolate) ≈ 1.5 atol=_ATOL rtol=_RTOL
        # HAND CHECK, computed from ASCE 7-22 §12.8.3. Not a published example.
        # The code also permits k = 2 between 0.5 s and 2.5 s.
        @test vertical_distribution_exponent(1.5; between=:two) ≈ 2.0 atol=_ATOL rtol=_RTOL
        # HAND CHECK, computed from ASCE 7-22 §12.8.3. Not a published example.
        # Inside (0.5, 2.5) the choice of k is required, so omitting it is rejected.
        @test_throws ArgumentError vertical_distribution_exponent(1.5)

        # HAND CHECK, computed from ASCE 7-22 Eqs. 12.8-12 and 12.8-13.
        # Not a published example. k = 1, weights [100, 100, 100], heights [10, 20, 30].
        # Denominator = 100*10 + 100*20 + 100*30 = 6000.
        # Cvx = [1000, 2000, 3000]/6000. Fx = Cvx * 600 = [100, 200, 300].
        dist = vertical_distribution([100.0, 100.0, 100.0], [10.0, 20.0, 30.0], 600.0, 1.0)
        @test dist.Fx ≈ [100.0, 200.0, 300.0] atol=_ATOL rtol=_RTOL
        @test sum(dist.Cvx) ≈ 1.0 atol=_ATOL rtol=_RTOL
        @test sum(dist.Fx) ≈ 600.0 atol=_ATOL rtol=_RTOL
    end

    @testset "story shear" begin
        # HAND CHECK, computed from ASCE 7-22 Eq. 12.8-14. Not a published example.
        # Fx = [10, 20, 30] at heights [30, 20, 10]: the top level carries 10,
        # the middle 10 + 20 = 30, the bottom 10 + 20 + 30 = 60.
        @test seismic_story_shear([10.0, 20.0, 30.0], [30.0, 20.0, 10.0]) ≈
              [10.0, 30.0, 60.0] atol=_ATOL rtol=_RTOL
        # HAND CHECK, computed from ASCE 7-22 Eq. 12.8-14. Not a published example.
        # The same levels in a shuffled order return the matching shuffled result.
        @test seismic_story_shear([30.0, 10.0, 20.0], [10.0, 30.0, 20.0]) ≈
              [60.0, 10.0, 30.0] atol=_ATOL rtol=_RTOL
        # HAND CHECK, computed from ASCE 7-22 Eq. 12.8-14. Not a published example.
        # A single level carries its own force. A negative Fx is a finite real
        # and is accepted: [5, -2] at heights [20, 10] gives [5, 3].
        @test seismic_story_shear([7.0], [12.0]) ≈ [7.0] atol=_ATOL rtol=_RTOL
        @test seismic_story_shear([5.0, -2.0], [20.0, 10.0]) ≈ [5.0, 3.0] atol=_ATOL rtol=_RTOL
        # HAND CHECK, computed from ASCE 7-22 Eq. 12.8-14. Not a published example.
        # Duplicate heights make "at and above" ambiguous; empty, unequal-length,
        # non-positive, and non-finite inputs are rejected.
        @test_throws ArgumentError seismic_story_shear([1.0, 2.0], [10.0, 10.0])
        @test_throws ArgumentError seismic_story_shear(Float64[], Float64[])
        @test_throws ArgumentError seismic_story_shear([1.0, 2.0], [10.0])
        @test_throws ArgumentError seismic_story_shear([1.0], [0.0])
        @test_throws ArgumentError seismic_story_shear([1.0], [-5.0])
        @test_throws ArgumentError seismic_story_shear([NaN], [10.0])
        @test_throws ArgumentError seismic_story_shear([1.0], [Inf])
    end

    @testset "accidental torsion" begin
        # HAND CHECK, computed from ASCE 7-22 §12.8.4.2.2. Not a published example.
        # 5% of a 100 ft plan dimension is 5 ft.
        @test accidental_eccentricity(100.0) ≈ 5.0 atol=_ATOL rtol=_RTOL

        # HAND CHECK, computed from ASCE 7-22 Eq. 12.8-15. Not a published example.
        # (1/(1.2*1))^2 is less than 1, so Ax is clamped up to 1.
        @test torsional_amplification(1.0, 1.0) ≈ 1.0 atol=_ATOL rtol=_RTOL
        # HAND CHECK, computed from ASCE 7-22 Eq. 12.8-15. Not a published example.
        # (1.5/(1.2*1))^2 = 1.5625, inside [1, 3].
        @test torsional_amplification(1.5, 1.0) ≈ 1.5625 atol=_ATOL rtol=_RTOL
        # HAND CHECK, computed from ASCE 7-22 Eq. 12.8-15. Not a published example.
        # (3/(1.2*1))^2 = 6.25, which is clamped down to 3.
        @test torsional_amplification(3.0, 1.0) ≈ 3.0 atol=_ATOL rtol=_RTOL
    end

    @testset "displacement and story drift" begin
        # HAND CHECK, computed from ASCE 7-22 Eq. 12.8-16. Not a published example.
        # δDE = 5*0.4/1 + 0.1 = 2.1.
        @test design_earthquake_displacement(5.0, 0.4, 1.0, 0.1) ≈ 2.1 atol=_ATOL rtol=_RTOL
        # HAND CHECK, computed from ASCE 7-22 Eq. 12.8-17. Not a published example.
        # δMCE = 1.5*8*0.4/1 + 0.1 = 4.9.
        @test maximum_considered_displacement(8.0, 0.4, 1.0, 0.1) ≈ 4.9 atol=_ATOL rtol=_RTOL

        # HAND CHECK, computed from ASCE 7-22 §12.8.6.5. Not a published example.
        # Center-of-mass story drift is 1.2 - 0.4 = 0.8.
        @test design_story_drift(1.2, 0.4) ≈ 0.8 atol=_ATOL rtol=_RTOL
        # HAND CHECK, computed from ASCE 7-22 §12.8.6.5. Not a published example.
        # Edge differences are 1.0-0.2 = 0.8 and 1.4-0.3 = 1.1. The largest is 1.1.
        @test edge_design_story_drift([1.0, 1.4], [0.2, 0.3]) ≈ 1.1 atol=_ATOL rtol=_RTOL
        # HAND CHECK, computed from ASCE 7-22 §12.8.6.5. Not a published example.
        # Unequal or empty edge vectors are rejected.
        @test_throws ArgumentError edge_design_story_drift([1.0, 1.4], [0.2])
        @test_throws ArgumentError edge_design_story_drift(Float64[], Float64[])

        # HAND CHECK, computed from ASCE 7-22 Table 12.12-1. Not a published example.
        # All other structures, risk category II: Δa = 0.020 * 120 = 2.4.
        @test allowable_story_drift(120.0, :II, :other) ≈ 2.4 atol=_ATOL rtol=_RTOL
        # HAND CHECK, computed from ASCE 7-22 Table 12.12-1. Not a published example.
        # Other masonry shear walls, any risk category: Δa = 0.007 * 100 = 0.7.
        @test allowable_story_drift(100.0, :I, :masonry_other) ≈ 0.7 atol=_ATOL rtol=_RTOL
        @test allowable_story_drift(100.0, :IV, :masonry_other) ≈ 0.7 atol=_ATOL rtol=_RTOL
        # HAND CHECK, computed from ASCE 7-22 Table 12.12-1. Not a published example.
        # Masonry cantilever shear walls, any risk category: Δa = 0.010 * 100 = 1.
        @test allowable_story_drift(100.0, :III, :masonry_cantilever) ≈ 1.0 atol=_ATOL rtol=_RTOL
        # HAND CHECK, computed from ASCE 7-22 Table 12.12-1. Not a published example.
        # Four stories or less, not masonry, interior walls designed to accommodate
        # the drifts, risk category IV: Δa = 0.015 * 200 = 3.
        @test allowable_story_drift(200.0, :IV, :lowrise_interior_walls) ≈ 3.0 atol=_ATOL rtol=_RTOL
        # HAND CHECK, computed from ASCE 7-22 §12.12.1.1. Not a published example.
        # The same all-other, risk II case divided by rho = 1.3 is 2.4/1.3.
        @test allowable_story_drift(120.0, :II, :other; rho=1.3) ≈ 2.4 / 1.3 atol=_ATOL rtol=_RTOL

        # HAND CHECK, computed from ASCE 7-22 §12.8.6.1. Not a published example.
        # Exactly 100 lb/ft² does not exceed 100, so the factor is 0.4.
        # 100.1 lb/ft² exceeds 100, so the factor is 0.8.
        @test drift_live_load_factor(100.0) ≈ 0.4 atol=_ATOL rtol=_RTOL
        @test drift_live_load_factor(100.1) ≈ 0.8 atol=_ATOL rtol=_RTOL

        # HAND CHECK, computed from ASCE 7-22 §12.8.6.1. Not a published example.
        # 1.0D + 0.5L with L = 0.4L0 at 80 lb/ft²: 100 + 0.5*0.4*50 = 110.
        # L = 0.8L0 at 150 lb/ft²: 100 + 0.5*0.8*50 = 120.
        # Exactly 100 lb/ft² does not exceed 100: 100 + 0.5*0.4*50 = 110.
        @test drift_expected_gravity_load(100.0, 50.0, 80.0) ≈ 110.0 atol=_ATOL rtol=_RTOL
        @test drift_expected_gravity_load(100.0, 50.0, 150.0) ≈ 120.0 atol=_ATOL rtol=_RTOL
        @test drift_expected_gravity_load(100.0, 50.0, 100.0) ≈ 110.0 atol=_ATOL rtol=_RTOL
        # HAND CHECK, computed from ASCE 7-22 §12.8.6.1. Not a published example.
        # Zero loads are allowed; negative D or L0 is rejected.
        @test drift_expected_gravity_load(0.0, 0.0, 40.0) ≈ 0.0 atol=_ATOL rtol=_RTOL
        @test_throws ArgumentError drift_expected_gravity_load(-1.0, 50.0, 80.0)
        @test_throws ArgumentError drift_expected_gravity_load(100.0, -1.0, 80.0)
    end

    @testset "P-delta" begin
        # HAND CHECK, computed from ASCE 7-22 Eq. 12.8-18. Not a published example.
        # θ = (1000/12) / (100/0.5) = 0.4166666666666667.
        @test stability_coefficient(1000.0, 12.0, 100.0, 0.5) ≈ 0.4166666666666667 atol=_ATOL rtol=_RTOL
        # HAND CHECK, computed from ASCE 7-22 Eq. 12.8-18. Not a published example.
        # Δxe = 0 is a rigid story, so θ = 0.
        @test stability_coefficient(1000.0, 12.0, 100.0, 0.0) ≈ 0.0 atol=_ATOL rtol=_RTOL

        # HAND CHECK, computed from ASCE 7-22 Eq. 12.8-19. Not a published example.
        # β = 1, Cd = 5: θmax = 0.5/(1*5) = 0.1.
        @test stability_coefficient_limit(1.0, 5.0) ≈ 0.1 atol=_ATOL rtol=_RTOL
        # HAND CHECK, computed from ASCE 7-22 Eq. 12.8-19. Not a published example.
        # β = 1, Cd = 1: 0.5/(1*1) = 0.5, which is capped at 0.25.
        @test stability_coefficient_limit(1.0, 1.0) ≈ 0.25 atol=_ATOL rtol=_RTOL
        # HAND CHECK, computed from ASCE 7-22 Eq. 12.8-19. Not a published example.
        # β = 1, Cd = 8: 0.5/(1*8) = 0.0625. The permission to raise θmax to 0.1
        # is not applied, so the result stays 0.0625.
        @test stability_coefficient_limit(1.0, 8.0) ≈ 0.0625 atol=_ATOL rtol=_RTOL
        # HAND CHECK, computed from ASCE 7-22 §12.8.7. Not a published example.
        # β shall not be taken less than 1.25/Ω0. 1.25/4 = 0.3125, and 0.5 is
        # not less than 0.3125, so β = 0.5 with Ω0 = 4 is permitted.
        # θmax = min(0.5/(0.5*5), 0.25) = 0.2.
        @test stability_coefficient_limit(0.5, 5.0; Ω0=4.0) ≈ 0.2 atol=_ATOL rtol=_RTOL
        # HAND CHECK, computed from ASCE 7-22 §12.8.7. Not a published example.
        # β = 0.2 is less than 1.25/Ω0 = 1.25/4 = 0.3125, so it is rejected.
        @test_throws ArgumentError stability_coefficient_limit(0.2, 5.0; Ω0=4.0)

        # HAND CHECK, computed from ASCE 7-22 §12.8.7. Not a published example.
        # θ = 0.10 does not require P-delta amplification, so the multiplier is 1.
        @test pdelta_displacement_multiplier(0.10, 0.25) ≈ 1.0 atol=_ATOL rtol=_RTOL
        # HAND CHECK, computed from ASCE 7-22 §12.8.7. Not a published example.
        # 0.10 < 0.2 <= 0.25, so the multiplier is 1/(1-0.2) = 1.25.
        @test pdelta_displacement_multiplier(0.2, 0.25) ≈ 1.25 atol=_ATOL rtol=_RTOL
        # HAND CHECK, computed from ASCE 7-22 §12.8.7. Not a published example.
        # θ = 0.3 exceeds θmax = 0.25, so the structure shall be redesigned.
        err = try
            pdelta_displacement_multiplier(0.3, 0.25)
            nothing
        catch e
            e
        end
        @test err isa ArgumentError
        @test occursin("redesigned", err.msg)
    end
end
