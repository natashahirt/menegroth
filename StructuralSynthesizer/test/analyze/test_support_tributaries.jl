using StructuralSynthesizer
using Test

const SS = StructuralSynthesizer
const _CELL = [(0.0, 0.0), (8.0, 0.0), (8.0, 8.0), (0.0, 8.0)]
const _CORNERS = [(0.0, 0.0), (8.0, 0.0), (8.0, 8.0), (0.0, 8.0)]
const _TOP = [(0.0, 8.0), (8.0, 8.0)]
const _BOTTOM_WALL = [((0.0, 0.0), (8.0, 0.0))]
const _NO_WALLS = Tuple{NTuple{2, Float64}, NTuple{2, Float64}}[]

_tribs(cell; axis = nothing) = begin
    pts = [SS.Meshes.Point(x, y) for (x, y) in cell]
    axis === nothing ? SS.StructuralSizer.get_tributary_polygons_isotropic(pts) :
        SS.StructuralSizer.get_tributary_polygons(pts; axis = collect(axis))
end
_split(cols, walls; cell = _CELL, axis = nothing) =
    split_cell_edges(cell, _tribs(cell; axis), cols, walls; axis)
_loop_area(loop) = abs(SS._shoelace(loop))
_same_loop(a, b) = length(a) == length(b) &&
    all(p -> any(q -> hypot(p[1] - q[1], p[2] - q[2]) < 1e-9, b), a)
_wall_area(split, k) = sum((s.area for s in split.walls if s.wall == k); init = 0.0)
_total(split) = sum((s.area for s in split.columns if s !== nothing); init = 0.0) +
                sum((s.area for s in split.walls); init = 0.0)

