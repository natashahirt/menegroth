# =============================================================================
# Corner-column punching with unbalanced moment — hand-calc oracle
# =============================================================================
#
# ACI 318-11 §11.11.7.1 / §11.11.7.2 (corpus: aci-318-11, pages 209–211)
# transfer γv Mu by eccentricity of shear at every slab-column connection,
# including two-sided (corner) sections.  Critical-section properties:
#
#   b1 = c1 + d/2,  b2 = c2 + d/2                         (§11.11.1.2, p.200)
#   c  = b1² / [2(b1 + b2)]                               (PCA Case D)
#   J/c = [b1² d (b1 + 4 b2) + d³ (b1 + b2)] / (6 b1)     (PCA Case D)
#   Jc  = (J/c) · c
#   γf  = 1 / (1 + (2/3)√(b1/b2))                         Eq. (13-1), p.250
#   γv  = 1 − γf                                          Eq. (11-37), p.210
#   vu  = Vu/(b0 d) + γv Mux,adj c_x / Jc_x
#                       + γv Muy,adj c_y / Jc_y           R11.11.7.2
#
# PCA EB712 Fig. 16-13 Case D (corpus: pca-eb712, page 486).
# Used by mat / strip footing `punching_check`.
# =============================================================================

using Test
using Unitful
using Asap
using StructuralSizer

const SS = StructuralSizer

@testset "Corner punching with moment — PCA Case D oracle" begin
    c1 = 16.0u"inch"
    c2 = 14.0u"inch"
    d  = 5.75u"inch"
    fc = 4000.0u"psi"
    Vu = 40.0kip
    Mux = 30.0kip * u"ft"
    Muy = 18.0kip * u"ft"

    b1 = c1 + d / 2
    b2 = c2 + d / 2
    b0 = b1 + b2
    cAB_x = b1^2 / (2 * (b1 + b2))
    cAB_y = b2^2 / (2 * (b1 + b2))

    J_over_c_x = (b1^2 * d * (b1 + 4 * b2) + d^3 * (b1 + b2)) / (6 * b1)
    J_over_c_y = (b2^2 * d * (b2 + 4 * b1) + d^3 * (b2 + b1)) / (6 * b2)
    Jc_x = J_over_c_x * cAB_x
    Jc_y = J_over_c_y * cAB_y

    γv_x = 1.0 - 1.0 / (1.0 + (2.0 / 3.0) * sqrt(b1 / b2))
    γv_y = 1.0 - 1.0 / (1.0 + (2.0 / 3.0) * sqrt(b2 / b1))

    e_x = c1 / 2 - cAB_x
    e_y = c2 / 2 - cAB_y
    Mux_adj = max(abs(Mux) - Vu * e_x, zero(Mux))
    Muy_adj = max(abs(Muy) - Vu * e_y, zero(Muy))

    v_direct = uconvert(u"psi", Vu / (b0 * d))
    v_Mux = uconvert(u"psi", γv_x * Mux_adj * cAB_x / Jc_x)
    v_Muy = uconvert(u"psi", γv_y * Muy_adj * cAB_y / Jc_y)
    vu_oracle = v_direct + v_Mux + v_Muy

    @testset "geometry + Jc helpers" begin
        geom = SS.punching_geometry_corner(c1, c2, d)
        @test ustrip(u"inch", geom.b1) ≈ ustrip(u"inch", b1) rtol=1e-12
        @test ustrip(u"inch", geom.b2) ≈ ustrip(u"inch", b2) rtol=1e-12
        @test ustrip(u"inch", geom.b0) ≈ ustrip(u"inch", b0) rtol=1e-12
        @test ustrip(u"inch", geom.cAB_x) ≈ ustrip(u"inch", cAB_x) rtol=1e-12
        @test ustrip(u"inch", geom.cAB_y) ≈ ustrip(u"inch", cAB_y) rtol=1e-12

        @test ustrip(u"inch^3", SS.polar_modulus_Jc_over_c_corner(b1, b2, d)) ≈
              ustrip(u"inch^3", J_over_c_x) rtol=1e-12
        @test ustrip(u"inch^4", SS.polar_moment_Jc_corner(b1, b2, d, cAB_x)) ≈
              ustrip(u"inch^4", Jc_x) rtol=1e-12
    end

    @testset "punching_check matches oracle (biaxial)" begin
        r = SS.punching_check(Vu, Mux, Muy, d, fc, c1, c2; position = :corner)
        @test ustrip(u"psi", r.vu) ≈ ustrip(u"psi", vu_oracle) rtol=1e-9
        @test ustrip(u"psi", r.vu) > ustrip(u"psi", v_direct)
    end

    @testset "concentric corner is v_direct only" begin
        r0 = SS.punching_check(Vu, 0.0kip * u"ft", 0.0kip * u"ft", d, fc, c1, c2;
                                position = :corner)
        @test ustrip(u"psi", r0.vu) ≈ ustrip(u"psi", v_direct) rtol=1e-9
    end

    @testset "each axis contributes" begin
        rx = SS.punching_check(Vu, Mux, 0.0kip * u"ft", d, fc, c1, c2; position = :corner)
        ry = SS.punching_check(Vu, 0.0kip * u"ft", Muy, d, fc, c1, c2; position = :corner)
        rxy = SS.punching_check(Vu, Mux, Muy, d, fc, c1, c2; position = :corner)
        @test ustrip(u"psi", rxy.vu) ≈
              ustrip(u"psi", rx.vu) + ustrip(u"psi", ry.vu) - ustrip(u"psi", v_direct) rtol=1e-9
    end
end
