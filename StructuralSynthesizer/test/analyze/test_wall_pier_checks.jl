# Pier strength checks on a vertical segment.
#
# Combinations are the solid-pier list, applied at each end. A long segment
# is the ordinary-wall check on the segment length and clear height. A short
# segment is a column. Slenderness past the neglect limit is withheld, and
# the moments are not magnified. A long horizontal segment is a beam. A
# deep one is one strut and one tie. A column segment is checked when
# the story is nonsway.

using Test
using Unitful
using Asap
using StructuralSynthesizer

# ACI 318-19 Table 20.5.1.3.1, column row, not exposed to weather: 1½ in.
const _COVER = 1.5u"inch"

function _pier_wall(; openings=WallOpening[])
    return Wall([1], 4.0u"m"; thickness=0.3u"m",
                x1=0.0, y1=0.0, x2=6.0, y2=0.0, story=1, openings=openings)
end

function _rc()
    ties = RebarSteel(29000.0u"ksi", 11200.0u"ksi", 60.0u"ksi", 90.0u"ksi",
                      490.0u"lb/ft^3", 0.30, 1.72u"kgCO2e/kg")
    return ReinforcedConcreteMaterial(NWC_4000, Rebar_60, ties)
end

function _segment(s0, s1, z0, z1, design)
    return StructuralSynthesizer.WallSegment(
        :vertical, [1], [1], s0, s1, z0, z1, Asap.ShellTri3[], design)
end

function _action(N, V, M)
    return CombinedWallAction(:strength_1_4D, :only, N, V, M)
end

@testset "segment end strength combinations" begin
    bottom = PierGravityActions(:Lr, WallAction(1.0e6, 0.0, 0.0),
                                WallAction(2.0e5, 0.0, 0.0), WallAction(1.0e4, 0.0, 0.0))
    top = PierGravityActions(:Lr, WallAction(8.0e5, 0.0, 0.0),
                             WallAction(1.0e5, 0.0, 0.0), WallAction(0.0, 0.0, 0.0))
    wind_bottom = WallAction(0.0, 1.0e4, 2.0e5)
    wind_top = WallAction(0.0, 5.0e3, 1.0e5)
    qe_bottom = WallAction(0.0, 2.0e4, 4.0e5)
    qe_top = WallAction(0.0, 1.0e4, 2.0e5)
    ends = segment_end_strength(bottom, top; wind_bottom, wind_top,
                                qe_bottom, qe_top, rho=1.0, SDS=1.0)
    @test ends.bottom == wall_strength_actions(bottom; wind=wind_bottom, qe=qe_bottom,
                                               rho=1.0, SDS=1.0)
    @test ends.top == wall_strength_actions(top; wind=wind_top, qe=qe_top,
                                            rho=1.0, SDS=1.0)
    @test length(ends.bottom) == 8
    @test length(ends.top) == 8
end

@testset "wall segment uses its own length and height" begin
    wall = _pier_wall()
    material = _rc()
    # ℓw/t = 2/0.3 > 3, so this is a wall. hw/ℓw = 3, which is not the
    # story height over the full wall length.
    segment = _segment(0.0, 2.0, 0.0, 6.0, :wall)
    bottom = [_action(1.0e5, 1.0e4, 2.0e4)]
    top = [_action(8.0e4, 1.2e4, 1.0e4)]
    records = check_pier_segment(wall, segment, bottom, top;
                                 material, wall_index=1, case=:gravity,
                                 boundary=:cantilever)
    direct_bottom = check_ordinary_wall(wall, bottom; material, wall_index=1,
                                        case=:gravity, boundary=:cantilever,
                                        lw=2.0u"m", hw=6.0u"m")
    direct_top = check_ordinary_wall(wall, top; material, wall_index=1,
                                     case=:gravity, boundary=:cantilever,
                                     lw=2.0u"m", hw=6.0u"m")
    n_bottom = length(direct_bottom)
    @test length(records) == n_bottom + length(direct_top)
    for (got, direct, face) in ((records[1:n_bottom], direct_bottom, "bottom"),
                                (records[n_bottom+1:end], direct_top, "top"))
        for (a, b) in zip(got, direct)
            @test a.check == "$face $(b.check)"
            @test a.passed == b.passed
            @test a.ratio ≈ b.ratio
            @test a.demand ≈ b.demand
            @test a.capacity ≈ b.capacity
            @test a.clause == b.clause
        end
    end
    full = check_ordinary_wall(wall, bottom; material, wall_index=1,
                               case=:gravity, boundary=:cantilever)
    seg_shear = only(r for r in direct_bottom if r.check == "in-plane shear")
    full_shear = only(r for r in full if r.check == "in-plane shear")
    @test seg_shear.capacity != full_shear.capacity
    @test all(r -> r.passed, records)
