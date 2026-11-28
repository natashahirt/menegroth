# Grade-wall groups: a closed cell is a mat, a run or an L is one strip,
# and a spur leaves the cell at the face. A shared corner is one reaction.

using Test
using Unitful
using StructuralSynthesizer

function _w(x1, y1, x2, y2)
    return Wall(1, 3.0u"m"; thickness = 0.25u"m",
                x1 = x1, y1 = y1, x2 = x2, y2 = y2, story = 0)
end

function _kinds(walls)
    groups = StructuralSynthesizer.classify_wall_foundation_groups(walls)
    return sort([g.kind for g in groups])
end

@testset "A straight wall is one strip" begin
    groups = StructuralSynthesizer.classify_wall_foundation_groups([_w(0, 0, 6, 0)])
    @test length(groups) == 1
    @test groups[1].kind == :strip
    @test length(groups[1].pieces) == 1
end

@testset "An L is one strip and the corner is one joint" begin
    groups = StructuralSynthesizer.classify_wall_foundation_groups([
        _w(0, 0, 6, 0), _w(0, 0, 0, 4)])
    @test length(groups) == 1
    @test groups[1].kind == :strip
    @test length(groups[1].pieces) == 2
end

@testset "A T that does not close is one strip" begin
    @test _kinds([_w(0, 0, 8, 0), _w(4, 0, 4, 3)]) == [:strip]
end

@testset "A door in the wall leaves the cell a mat" begin
    door = WallOpening(3.1, 0.0, 1.8, 2.1, :door)
    walls = [
        Wall(1, 3.6u"m"; thickness = 0.25u"m", x1 = 0.0, y1 = 0.0, x2 = 8.0, y2 = 0.0,
             story = 0, openings = [door]),
        _w(8, 0, 8, 8), _w(8, 8, 0, 8), _w(0, 8, 0, 0),
    ]
    groups = StructuralSynthesizer.classify_wall_foundation_groups(walls)
    @test length(groups) == 1
    @test groups[1].kind == :mat
    @test StructuralSynthesizer.point_in_wall_group(groups[1], 4.0, 4.0)
    @test any(p -> p.wall_index == 1, groups[1].pieces)
end

@testset "A closed cell is one mat and contains its centre" begin
    walls = [_w(0, 0, 8, 0), _w(8, 0, 8, 6), _w(8, 6, 0, 6), _w(0, 6, 0, 0)]
    groups = StructuralSynthesizer.classify_wall_foundation_groups(walls)
    @test length(groups) == 1
    @test groups[1].kind == :mat
    @test StructuralSynthesizer.point_in_wall_group(groups[1], 4.0, 3.0)
    @test !StructuralSynthesizer.point_in_wall_group(groups[1], 4.0, 0.0)
    @test !StructuralSynthesizer.point_in_wall_group(groups[1], 20.0, 3.0)
end

@testset "A spur is a strip and the cell stays a mat" begin
    walls = [_w(0, 0, 6, 0), _w(6, 0, 6, 6), _w(6, 6, 0, 6), _w(0, 6, 0, 0),
             _w(6, 3, 10, 3)]
    kinds = _kinds(walls)
    @test count(==( :mat), kinds) == 1
    @test count(==( :strip), kinds) == 1
end

@testset "Two separate cells are two mats" begin
    walls = [_w(0, 0, 4, 0), _w(4, 0, 4, 4), _w(4, 4, 0, 4), _w(0, 4, 0, 0),
             _w(10, 0, 14, 0), _w(14, 0, 14, 4), _w(14, 4, 10, 4), _w(10, 4, 10, 0)]
    @test _kinds(walls) == [:mat, :mat]
end

@testset "A corner reaction is counted once, on the longer leg" begin
    pieces = [
        StructuralSynthesizer.WallFoundationPiece(1, (0.0, 0.0), (6.0, 0.0)),
        StructuralSynthesizer.WallFoundationPiece(2, (0.0, 0.0), (0.0, 4.0)),
    ]
    nodes = [
        StructuralSynthesizer.GradeWallNode(UInt64(1), 1, 0.0, 0.0, 100.0, 70.0),
        StructuralSynthesizer.GradeWallNode(UInt64(1), 2, 0.0, 0.0, 100.0, 70.0),
        StructuralSynthesizer.GradeWallNode(UInt64(2), 1, 6.0, 0.0, 40.0, 30.0),
        StructuralSynthesizer.GradeWallNode(UInt64(3), 2, 0.0, 4.0, 20.0, 15.0),
    ]
    samples, owners, piece_ids = StructuralSynthesizer.assign_grade_wall_nodes(
        pieces, nodes, [0.25, 0.25])
    @test sum(length, piece_ids) == sum(length, samples)
    @test owners[UInt64(1)][1] == 1
    total = sum(p for piece in samples for (_, p, _) in piece)
    @test total ≈ 160.0
    @test sum(length(piece) for piece in samples) == 3
end

@testset "A door at the base shortens the dowel length" begin
    wall = _w(0, 0, 8, 0)
    wall.openings = [
        WallOpening(1.0, 0.0, 2.0, 2.1, :door),
        WallOpening(4.0, 0.9, 1.5, 1.2, :window),
        WallOpening(5.5, 0.0, 1.5, 2.0, :door),
        WallOpening(6.0, 0.0, 1.5, 2.0, :door),
    ]
    piece = StructuralSynthesizer.WallFoundationPiece(1, (0.0, 0.0), (8.0, 0.0))
    # Door 1–3 m and overlapping doors 5.5–7.5 m. The window sill is not at the base.
    @test StructuralSynthesizer._base_solid_length(wall, piece) ≈ 4.0
end
