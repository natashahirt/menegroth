# =============================================================================
# ASCE 7-22 Chapter 27 Directional Procedure — hand checks
# =============================================================================
# Every case below is a HAND CHECK from Figure 27.3-1, Eq. 27.3-1, and
# Figure 27.3-8. None of these cases is a published example.
#
# Cp, from Figure 27.3-1 (PDF page 345): windward 0.8, side -0.7,
# leeward -0.5 for L/B ≤ 1, -0.3 at L/B = 2, -0.2 for L/B ≥ 4.
# Note 2 interpolates linearly between the leeward values.

using Test
using StructuralSizer

const _ATOL = 1e-9

# 10 × 10 square, open ring, counterclockwise. L/B = 1 for an axis wind.
const _SQ = [(0.0, 0.0), (10.0, 0.0), (10.0, 10.0), (0.0, 10.0)]

function _wall(loops, direction; qz=10.0, qh=20.0, Kd=1.0, G=1.0, GCpi=0.0,
               height=1.0, qi=nothing, flexible=false, gust=nothing)
    return wind_wall_resultant(loops, direction; qz, qh, Kd, G, GCpi, height, qi,
                               flexible, gust)
end

@testset "ASCE 7-22 Chapter 27 MWFRS wind" begin

    @testset "wall Cp and Eq. 27.3-1" begin
        # Figure 27.3-1 wall table. Not interpolated.
        @test wind_wall_cp(0.5, :windward) == 0.8
        @test wind_wall_cp(3.0, :windward) == 0.8
        @test wind_wall_cp(0.5, :side) == -0.7
        @test wind_wall_cp(0.5, :leeward) == -0.5
        @test wind_wall_cp(1.0, :leeward) == -0.5
        @test wind_wall_cp(2.0, :leeward) == -0.3
        @test wind_wall_cp(4.0, :leeward) == -0.2
        @test wind_wall_cp(5.0, :leeward) == -0.2
        # Note 2, between the tabulated leeward values, same sign.
        # L/B = 1.5 is halfway from -0.5 to -0.3 → -0.4.
        # L/B = 3 is halfway from -0.3 (L/B = 2) to -0.2 (L/B = 4) → -0.25.
        @test wind_wall_cp(1.5, :leeward) ≈ -0.4 atol=_ATOL
        @test wind_wall_cp(3.0, :leeward) ≈ -0.25 atol=_ATOL
        @test_throws ArgumentError wind_wall_cp(0.0, :leeward)
        @test_throws ArgumentError wind_wall_cp(-1.0, :windward)
        @test_throws ArgumentError wind_wall_cp(1.0, :roof)

        # HAND CHECK, Eq. 27.3-1. p = 10*1*1*0.8 - 4*1*0.5 = 6.
        @test wind_design_pressure(; q=10.0, qi=4.0, Kd=1.0, G=1.0, Cp=0.8, GCpi=0.5) ≈ 6.0 atol=_ATOL
        @test_throws ArgumentError wind_design_pressure(; q=-1.0, qi=0.0, Kd=1.0, G=1.0, Cp=0.8, GCpi=0.0)

        # An edge at 45° to the wind is not a side wall. |n̂·d̂| = √2/2.
        @test wind_surface((1.0, -1.0), (1.0, 0.0)) === :leeward
        @test wind_surface((0.0, -1.0), (1.0, 1.0)) === :windward
        # A horizontal edge in a +X wind is parallel to the wind.
        @test wind_surface((0.0, -1.0), (1.0, 0.0)) === :side

        @test wind_figure_2731_roof(:flat) === :flat
        @test wind_figure_2731_roof(:mansard) === :mansard
        @test_throws ArgumentError wind_figure_2731_roof(:dome)
        @test_throws ArgumentError wind_figure_2731_roof(:arch)

        # §27.1.5. 0.77*10 + 0.38*4 = 9.22. 16*10 + 8*4 = 192.
        @test wind_minimum_horizontal_force(10.0, 4.0; system=:kN_m2) ≈ 9.22 atol=_ATOL
        @test wind_minimum_horizontal_force(10.0, 4.0; system=:psf) ≈ 192.0 atol=_ATOL
        @test_throws ArgumentError wind_minimum_horizontal_force(1.0, 0.0; system=:ksi)
        # Force through a center 2 length-units off the centroid, wind toward +Y.
        # F = 0.77*10 = 7.7. Mz = 2 * 7.7 = 15.4.
        mini = wind_minimum_resultant(10.0, 0.0, (0.0, 1.0), (0.0, 0.0), (2.0, 0.0); system=:kN_m2)
        @test mini.Fx ≈ 0.0 atol=_ATOL
        @test mini.Fy ≈ 7.7 atol=_ATOL
        @test mini.Mz ≈ 15.4 atol=_ATOL
        @test wind_rigid_eccentricity(10.0) ≈ 1.5 atol=_ATOL
    end

    @testset "rectangle along +X" begin
        # HAND CHECK. Square 10 × 10, height 1. qz = 10, qh = 20, Kd = G = 1,
        # (GCpi) = 0. L/B = 1, so leeward Cp = -0.5.
        # Windward: p = 10*0.8 = 8, A = 10, force = 80 in +X.
        # Leeward:  p = 20*(-0.5) = -10, A = 10, force = 100 in +X.
        # Sides cancel. Net Fx = 180, Fy = 0, no shape torsion.
        r = _wall(_SQ, (1.0, 0.0))
        @test r.L ≈ 10.0 atol=_ATOL
        @test r.B ≈ 10.0 atol=_ATOL
        @test r.Cp_leeward == -0.5
        @test r.Fx ≈ 180.0 atol=_ATOL
        @test r.Fy ≈ 0.0 atol=_ATOL
        @test r.Mz ≈ 0.0 atol=_ATOL
        @test r.Fx > 0

        # Same square, wind toward -X. Opposite faces are equal, so the
        # resultant reverses. Wind coming from +X is direction (-1, 0).
        back = _wall(_SQ, (-1.0, 0.0))
        @test back.Fx ≈ -180.0 atol=_ATOL
        @test back.Fy ≈ 0.0 atol=_ATOL
        @test back.Mz ≈ 0.0 atol=_ATOL

        # L/B = 3 uses the interpolated leeward Cp = -0.25, not a tabulated row.
        # Depth 30, width 10. Windward force 80. Leeward p = 20*(-0.25) = -5,
        # force 50. Net Fx = 130.
        deep = [(0.0, 0.0), (30.0, 0.0), (30.0, 10.0), (0.0, 10.0)]
        rd = _wall(deep, (1.0, 0.0))
        @test rd.L_over_B ≈ 3.0 atol=_ATOL
        @test rd.Cp_leeward ≈ -0.25 atol=_ATOL
        @test rd.Fx ≈ 130.0 atol=_ATOL
        @test rd.Fy ≈ 0.0 atol=_ATOL
        @test rd.Mz ≈ 0.0 atol=_ATOL

        # A repeated closing vertex is not an extra edge.
        closed = [(0.0, 0.0), (10.0, 0.0), (10.0, 10.0), (0.0, 10.0), (0.0, 0.0)]
        @test _wall(closed, (1.0, 0.0)).Fx ≈ r.Fx atol=_ATOL
        @test_throws ArgumentError _wall([(0.0, 0.0), (1.0, 0.0), (2.0, 0.0)], (1.0, 0.0))
        @test_throws ArgumentError _wall(_SQ, (0.0, 0.0))
        @test_throws ArgumentError _wall(_SQ, (1.0, 0.0); flexible=true)
        @test_throws ArgumentError _wall(_SQ, (1.0, 0.0); flexible=true,
                                         gust=(eR=1.0, Iz=0.2, gQ=3.4, Q=0.8, gR=3.8))
    end

    @testset "Eq. 27.3-4" begin
        # HAND CHECK. The square-root term does not change sign, so −e_Q is
        # not the negative of +e_Q.
        # e_Q = 4.5, e_R = 1, I_z = 0.2, g_Q = 3.4, Q = 0.8, g_R = 3.8, R = 0.3.
        # √((3.4·0.8·4.5)^2 + (3.8·0.3·1)^2) = √(12.24^2 + 1.14^2)
        # √((3.4·0.8)^2 + (3.8·0.3)^2) = √(2.72^2 + 1.14^2)
        eQ, eR = 4.5, 1.0
        Iz, gQ, Q, gR, R = 0.2, 3.4, 0.8, 3.8, 0.3
        root_den = sqrt((gQ * Q)^2 + (gR * R)^2)
        den = 1 + 1.7 * Iz * root_den
        plus = (eQ + 1.7 * Iz * sqrt((gQ * Q * eQ)^2 + (gR * R * eR)^2)) / den
        minus = (-eQ + 1.7 * Iz * sqrt((gQ * Q * -eQ)^2 + (gR * R * eR)^2)) / den
        kw = (; Iz, gQ, Q, gR, R)
        @test wind_flexible_eccentricity(eQ, eR; kw...) ≈ plus atol=_ATOL
        @test wind_flexible_eccentricity(-eQ, eR; kw...) ≈ minus atol=_ATOL
        @test minus ≉ -plus

        # Case 2 on the 10 × 10 square. Along-wind shear is 180, so 75% is
        # 135. B = 10 and e_Q = ±1.5. The shape moment is 0.
        gust = (eR=eR, Iz=Iz, gQ=gQ, Q=Q, gR=gR, R=R)
        fx = _wall(_SQ, (1.0, 0.0); flexible=true, gust)
        fy = _wall(_SQ, (0.0, 1.0); flexible=true, gust)
        cases = wind_cases_from_resultants(fx, fy)
        cplus = only(c for c in cases if c.kind === :case2 && c.sign_1 == 1 && c.direction == (1.0, 0.0))
        cminus = only(c for c in cases if c.kind === :case2 && c.sign_1 == -1 && c.direction == (1.0, 0.0))
        e_plus = wind_flexible_eccentricity(0.15 * 10, eR; kw...)
        e_minus = wind_flexible_eccentricity(-0.15 * 10, eR; kw...)
        @test cplus.Mz ≈ 135.0 * e_plus atol=_ATOL
        @test cminus.Mz ≈ 135.0 * e_minus atol=_ATOL
        @test cplus.Mz ≉ -cminus.Mz
    end

    @testset "oblique wind and a non-rectangular plan" begin
        # HAND CHECK. Same square, direction (1, 1). Two windward edges and
        # two leeward edges. Each windward force is 80 and each leeward force
        # is 100, so the resultant is (180, 180). L/B stays 1.
        diag = _wall(_SQ, (1.0, 1.0))
        @test diag.Fx ≈ 180.0 atol=_ATOL
        @test diag.Fy ≈ 180.0 atol=_ATOL
        @test diag.Fx ≈ diag.Fy atol=_ATOL
        @test diag.Mz ≈ 0.0 atol=_ATOL
        @test diag.L_over_B ≈ 1.0 atol=_ATOL

        # HAND CHECK. Right triangle (0,0)-(10,0)-(0,10), wind toward +X.
        # Windward vertical edge: force (80, 0).
        # Leeward diagonal, length 10√2, Cp = -0.5, p = -10:
        #   force = 100 in the direction of the outward normal (1, 1)/√2,
        #   which is (100, 100).
        # Side edge on the X axis: p = 20*(-0.7) = -14, outward normal (0, -1),
        #   force (0, -140).
        # Net (180, -40), which is not parallel to +X.
        # Centroid (10/3, 10/3). Mz = -1100/3.
        tri_pts = [(0.0, 0.0), (10.0, 0.0), (0.0, 10.0)]
        tri = _wall(tri_pts, (1.0, 0.0))
        @test tri.Fx ≈ 180.0 atol=_ATOL
        @test tri.Fy ≈ -40.0 atol=_ATOL
        @test abs(tri.Fy) > 1.0
        @test tri.Mz ≈ -1100.0 / 3.0 atol=_ATOL
        @test tri.B ≈ 10.0 atol=_ATOL

        # Two exterior loops have no single L/B.
        other = [(3.0, 0.0), (4.0, 0.0), (4.0, 1.0), (3.0, 1.0)]
        @test_throws ArgumentError _wall([_SQ, other], (1.0, 0.0))

        # A clockwise courtyard is a hole, not a second exterior. L and B
        # stay on the 30 × 30 exterior. Internal pressure still cancels.
        ext = [(0.0, 0.0), (30.0, 0.0), (30.0, 30.0), (0.0, 30.0)]
        hole = [(10.0, 10.0), (10.0, 20.0), (20.0, 20.0), (20.0, 10.0)]
        court = _wall([ext, hole], (1.0, 0.0); qz=0.0, qh=0.0, G=0.0, GCpi=0.18, qi=10.0)
        @test court.L ≈ 30.0 atol=_ATOL
        @test court.B ≈ 30.0 atol=_ATOL
        @test court.Fx ≈ 0.0 atol=_ATOL
        @test court.Fy ≈ 0.0 atol=_ATOL
        @test court.Mz ≈ 0.0 atol=_ATOL
        # p = -10*0.18 = -1.8. Exterior length 120 plus hole length 40.
        @test court.sum_pA ≈ -1.8 * 160.0 atol=_ATOL
    end

    @testset "internal pressure cancels on a closed rectangle" begin
        # G = 0 kills the external term. p = -qi*Kd*(GCpi) = -1.8 on every
        # edge. Perimeter 40, so Σ pA = -72, and the net force and moment are 0.
        alone = _wall(_SQ, (1.0, 0.0); qz=10.0, qh=10.0, G=0.0, GCpi=0.18, qi=10.0)
        @test alone.sum_pA ≈ -72.0 atol=_ATOL
        @test alone.Fx ≈ 0.0 atol=_ATOL
        @test alone.Fy ≈ 0.0 atol=_ATOL
        @test alone.Mz ≈ 0.0 atol=_ATOL

        # The same (GCpi) on top of external pressure changes Σ pA and leaves
        # the net force alone, because the loop is closed and qi is uniform.
        bare = _wall(_SQ, (1.0, 0.0); qh=20.0)
        with_pi = _wall(_SQ, (1.0, 0.0); qh=20.0, GCpi=0.18, qi=20.0)
        @test with_pi.Fx ≈ bare.Fx atol=_ATOL
        @test with_pi.Fy ≈ bare.Fy atol=_ATOL
        @test with_pi.Mz ≈ bare.Mz atol=_ATOL
        @test with_pi.sum_pA ≉ bare.sum_pA
    end

    @testset "Figure 27.3-8 cases" begin
        rx = _wall(_SQ, (1.0, 0.0))
        ry = _wall(_SQ, (0.0, 1.0))
        cases = wind_cases_from_resultants(rx, ry)
        @test length(cases) == 11

        # Cases 3 and 4 combine two principal axes of one floor.
        @test_throws ArgumentError wind_cases_from_resultants(rx, rx)
        @test_throws ArgumentError wind_cases_from_resultants(rx, _wall(_SQ, (-1.0, 0.0)))
        @test_throws ArgumentError wind_cases_from_resultants(rx, _wall(_SQ, (1.0, 1.0)))
        @test_throws ArgumentError wind_principal_directions((0.0, 0.0), (0.0, 1.0))
        d1, d2 = wind_principal_directions((2.0, 0.0), (0.0, -3.0))
        @test d1 == (1.0, 0.0) && d2 == (0.0, -1.0)
        # A skewed pair is refused until the caller overrides the principal-axis check.
        skew = _wall(_SQ, (1.0, 1.0))
        @test_throws ArgumentError wind_principal_directions((1.0, 0.0), (1.0, 1.0))
        sd1, sd2 = wind_principal_directions((1.0, 0.0), (1.0, 1.0); perpendicular=false)
        @test sd1 == (1.0, 0.0)
        @test sd2[1] ≈ sd2[2] atol=_ATOL
        @test_throws ArgumentError wind_principal_directions((1.0, 0.0), (-2.0, 0.0); perpendicular=false)
        skewed = wind_cases_from_resultants(rx, skew; perpendicular=false)
        @test length(skewed) == 11
        # An added direction is Case 1 and Case 2 only.
        alone = wind_direction_cases(skew)
        @test length(alone) == 3
        @test alone[1].kind === :case1 && alone[1].direction == skew.direction
        @test alone[2].kind === :case2 && alone[2].sign_1 == 1
        @test alone[3].sign_1 == -1
        @test wind_unit_direction((0.0, -2.0)) == (0.0, -1.0)
        @test_throws ArgumentError wind_unit_direction((0.0, 0.0))
        # A 10 × 10 square and a 20 × 5 rectangle share the centroid (5, 5).
        # They are not the same floor.
        wide = [(-5.0, 2.5), (15.0, 2.5), (15.0, 7.5), (-5.0, 7.5)]
        @test _wall(wide, (0.0, 1.0)).centroid[1] ≈ rx.centroid[1] atol=_ATOL
        @test _wall(wide, (0.0, 1.0)).centroid[2] ≈ rx.centroid[2] atol=_ATOL
        @test_throws ArgumentError wind_cases_from_resultants(rx, _wall(wide, (0.0, 1.0)))
        c1 = cases[1]
        plus = cases[2]
        minus = cases[3]
        @test c1.kind === :case1
        @test c1.Fx ≈ 180.0 atol=_ATOL
        @test c1.Mz ≈ 0.0 atol=_ATOL
        # Case 2: 75% of the shear, plus ±0.15 B. Shape moment is 0.
        # 0.75 * 180 = 135. e = 0.15 * 10 = 1.5. Mz = ±135 * 1.5 = ±202.5.
        @test plus.kind === :case2 && plus.sign_1 == 1
        @test minus.sign_1 == -1
        @test plus.Fx ≈ 135.0 atol=_ATOL
        @test plus.Fy ≈ 0.0 atol=_ATOL
        @test plus.Mz ≈ 202.5 atol=_ATOL
        @test minus.Mz ≈ -202.5 atol=_ATOL
        @test plus.Mz ≈ 0.75 * c1.Mz + 0.75 * c1.Fx * wind_rigid_eccentricity(rx.B) atol=_ATOL
        @test minus.Mz ≈ 0.75 * c1.Mz - 0.75 * c1.Fx * wind_rigid_eccentricity(rx.B) atol=_ATOL

        # The triangle's own moment is kept, and the eccentricity is added.
        tri = _wall([(0.0, 0.0), (10.0, 0.0), (0.0, 10.0)], (1.0, 0.0))
        tri_y = _wall([(0.0, 0.0), (10.0, 0.0), (0.0, 10.0)], (0.0, 1.0))
        tcases = wind_cases_from_resultants(tri, tri_y)
        tplus = tcases[2]
        tminus = tcases[3]
        e = wind_rigid_eccentricity(tri.B)
        along = tri.Fx * tri.direction[1] + tri.Fy * tri.direction[2]
        @test tplus.Mz ≈ 0.75 * tri.Mz + 0.75 * along * e atol=_ATOL
        @test tminus.Mz ≈ 0.75 * tri.Mz - 0.75 * along * e atol=_ATOL
        @test tplus.Mz > tminus.Mz

        # Case 3 is 75% of +X and 75% of +Y, not a 45° Case 1.
        # 0.75 * (180, 0) + 0.75 * (0, 180) = (135, 135).
        # Case 1 at (1, 1) is (180, 180).
        c3 = only(c for c in cases if c.kind === :case3)
        @test c3.Fx ≈ 135.0 atol=_ATOL
        @test c3.Fy ≈ 135.0 atol=_ATOL
        @test c3.Mz ≈ 0.0 atol=_ATOL
        oblique = _wall(_SQ, (1.0, 1.0))
        @test oblique.Fx ≉ c3.Fx

        # Case 4 is 75% of both Case 2 resultants. ++ gives
        # Fx = 0.75*135 = 101.25 and Mz = 0.75*(202.5+202.5) = 303.75.
        both = [c for c in cases if c.kind === :case4]
        @test length(both) == 4
        pp = only(c for c in both if c.sign_1 == 1 && c.sign_2 == 1)
        @test pp.Fx ≈ 101.25 atol=_ATOL
        @test pp.Fy ≈ 101.25 atol=_ATOL
        @test pp.Mz ≈ 303.75 atol=_ATOL
        @test pp.Mz ≈ 0.75 * (plus.Mz + cases[5].Mz) atol=_ATOL
    end

    # Caller-supplied pressure on the same edges. Not a Chapter 27 coefficient.
    # Unit square, CCW. Right edge only, p = 2 toward the surface, height 3.
    # A = 3, n = (1, 0), force on the floor = −p·A·n = (−6, 0).
    @testset "pressure per facade edge" begin
        square = [(0.0, 0.0), (1.0, 0.0), (1.0, 1.0), (0.0, 1.0)]
        edges = wind_facade_edges(square; direction=(1.0, 0.0))
        @test length(edges) == 4
        windward = only(e for e in edges if e.outward_normal[1] < -0.5)
        @test windward.cosine < 0
        @test windward.pressure == 0.0
        got = wind_forces_from_pressures(square, [0.0, 2.0, 0.0, 0.0]; height=3.0)
        @test got.Fx ≈ -6.0 atol=_ATOL
        @test got.Fy ≈ 0.0 atol=_ATOL
        @test got.Mz ≈ 0.0 atol=_ATOL
        @test_throws ArgumentError wind_forces_from_pressures(square, [1.0, 2.0]; height=3.0)
    end
end
