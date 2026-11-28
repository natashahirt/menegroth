# Minimum thickness of two-way slabs with beams, ACI 318-11 §9.5.3.3
# (corpus: aci-318-11, pages 134–135), and αf from Eq. (13-3) (page 253).
#
# Hand values use fy = 60 ksi and ln = 20 ft = 240 in, so the numerator
# ln(0.8 + fy/200000) is 1.1 × 240 = 264 in.

using Test
using Unitful
using StructuralSizer

const _ln20 = 20.0u"ft"
_in(x) = ustrip(u"inch", x)

@testset "Two-way slab with beams: minimum thickness" begin
    @testset "αf from Eq. (13-3)" begin
        # Is = 240 × 8³ / 12 = 10240 in⁴. 12000 / 10240 = 1.171875.
        αf = alpha_f(4000.0u"ksi", 12000.0u"inch^4", 4000.0u"ksi", 240.0u"inch", 8.0u"inch")
        @test isapprox(αf, 1.171875; rtol=1e-9)
        @test alpha_fm([1.0, 2.0, 3.0, 2.0]) == 2.0
        @test_throws ArgumentError alpha_fm(Float64[])
    end

    @testset "(a) αfm ≤ 0.2 uses Table 9.5(c)" begin
        # Interior ln/33 = 7.2727 in. Exterior without edge beams ln/30 = 8 in.
        @test isapprox(_in(min_thickness(TwoWay(), _ln20; alpha_fm=0.1, discontinuous_edge=false)),
                       240 / 33; rtol=1e-9)
        @test isapprox(_in(min_thickness(TwoWay(), _ln20; alpha_fm=0.1, discontinuous_edge=true)),
                       8.0; rtol=1e-9)
        # An edge beam with αf ≥ 0.8 uses the edge-beam column, equal to interior.
        @test isapprox(_in(min_thickness(TwoWay(), _ln20; alpha_fm=0.1, discontinuous_edge=true,
                                         edge_beam_alpha_f=1.0)), 240 / 33; rtol=1e-9)
        # αfm exactly 0.2 is still (a).
        @test isapprox(_in(min_thickness(TwoWay(), _ln20; alpha_fm=0.2, discontinuous_edge=false)),
                       240 / 33; rtol=1e-9)
        # fy = 50 ksi interpolates between ln/33 at 40 ksi and ln/30 at 60 ksi.
        @test isapprox(_in(min_thickness(TwoWay(), _ln20; fy=50000.0u"psi", alpha_fm=0.1,
                                         discontinuous_edge=true)),
                       (240 / 33 + 240 / 30) / 2; rtol=1e-9)
    end

    @testset "(b) Eq. (9-12)" begin
        # 264 / (36 + 5 × 1 × 0.8) = 6.6 in.
        @test isapprox(_in(min_thickness(TwoWay(), _ln20; alpha_fm=1.0, discontinuous_edge=false)),
                       6.6; rtol=1e-9)
        # (d): no qualifying edge beam, +10 percent.
        @test isapprox(_in(min_thickness(TwoWay(), _ln20; alpha_fm=1.0, discontinuous_edge=true)),
                       7.26; rtol=1e-9)
        @test isapprox(_in(min_thickness(TwoWay(), _ln20; alpha_fm=1.0, discontinuous_edge=true,
                                         edge_beam_alpha_f=0.9)), 6.6; rtol=1e-9)
        # A missing building-edge beam fails the αf ≥ 0.8 alternative, so the
        # 10% applies even when some other edge beam is stiff. 6.6 × 1.1 = 7.26.
        @test isapprox(_in(min_thickness(TwoWay(), _ln20; alpha_fm=1.0,
                                         discontinuous_edge=false, edge_beam_alpha_f=0.9,
                                         missing_edge_beam=true)), 7.26; rtol=1e-9)
        # Not less than 5 in.
        @test _in(min_thickness(TwoWay(), 10.0u"ft"; alpha_fm=1.0, discontinuous_edge=false)) == 5.0
    end

    @testset "(c) Eq. (9-13)" begin
        # 264 / (36 + 9 × 1.25) = 5.5873 in.
        @test isapprox(_in(min_thickness(TwoWay(), _ln20; alpha_fm=3.0, beta=1.25,
                                         discontinuous_edge=false)), 264 / 47.25; rtol=1e-9)
        # A wall on every side selects (c) without a computed αfm, and does
        # not add §9.5.3.3(d)'s 10% even at a discontinuous edge.
        h_wall = min_thickness(TwoWay(), _ln20; beta=1.25, wall_supported=true,
                               discontinuous_edge=true)
        @test isapprox(_in(h_wall), 264 / 47.25; rtol=1e-9)
        # Not less than 3.5 in. 132 / 47.25 = 2.79 in.
        @test _in(min_thickness(TwoWay(), 10.0u"ft"; alpha_fm=3.0, beta=1.25,
                                discontinuous_edge=false)) == 3.5
    end

    @testset "Unknown beams use the largest case" begin
        # max(ln/30 = 8.0, 1.1 × 264 / 36 = 8.0667, 5) = 8.0667 in.
        h = _in(min_thickness(TwoWay(), _ln20))
        @test isapprox(h, 1.1 * 264 / 36; rtol=1e-9)
        for αfm in (0.0, 0.1, 0.2, 0.21, 0.5, 1.0, 2.0, 2.01, 5.0), β in (1.0, 1.5, 2.0),
            edge in (false, true)
            @test h >= _in(min_thickness(TwoWay(), _ln20; alpha_fm=αfm, beta=β,
                                         discontinuous_edge=edge)) - 1e-9
        end
    end

    @testset "Inputs outside the clause throw" begin
        @test_throws ArgumentError min_thickness(TwoWay(), _ln20; beta=0.9, alpha_fm=1.0)
        @test_throws ArgumentError min_thickness(TwoWay(), _ln20; fy=80000.0u"psi")
        @test_throws ArgumentError min_thickness(TwoWay(), 0.0u"ft")
    end

    @testset "Span sizer uses the long span" begin
        # ln = 20 ft (not 16), β = 1.25, αfm = 3: 5.587 in, up to 6.0 in.
        r = StructuralSizer._size_span_floor(TwoWay(), 20.0u"ft", 1.0u"kPa", 2.0u"kPa";
                                             l2=16.0u"ft", alpha_fm=3.0, position=:interior)
        @test isapprox(uconvert(u"inch", r.thickness), 6.0u"inch"; atol=1e-6u"inch")
        r16 = StructuralSizer._size_span_floor(TwoWay(), 16.0u"ft", 1.0u"kPa", 2.0u"kPa";
                                               l2=20.0u"ft", alpha_fm=3.0, position=:interior)
        @test r16.thickness == r.thickness
    end
end
