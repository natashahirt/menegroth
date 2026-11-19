using Test
using StructuralSynthesizer
const SSy = StructuralSynthesizer

@testset "rib story column bays" begin
    # 3 × 2 rectangular column grid, 9 m × 7 m bays: two quadrilaterals.
    pts = [(x, y) for y in (0.0, 7.0) for x in (0.0, 9.0, 18.0)]
    bays = SSy._column_bays(pts)
    @test length(bays) == 2
    @test all(length(b) == 4 for b in bays)
    @test all(SSy._bay_span(pts[b]) ≈ 9.0 for b in bays)

    # Bilinear surface through moving corners reproduces corner values and
    # a plane exactly.
    xy = [(0.0, 0.0), (9.0, 0.0), (9.0, 7.0), (0.0, 7.0)]
    w = [0.0, -0.002, -0.003, -0.001]
    for k in 1:4
        @test SSy._bay_surface(xy, w, xy[k]) ≈ w[k] atol = 1e-12
    end
    plane(p) = 0.001 - 2e-4 * p[1] + 3e-4 * p[2]
    p = (3.3, 5.1)
    @test SSy._bay_surface(xy, plane.(xy), p) ≈ plane(p) atol = 1e-12

    # Triangle bay: linear interpolation.
    tri = [(0.0, 0.0), (6.0, 0.0), (0.0, 8.0)]
    @test SSy._bay_surface(tri, plane.(tri), (1.0, 2.0)) ≈ plane((1.0, 2.0)) atol = 1e-12
    @test SSy._bay_span(tri) ≈ 10.0

    @test SSy._in_bay(xy, (4.5, 3.5), 1e-6)
    @test SSy._in_bay(xy, (9.0, 3.5), 1e-6)
    @test !SSy._in_bay(xy, (9.5, 3.5), 1e-6)

    # Irregular columns still tile their convex hull (column 2 is inside it).
    irr = [(0.0, 0.0), (8.0, 0.5), (16.5, 0.0), (0.3, 7.0), (8.2, 7.4), (16.0, 7.1)]
    b2 = SSy._column_bays(irr)
    q = irr[[1, 3, 6, 5, 4]]
    hull = 0.5 * abs(sum(SSy._cross2((0.0, 0.0), q[k], q[mod1(k + 1, 5)]) for k in 1:5))
    area(b) = 0.5 * sum(SSy._cross2((0.0, 0.0), irr[b[k]], irr[b[mod1(k + 1, length(b))]])
                        for k in eachindex(b))
    @test sum(area, b2) ≈ hull rtol = 1e-9
end
