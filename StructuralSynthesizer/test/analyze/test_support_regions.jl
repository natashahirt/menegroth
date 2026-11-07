using StructuralSynthesizer
using Test

const _CELL = [(0.0, 0.0), (8.0, 0.0), (8.0, 8.0), (0.0, 8.0)]
const _TOP = [(0.0, 8.0), (8.0, 8.0)]
const _WALL = [((0.0, 0.0), (8.0, 0.0))]

_area(shares) = sum(s.area for s in shares; init=0.0)
_by_xy(shares, xy) = only(s for s in shares if hypot(s.xy[1] - xy[1], s.xy[2] - xy[2]) < 1e-9)

@testset "support regions" begin
    @testset "no wall, every corner is a column" begin
        cols = [(0.0, 0.0), (8.0, 0.0), (8.0, 8.0), (0.0, 8.0)]
        split = split_cell_supports(_CELL, cols, Tuple{NTuple{2,Float64},NTuple{2,Float64}}[])
        @test length(split.walls) == 0
        @test _area(split.columns) ≈ 64 atol=1e-6
        for s in split.columns
            @test s.area ≈ 16 atol=1e-6
        end
    end

    @testset "no wall, two columns keep the dropped corners" begin
        split = split_cell_supports(_CELL, _TOP, Tuple{NTuple{2,Float64},NTuple{2,Float64}}[])
        @test _area(split.columns) ≈ 64 atol=1e-6
        @test _by_xy(split.columns, (0.0, 8.0)).area ≈ 32 atol=1e-6
        @test _by_xy(split.columns, (8.0, 8.0)).area ≈ 32 atol=1e-6
    end

    @testset "wall and two far columns: columns keep the corner region" begin
        split = split_cell_supports(_CELL, _TOP, _WALL)
        @test _by_xy(split.columns, (0.0, 8.0)).area ≈ 16 atol=1e-6
        @test _by_xy(split.columns, (8.0, 8.0)).area ≈ 16 atol=1e-6
        wall = only(split.walls)
        @test wall.area ≈ 32 atol=1e-6
        @test _area(split.columns) + wall.area ≈ 64 atol=1e-6
        # The complement of the two upper quadrants is a 4 m strip.
        @test !isempty(wall.pieces)
        for piece in wall.pieces
            @test piece.a ≈ 0 atol=1e-8
            @test piece.b ≈ 0 atol=1e-8
            @test piece.c ≈ 4 atol=1e-6
        end
    end

    @testset "one column: the parabola is the larger region" begin
        split = split_cell_supports(_CELL, [(0.0, 8.0)], _WALL)
        col = only(split.columns)
        wall = only(split.walls)
        # ∫_0^8 (8 - (u² + 64)/16) du = 64/3
        @test col.area ≈ 64 / 3 atol=1e-6
        @test wall.area ≈ 128 / 3 atol=1e-6
        @test col.area + wall.area ≈ 64 atol=1e-6
        piece = only(wall.pieces)
        # w(u) = u²/16 + 4
        @test piece.u0 ≈ 0 atol=1e-8
        @test piece.u1 ≈ 8 atol=1e-8
        @test piece.a ≈ 1 / 16 atol=1e-8
        @test piece.b ≈ 0 atol=1e-6
        @test piece.c ≈ 4 atol=1e-6
        # w = u²/16 + 4, so the stored loop follows the parabola (w(4) = 5), not the chord.
        loops = StructuralSynthesizer._wall_share_polygons(0.0, 0.0, 8.0, 0.0, wall.pieces, _CELL)
        loop = only(loops)
        inner = filter(p -> p[2] > 1.0, loop)
        i = argmin(k -> abs(inner[k][1] - 4.0), eachindex(inner))
        @test length(loop) > 4
        @test inner[i][2] > 4.5
        @test inner[i][2] ≈ inner[i][1]^2 / 16 + 4 atol = 1e-6
        # The column boundary is the same parabola, already sampled on the share.
        @test length(col.polygon) > 4
    end

    @testset "two walls and one column still fill the cell" begin
        walls = [((0.0, 0.0), (8.0, 0.0)), ((0.0, 0.0), (0.0, 8.0))]
        split = split_cell_supports(_CELL, [(8.0, 8.0)], walls)
        @test _area(split.columns) + _area(split.walls) ≈ 64 atol=1e-4
        @test all(w.area > 0 for w in split.walls)
        @test only(split.columns).area > 0
    end

    @testset "nodal forces" begin
        # Uniform 4 m width, 1000 Pa, one span of 8 m. Each node takes half.
        piece = WallWidthPiece(0.0, 8.0, 0.0, 0.0, 4.0)
        F = wall_edge_nodal_forces([0.0, 8.0], [piece], 1000.0)
        @test sum(F) ≈ 4 * 8 * 1000 atol=1e-6
        @test F[1] ≈ F[2] atol=1e-6

        # w = u²/16 + 4 on [0, 8]. Total load is the wall area times pressure.
        curved = WallWidthPiece(0.0, 8.0, 1 / 16, 0.0, 4.0)
        Fc = wall_edge_nodal_forces([0.0, 8.0], [curved], 1000.0)
        @test sum(Fc) ≈ (128 / 3) * 1000 atol=1e-4
        # The width grows toward u = 8, so the far node takes more.
        @test Fc[2] > Fc[1]
    end
end
