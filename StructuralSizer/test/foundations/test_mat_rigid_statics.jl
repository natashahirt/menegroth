# Bowles 5th ed. §9-2: a rigid strip is a combined footing. Soil pressure
# is uniform and upward; column loads are downward point loads. The moment
# between the columns is negative (top steel). The moment in the column
# region is positive (bottom steel).
# corpus: textbook-bowles-foundation-analysis-design-5e, PDF pages 502–504.

using StructuralSizer
using Test
using Unitful

const SS = StructuralSizer

@testset "rigid strip moments from the shear diagram" begin
    # L = 20 ft, width = 10 ft, columns 100 kip at 2 ft and 18 ft.
    # qu = 200 kip / 200 ft² = 1 ksf, so w = 10 kip/ft.
    # M(10) = 10*(10)^2/2 − 100*(10−2) = −300 kip·ft.
    # M(2)  = 10*(2)^2/2 = 20 kip·ft.
    L = 20.0u"ft"
    width = 10.0u"ft"
    qu = 1.0ksf
    stations = [2.0u"ft", 18.0u"ft"]
    loads = [100.0kip, 100.0kip]
    mom = SS._rigid_mat_strip_moments(qu, L, width, stations, loads)
    @test ustrip(kip * u"ft", mom.M_neg) ≈ 300.0 rtol = 0.02
    @test ustrip(kip * u"ft", mom.M_pos) ≈ 20.0 rtol = 0.05
    @test mom.M_neg > mom.M_pos

    diag = SS._strip_VM_diagram(L, width, qu, stations, loads)
    @test abs(diag.M_kipft[end]) < 1.0
    @test abs(diag.V_kip[end]) < 1.0
end

@testset "mat plan grows until an offset combination is in the kern" begin
    # Equal loads. The mat centroid stays at midspan. The second combination
    # puts almost all of the load on the first column, 8.75 ft off center.
    d1 = FoundationDemand(1; Pu=100.0kip, Ps=80.0kip, c1=12.0u"inch", c2=12.0u"inch")
    d2 = FoundationDemand(2; Pu=100.0kip, Ps=80.0kip, c1=12.0u"inch", c2=12.0u"inch")
    positions = [(0.0u"ft", 0.0u"ft"), (20.0u"ft", 0.0u"ft")]
    soil = Soil(10.0ksf, 18.0u"kN/m^3", 30.0, 0.0u"kPa", 25.0u"MPa")
    opts = MatParams(; check_development=false, min_depth=18.0u"inch",
                      depth_increment=3.0u"inch", size_increment=3.0u"inch")
    demands = [d1, d2]
    plain = SS._mat_plan_sizing(positions, opts; demands=demands, soil=soil)
    newtons(F) = ustrip(u"N", F)
    service = [
        [FootingAction(:g, newtons(80.0u"kip"), 0.0, 0.0),
         FootingAction(:lat, newtons(150.0u"kip"), 0.0, 0.0)],
        [FootingAction(:g, newtons(80.0u"kip"), 0.0, 0.0),
         FootingAction(:lat, newtons(10.0u"kip"), 0.0, 0.0)],
    ]
    strength = [
        [FootingAction(:gu, newtons(100.0u"kip"), 0.0, 0.0),
         FootingAction(:lu, newtons(180.0u"kip"), 0.0, 0.0)],
        [FootingAction(:gu, newtons(100.0u"kip"), 0.0, 0.0),
         FootingAction(:lu, newtons(20.0u"kip"), 0.0, 0.0)],
    ]
    covered = SS._mat_opts_for_actions(positions, opts, demands, soil,
                                       WallLineDemand[], service, strength)
    grown = SS._mat_plan_sizing(positions, covered; demands=demands, soil=soil)
    @test grown.B > plain.B
    @test SS._mat_actions_fit(grown, service, strength, soil.qa)
    @test abs(ustrip(u"ft", grown.x_left + grown.B / 2) - 10.0) < 0.05
end

@testset "a wall line grows the mat about the wall, not toward the resultant" begin
    # Gravity samples are equal, so the wall resultant is at midspan.
    # The second combination is at 2 ft. The centroid stays at 10 ft, so
    # the overhang has to reach L/6 ≥ 8 ft: (20 + 2·oh)/6 ≥ 8, oh ≥ 14 ft.
    samples = [
        WallLineSample(0.0u"ft", 140.0u"kip", 100.0u"kip"),
        WallLineSample(20.0u"ft", 140.0u"kip", 100.0u"kip"),
    ]
    leg = WallLineDemand(1, (0.0u"ft", 0.0u"ft"), (20.0u"ft", 0.0u"ft"),
                         8.0u"inch", 10.0u"ft", samples)
    heavy = [
        WallLineSample(0.0u"ft", 252.0u"kip", 180.0u"kip"),
        WallLineSample(20.0u"ft", 28.0u"kip", 20.0u"kip"),
    ]
    leg2 = WallLineDemand(1, leg.p1, leg.p2, leg.tw, leg.hw, heavy)
    positions = NTuple{2, typeof(1.0u"ft")}[]
    demands = FoundationDemand[]
    soil = Soil(20.0ksf, 18.0u"kN/m^3", 30.0, 0.0u"kPa", 25.0u"MPa")
    opts = MatParams(; check_development = false, size_increment = 3.0u"inch")
    empty_a = Vector{FootingAction}[]
    covered = SS._mat_opts_for_actions(
        positions, opts, demands, soil, WallLineDemand[leg], empty_a, empty_a;
        wall_service = [WallLineDemand[leg2]],
        wall_strength = [WallLineDemand[leg2]])
    @test covered.edge_overhang !== nothing
    @test ustrip(u"ft", covered.edge_overhang) >= 14
end
