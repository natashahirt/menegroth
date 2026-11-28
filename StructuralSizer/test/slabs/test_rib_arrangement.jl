# Ribs on any plan region: bays are the faces of the boundary and the ribs,
# and each bay's isotropic skeleton sends its whole area to the edges around
# it. ACI 318-19 §8.2.1 (corpus: aci-318-19, page 101).

using Test
using StructuralSizer

const SSA = StructuralSizer

"""Area the edge profiles of `arr` carry."""
function _carried(arr, profiles)
    total = 0.0
    for (e, (pos, w)) in profiles
        a, b = arr.edges[e]
        L = hypot(arr.nodes[b][1] - arr.nodes[a][1], arr.nodes[b][2] - arr.nodes[a][2])
        total += SSA.tributary_profile_area(L, pos, w)
    end
    return total
end

"""Two segments with the same ends, to rounding."""
_same(s, t) = all(isapprox(s[i][j], t[i][j]; atol = 1e-12) for i in 1:2, j in 1:2)

@testset "rib arrangement" begin
    rect = [(0.0, 0.0), (6.0, 0.0), (6.0, 4.0), (0.0, 4.0)]

    @testset "a rectangular grid matches the closed form" begin
        ribs = [[(3.0, 0.0), (3.0, 4.0)], [(0.0, 2.0), (6.0, 2.0)]]
        arr = SSA.rib_arrangement(rect, (), ribs)
        @test length(arr.bays) == 4
        @test all(b -> b.area ≈ 6.0, arr.bays)
        profiles = SSA.bay_edge_profiles(arr)
        @test _carried(arr, profiles) ≈ 24.0
        # The interior rib x = 3, y ∈ [0, 2] takes two 2-by-3 bays. Each gives
        # the triangle of a 2 m edge with a 3 m neighbour: peak 1 m, area 1 m².
        e = findfirst(arr.edges) do (a, b)
            Set((arr.nodes[a], arr.nodes[b])) == Set(((3.0, 0.0), (3.0, 2.0)))
        end
        pos, w = profiles[e]
        L = 2.0
        @test SSA.tributary_profile_area(L, pos, w) ≈ 2.0
        @test maximum(w) ≈ 2.0
    end

    @testset "module offsets are centered" begin
        lines = SSA.modular_rib_lines(rect; angle = 0.0, spacing = (1.5, 3.0))
        ys = sort([l.point[2] for l in lines if l.family == 1])
        xs = sort([l.point[1] for l in lines if l.family == 2])
        @test ys ≈ [1.25, 2.75]
        # 6 m at 3 m: one rib, centered, two 3 m bays.
        @test xs ≈ [3.0]
        through = SSA.modular_rib_lines(rect; angle = 0.0, spacing = (1.0, 1.0),
                                        origin = (0.5, 0.5))
        @test sort([l.point[2] for l in through if l.family == 1]) ≈ [0.5, 1.5, 2.5, 3.5]
        @test_throws ArgumentError SSA.modular_rib_lines(rect; angle = 0.0, spacing = (0.0, 1.0))
    end

    @testset "clipping keeps the line inside the region" begin
        U = [(0.0, 0.0), (6.0, 0.0), (6.0, 4.0), (4.0, 4.0), (4.0, 1.0),
             (2.0, 1.0), (2.0, 4.0), (0.0, 4.0)]
        pieces = SSA.clip_line_to_region((0.0, 2.0), (1.0, 0.0), U)
        @test length(pieces) == 2
        @test _same(pieces[1], ((0.0, 2.0), (2.0, 2.0)))
        @test _same(pieces[2], ((4.0, 2.0), (6.0, 2.0)))
        @test isempty(SSA.clip_line_to_region((0.0, 0.0), (1.0, 0.0), U))
        hole = [[(2.0, 1.0), (2.0, 3.0), (4.0, 3.0), (4.0, 1.0)]]
        around = SSA.clip_line_to_region((3.0, 0.0), (0.0, 1.0), rect, hole)
        @test length(around) == 2
        @test _same(around[1], ((3.0, 0.0), (3.0, 1.0)))
        @test _same(around[2], ((3.0, 3.0), (3.0, 4.0)))
    end

    @testset "an L-shaped region keeps its area" begin
        L = [(0.0, 0.0), (8.0, 0.0), (8.0, 3.0), (3.0, 3.0), (3.0, 7.0), (0.0, 7.0)]
        arr = SSA.modular_rib_arrangement(L; angle = 0.0, spacing = (1.0, 1.0))
        area = 8 * 3 + 3 * 4
        @test length(arr.bays) == area
        @test sum(b -> b.area, arr.bays) ≈ area
        @test _carried(arr, SSA.bay_edge_profiles(arr)) ≈ area rtol = 1e-9
    end

    @testset "an angled grid around a hole" begin
        outline = [(0.0, 0.0), (10.0, 0.0), (10.0, 7.0), (0.0, 7.0)]
        hole = [[(4.0, 2.0), (4.0, 4.0), (6.5, 4.0), (6.5, 2.0)]]
        arr = SSA.modular_rib_arrangement(outline, hole; angle = deg2rad(30),
                                          spacing = (0.9, 0.9))
        area = 70.0 - 2.0 * 2.5
        @test sum(b -> b.area, arr.bays) ≈ area rtol = 1e-9
        @test _carried(arr, SSA.bay_edge_profiles(arr)) ≈ area rtol = 1e-6
        small = SSA.undersized_bays(arr, 0.81)
        @test !isempty(small)
        @test all(k -> arr.bays[k].area < 0.405, small)
        @test length(small) < length(arr.bays)
    end

    @testset "a free-standing ring is a hole of its bay" begin
        ring = [(2.0, 1.0), (4.0, 1.0), (4.0, 3.0), (2.0, 3.0)]
        nodes = vcat(rect, ring)
        edges = [(1, 2), (2, 3), (3, 4), (4, 1), (5, 6), (6, 7), (7, 8), (8, 5)]
        arr = SSA.planar_bays(nodes, edges)
        @test length(arr.bays) == 2
        outer = only(filter(b -> !isempty(b.holes), arr.bays))
        @test outer.area ≈ 24.0 - 4.0
        @test _carried(arr, SSA.bay_edge_profiles(arr)) ≈ 24.0 rtol = 1e-6
    end

    @testset "a rib that ends inside a bay throws" begin
        nodes = vcat(rect, [(3.0, 0.0), (3.0, 2.0)])
        edges = [(1, 5), (5, 2), (2, 3), (3, 4), (4, 1), (5, 6)]
        @test_throws ArgumentError SSA.planar_bays(nodes, edges)
    end

    @testset "a rib end a millimetre off its crossing is noded" begin
        # The vertical rib stops 0.5 mm short of the horizontal rib, and the
        # horizontal rib's ends sit on the side beams. Nothing is noded yet.
        nodes = [
            (0.0, 0.0), (6.0, 0.0), (6.0, 4.0), (0.0, 4.0),
            (3.0, 0.0), (3.0, 1.9995),
            (0.0, 2.0), (6.0, 2.0),
        ]
        edges = [(1, 2), (2, 3), (3, 4), (4, 1), (5, 6), (7, 8)]
        @test_throws ArgumentError SSA.planar_bays(nodes, edges)
        xy, E, src = SSA.stitch_nodes_onto_edges(nodes, edges)
        @test length(src) == length(E)
        @test all(s -> 1 <= s <= length(edges), src)
        arr = SSA.planar_bays(xy, E)
        @test length(arr.bays) == 3
        @test sum(b.area for b in arr.bays) ≈ 24.0
    end
end
