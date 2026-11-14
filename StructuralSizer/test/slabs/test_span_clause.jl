# One-way Table 9.5(a) and two-way αf = Eq. (13-3).
# corpus: aci-318-11, pages 131 and 253.

using Test
using Unitful
using Asap
using StructuralSizer

@testset "One-way support condition and thickness" begin
    cond = StructuralSizer.one_way_support_condition
    @test cond(:supported, :supported) == SIMPLE
    @test cond(:continuous, :supported) == ONE_END_CONT
    @test cond(:continuous, :continuous) == BOTH_ENDS_CONT
    @test cond(:free, :supported) == CANTILEVER
    @test_throws ArgumentError cond(:free, :free)

    ln = 10.0u"ft"
    h(s) = min_thickness(OneWay(), ln; fy = 60_000u"psi", support = s)
    # fy = 60 ksi, so the factor is 0.4 + 60/100 = 1.0 and h = ln / divisor.
    @test h(CANTILEVER) ≈ ln / 10
    @test h(SIMPLE) ≈ ln / 20
    @test h(ONE_END_CONT) ≈ ln / 24
    @test h(BOTH_ENDS_CONT) ≈ ln / 28
    @test h(CANTILEVER) > h(SIMPLE) > h(ONE_END_CONT) > h(BOTH_ENDS_CONT)
    @test StructuralSizer.thicker_support(BOTH_ENDS_CONT, SIMPLE) == SIMPLE
    @test StructuralSizer.thicker_support(CANTILEVER, SIMPLE) == CANTILEVER
end

@testset "Eq. 13-3 beam-to-slab stiffness" begin
    E = 4000u"ksi"
    Ib = 12.0u"inch" * (20.0u"inch")^3 / 12
    ls = 10.0u"ft"
    hs = 8.0u"inch"
    Is = StructuralSizer.slab_strip_inertia(ls, hs)
    α = StructuralSizer.beam_slab_alpha_f(E, Ib, E, Is)
    @test α ≈ ustrip(u"m^4", Ib) / ustrip(u"m^4", Is)
    @test StructuralSizer.panel_alpha_fm([α, 2α]) ≈ 1.5 * α
    @test_throws ArgumentError StructuralSizer.beam_slab_alpha_f(E, Ib, E, 0.0u"m^4")
    @test_throws ArgumentError StructuralSizer.panel_alpha_fm(Float64[])
end
