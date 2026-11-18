# Solid heads on rib arrangements that are not rectangles.
#
# The bays around each column are cast solid, the frame is solved, and a
# failing check grows one bay. The load on the columns equals the pressure
# times the slab area. A second call matches the first. A heavier pressure
# does not shrink a head.

using Test
using Unitful
using StructuralSynthesizer
using StructuralSizer

const SY = StructuralSynthesizer
const SS = StructuralSizer

function _head_kw(; pressure)
    return (
        concrete = NWC_4000,
        depth = 0.30u"m",
        d_head = 0.24u"m",
        bw = 0.10u"m",
        d_rib = 0.18u"m",
        h_rib = 0.25u"m",
        fy = Rebar_60.Fy,
        topping = 0.08u"m",
        pressure = pressure,
    )
end

function _resolve(arr, columns, outline, holes, pressure)
    kw = _head_kw(; pressure = pressure)
    return SY.resolve_arrangement_heads(arr, columns, kw.pressure;
        outline = outline, holes = holes,
        concrete = kw.concrete, depth = kw.depth, d_head = kw.d_head,
        bw = kw.bw, d_rib = kw.d_rib, h_rib = kw.h_rib,
        fy = kw.fy, topping = kw.topping)
end

function _same_heads(a, b)
    length(a.heads) == length(b.heads) || return false
    for (p, q) in zip(a.heads, b.heads)
        p.bays == q.bays || return false
    end
    return all(zip(a.checks, b.checks)) do (p, q)
        p.ratio ≈ q.ratio && p.governing == q.governing && p.ok == q.ok
    end
end

function _check_geometry(name, arr, columns, outline, holes)
    area = sum(b.area for b in arr.bays)
    heavy = _resolve(arr, columns, outline, holes, 20_000.0)
    light = _resolve(arr, columns, outline, holes, 500.0)
    again = _resolve(arr, columns, outline, holes, 20_000.0)
    println(name, ": stop=", heavy.stop, " steps=", heavy.steps,
            " bays=", [length(h.bays) for h in heavy.heads],
            " gov=", [c.governing for c in heavy.checks],
            " ratio=", [round(c.ratio; digits = 2) for c in heavy.checks])
    @test sum(heavy.solved.reactions) ≈ 20_000.0 * area rtol = 1e-3
    @test _same_heads(heavy, again)
    @test sum(length(h.bays) for h in light.heads) <=
          sum(length(h.bays) for h in heavy.heads)
    for (xy, head) in zip(columns, heavy.heads)
        @test issubset(SS.seed_column_head(arr, xy).bays, head.bays)
    end
    @test heavy.stop in (:passed, :stopped)
    return heavy
end

@testset "solid heads grow on irregular rib plans" begin
    @testset "an L, including the re-entrant corner" begin
        L = [(0.0, 0.0), (8.0, 0.0), (8.0, 4.0), (4.0, 4.0), (4.0, 8.0), (0.0, 8.0)]
        arr = SS.modular_rib_arrangement(L; angle = 0.0, spacing = (2.0, 2.0),
                                         origin = (0.0, 0.0))
        columns = [(0.0, 0.0), (8.0, 0.0), (8.0, 4.0), (4.0, 4.0), (4.0, 8.0), (0.0, 8.0)]
        _check_geometry("L", arr, columns, L, ())
    end

    @testset "a skewed grid around a hole" begin
        outline = [(0.0, 0.0), (10.0, 0.0), (10.0, 8.0), (0.0, 8.0)]
        hole = [[(4.0, 3.0), (6.0, 3.0), (6.0, 5.0), (4.0, 5.0)]]
        arr = SS.modular_rib_arrangement(outline, hole; angle = deg2rad(25),
                                         spacing = (2.0, 2.0), origin = (0.0, 0.0))
        function nearest(target)
            best = arr.nodes[1]
            best_d = Inf
            for p in arr.nodes
                d = hypot(p[1] - target[1], p[2] - target[2])
                d < best_d || continue
                best = p
                best_d = d
            end
            return best
        end
        columns = [nearest((0.0, 0.0)), nearest((10.0, 8.0)), nearest((4.0, 3.0))]
        _check_geometry("hole", arr, columns, outline, hole)
    end

    @testset "a concave arrow" begin
        arrow = [(0.0, 0.0), (8.0, 1.5), (4.0, 3.0), (8.0, 4.5), (0.0, 6.0)]
        arr = SS.modular_rib_arrangement(arrow; angle = deg2rad(15),
                                         spacing = (2.0, 2.0))
        function nearest(target)
            best = arr.nodes[1]
            best_d = Inf
            for p in arr.nodes
                d = hypot(p[1] - target[1], p[2] - target[2])
                d < best_d || continue
                best = p
                best_d = d
            end
            return best
        end
        columns = [nearest(p) for p in arrow]
        _check_geometry("arrow", arr, columns, arrow, ())
    end
end

@testset "each rib leaving a head is checked on its own section" begin
    square = [(0.0, 0.0), (8.0, 0.0), (8.0, 8.0), (0.0, 8.0)]
    arr = SS.modular_rib_arrangement(square; angle = 0.0, spacing = (2.0, 2.0),
                                     origin = (0.0, 0.0))
    columns = [(0.0, 0.0), (8.0, 0.0), (8.0, 8.0), (0.0, 8.0)]
    heads = [SS.seed_column_head(arr, xy) for xy in columns]
    kw = _head_kw(; pressure = 20_000.0)
    solve(dims) = SY._solve_arrangement_heads(arr, heads, columns, kw.pressure;
        free_loops = (square,), concrete = kw.concrete, depth = kw.depth,
        d_head = kw.d_head, bw = kw.bw, d_rib = kw.d_rib, h_rib = kw.h_rib,
        fy = kw.fy, topping = kw.topping, column_size = 0.40u"m",
        column_height = 3.0u"m", rib_dims = dims)[2]
    m(x) = ustrip(u"m", x)
    shared = (m(kw.bw), m(kw.d_rib), m(kw.h_rib))
    base = solve(nothing)
    same = solve(fill(shared, length(arr.edges)))
    for (a, b) in zip(base, same)
        @test [r.ratio for r in a.ribs] ≈ [r.ratio for r in b.ribs]
        @test [r.ratio for r in a.hogging] ≈ [r.ratio for r in b.hogging]
    end

    # Widen only the ribs leaving the first head.
    leaving = Set(rib.path[1][1] for rib in SY._arrangement_leaving_ribs(arr, heads[1],
                                                                        length(arr.edges)))
    @test !isempty(leaving)
    dims = Union{Nothing, NTuple{3, Float64}}[e in leaving ? (2 * shared[1], shared[2], shared[3]) :
                                              shared for e in eachindex(arr.edges)]
    wide = solve(dims)
    @test all(r.bw ≈ 2 * kw.bw for r in wide[1].ribs)
    @test all(r.bw ≈ kw.bw for r in wide[2].ribs)
    # Vc doubles with bw (Eq. 11-3). The shear moves a little with the stiffer rib.
    for (a, b) in zip(base[1].ribs, wide[1].ribs)
        @test b.φVc ≈ 2 * a.φVc
        @test b.ratio < 0.6 * a.ratio
    end
end
