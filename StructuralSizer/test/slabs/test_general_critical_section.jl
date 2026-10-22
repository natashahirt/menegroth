# =============================================================================
# General-shape punching critical sections — ACI 421.1R-99 Appendix B
# =============================================================================
#
# Validates the segment-summation critical-section engine
# (`critical_section_properties` / `punching_stress_general`) that generalizes
# punching to non-orthogonal, re-entrant, circular, and I-/odd-shaped supports
# via the true principal axes.
#
# Hand-calc oracles (corpus: aci-421-1r-99, Appendix B, p. 421.1R-11):
#   Ac = d·Σl                                               (B-1)
#   Ix = Σ (d·l/3)(yi² + yi·yj + yj²)                        (B-2)
#   Iy = Σ (d·l/3)(xi² + xi·xj + xj²)                        (B-3)
#   Jx ≈ Ix, Jy ≈ Iy on the principal axes.
#
# Test shapes with closed-form App. B values:
#   • Axis-aligned rectangle (b1×b2): Ix = d(b1·b2²/2 + b2³/6),
#       Iy = d(b2·b1²/2 + b1³/6), Ixy = 0.
#   • Rotated rectangle: same vu as unrotated (principal-axis invariance).
#   • Symmetric V-wedge (half-angle α, leg L, open): b0 = 2L, x̄ = L·cosα/2,
#       Ix = d·2L³·sin²α/3, Iy = d·L³·cos²α/6, Ixy = 0.
#   • Circular ring (diam D+d): b0 → π(D+d), J1 = J2 → d·π·r³, Ixy = 0.
# =============================================================================

using Test
using Unitful
using Asap
using StructuralSizer

const SS = StructuralSizer

@testset "General-shape critical sections (ACI 421.1R-99 App. B)" begin

    @testset "Axis-aligned rectangle reduces to App. B closed form" begin
        b1 = 20.0u"inch"   # x-dimension
        b2 = 14.0u"inch"   # y-dimension
        d  = 8.0u"inch"
        pts = [( b1 / 2,  b2 / 2), (-b1 / 2,  b2 / 2),
               (-b1 / 2, -b2 / 2), ( b1 / 2, -b2 / 2)]
        p = SS.critical_section_properties(pts, d; closed = true)

        @test ustrip(u"inch",   p.b0) ≈ 2 * ustrip(u"inch", b1 + b2)          rtol = 1e-10
        @test ustrip(u"inch^2", p.Ac) ≈ ustrip(u"inch", d) * 2 * ustrip(u"inch", b1 + b2) rtol = 1e-10
        @test ustrip(u"inch",   p.xc) ≈ 0 atol = 1e-9
        @test ustrip(u"inch",   p.yc) ≈ 0 atol = 1e-9
        @test ustrip(u"inch^4", p.Ixy) ≈ 0 atol = 1e-6
        @test p.θp ≈ 0 atol = 1e-9

        dd  = ustrip(u"inch", d)
        B1  = ustrip(u"inch", b1)
        B2  = ustrip(u"inch", b2)
        Ix  = dd * (B1 * B2^2 / 2 + B2^3 / 6)   # ∫y² → J1 (about x)
        Iy  = dd * (B2 * B1^2 / 2 + B1^3 / 6)   # ∫x² → J2 (about y)
        @test ustrip(u"inch^4", p.J1) ≈ Ix rtol = 1e-10
        @test ustrip(u"inch^4", p.J2) ≈ Iy rtol = 1e-10
        @test ustrip(u"inch", p.l1) ≈ B1 rtol = 1e-10
        @test ustrip(u"inch", p.l2) ≈ B2 rtol = 1e-10
    end

    @testset "Rotated rectangle — principal-axis invariance of vu" begin
        b1 = 20.0u"inch"; b2 = 14.0u"inch"; d = 8.0u"inch"
        Vu = 50.0kip
        Mux = 30.0kip * u"ft"
        Muy = 20.0kip * u"ft"
        pts = [( b1 / 2,  b2 / 2), (-b1 / 2,  b2 / 2),
               (-b1 / 2, -b2 / 2), ( b1 / 2, -b2 / 2)]
        base = SS.punching_stress_general(Vu, Mux, Muy, pts, d; closed = true)

        β = deg2rad(30.0)
        cβ = cos(β); sβ = sin(β)
        pts_r = [(x * cβ - y * sβ, x * sβ + y * cβ) for (x, y) in pts]
        # Rotate the moment vector by the same rigid rotation.
        Mux_r = Mux * cβ - Muy * sβ
        Muy_r = Mux * sβ + Muy * cβ
        rot = SS.punching_stress_general(Vu, Mux_r, Muy_r, pts_r, d; closed = true)

        @test ustrip(u"psi", rot.vu) ≈ ustrip(u"psi", base.vu) rtol = 1e-8
        @test ustrip(u"inch^4", rot.J1) ≈ ustrip(u"inch^4", base.J1) rtol = 1e-8
        @test ustrip(u"inch^4", rot.J2) ≈ ustrip(u"inch^4", base.J2) rtol = 1e-8
    end

    @testset "Symmetric 60° V-wedge (non-orthogonal, open polyline)" begin
        L = 10.0u"inch"
        d = 8.0u"inch"
        α = deg2rad(30.0)          # half-angle ⇒ 60° opening
        pts = [(L * cos(α),  L * sin(α)), (0.0u"inch", 0.0u"inch"),
               (L * cos(α), -L * sin(α))]
        p = SS.critical_section_properties(pts, d; closed = false)

        LL = ustrip(u"inch", L); dd = ustrip(u"inch", d)
        @test ustrip(u"inch",   p.b0) ≈ 2 * LL rtol = 1e-10
        @test ustrip(u"inch^2", p.Ac) ≈ dd * 2 * LL rtol = 1e-10
        @test ustrip(u"inch",   p.xc) ≈ LL * cos(α) / 2 rtol = 1e-10
        @test ustrip(u"inch",   p.yc) ≈ 0 atol = 1e-9
        @test ustrip(u"inch^4", p.Ixy) ≈ 0 atol = 1e-6
        @test ustrip(u"inch^4", p.J1) ≈ dd * 2 * LL^3 * sin(α)^2 / 3 rtol = 1e-10  # about x
        @test ustrip(u"inch^4", p.J2) ≈ dd * LL^3 * cos(α)^2 / 6 rtol = 1e-10      # about y
    end

    @testset "Circular ring converges to analytic d·π·r³" begin
        D = 18.0u"inch"
        d = 8.0u"inch"
        pts = SS.circular_critical_section(D, d; n = 256)
        p = SS.critical_section_properties(pts, d; closed = true)

        r  = ustrip(u"inch", (D + d) / 2)
        dd = ustrip(u"inch", d)
        @test ustrip(u"inch",   p.b0) ≈ π * ustrip(u"inch", D + d) rtol = 1e-3
        @test ustrip(u"inch^4", p.J1) ≈ dd * π * r^3 rtol = 2e-3
        @test ustrip(u"inch^4", p.J1) ≈ ustrip(u"inch^4", p.J2) rtol = 1e-6
        @test ustrip(u"inch^4", p.Ixy) ≈ 0 atol = 1e-3
    end

end
