# =============================================================================
# ASCE 7-22 §12.8 ELF demand — 2020 NEHRP Provisions Design Examples
# =============================================================================
# Source: corpus source_id nehrp-2020-design-examples-v1 (FEMA P-2192-V1,
# 2020 NEHRP Provisions Design Examples, Vol. 1). PDF page = printed page + 1.
#
# The oracle is the ASCE 7-22 arithmetic on each example's printed inputs.
# Where the publication prints a mistake, the mistake is quoted in a comment
# and the corrected number is asserted, labeled HAND CHECK FROM EXAMPLE INPUTS.
# Values asserted exactly as printed are labeled PUBLISHED EXAMPLE.
#
# Both examples use the UNROUNDED period T = Cu*Ta in every call. The
# publication rounds Ta and T before using them.

using Test
using StructuralSizer

@testset "NEHRP 2020 design examples, ASCE 7-22 ELF" begin

    @testset "Example 4 ELF base shear (nehrp-2020-design-examples-v1, §4.5.1.2 and §4.5.1.7, PDF pages 146-149)" begin
        # Inputs printed on PDF page 146 (§4.5.1.2): SDS = 1.10, SD1 = 0.65,
        # S1 = 0.65, TL = 8 s, R = 8, Ie = 1.0. PDF page 147: W = 43,099 kips.
        # PDF page 148 (§4.5.1.7): hn = 234.25 ft, Ct = 0.02, x = 0.75, Cu = 1.4.
        SDS, SD1, S1, TL, R, Ie, W = 1.10, 0.65, 0.65, 8.0, 8.0, 1.0, 43_099.0
        # Unrounded T = Cu*Ta = 1.4 * 0.02 * 234.25^0.75 = 1.67655 s.
        # The publication prints Ta = 1.2 s and T = 1.68 s.
        T = 1.4 * 0.02 * 234.25^0.75
        tol = 1e-12

        # HAND CHECK FROM EXAMPLE INPUTS. Published mistake (PDF page 149):
        # "0.044SDSIe = 0.044 × 0.65 × 1.0 = 0.029". The 0.65 is SD1 and S1,
        # not SDS; SDS on PDF page 146 is 1.10. Corrected Eq. 12.8-6 floor:
        # 0.044 * 1.10 * 1.0 = 0.0484.
        floor_eq6 = 0.044 * SDS * Ie
        @test floor_eq6 ≈ 0.0484 atol=tol rtol=tol

        # HAND CHECK FROM EXAMPLE INPUTS. Eq. 12.8-4 cap = 0.65/(T*8) = 0.048462.
        # It exceeds the corrected floor 0.0484 and Eq. 12.8-7 = 0.5*0.65/8 =
        # 0.040625, and is below Eq. 12.8-3 = 1.10/8 = 0.1375, so it governs.
        # The publication labels these with ASCE 7-16 numbers (12.8-2, -3, -5, -6).
        cap_eq4 = SD1 / (T * R / Ie)
        @test cap_eq4 ≈ 0.04846248042991762 atol=1e-15 rtol=1e-12
        @test cap_eq4 > floor_eq6
        @test cap_eq4 > 0.5 * S1 / (R / Ie)
        Cs = seismic_response_coefficient(;
            method=:sds, SDS=SDS, SD1=SD1, S1=S1, T=T, TL=TL, R=R, Ie=Ie)
        @test Cs ≈ cap_eq4 atol=tol rtol=tol
        # PUBLISHED EXAMPLE (PDF page 149): the Eq. 12.8-4 value is printed as
        # 0.0485, i.e. 0.0485 ± 0.00005 from its printed rounding.
        @test abs(Cs - 0.0485) <= 0.00005

        # HAND CHECK FROM EXAMPLE INPUTS. V = Cs * W = 0.048462 * 43,099 = 2,088.68 kips.
        V = seismic_base_shear(Cs, W)
        @test V ≈ cap_eq4 * W atol=1e-9 rtol=tol
        # The publication prints "V = CSW = 0.048 × 43,099 = 2,090 kips"
        # (PDF page 149). 2,090 is 0.0485 × 43,099 = 2,090.30 rounded, so it is
        # the published rounding, not the expected result. The difference from
        # the corrected V is only the effect of rounding Cs to 0.0485:
        # |0.0485 - Cs| * 43,099 = 1.62 kips. That is the bound used here.
        @test abs(V - 0.0485 * W) <= abs(0.0485 - cap_eq4) * W + 1e-9
    end

    @testset "Example 4 Table 4-7 Cd*δxe/Ie arithmetic (nehrp-2020-design-examples-v1, §4.5.1.8, PDF page 151)" begin
        # PUBLISHED EXAMPLE, Table 4-7 X-direction (PDF page 151; an MRSA result).
        # Checks the Cd*δxe/Ie arithmetic of Eq. 12.8-16 only, with Cd = 8,
        # Ie = 1.0 (PDF page 146), δdi = 0. δxe is printed to 0.01 in., so the
        # tolerance is Cd * 0.005 = 0.04 in.
        Cd, Ie = 8.0, 1.0
        tol = Cd * 0.005
        # Story L22: δxe = 3.21 in., printed δx = 25.65 in.
        @test design_earthquake_displacement(Cd, 3.21, Ie, 0.0) ≈ 25.65 atol=tol
        # Story L20: δxe = 2.90 in., printed δx = 23.18 in.
        @test design_earthquake_displacement(Cd, 2.90, Ie, 0.0) ≈ 23.18 atol=tol
        # Story L02: δxe = 0.07 in., printed δx = 0.55 in.
        @test design_earthquake_displacement(Cd, 0.07, Ie, 0.0) ≈ 0.55 atol=tol
    end

    @testset "Example 5 ELF base shear (nehrp-2020-design-examples-v1, §5.5.3.5-§5.5.3.6, PDF pages 191-193)" begin
        # Inputs printed on PDF page 191 (§5.5.3.5): SDS = 1.101, SD1 = 0.650,
        # R = 8, Ie = 1.0. S1 is not listed there; 0.650 is the value printed
        # for S1 inside the 0.5*S1/(R/Ie) line on PDF page 192. PDF page 192:
        # hn = 238 ft, Ct = 0.020, x = 0.75, Cu = 1.4. PDF page 193: W = 25,844
        # kips in "V = Cs W = (0.048) (25,844)".
        SDS, SD1, S1, R, Ie, W = 1.101, 0.650, 0.650, 8.0, 1.0, 25_844.0
        # Unrounded T = Cu*Ta = 1.4 * 0.020 * 238^0.75 = 1.69664 s.
        # The publication prints Ta = 1.21 s and T = 1.70 s.
        T = 1.4 * 0.020 * 238^0.75
        # ENGINEERING JUDGMENT: TL is not printed for Example 5. The publication
        # uses the T <= TL cap (Eq. 12.8-4), and Cs is the same for every
        # TL >= T, so TL = T is passed; at T == TL the function uses Eq. 12.8-4.
        TL = T
        tol = 1e-12

        # Published equation-number mistakes (PDF page 192), comment only: the
        # publication labels SDS/(R/Ie) as Eq. 12.8-2, SD1/(T(R/Ie)) as
        # Eq. 12.8-3, the floor as Eq. 12.8-5, and 0.5*S1/(R/Ie) as Eq. 12.8-6.
        # Those are ASCE 7-16 numbers; in ASCE 7-22 they are Eqs. 12.8-3,
        # 12.8-4, 12.8-6, and 12.8-7. It also prints "Cs,Min = 0.44 SDS Ie =
        # (0.44)(1.101)(1) = 0.048". 0.44*1.101 = 0.484; the printed 0.048 is
        # 0.044*1.101. The coefficient in Eq. 12.8-6 is 0.044.
        #
        # Published base-shear mistake (PDF page 193): "The seismic response
        # coefficient that governs is 0.048 from Eq. 12.8-3, and this matches
        # the minimum value from Eq. 12.8-5", then "V = Cs W = (0.048) (25,844)
        # = 1,238 kips". Unrounded, the Eq. 12.8-4 cap is 0.65/(T*8) = 0.047889
        # and the Eq. 12.8-6 floor 0.044*1.101*1.0 = 0.048444 is larger, so the
        # floor governs. Eq. 12.8-7 = 0.5*0.650/8 = 0.040625 does not govern.
        cap_eq4 = SD1 / (T * R / Ie)
        floor_eq6 = 0.044 * SDS * Ie
        @test cap_eq4 ≈ 0.04788865289281741 atol=1e-15 rtol=1e-12
        @test floor_eq6 > cap_eq4
        @test floor_eq6 > 0.5 * S1 / (R / Ie)

        # HAND CHECK FROM EXAMPLE INPUTS. Cs = 0.044 * 1.101 = 0.048444.
        Cs = seismic_response_coefficient(;
            method=:sds, SDS=SDS, SD1=SD1, S1=S1, T=T, TL=TL, R=R, Ie=Ie)
        @test Cs ≈ 0.044 * 1.101 atol=tol rtol=tol
        # HAND CHECK FROM EXAMPLE INPUTS. V = 0.048444 * 25,844 = 1,251.99 kips.
        V = seismic_base_shear(Cs, W)
        @test V ≈ 0.044 * 1.101 * 25_844 atol=1e-9 rtol=tol
    end

    @testset "Example 5 vertical distribution and story shear (nehrp-2020-design-examples-v1, §5.5.3.6 and Table 5-4, PDF pages 192-194)" begin
        SDS, SD1, S1, R, Ie, W = 1.101, 0.650, 0.650, 8.0, 1.0, 25_844.0
        T = 1.4 * 0.020 * 238^0.75
        tol = 1e-12

        # HAND CHECK FROM EXAMPLE INPUTS. k = 1 + (T - 0.5)/2 = 1.59832 by linear
        # interpolation (ASCE 7-22 §12.8.3). The publication prints k = 1.6
        # (PDF page 193), which is its rounding of this value.
        k = vertical_distribution_exponent(T; between=:interpolate)
        @test k ≈ 1 + (T - 0.5) / 2 atol=tol rtol=tol
        @test k ≈ 1.59832204595367 atol=1e-12

        # Table 5-4 (PDF page 194): elevations (ft) and weights (kips), Roof first,
        # then Levels 18 through 2.
        h = [238.0, 225.0, 212.0, 199.0, 186.0, 173.0, 160.0, 147.0, 134.0,
             121.0, 108.0, 95.0, 82.0, 69.0, 56.0, 43.0, 30.0, 17.0]
        w = [1263.0; fill(1440.0, 16); 1555.0]
        # The level weights sum to 1,263 + 16*1,440 + 1,555 = 25,858 kips. Table
        # 5-4 prints SUM = 25,855, §5.5.3.4 (PDF page 190) prints 25,855, and
        # the base-shear equation (PDF page 193) uses 25,844. The level weights
        # are used as printed; W = 25,844 is used for V.
        @test sum(w) == 25_858.0

        # The printed w*h^k column (PDF page 194) is not asserted. It is printed
        # to the integer (relative rounding about 3.5e-6 at most), but w*h^k
        # with the unrounded k differs from it by about 1.4e-4 relative, so it
        # cannot be reproduced within its printed rounding from the printed
        # inputs.

        # Cvx does not depend on V. PUBLISHED EXAMPLE, Table 5-4 Cvx column,
        # printed to 3 decimals, so the tolerance is 0.0005.
        Cvx_printed = [0.118, 0.123, 0.112, 0.101, 0.091, 0.081, 0.071, 0.062, 0.054,
                       0.046, 0.038, 0.031, 0.025, 0.019, 0.013, 0.009, 0.005, 0.002]
        Cs = seismic_response_coefficient(;
            method=:sds, SDS=SDS, SD1=SD1, S1=S1, T=T, TL=T, R=R, Ie=Ie)
        V = seismic_base_shear(Cs, W)
        dist = vertical_distribution(w, h, V, k)
        @test all(abs.(dist.Cvx .- Cvx_printed) .<= 0.0005)
        @test sum(dist.Cvx) ≈ 1.0 atol=tol

        # HAND CHECK FROM EXAMPLE INPUTS. The corrected base shear V = 1,251.99
        # kips (previous testset) is distributed, not the published 1,238. The
        # printed Fx and Vx columns were built from 1,238 kips and are not used
        # as expected forces; scaled by V/1,238 = 1.01130 they are what the
        # table should have been (e.g. Roof Fx 146.2 -> 147.9 kips).
        @test dist.Fx ≈ dist.Cvx .* V atol=1e-9 rtol=tol
        @test sum(dist.Fx) ≈ V atol=1e-9 rtol=tol

        # HAND CHECK FROM EXAMPLE INPUTS. ASCE 7-22 Eq. 12.8-14: Vx is the sum
        # of Fx at and above each level. Levels are listed top down, so Vx is
        # the running sum, and the lowest story carries the full base shear.
        Vx = seismic_story_shear(dist.Fx, h)
        @test Vx ≈ cumsum(dist.Fx) atol=1e-9 rtol=tol
        @test Vx[end] ≈ V atol=1e-9 rtol=tol
        @test Vx[1] ≈ dist.Fx[1] atol=tol rtol=tol
    end
end