@testset "support tributaries" begin
    @testset "four columns: each corner square" begin
        split = _split(_CORNERS, _NO_WALLS)
        @test isempty(split.walls)
        @test isempty(split.overhang)
        for s in split.columns
            @test s.area ≈ 16 atol = 1e-9
            @test _loop_area(s.polygon) ≈ 16 atol = 1e-9
            @test length(s.polygon) == 4
        end
    end

    @testset "wall and two far columns" begin
        # The wall owns its triangle and the halves of the side edges at its
        # ends; each column keeps the halves at its corner.
        split = _split(_TOP, _BOTTOM_WALL)
        @test all(s -> s.area ≈ 16, split.columns)
        @test _wall_area(split, 1) ≈ 32 atol = 1e-9
        @test isempty(split.overhang)
        # In a square the two 45° halves at a corner join into the 4 × 4
        # square, and the wall's triangle and end halves into a 4 m strip.
        wall = only(split.walls)
        @test length(wall.polygons) == 1
        @test _same_loop(only(wall.polygons), [(0.0, 0.0), (8.0, 0.0), (8.0, 4.0), (0.0, 4.0)])
        @test _same_loop(split.columns[1].polygon, [(0.0, 4.0), (4.0, 4.0), (4.0, 8.0), (0.0, 8.0)])
    end

    @testset "rectangle with four columns: quarter rectangles" begin
        # The skeleton ridge lies on the midline, so a corner's halves of a
        # long-edge trapezoid and a short-edge triangle are a 4 × 3 rectangle.
        cell = [(0.0, 0.0), (8.0, 0.0), (8.0, 6.0), (0.0, 6.0)]
        split = _split(cell, _NO_WALLS; cell)
        # The skeleton's own area is short of 8×6/4 by ~2e-7 m².
        @test all(s -> isapprox(s.area, 12; atol = 1e-6), split.columns)
        @test _same_loop(split.columns[1].polygon, [(0.0, 0.0), (4.0, 0.0), (4.0, 3.0), (0.0, 3.0)])
    end

    @testset "a corner held by walls that frame into it from outside" begin
        # A bay whose fourth corner is a core corner with no column. The
        # core walls end there; each takes the half of the edge on its line.
        cols = [(0.0, 0.0), (8.0, 0.0), (0.0, 8.0)]
        walls = [((8.0, 8.0), (8.0, 16.0)), ((8.0, 8.0), (16.0, 8.0))]
        split = _split(cols, walls)
        @test all(s -> s.area ≈ 16, split.columns)
        @test _wall_area(split, 1) ≈ 8 atol = 1e-9
        @test _wall_area(split, 2) ≈ 8 atol = 1e-9
        @test _same_loop(only(split.walls[1].polygons), [(8.0, 4.0), (8.0, 8.0), (4.0, 4.0)])
        @test isempty(split.overhang)
    end

    @testset "corners with no support go to the nearest one" begin
        split = _split(_TOP, _NO_WALLS)
        @test all(s -> s.area ≈ 32, split.columns)
        @test length(split.overhang) == 3
        @test _total(split) ≈ 64 atol = 1e-9

        # One column and a wall: the far corner's halves walk to the closer
        # support, a tie going along the edge being split.
        one = _split([(0.0, 8.0)], _BOTTOM_WALL)
        @test only(one.columns).area ≈ 24 atol = 1e-9
        @test _wall_area(one, 1) ≈ 40 atol = 1e-9
        @test length(one.overhang) == 2
        @test _total(one) ≈ 64 atol = 1e-9
        @test isempty(split_cell_edges(_CELL, _tribs(_CELL), _TOP, _NO_WALLS;
                                       flag_overhang = false).overhang)
    end

    @testset "four walls on a long rectangle" begin
        cell = [(0.0, 0.0), (8.0, 0.0), (8.0, 2.5), (0.0, 2.5)]
        walls = [((0.0, 0.0), (8.0, 0.0)), ((8.0, 0.0), (8.0, 2.5)),
                 ((8.0, 2.5), (0.0, 2.5)), ((0.0, 2.5), (0.0, 0.0))]
        split = _split(NTuple{2, Float64}[], walls; cell)
        @test _wall_area(split, 1) ≈ 8.4375 atol = 1e-6
        @test _wall_area(split, 3) ≈ 8.4375 atol = 1e-6
        @test _wall_area(split, 2) ≈ 1.5625 atol = 1e-6
        @test _wall_area(split, 4) ≈ 1.5625 atol = 1e-6
    end

    @testset "walls on one line share the edge they cover together" begin
        walls = [((0.0, 0.0), (3.0, 0.0)), ((8.0, 0.0), (3.0, 0.0))]
        split = _split(_TOP, walls)
        @test all(s -> s.area ≈ 16, split.columns)
        # ∫₀³ x dx of the bottom triangle, plus the side half at each end.
        @test _wall_area(split, 1) ≈ 4.5 + 8 atol = 1e-9
        @test _wall_area(split, 2) ≈ 11.5 + 8 atol = 1e-9

        # Part of an edge is not that edge's support, but the wall still
        # holds the corner it ends at.
        part = _split(_TOP, [((0.0, 0.0), (3.0, 0.0))])
        @test _wall_area(part, 1) ≈ 24 atol = 1e-9
        @test part.columns[1].area ≈ 16 atol = 1e-9
        @test part.columns[2].area ≈ 24 atol = 1e-9
        @test _total(part) ≈ 64 atol = 1e-9
    end

    @testset "a wall through the cell carries both faces" begin
        split = split_cell_walls(_CELL, _CORNERS, [((0.0, 4.0), (8.0, 4.0))])
        # Each half is 8 × 4: its long-edge trapezoid is 12, a short-edge
        # triangle 4. A column keeps half a trapezoid and half a triangle.
        # Each half-cell's skeleton is short of 32 m² by ~3e-7 m².
        @test all(s -> isapprox(s.area, 8; atol = 1e-6), split.columns)
        @test length(split.walls) == 2
        @test all(s -> s.wall == 1 && isapprox(s.area, 16; atol = 1e-6), split.walls)
        @test _total(split) ≈ 64 atol = 1e-6

        walls = [((0.0, 4.0), (8.0, 4.0)), ((4.0, 4.0), (4.0, 8.0))]
        split2 = split_cell_walls(_CELL, _CORNERS, walls)
        @test _total(split2) ≈ 64 atol = 1e-6
        @test count(s -> s.wall == 2, split2.walls) == 2

        walls3 = [((0.0, 4.0), (4.0, 4.0)), ((8.0, 4.0), (4.0, 4.0)), ((4.0, 4.0), (4.0, 8.0))]
        split3 = split_cell_walls(_CELL, _CORNERS, walls3)
        @test _total(split3) ≈ 64 atol = 1e-6
        @test sum(s.area for s in split2.walls if s.wall == 1) ≈
              sum(s.area for s in split3.walls if s.wall in (1, 2)) atol = 1e-6

        @test_throws ArgumentError split_cell_walls(_CELL, _CORNERS, [((2.0, 4.0), (6.0, 4.0))])
    end

    @testset "uncut cell reuses the edge polygons it is given" begin
        tribs = _tribs(_CELL)
        a = split_cell_walls(_CELL, _TOP, _BOTTOM_WALL; tribs)
        b = split_cell_walls(_CELL, _TOP, _BOTTOM_WALL)
        @test [s.area for s in a.columns] ≈ [s.area for s in b.columns]
    end

    @testset "one-way partition" begin
        cell = [(0.0, 0.0), (8.0, 0.0), (8.0, 4.0), (0.0, 4.0)]
        split = _split(cell, _NO_WALLS; cell, axis = (0.0, 1.0))
        @test all(s -> s.area ≈ 8, split.columns)

        # A skew span: each half is cut along the span, so its outline holds
        # the area its load profile carries.
        skew = _split(_CORNERS, _NO_WALLS; axis = (1.0, 2.0))
        @test _total(skew) ≈ 64 atol = 1e-6
        for s in skew.columns
            @test _loop_area(s.polygon) ≈ s.area atol = 1e-6
        end
    end

    @testset "clockwise outline is refused" begin
        @test_throws ArgumentError split_cell_edges(reverse(_CELL), _tribs(_CELL), _CORNERS, _NO_WALLS)
    end

    @testset "merge pieces cut at different points" begin
        lower = [(0.0, 0.0), (4.0, 0.0), (4.0, 4.0)]
        upper = [(0.0, 0.0), (4.0, 4.0), (2.0, 4.0), (0.0, 4.0)]
        loops = SS._merge_loops([lower, upper])
        @test length(loops) == 1
        @test _loop_area(loops[1]) ≈ 16 atol = 1e-12
        @test length(loops[1]) == 4
    end

    @testset "nodal forces" begin
        piece = WallWidthPiece(0.0, 8.0, 0.0, 0.0, 4.0)
        F = wall_edge_nodal_forces([0.0, 8.0], [piece], 1000.0)
        @test sum(F) ≈ 4 * 8 * 1000 atol = 1e-6
        @test F[1] ≈ F[2] atol = 1e-6

        curved = WallWidthPiece(0.0, 8.0, 1 / 16, 0.0, 4.0)
        Fc = wall_edge_nodal_forces([0.0, 8.0], [curved], 1000.0)
        @test sum(Fc) ≈ (128 / 3) * 1000 atol = 1e-4
        @test Fc[2] > Fc[1]
    end
end
