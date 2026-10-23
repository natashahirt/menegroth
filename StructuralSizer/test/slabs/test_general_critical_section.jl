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

    @testset "Rectangular builders reproduce closed-form perimeters" begin
        c1 = 16.0u"inch"; c2 = 12.0u"inch"; d = 6.0u"inch"
        intr, cl = SS.rectangular_critical_section(c1, c2, d; position = :interior)
        @test cl
        @test ustrip(u"inch", SS.critical_section_properties(intr, d; closed = true).b0) ≈
              ustrip(u"inch", 2 * (c1 + d) + 2 * (c2 + d)) rtol = 1e-10

        edg, cle = SS.rectangular_critical_section(c1, c2, d; position = :edge)
        @test !cle
        @test ustrip(u"inch", SS.critical_section_properties(edg, d; closed = false).b0) ≈
              ustrip(u"inch", 2 * (c1 + d / 2) + (c2 + d)) rtol = 1e-10

        cor, clc = SS.rectangular_critical_section(c1, c2, d; position = :corner)
        @test !clc
        @test ustrip(u"inch", SS.critical_section_properties(cor, d; closed = false).b0) ≈
              ustrip(u"inch", (c1 + d / 2) + (c2 + d / 2)) rtol = 1e-10
    end

    @testset "corner_critical_section clipper: exact orthogonal reductions + skew" begin
        c1 = 16.0u"inch"; c2 = 16.0u"inch"; d = 6.0u"inch"
        n_ortho = [(-1.0, 0.0), (0.0, -1.0)]       # slab in −x,−y quadrant

        # Convex orthogonal ⇒ identical to the closed-form 2-sided corner L.
        cvx, clc = SS.corner_critical_section(c1, c2, d, :convex, n_ortho)
        @test !clc
        pc = SS.critical_section_properties(cvx, d; closed = false)
        ref, _ = SS.rectangular_critical_section(c1, c2, d; position = :corner)
        pr = SS.critical_section_properties(ref, d; closed = false)
        @test ustrip(u"inch", pc.b0) ≈ ustrip(u"inch", pr.b0) rtol = 1e-10
        @test ustrip(u"inch", pc.b0) ≈ ustrip(u"inch", (c1 + d / 2) + (c2 + d / 2)) rtol = 1e-10

        # Re-entrant orthogonal ⇒ open loop, b0 = 2(c1+c2)+3d (notch edges dropped).
        rez, clr = SS.corner_critical_section(c1, c2, d, :reentrant, n_ortho)
        @test !clr
        pre = SS.critical_section_properties(rez, d; closed = false)
        @test ustrip(u"inch", pre.b0) ≈ ustrip(u"inch", 2 * (c1 + c2) + 3 * d) rtol = 1e-10
        # … exactly d less than the full 4-sided interior loop.
        @test ustrip(u"inch", pre.b0) ≈
              ustrip(u"inch", 2 * (c1 + d) + 2 * (c2 + d) - d) rtol = 1e-10

        # Non-orthogonal convex wedge (60°): open, rotated principal axis, legs
        # longer than the orthogonal idealization.
        n_wedge = [(-sin(deg2rad(30)), -cos(deg2rad(30))),
                   ( sin(deg2rad(30)), -cos(deg2rad(30)))]
        wdg, clw = SS.corner_critical_section(c1, c2, d, :convex, n_wedge)
        @test !clw
        pw = SS.critical_section_properties(wdg, d; closed = false)
        @test ustrip(u"inch", pw.b0) > ustrip(u"inch", (c1 + d / 2) + (c2 + d / 2))
        @test abs(pw.θp) > 1e-3                      # principal axes rotate off x/y

        # Bad inputs are rejected.
        @test_throws ArgumentError SS.corner_critical_section(c1, c2, d, :convex, n_ortho[1:1])
        @test_throws ArgumentError SS.corner_critical_section(c1, c2, d, :weird, n_ortho)
    end

    @testset "Re-entrant corner resists the offset loop minus the notch edges" begin
        # Square re-entrant: symmetric about the notch diagonal ⇒ not flagged.
        c = 14.0u"inch"; d = 7.0u"inch"
        pts, cl = SS.reentrant_critical_section(c, c, d; notch = (1, 1))
        @test !cl                                    # open: terminates at free edges
        p = SS.critical_section_properties(pts, d; closed = false)
        # b0 = 2(c1+c2)+3d — full offset loop minus the two non-resisting d/2
        # notch edges (which lie along the free edges).
        @test ustrip(u"inch", p.b0) ≈ ustrip(u"inch", 2 * (c + c) + 3 * d) rtol = 1e-10
        @test SS.punching_check_general(40.0kip, 20.0kip * u"ft", 20.0kip * u"ft",
                                        d, 4000.0u"psi", pts; closed = false).asymmetric == false

        # Unequal legs: no principal axis of symmetry ⇒ asymmetric flag set.
        pts2, _ = SS.reentrant_critical_section(16.0u"inch", 10.0u"inch", d; notch = (1, 1))
        res2 = SS.punching_check_general(40.0kip, 20.0kip * u"ft", 20.0kip * u"ft",
                                         d, 4000.0u"psi", pts2; closed = false)
        @test res2.asymmetric == true
        @test ustrip(u"inch", res2.b0) ≈
              ustrip(u"inch", 2 * (16.0u"inch" + 10.0u"inch") + 3 * d) rtol = 1e-10
    end

    @testset "Moment convention locked against closed-form punching_check" begin
        # punching_check names moments by stress-direction (`Mux` ⇒ stress in x);
        # the general engine follows 421.1R (`Mux` about x ⇒ stress in y). The
        # bridge is therefore a swap. Lock it: with an aspect ratio ≠ 1 the two
        # orientations give clearly different vu, so a wrong mapping cannot pass.
        # Aspect ratio 4:1 maximizes the x-vs-y separation (~8%), which exceeds the
        # small App. B J≈I gap (~2–3%) so the mapping is observable. (The direct
        # Vu/Ac term is identical across all four quantities, so it cancels in every
        # difference below — the lock is load-independent.)
        c1 = 32.0u"inch"; c2 = 8.0u"inch"; d = 8.0u"inch"; fc = 4000.0u"psi"
        Vu = 8.0kip; M = 180.0kip * u"ft"
        pts, _ = SS.rectangular_critical_section(c1, c2, d; position = :interior)

        # Two closed-form oracles: moment driving stress in x vs in y.
        cf_x = SS.punching_check(Vu, M, 0.0kip * u"ft", d, fc, c1, c2; position = :interior)
        cf_y = SS.punching_check(Vu, 0.0kip * u"ft", M, d, fc, c1, c2; position = :interior)
        vx = ustrip(u"psi", cf_x.vu); vy = ustrip(u"psi", cf_y.vu)

        # The general engine (421.1R convention): Muy ⇒ stress in x, Mux ⇒ stress in y.
        g_as_Muy = SS.punching_stress_general(Vu, 0.0kip * u"ft", M, pts, d; closed = true)  # ≡ cf_x
        g_as_Mux = SS.punching_stress_general(Vu, M, 0.0kip * u"ft", pts, d; closed = true)  # ≡ cf_y

        # The two orientations genuinely differ (so "nearer-oracle" discriminates).
        @test abs(vx - vy) / vx > 0.05
        gy = ustrip(u"psi", g_as_Muy.vu)   # Muy ⇒ stress in x ⇒ should track cf_x
        gx = ustrip(u"psi", g_as_Mux.vu)   # Mux ⇒ stress in y ⇒ should track cf_y
        # App. B is slightly conservative vs the closed form (J≈I gap, same sign on both axes).
        @test 0.98 ≤ gy / vx ≤ 1.08
        @test 0.98 ≤ gx / vy ≤ 1.08
        # Convention lock: each mapping is nearer its MATCHING oracle than the other.
        # A swapped mapping would flip both of these, so it cannot pass.
        @test abs(gy - vx) < abs(gy - vy)
        @test abs(gx - vy) < abs(gx - vx)
    end

    @testset "Invariant: notching a corner can only raise stress; far below 2-sided" begin
        c1 = 16.0u"inch"; c2 = 16.0u"inch"; d = 6.0u"inch"; fc = 4000.0u"psi"
        Vu = 40.0kip; Mx = 20.0kip * u"ft"; My = 12.0kip * u"ft"
        pts_int, _ = SS.rectangular_critical_section(c1, c2, d; position = :interior)
        pts_re,  _ = SS.reentrant_critical_section(c1, c2, d)

        g_int = SS.punching_check_general(Vu, Mx, My, d, fc, pts_int; closed = true)
        g_re  = SS.punching_check_general(Vu, Mx, My, d, fc, pts_re;  closed = false)
        # The notch drops the two d/2 free-edge segments (b0 smaller by exactly d)
        # and offsets the centroid ⇒ stress can only rise vs the full interior loop.
        @test g_re.vu ≥ g_int.vu
        @test ustrip(u"inch", g_re.b0) ≈ ustrip(u"inch", g_int.b0 - d) rtol = 1e-9

        # … yet far below the legacy 2-sided corner idealization (half the b0).
        cx = (position = :corner, corner_kind = :convex, c1 = c1, c2 = c2, shape = :rectangular)
        r_cx = SS.check_punching_for_column(cx, Vu, Mx, d, 8.0u"inch", fc; Muy = My)
        @test g_re.vu < r_cx.vu
    end

    @testset "Invariant: centroid-transfer is the pinned R11.11.7.2 reduction" begin
        # Production references Mu to the section centroidal axis per ACI 318-11
        # R11.11.7.2: M_cc = |M| − Vu·e (reduction), the same convention worked in
        # the PCA/ACI example and validated against spSlab for orthogonal
        # edge/corner columns — inherited here via the true offset (xc, yc).
        c1 = 16.0u"inch"; c2 = 16.0u"inch"; d = 6.0u"inch"; fc = 4000.0u"psi"
        Vu = 40.0kip; Mub = 20.0kip * u"ft"; Muy_val = 12.0kip * u"ft"
        pts, _ = SS.reentrant_critical_section(c1, c2, d)
        p = SS.critical_section_properties(pts, d; closed = false)

        vu_of(sgn) = ustrip(u"psi", SS.punching_check_general(
            Vu,
            max(0.0kip * u"ft", abs(Muy_val) + sgn * Vu * abs(p.yc)),
            max(0.0kip * u"ft", abs(Mub)     + sgn * Vu * abs(p.xc)),
            d, fc, pts; closed = false).vu)

        v_sub = vu_of(-1.0); v_zero = vu_of(0.0); v_add = vu_of(+1.0)  # −1 ≡ production
        @test v_sub ≤ v_zero ≤ v_add                 # monotone in the transfer sign
        @test (v_add - v_sub) / v_zero < 0.12        # full ± swing bounded (~10%)

        # The routed corner uses the reduction branch ⇒ its demand matches v_sub.
        re_col = (position = :corner, corner_kind = :reentrant, corner_angle = 3π / 2,
                  c1 = c1, c2 = c2, shape = :rectangular,
                  boundary_inward_normals = [(-1.0, 0.0), (0.0, -1.0)])
        r = SS.check_punching_for_column(re_col, Vu, Mub, d, 8.0u"inch", fc; Muy = Muy_val)
        @test ustrip(u"psi", r.vu) ≈ v_sub rtol = 1e-9
    end

    @testset "check_punching_for_column routes re-entrant corners to App. B" begin
        c1 = 16.0u"inch"; c2 = 16.0u"inch"; d = 6.0u"inch"; h = 8.0u"inch"
        fc = 4000.0u"psi"
        Vu = 40.0kip; Mub = 25.0kip * u"ft"; Muy = 15.0kip * u"ft"

        # Orthogonal re-entrant (slab angle 3π/2) routes to the general engine.
        # Routing requires the two free-edge inward normals (void in +x,+y ⇒
        # inward normals −x and −y).
        re_col = (position = :corner, corner_kind = :reentrant, corner_angle = 3π / 2,
                  c1 = c1, c2 = c2, shape = :rectangular,
                  boundary_inward_normals = [(-1.0, 0.0), (0.0, -1.0)])
        cx_col = (position = :corner, corner_kind = :convex, corner_angle = π / 2,
                  c1 = c1, c2 = c2, shape = :rectangular,
                  boundary_inward_normals = [(-1.0, 0.0), (0.0, -1.0)])

        r_re = SS.check_punching_for_column(re_col, Vu, Mub, d, h, fc; Muy = Muy)
        r_cx = SS.check_punching_for_column(cx_col, Vu, Mub, d, h, fc; Muy = Muy)

        # Re-entrant resists the offset loop minus the notch edges (2(c1+c2)+3d);
        # orthogonal convex keeps the validated closed-form 2-sided section.
        @test ustrip(u"inch", r_re.b0) ≈ ustrip(u"inch", 2 * (c1 + c2) + 3 * d) rtol = 1e-9
        @test ustrip(u"inch", r_cx.b0) ≈ ustrip(u"inch", (c1 + d / 2) + (c2 + d / 2)) rtol = 1e-9
        # Larger perimeter ⇒ the re-entrant demand is well below the 2-sided result.
        @test r_re.vu < r_cx.vu
        @test r_re.ok isa Bool
        @test r_re.ratio > 0
    end

    @testset "Routing needs inward normals; skewed corners use the clipper" begin
        c1 = 16.0u"inch"; c2 = 16.0u"inch"; d = 6.0u"inch"; h = 8.0u"inch"
        fc = 4000.0u"psi"; Vu = 40.0kip; Mub = 25.0kip * u"ft"; Muy = 15.0kip * u"ft"
        two_sided = (c1 + d / 2) + (c2 + d / 2)

        # (1) A corner lacking inward normals (e.g. a bare stub) cannot be clipped
        #     ⇒ conservative 2-sided closed-form fallback (over-predicts — safe).
        bare = (position = :corner, corner_kind = :reentrant,
                c1 = c1, c2 = c2, shape = :rectangular)
        r_bare = SS.check_punching_for_column(bare, Vu, Mub, d, h, fc; Muy = Muy)
        @test ustrip(u"inch", r_bare.b0) ≈ ustrip(u"inch", two_sided) rtol = 1e-9

        # (2) A SKEWED re-entrant corner (slab angle ≠ 3π/2) now routes through the
        #     general clipper — no orthogonality restriction — and resists far more
        #     perimeter than the 2-sided fallback.
        n_skew = [(-1.0, 0.0), (sin(deg2rad(30)), -cos(deg2rad(30)))]
        skew = (position = :corner, corner_kind = :reentrant, corner_angle = deg2rad(225),
                c1 = c1, c2 = c2, shape = :rectangular, boundary_inward_normals = n_skew)
        r_skew = SS.check_punching_for_column(skew, Vu, Mub, d, h, fc; Muy = Muy)
        @test ustrip(u"inch", r_skew.b0) > ustrip(u"inch", two_sided)

        # (3) A non-orthogonal CONVEX wedge (60°) also routes; its clipped 2-sided
        #     legs exceed the orthogonal idealization.
        n_wedge = [(-sin(deg2rad(30)), -cos(deg2rad(30))),
                   ( sin(deg2rad(30)), -cos(deg2rad(30)))]
        wedge = (position = :corner, corner_kind = :convex, corner_angle = deg2rad(60),
                 c1 = c1, c2 = c2, shape = :rectangular, boundary_inward_normals = n_wedge)
        r_wedge = SS.check_punching_for_column(wedge, Vu, Mub, d, h, fc; Muy = Muy)
        @test ustrip(u"inch", r_wedge.b0) > ustrip(u"inch", two_sided)
        @test r_wedge.ok isa Bool
    end

    @testset "Symmetry detection and punching_check_general result" begin
        c1 = 16.0u"inch"; c2 = 12.0u"inch"; d = 6.0u"inch"
        rect, _ = SS.rectangular_critical_section(c1, c2, d; position = :interior)
        pr = SS.critical_section_properties(rect, d; closed = true)
        s1, s2 = SS.section_symmetry(rect, pr)
        @test s1 && s2

        # Scalene triangle — no axis of symmetry.
        tri = [(0.0u"inch", 0.0u"inch"), (13.0u"inch", 1.0u"inch"), (3.0u"inch", 9.0u"inch")]
        pt = SS.critical_section_properties(tri, d; closed = true)
        ts1, ts2 = SS.section_symmetry(tri, pt)
        @test !(ts1 || ts2)

        res = SS.punching_check_general(45.0kip, 25.0kip * u"ft", 15.0kip * u"ft",
                                        d, 4000.0u"psi", rect; closed = true, β = 16 / 12, αs = 40)
        @test res.ok isa Bool
        @test res.utilization > 0
        @test ustrip(u"psi", res.vu) > 0
        @test ustrip(u"psi", res.ϕvc) > 0
    end

end
