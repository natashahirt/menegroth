using Test
using StructuralSynthesizer
using Unitful
import StructuralSizer as SS
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

@testset "rib compression-steel ladder" begin
    # `_rib_comp_ratios` sorts, de-duplicates, and always starts at 0.0.
    @test SSy._rib_comp_ratios((rib_comp_steel_ratios = Float64[],)) == [0.0]
    @test SSy._rib_comp_ratios((rib_comp_steel_ratios = [0.02, 0.01, 0.01],)) ==
          [0.0, 0.01, 0.02]
    @test SSy._rib_comp_ratios((rib_comp_steel_ratios = [0.0, 0.015],)) == [0.0, 0.015]

    # λΔ = ξ/(1+50ρ′) (ACI 318-11 §9.5.2.5, Eq. 9-11) falls as ρ′ rises, and
    # ρ′ ≈ 0.02 halves the 5-year multiplier.
    @test SS.long_term_deflection_factor(2.0, 0.0) ≈ 2.0
    @test SS.long_term_deflection_factor(2.0, 0.02) ≈ 1.0
    @test SS.long_term_deflection_factor(2.0, 0.01) ≈ 2.0 / 1.5

    # `_screen_defl_ok` summarizes a stem's deflection over the tried ρ′:
    # missing when untried, false when every tried ρ′ failed, true if any passed.
    ratios = [0.0, 0.01, 0.02]
    checked = Dict{Any, NamedTuple}()
    @test SSy._screen_defl_ok(checked, 10.0u"inch", ratios) === missing
    checked[(10.0u"inch", 0.0)] = (ok = false,)
    checked[(10.0u"inch", 0.01)] = (ok = false,)
    @test SSy._screen_defl_ok(checked, 10.0u"inch", ratios) === false
    checked[(10.0u"inch", 0.02)] = (ok = true,)
    @test SSy._screen_defl_ok(checked, 10.0u"inch", ratios) === true
end