end

@testset "narrow pier column check" begin
    wall = _pier_wall()
    material = _rc()
    # ℓw/t = 0.5/0.3 ≤ 3. hw = 1 m, k = 1, unbraced: kℓu/r is about 6.7
    # in-plane and 11 in the thickness, both within 22.
    short = _segment(0.0, 0.5, 0.0, 1.0, :column)
    actions = [_action(1.0e5, 1.0e4, 5.0e3)]
    @test_throws ArgumentError check_pier_segment(
        wall, short, actions, actions; material, wall_index=1, case=:gravity,
        boundary=:cantilever, braced=false, cover=_COVER)
    @test_throws ArgumentError check_pier_segment(
        wall, short, actions, actions; material, wall_index=1, case=:gravity,
        boundary=:cantilever, k=1.0, braced=true, cover=_COVER)
    records = check_pier_segment(
        wall, short, actions, actions; material, wall_index=1, case=:gravity,
        boundary=:cantilever, k=1.0, braced=false, cover=_COVER)
    slenderness = only(r for r in records if r.check == "in-plane slenderness")
    @test slenderness.passed
    @test slenderness.demand ≈ 1.0 / (0.3 * 0.5) atol=1e-9
    @test slenderness.capacity == 22.0
    ratio = only(r for r in records if r.check == "longitudinal ratio")
    @test ratio.passed
    @test 0.01 <= ratio.demand <= 0.08
    @test all(r -> r.passed, (r for r in records if endswith(r.check, "axial-flexure")))
    shear = only(r for r in records if r.check == "bottom one-way shear")
    @test shear.passed
    @test shear.ratio < 1
    @test occursin("22.5", shear.clause)
    @test occursin("ties at", shear.clause)
    @test !occursin("withheld", shear.clause)
    section_limit = only(r for r in records if r.check == "bottom one-way shear section")
    @test section_limit.passed

    # Same section, story height. Unbraced kℓu/r is about 27, past 22.
    # No short-column acceptance is recorded.
    tall = _segment(0.0, 0.5, 0.0, 4.0, :column)
    tall_records = check_pier_segment(
        wall, tall, actions, actions; material, wall_index=1, case=:gravity,
        boundary=:cantilever, k=1.0, braced=false, cover=_COVER)
    tall_slender = only(r for r in tall_records if r.check == "in-plane slenderness")
    @test !tall_slender.passed
    @test tall_slender.demand ≈ 4.0 / (0.3 * 0.5) atol=1e-9
    @test !any(r -> occursin("axial-flexure", r.check), tall_records)
end

