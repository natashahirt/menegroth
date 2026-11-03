# Lateral system and demand assignment. Only walls-as-seismic-system and the
# whole-building assignment run; the others refuse at their first hook.

using Test
using Unitful
using StructuralSynthesizer

function _girder_struc(; release_start=:default, with_wall=true)
    girder = Beam([1], 4.0u"m"; role=:girder)
    joist = Beam([2], 4.0u"m"; role=:joist)
    segs = [Segment(1, 4.0u"m"; release_start=release_start), Segment(2, 4.0u"m")]
    walls = with_wall ? [Wall([3], 4.0u"m"; thickness=0.3u"m", x2=5.0)] : Wall{typeof(1.0u"m")}[]
    return (beams=[girder, joist], segments=segs, walls=walls)
end

@testset "lateral approaches" begin
    @test DesignParameters().lateral === nothing
    @test_throws ArgumentError WallsSeismicSystem()
    @test_throws ArgumentError WallsSeismicSystem(:F)
    @test WallsSeismicSystem(:B6).row === :B6
    design = LateralDesign(; system=WallsSeismicSystem(:A3), assignment=BuildingUnit())
    @test DesignParameters(lateral=design).lateral.system isa WallsSeismicSystem
    @test design.system_x.row === :A3 && design.system_y.row === :A3
    @test_throws UndefKeywordError LateralDesign(; system=WallsSeismicSystem(:A3))
    split = LateralDesign(; system_x=WallsSeismicSystem(:A3),
                          system_y=InteractiveShearWallFrameSystem(),
                          assignment=BuildingUnit())
    @test split.system_x isa WallsSeismicSystem
    @test split.system_y isa InteractiveShearWallFrameSystem
    @test_throws ArgumentError split.system
    @test_throws ArgumentError LateralDesign(; system_x=WallsSeismicSystem(:A3),
                                            system_y=WallsSeismicSystem(:B6),
                                            assignment=BuildingUnit())
    @test_throws ArgumentError StructuralSynthesizer._elf_direction_factors(
        :y, 4.0, 4.0, 2.5, 5.0, nothing, 2.5)
    Ry, Cy, Ωy = StructuralSynthesizer._elf_direction_factors(
        :y, 4.0, 4.0, 2.5, 4.5, 4.0, 2.5)
    @test (Ry, Cy, Ωy) == (4.5, 4.0, 2.5)
    Rx, Cx, Ωx = StructuralSynthesizer._elf_direction_factors(
        :x, 4.0, 4.0, 2.5, 4.5, 4.0, 2.5)
    @test (Rx, Cx, Ωx) == (4.0, 4.0, 2.5)
    @test :lateral in StructuralSynthesizer.PREPARE_AFFECTING_FIELDS

    struc = _girder_struc()
    prepare_lateral_model!(struc, WallsSeismicSystem(:A3))
    @test all(b -> b.lateral_role === :gravity, struc.beams)
    @test seismic_members(struc, WallsSeismicSystem(:A3)) == (walls=[1], beams=Int[], columns=Int[])
    framed = (walls=[1], beams=[1, 2], columns=Int[])
    @test seismic_members(framed, InteractiveShearWallFrameSystem()) ==
          (walls=[1], beams=[1, 2], columns=Int[])
    prepare_lateral_model!(struc, InteractiveShearWallFrameSystem())
    prepare_lateral_model!(struc, split)
    @test_throws ArgumentError prepare_lateral_model!(
        _girder_struc(; with_wall=false), InteractiveShearWallFrameSystem())

    # Steel gravity girders and beams resolve pinned; concrete stays fixed; an
    # explicit fixed end is a user-chosen moment connection and is kept.
    girder, chain = struc.beams[1], [struc.segments[1]]
    @test StructuralSynthesizer.resolve_release(girder, chain, A992_Steel) === :freefree
    @test StructuralSynthesizer.resolve_release(girder, chain, NWC_4000) === :fixedfixed
    fixed = _girder_struc(; release_start=:fixed)
    @test StructuralSynthesizer.resolve_release(fixed.beams[1], [fixed.segments[1]],
                                                A992_Steel) === :fixedfree
    mf = Beam([1], 4.0u"m"; role=:girder, lateral_role=:moment_frame)
    @test StructuralSynthesizer.resolve_release(mf, chain, A992_Steel) === :fixedfixed

    @test_throws ArgumentError prepare_lateral_model!(_girder_struc(; with_wall=false),
                                                      WallsSeismicSystem(:A3))

    @test isempty(system_checks(struc, WallsSeismicSystem(:A3); seismic_design_category=:C))
    @test_throws ArgumentError system_checks(struc, WallsSeismicSystem(:A3);
                                             seismic_design_category=:D)
    @test_throws ArgumentError system_checks(struc, WallsSeismicSystem(:A3);
                                             seismic_design_category=:G)

    @test_throws ArgumentError prepare_lateral_model!(struc, OutriggerSystem())
    @test_throws ArgumentError seismic_members(struc, OutriggerSystem())
    share = IsolatedWallShare(0.5)
    @test share.share == 0.5
    @test_throws ArgumentError IsolatedWallShare(0)
    @test_throws ArgumentError IsolatedWallShare(1.5)
    @test_throws ArgumentError assign_lateral_demands(share, nothing, nothing, Float64[])
end
