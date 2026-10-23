# Unequal strip columns: transverse Mu uses each column's own across-face.
#
# ACI 318-11 §15.4.2(a) (corpus: aci-318-11, pages 272–273) places Mu at
# the face of each concrete column. Strip width B is still floored at the
# largest across-face. Equal-column tests do not see a shared c_across_max,
# because that face is every column's face. A smaller column has a longer
# cantilever; using the large face for its band under-sizes As_trans.

using Test
using Unitful
using StructuralSizer

const SS = StructuralSizer

@testset "Unequal strip columns use each c_across for transverse Mu" begin
    # Y-strip: named c1 is across. Supports at 0 / 20 ft. Target B = 16 ft
    # so both cantilevers are long enough that flexure, not §7.12 minimum
    # steel, sets As_trans. A 5 ft strip leaves both bands on that minimum,
    # which hides a shared c_across_max. Same along-face keeps the band
    # width identical, so the steel difference is the cantilever only.
    c_small = 12.0u"inch"
    c_large = 36.0u"inch"
    c_along = 36.0u"inch"
    Pu = 80.0kip
    d_small = FoundationDemand(1; Pu=Pu, Ps=Pu, c1=c_small, c2=c_along)
    d_large = FoundationDemand(2; Pu=Pu, Ps=Pu, c1=c_large, c2=c_along)
    L_plan = 22.0u"ft"
    B_plan = 16.0u"ft"
    qa = (2 * Pu) / (B_plan * L_plan)
    soil = Soil(qa, 18.0u"kN/m^3", 30.0, 0.0u"kPa", 25.0u"MPa")
    opts = StripParams(min_depth=12.0u"inch")

    result = design_footing(StripFooting(), [d_small, d_large],
                            [0.0u"ft", 20.0u"ft"], soil;
                            opts, strip_axis=:y)

    B, d, h, L = result.B, result.d, result.D, result.L_ftg
    @test B ≥ c_large
    cant_small = (B - c_small) / 2
    cant_large = (B - c_large) / 2
    @test cant_small > cant_large
    @test cant_large ≥ zero(cant_large)

    qu = (d_small.Pu + d_large.Pu) / (B * L)
    fc = opts.material.concrete.fc′
    fy = opts.material.rebar.Fy
    ϕf = opts.ϕ_flexure

    function band_As(c_across)
        bw = c_along + d
        Mu = (qu * ((B - c_across) / 2)^2 / 2) * bw
        return max(SS._flexural_steel_footing(Mu, bw, d, fc, fy, ϕf),
                   SS._min_steel_footing(bw, h, fy))
    end

    As_own = max(band_As(c_small), band_As(c_large))
    As_shared_max = band_As(c_large)
    @test As_own > As_shared_max
    @test result.As_trans ≈ uconvert(u"m^2", As_own) rtol=1e-6
    @test !isapprox(result.As_trans, uconvert(u"m^2", As_shared_max); rtol=1e-3)
end