@testset "column one-way shear equation" begin
    # Table 22.5.5.1(a) with Nu = 0: Vc = 2√f'c bw d.
    # f'c = 4000 psi, bw = 12 in, d = 20 in. φ = WALL_PHI_SHEAR.
    fc = 4000.0 * Asap.PSI_TO_PA
    bw = 12.0 * Asap.IN_TO_M
    d = 20.0 * Asap.IN_TO_M
    Ag = 12.0 * 24.0 * Asap.IN_TO_M^2
    shear = column_one_way_shear_capacity(bw, d, Ag, fc, 0.0)
    Vc_lb = 2.0 * sqrt(4000.0) * 12.0 * 20.0
    @test shear.ϕVc / Asap.LBF_TO_N ≈ WALL_PHI_SHEAR * Vc_lb rtol=1e-12
    @test shear.ϕVn_limit / Asap.LBF_TO_N ≈
        WALL_PHI_SHEAR * (Vc_lb + 8.0 * sqrt(4000.0) * 12.0 * 20.0) rtol=1e-12
    @test 90_000.0 < shear.ϕVc < 120_000.0

    # Nu/(6Ag) = 100 psi of compression raises Vc by 100·bw·d.
    Nu = 100.0 * 6.0 * (12.0 * 24.0) * Asap.LBF_TO_N
    compressed = column_one_way_shear_capacity(bw, d, Ag, fc, Nu)
    @test compressed.ϕVc / Asap.LBF_TO_N ≈
        WALL_PHI_SHEAR * (Vc_lb + 100.0 * 12.0 * 20.0) rtol=1e-9

    # Tension that cancels 2λ√f'c leaves Vc at zero, not negative.
    Nu_zero = -(2.0 * sqrt(4000.0)) * 6.0 * (12.0 * 24.0) * Asap.LBF_TO_N
    @test column_one_way_shear_capacity(bw, d, Ag, fc, Nu_zero).ϕVc ≈ 0.0 atol=1e-6
    @test column_one_way_shear_capacity(bw, d, Ag, fc, 2.0 * Nu_zero).ϕVc ≈ 0.0 atol=1e-6

    # §22.5.5.1.2 stops Nu/(6Ag) at 0.05f'c, and §22.5.5.1.1 then stops Vc
    # at 5λ√f'c bw d. 2√4000 + 200 psi is past that ceiling, so a larger Nu
    # does not raise Vc any further.
    Nu_cap = 0.05 * 4000.0 * 6.0 * (12.0 * 24.0) * Asap.LBF_TO_N
    Nu_over = 2.0 * Nu_cap
    at_ceiling = column_one_way_shear_capacity(bw, d, Ag, fc, Nu_cap)
    @test at_ceiling.ϕVc / Asap.LBF_TO_N ≈
        WALL_PHI_SHEAR * 5.0 * sqrt(4000.0) * 12.0 * 20.0 rtol=1e-9
    @test column_one_way_shear_capacity(bw, d, Ag, fc, Nu_over).ϕVc ≈
        at_ceiling.ϕVc rtol=1e-12

    # §22.5.3.1 caps √f'c at 100 psi inside Vc. Eq. (22.5.1.2) keeps the
    # uncapped root in the 8√f'c term.
    fc_hi = 15_000.0 * Asap.PSI_TO_PA
    hi = column_one_way_shear_capacity(bw, d, Ag, fc_hi, 0.0)
    @test hi.ϕVc / Asap.LBF_TO_N ≈ WALL_PHI_SHEAR * 2.0 * 100.0 * 12.0 * 20.0 rtol=1e-9
    @test hi.ϕVn_limit / Asap.LBF_TO_N ≈
        WALL_PHI_SHEAR * (2.0 * 100.0 * 12.0 * 20.0 + 8.0 * sqrt(15_000.0) * 12.0 * 20.0) rtol=1e-9
end

@testset "a column pier past the shear limit fails" begin
    wall = _pier_wall()
    material = _rc()
    short = _segment(0.0, 0.5, 0.0, 1.0, :column)
    # Same axial and moment as the passing pier. The shear is far past
    # φ(Vc + 8√f'c bw d) for a 0.3 m by 0.5 m section.
    actions = [_action(1.0e5, 5.0e6, 5.0e3)]
    records = check_pier_segment(
        wall, short, actions, actions; material, wall_index=1, case=:gravity,
        boundary=:cantilever, k=1.0, braced=false, cover=_COVER)
    shear = only(r for r in records if r.check == "bottom one-way shear")
    @test !shear.passed
    @test shear.ratio > 1
    @test occursin("22.5.1.2", shear.clause)
    section_limit = only(r for r in records if r.check == "bottom one-way shear section")
    @test !section_limit.passed
    @test section_limit.ratio > 1
end

@testset "column shear can be the governing column check" begin
    col = ColumnDesignResult(;
        ok = false, axial_ratio = 0.2, interaction_ratio = 0.4,
        shear_ratio = 1.4, shear_ok = false)
    @test StructuralSynthesizer.column_diagnostic_governing_check(col) == "column_shear"
end

@testset "a horizontal segment is not passed" begin
    opening = WallOpening(1.0, 1.0, 1.0, 1.0, :window)
    wall = _pier_wall(; openings=[opening])
    horizontal = StructuralSynthesizer.WallSegment(
        :horizontal, [1], [1], 0.0, 2.0, 1.0, 1.5, Asap.ShellTri3[], :beam)
    @test_throws ArgumentError check_pier_segment(
        wall, horizontal, [_action(1.0, 1.0, 1.0)], [_action(1.0, 1.0, 1.0)];
        material=_rc(), wall_index=1, case=:gravity, boundary=:cantilever)
    record = StructuralSynthesizer.unchecked_horizontal_segment(wall, 1, :X, :beam)
    @test record.passed == false
    @test occursin("unchecked", record.check)
    withheld = StructuralSynthesizer.withheld_column_segment(wall, 1, :X)
    @test withheld.passed == false
    @test occursin("6.6.4.3", withheld.clause)
