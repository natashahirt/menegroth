# Item 15: diagnostic populate must use sizer Chapter F φMn (LTB), not plastic Mp.
# AISC 360-16 §F2.2 (corpus: aisc-360-16, page 103); §H1.1 (page 133).

using Test
using Unitful
using StructuralSizer
using StructuralSynthesizer

@testset "Item 15: populate φMn follows sizer LTB, not plastic Mp" begin
    sec = W("W16X26")
    sec.material = A992_Steel
    Lb = 20.0u"ft"
    Cb = 1.0

    φMn_sizer = StructuralSynthesizer._steel_column_φMnx(sec, Lb; Cb = Cb)
    @test !isnothing(φMn_sizer)
    φMn_ltb = ustrip(u"N*m", get_ϕMn(sec, A992_Steel; Lb = Lb, Cb = Cb, axis = :strong))
    @test φMn_sizer ≈ φMn_ltb rtol=1e-12

    φMn_plastic = 0.9 * ustrip(u"Pa", A992_Steel.Fy) * ustrip(u"m^3", sec.Zx)
    @test φMn_ltb < 0.7 * φMn_plastic   # LTB governs on a 20 ft unbraced W16X26
    # Old path: populate returned plastic φMp; that must not match Chapter F.
    @test abs(φMn_sizer - φMn_plastic) / φMn_plastic > 0.3

    Mux = 0.5 * (φMn_ltb + φMn_plastic)
    @test Mux / φMn_ltb > 1.0           # sizer / populate interaction fails
    @test Mux / φMn_plastic < 1.0       # plastic-Mp screen would have passed

    checker = AISCChecker()
    cache = StructuralSizer.create_cache(checker, 1)
    StructuralSizer.precompute_capacities!(
        checker, cache, [sec], A992_Steel, MinWeight())
    geom = SteelMemberGeometry(ustrip(u"m", Lb);
                               Lb = ustrip(u"m", Lb), Cb = Cb, Kx = 1.0, Ky = 1.0)
    demand = MemberDemand(1; Pu_c = 0.0u"N", Mux = Mux * u"N*m")
    @test !is_feasible(checker, cache, 1, sec, A992_Steel, demand, geom)
end
