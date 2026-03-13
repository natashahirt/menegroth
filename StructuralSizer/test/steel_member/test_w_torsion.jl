# =============================================================================
# Tests for AISC Design Guide 9 — W-Shape Torsion
# =============================================================================
# Validates:
#   1. DG9 torsional properties (Wno, Sw1, a)
#   2. Torsional rotation derivatives (Case 3 — concentrated midspan)
#   3. Torsional stress calculations
#   4. Design checks (yielding, interaction)
#   5. Full design_w_torsion — validated against DG9 Example 5.1 (W10x49)
#   6. MemberDemand backward compatibility with Tu field
#   7. Adversarial / edge cases
# =============================================================================

using Test
using Unitful
using Unitful: @u_str
using StructuralSizer
using Asap

@testset "AISC DG9 W-Shape Torsion" begin

    # =========================================================================
    # Reference Data — DG9 Example 5.1
    # =========================================================================
    # W10x49, L = 15 ft (180 in), pinned-pinned
    # 15-kip factored load at midspan, 6 in. eccentricity from shear center
    # → Tu = 15 × 6 = 90 kip-in (factored)
    # → Mu = 15 × 180/4 = 675 kip-in (at midspan)
    # → Vu = 15/2 = 7.5 kip (at support)
    #
    # Section properties (W10x49):
    #   d=10.0", bf=10.0", tw=0.34", tf=0.56"
    #   J=1.39 in⁴, Cw=2070 in⁶, Ix=272 in⁴, Sx=54.6 in³
    #   ho = 9.44 in, Wno = 23.6 in², Sw1 = 33.0 in⁴
    #
    # Reference results:
    #   σ_b = 675/54.6 = 12.4 ksi
    #   Max combined normal stress ≈ 40.4 ksi (midspan)
    #   Max combined shear stress  ≈ 11.4 ksi (support)
    #   Max rotation ≈ 0.062 rad (midspan, service load = 60 kip-in)
    # =========================================================================

    mat = A992_Steel
    E_ksi = 29000.0
    G_ksi = E_ksi / (2 * (1 + 0.3))  # ≈ 11153.8

    @testset "DG9 Properties — W10x49" begin
        sec = W("W10X49")

        Wno = dg9_Wno(sec)
        Sw1 = dg9_Sw1(sec)
        a   = dg9_torsional_parameter(sec, mat)

        Wno_in2 = ustrip(u"inch^2", Wno)
        @test Wno_in2 ≈ 23.6  atol=0.5

        Sw1_in4 = ustrip(u"inch^4", Sw1)
        @test Sw1_in4 ≈ 33.0  atol=1.0

        a_in = ustrip(u"inch", a)
        @test a_in ≈ 62.1  atol=2.0
    end

    @testset "DG9 Properties — Various Sections" begin
        sec_small = W("W6X9")
        sec_large = W("W24X76")

        Wno_small = ustrip(u"inch^2", dg9_Wno(sec_small))
        Wno_large = ustrip(u"inch^2", dg9_Wno(sec_large))

        @test Wno_large > Wno_small
        @test Wno_small > 0
        @test ustrip(u"inch^4", dg9_Sw1(sec_small)) > 0
    end

    @testset "Torsional Derivatives — Case 3 (Concentrated Midspan)" begin
        # W10x49 properties
        J_in4 = 1.39
        Cw_in6 = 2070.0
        a_in = sqrt(E_ksi * Cw_in6 / (G_ksi * J_in4))  # ≈ 62.1 in
        L_in = 180.0
        T_kipin = 90.0

        # At support (z = 0)
        d_sup = torsion_case3_derivatives(0.0, L_in, T_kipin, a_in, G_ksi, J_in4)
        @test d_sup.θ ≈ 0.0  atol=1e-10
        @test d_sup.θpp ≈ 0.0  atol=1e-10  # Free warping at support
        @test d_sup.θp > 0  # Positive rotation rate

        # At midspan (z = L/2)
        d_mid = torsion_case3_derivatives(L_in/2, L_in, T_kipin, a_in, G_ksi, J_in4)
        @test d_mid.θp ≈ 0.0  atol=1e-8  # Zero twist rate at midspan
        @test d_mid.θ > 0  # Maximum rotation at midspan

        # θ increases monotonically from 0 to L/2
        θ_quarter = torsion_case3_derivatives(L_in/4, L_in, T_kipin, a_in, G_ksi, J_in4).θ
        @test 0 < θ_quarter < d_mid.θ

        # Service rotation at midspan (T_service = 60 kip-in)
        d_mid_svc = torsion_case3_derivatives(L_in/2, L_in, 60.0, a_in, G_ksi, J_in4)
        @test d_mid_svc.θ ≈ 0.062  atol=0.010  # Reference: 0.062 rad
    end

    @testset "Torsional Stresses — W10x49 at Support" begin
        J_in4 = 1.39
        Cw_in6 = 2070.0
        a_in = sqrt(E_ksi * Cw_in6 / (G_ksi * J_in4))
        L_in = 180.0
        T_kipin = 90.0

        # Section properties
        tf_in = 0.56; tw_in = 0.34; d_in = 10.0; ho_in = 9.44
        Ix_in4 = 272.0; Sx_in3 = 54.6
        Wno_in2 = 10.0 * 9.44 / 4    # = 23.6
        Sw1_in4 = 0.56 * 100 * 9.44 / 16  # = 33.04

        d_sup = torsion_case3_derivatives(0.0, L_in, T_kipin, a_in, G_ksi, J_in4)
        stresses = torsional_stresses_ksi(E_ksi, G_ksi, tf_in, tw_in, d_in, Ix_in4,
                                          Wno_in2, Sw1_in4,
                                          d_sup.θp, d_sup.θpp, d_sup.θppp;
                                          Vu_kip=7.5)

        # Pure torsional shear in flange ≈ 10 ksi
        @test stresses.τ_t_flange > 5.0
        @test stresses.τ_t_flange < 15.0

        # Warping normal stress at support should be ~0 (θ'' = 0 at support)
        @test abs(stresses.σ_w) < 0.1

        # Flexural shear stress (7.5 / (10.0 × 0.34) ≈ 2.2 ksi)
        @test stresses.τ_b_web > 0
        @test stresses.τ_b_web ≈ 2.2  atol=0.3
    end

    @testset "Torsional Stresses — W10x49 at Midspan" begin
        J_in4 = 1.39
        Cw_in6 = 2070.0
        a_in = sqrt(E_ksi * Cw_in6 / (G_ksi * J_in4))
        L_in = 180.0
        T_kipin = 90.0

        tf_in = 0.56; tw_in = 0.34; d_in = 10.0
        Ix_in4 = 272.0; Sx_in3 = 54.6
        Wno_in2 = 23.6; Sw1_in4 = 33.0

        d_mid = torsion_case3_derivatives(L_in/2, L_in, T_kipin, a_in, G_ksi, J_in4)
        stresses = torsional_stresses_ksi(E_ksi, G_ksi, tf_in, tw_in, d_in, Ix_in4,
                                          Wno_in2, Sw1_in4,
                                          d_mid.θp, d_mid.θpp, d_mid.θppp)

        # θ'(L/2) = 0 → τ_t = 0
        @test stresses.τ_t_flange ≈ 0.0  atol=0.1

        # Warping normal stress at midspan ≈ 28 ksi
        @test abs(stresses.σ_w) > 15.0
        @test abs(stresses.σ_w) < 40.0
    end

    @testset "Design Check — W10x49 Yielding (raw ksi)" begin
        Fy_ksi = 50.0

        # Simulated stresses from Example 5.1
        result = check_torsion_yielding(12.4, 28.0, 2.4, 10.0, 0.6, Fy_ksi)

        @test result.f_un ≈ 40.4  atol=0.1
        @test result.φFy ≈ 45.0   atol=0.1
        @test result.normal_ok == true
        @test result.shear_ok == true
        @test result.interaction_ratio > 0.8
    end

    @testset "Design Check — Unitful Wrapper" begin
        Fy = 50.0ksi
        result = check_torsion_yielding(
            12.4ksi, 28.0ksi, 2.4ksi, 10.0ksi, 0.6ksi, Fy)

        @test ustrip(ksi, result.f_un) ≈ 40.4  atol=0.1
        @test result.normal_ok == true
    end

    # =========================================================================
    # Full Design Function — DG9 Example 5.1
    # =========================================================================

    @testset "Full design_w_torsion — DG9 Example 5.1" begin
        sec = W("W10X49")
        L   = 15.0u"ft"
        Tu  = 90.0kip*u"inch"
        Vu  = 7.5kip
        Mu  = 675.0kip*u"inch"

        result = design_w_torsion(sec, mat, Tu, Vu, Mu, L;
                                  load_type=:concentrated_midspan)

        # Bending stress = Mu/Sx = 675/54.6 = 12.4 ksi
        @test result.σ_b_ksi ≈ 12.4  atol=0.5

        # Warping normal stress at midspan ≈ 28 ksi
        @test abs(result.σ_w_midspan_ksi) > 15.0
        @test abs(result.σ_w_midspan_ksi) < 40.0

        # Maximum combined normal stress ≈ 40.4 ksi
        @test result.f_un_midspan_ksi ≈ 40.4  atol=5.0

        # Service rotation (scale by 60/90 for service torque)
        θ_service = result.θ_max_rad * (60.0 / 90.0)
        @test θ_service ≈ 0.062  atol=0.015
    end

    # =========================================================================
    # Adversarial / Edge Cases
    # =========================================================================

    @testset "ADVERSARIAL: Very Short Span (L/a < 1)" begin
        sec = W("W10X49")
        result = design_w_torsion(sec, mat,
            30.0kip*u"inch", 5.0kip, 50.0kip*u"inch", 3.0u"ft")

        @test !isnan(result.f_un_midspan_ksi)
        @test result.θ_max_rad ≥ 0
    end

    @testset "ADVERSARIAL: Very Long Span (L/a >> 1)" begin
        sec = W("W10X49")
        result = design_w_torsion(sec, mat,
            90.0kip*u"inch", 7.5kip, 675.0kip*u"inch", 50.0u"ft")

        @test !isnan(result.σ_w_midspan_ksi)
        @test result.θ_max_rad > 0
    end

    @testset "ADVERSARIAL: Very Large Torque — Section Fails" begin
        sec = W("W10X49")
        result = design_w_torsion(sec, mat,
            500.0kip*u"inch", 7.5kip, 675.0kip*u"inch", 15.0u"ft")

        @test result.ok == false
    end

    @testset "ADVERSARIAL: Light W-shape Under Torsion" begin
        sec = W("W6X9")
        result = design_w_torsion(sec, mat,
            20.0kip*u"inch", 3.0kip, 100.0kip*u"inch", 10.0u"ft")

        @test result.f_un_midspan_ksi > 20.0
        @test result.θ_max_rad > 0.01
    end

    @testset "ADVERSARIAL: Heavy W-shape — Torsion Barely Matters" begin
        sec = W("W24X370")
        result = design_w_torsion(sec, mat,
            100.0kip*u"inch", 50.0kip, 5000.0kip*u"inch", 20.0u"ft")

        σ_w_abs = abs(result.σ_w_midspan_ksi)
        @test σ_w_abs < abs(result.σ_b_ksi)  # Torsion stress < bending stress
        @test result.ok == true
    end

    @testset "ADVERSARIAL: Zero Torque" begin
        sec = W("W10X49")
        result = design_w_torsion(sec, mat,
            0.0kip*u"inch", 7.5kip, 675.0kip*u"inch", 15.0u"ft")

        @test result.σ_w_midspan_ksi ≈ 0.0  atol=1e-10
        @test result.τ_t_support_ksi ≈ 0.0   atol=1e-10
        @test result.θ_max_rad ≈ 0.0  atol=1e-10
        @test result.ok == true
    end

    @testset "ADVERSARIAL: Symmetric Load on Deep Section" begin
        # W36x150 — very deep section, warping dominates
        sec = W("W36X150")
        result = design_w_torsion(sec, mat,
            200.0kip*u"inch", 30.0kip, 3000.0kip*u"inch", 30.0u"ft")

        @test !isnan(result.f_un_midspan_ksi)
        @test !isnan(result.f_uv_support_ksi)
    end

    @testset "MemberDemand backward compatibility" begin
        d1 = MemberDemand(1; Mux=100.0, Vu_strong=10.0)
        @test d1.Tu == 0.0

        d2 = MemberDemand(1; Mux=100.0, Vu_strong=10.0, Tu=50.0)
        @test d2.Tu == 50.0
    end
end