end

@testset "column end-moment ratio and the nonsway test" begin
    # Same sign is single curvature, so the ratio is negative.
    @test StructuralSynthesizer.segment_end_moment_ratio(100.0, 40.0) ≈ -0.4
    @test StructuralSynthesizer.segment_end_moment_ratio(-100.0, -25.0) ≈ -0.25
    # Opposite signs are double curvature.
    @test StructuralSynthesizer.segment_end_moment_ratio(100.0, -40.0) ≈ 0.4
    @test StructuralSynthesizer.segment_end_moment_ratio(0.0, 0.0) == 0.0

    first = [WallAction(0.0, 0.0, 100.0)]
    within = [WallAction(0.0, 0.0, 105.0)]
    over = [WallAction(0.0, 0.0, 107.0)]
    quiet = [WallAction(0.0, 0.0, 0.0)]
    grown = [WallAction(0.0, 0.0, 1000.0)]
    @test StructuralSynthesizer.story_end_moments_are_nonsway(first, first, within, within)
    @test !StructuralSynthesizer.story_end_moments_are_nonsway(first, first, over, over)
    @test !StructuralSynthesizer.story_end_moments_are_nonsway(quiet, quiet, grown, grown)
end

@testset "an ordinary spandrel uses beam flexure and shear" begin
    wall = _pier_wall()
    # Height 1 m. The tag is the layout's :beam route.
    band = StructuralSynthesizer.WallSegment(
        :horizontal, [1], [1], 0.0, 6.0, 2.0, 3.0, Asap.ShellTri3[], :beam)
    light = [_action(0.0, 1.0e4, 2.0e4)]
    records = StructuralSynthesizer.check_spandrel_beam(
        wall, band, light, light; material=_rc(), wall_index=1, direction=:X)
    flex = only(r for r in records if r.check == "spandrel flexure")
    shear = only(r for r in records if r.check == "spandrel shear")
    @test flex.passed
    @test occursin("10.2", flex.clause)
    @test shear.passed
    @test occursin("11.2", shear.clause)

    huge = [_action(0.0, 1.0e4, 1.0e8)]
    over = StructuralSynthesizer.check_spandrel_beam(
        wall, band, huge, huge; material=_rc(), wall_index=1, direction=:X)
    @test !only(r for r in over if r.check == "spandrel flexure").passed

    deep = StructuralSynthesizer.WallSegment(
        :horizontal, [1], [1], 0.0, 1.0, 2.0, 3.0, Asap.ShellTri3[], :stm)
    @test_throws ArgumentError StructuralSynthesizer.check_spandrel_beam(
        wall, deep, light, light; material=_rc(), wall_index=1, direction=:X)
end

@testset "a deep spandrel is one strut and one tie" begin
    wall = _pier_wall()
    # Span 1 m, depth 1 m. The layout routes this :stm.
    band = StructuralSynthesizer.WallSegment(
        :horizontal, [1], [1], 0.0, 1.0, 2.0, 3.0, Asap.ShellTri3[], :stm)
    light = [_action(0.0, 1.0e4, 2.0e4)]
    records = StructuralSynthesizer.check_spandrel_deep_beam(
        wall, band, light, light; material=_rc(), wall_index=1, direction=:X)
    @test only(r for r in records if r.check == "deep-beam shear limit").passed
    @test only(r for r in records if r.check == "deep-beam side reinforcement").passed
    @test only(r for r in records if r.check == "deep-beam strut").passed
    @test only(r for r in records if r.check == "deep-beam tie").passed
    @test only(r for r in records if r.check == "deep-beam node").passed
    @test occursin("9.9.2.1", only(r for r in records if r.check == "deep-beam shear limit").clause)
    @test occursin("23.7.2", only(r for r in records if r.check == "deep-beam tie").clause)

    huge = [_action(0.0, 1.0e8, 2.0e4)]
    over = StructuralSynthesizer.check_spandrel_deep_beam(
        wall, band, huge, huge; material=_rc(), wall_index=1, direction=:X)
    @test !only(r for r in over if r.check == "deep-beam shear limit").passed
end
