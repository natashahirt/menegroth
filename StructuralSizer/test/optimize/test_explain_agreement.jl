# `explain_feasibility` is a separate implementation of each checker's
# `is_feasible`. The design summary reports its ratios for the section the
# optimizer chose, so the two must agree on every section and demand.

using Test
using Unitful
using StructuralSizer
using Asap: kip

"""Sections where `explain_feasibility(...).passed` differs from `is_feasible`."""
function _explain_disagreements(checker, catalog, material, demands, geom)
    cache = create_cache(checker, length(catalog))
    precompute_capacities!(checker, cache, catalog, material, MinVolume())
    out = Tuple{Int, Int}[]
    for (i, d) in enumerate(demands), (j, s) in enumerate(catalog)
        ok = is_feasible(checker, cache, j, s, material, d, geom)
        expl = explain_feasibility(checker, cache, j, s, material, d, geom)
        expl.passed == ok || push!(out, (i, j))
    end
    return out
end

@testset "explain_feasibility agrees with is_feasible" begin
    @testset "AISC W, bare steel" begin
        catalog = preferred_W()
        Nm(x) = ustrip(u"N*m", x * kip * u"ft")
        N(x) = ustrip(u"N", x * kip)
        demands = [
            MemberDemand(1; Mux=Nm(m), Mux_pos=Nm(m), Mux_neg=Nm(h), Vu_strong=N(v),
                         Pu_c=N(p), δ_max_LL=0.01, I_ref=5e-4)
            for (m, h, v, p) in ((50, 0, 10, 0), (250, 120, 60, 0), (400, 400, 90, 0),
                                 (150, 60, 30, 80), (600, 300, 150, 200))]
        checker = AISCChecker(; deflection_limit = 1/360)
        for geom in (SteelMemberGeometry(20.0u"ft"; Lb=20.0u"ft"),
                     SteelMemberGeometry(30.0u"ft"; Lb=5.0u"ft", Cb=1.14))
            @test isempty(_explain_disagreements(checker, catalog, A992_Steel, demands, geom))
        end
    end

    @testset "ACI rectangular beam" begin
        catalog = standard_rc_beams()
        demands = [RCBeamDemand(1; Mu=m, Mu_neg=h, Vu=v)
                   for (m, h, v) in ((40.0, 0.0, 15.0), (180.0, 220.0, 60.0), (450.0, 300.0, 120.0))]
        checker = ACIBeamChecker(; fy_ksi=60.0, λ=1.0)
        @test isempty(_explain_disagreements(checker, catalog, NWC_4000, demands,
                                             ConcreteMemberGeometry(8.0u"m")))
    end

    @testset "ACI column" begin
        catalog = standard_rc_columns(; sizes = 12:4:28)
        kft = kip * u"ft"
        demands = [RCColumnDemand(1; Pu=p * kip, Mux=mx * kft, Muy=my * kft,
                                  M1x=0.0 * kft, M1y=0.0 * kft)
                   for (p, mx, my) in ((100.0, 20.0, 0.0), (400.0, 150.0, 60.0),
                                       (900.0, 80.0, 80.0), (30.0, 120.0, 10.0))]
        push!(demands, RCColumnDemand(1; Pu=200.0 * kip, Mux=0.0 * kft, Muy=60.0 * kft,
                                      M1x=0.0 * kft, M1y=0.0 * kft))
        # The 9 m column puts small sections past the §6.2.5.3 δns ≤ 1.4 limit.
        for slender in (false, true), biaxial in (false, true),
            geom in (ConcreteMemberGeometry(3.66; k=1.0, braced=true),
                     ConcreteMemberGeometry(9.0; k=1.0, braced=true))
            checker = ACIColumnChecker(; include_slenderness=slender, include_biaxial=biaxial,
                                       fy_ksi=60.0, Es_ksi=29000.0)
            @test isempty(_explain_disagreements(checker, catalog, NWC_4000, demands, geom))
        end
    end
end
