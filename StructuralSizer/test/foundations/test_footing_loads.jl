using StructuralSizer
using Unitful
using Test

const SZ = StructuralSizer

# `FootingLoads` + the unified `design_footing` entry must reproduce the
# positional designers exactly. Phase A is an API consolidation, not a change
# in behavior, so every field of the result has to match.

_same(a, b) = (
    ustrip(u"m", SZ.footing_width(a))  ≈ ustrip(u"m", SZ.footing_width(b))  &&
    ustrip(u"m", SZ.footing_length(a)) ≈ ustrip(u"m", SZ.footing_length(b)) &&
    ustrip(u"m", SZ.footing_depth(a))  ≈ ustrip(u"m", SZ.footing_depth(b))  &&
    SZ.utilization(a) ≈ SZ.utilization(b)
)

newtons(F) = ustrip(u"N", F)
nmoment(M) = ustrip(u"N*m", M)

@testset "FootingLoads reproduces the positional spread call" begin
    demand = FoundationDemand(1; Pu=912.0kip, Ps=670.0kip,
                             c1=18.0u"inch", c2=18.0u"inch", shape=:rectangular)
    soil = Soil(5.37ksf, 18.0u"kN/m^3", 30.0, 0.0u"kPa", 25.0u"MPa")
    opts = SpreadParams(material=RC_3000_60, check_development=false)

    plain = design_footing(SpreadFooting(), demand, soil; opts=opts)
    loads = footing_loads(; demands=[demand], positions=[(0.0u"m", 0.0u"m")])
    via = design_footing(SpreadFooting(), loads, soil; opts=opts)
    @test _same(plain, via)

    # With allowable-stress and strength combinations.
    service = [FootingAction(:D, newtons(670.0u"kip"), 0.0, 0.0),
               FootingAction(:E, newtons(500.0u"kip"), nmoment(200.0u"kip*ft"), 0.0)]
    strength = [FootingAction(:Du, newtons(912.0u"kip"), 0.0, 0.0),
                FootingAction(:Eu, newtons(700.0u"kip"), nmoment(260.0u"kip*ft"), 0.0)]
    plain_a = design_footing(SpreadFooting(), demand, soil; opts=opts,
                             service_actions=service, strength_actions=strength)
    loads_a = footing_loads(; demands=[demand], positions=[(0.0u"m", 0.0u"m")],
                            column_service=[service], column_strength=[strength])
    via_a = design_footing(SpreadFooting(), loads_a, soil; opts=opts)
    @test _same(plain_a, via_a)
end

@testset "FootingLoads reproduces the positional column strip call" begin
    d1 = FoundationDemand(1; Pu=480.0kip, Ps=350.0kip, c1=24.0u"inch", c2=16.0u"inch")
    d2 = FoundationDemand(2; Pu=720.0kip, Ps=525.0kip, c1=24.0u"inch", c2=24.0u"inch")
    demands = [d1, d2]
    positions = [0.0u"ft", 18.0u"ft"]
    soil = Soil(4.37ksf, 18.0u"kN/m^3", 30.0, 0.0u"kPa", 25.0u"MPa")
    opts = StripParams(material=RC_3000_60, check_development=false)

    plain = design_footing(StripFooting(), demands, positions, soil; opts=opts, strip_axis=:x)
    loads = footing_loads(; demands=demands, positions=positions)
    via = design_footing(StripFooting(), loads, soil; opts=opts, strip_axis=:x)
    @test _same(plain, via)
end

@testset "FootingLoads reproduces the positional mat call" begin
    # Two close columns keep the Winkler mesh small so the equivalence check is
    # quick; the plan still falls below Kr = 0.5 and exercises the flexible path.
    d1 = FoundationDemand(1; Pu=300.0kip, Ps=220.0kip, c1=18.0u"inch", c2=18.0u"inch")
    d2 = FoundationDemand(2; Pu=300.0kip, Ps=220.0kip, c1=18.0u"inch", c2=18.0u"inch")
    demands = [d1, d2]
    positions = [(0.0u"ft", 0.0u"ft"), (10.0u"ft", 0.0u"ft")]
    soil = Soil(6.0ksf, 18.0u"kN/m^3", 30.0, 0.0u"kPa", 25.0u"MPa"; ks=25_000.0u"kN/m^3")
    opts = MatParams(; check_development=false, min_depth=18.0u"inch")

    plain = design_footing(MatFoundation(), demands, positions, soil; opts=opts)
    loads = footing_loads(; demands=demands, positions=positions)
    via = design_footing(MatFoundation(), loads, soil; opts=opts)
    @test _same(plain, via)
end

@testset "FootingLoads reproduces the positional wall strip call" begin
    samples = [WallLineSample(s, 1.4 * 40.0u"kip", 40.0u"kip") for s in
               (0.0u"ft", 5.0u"ft", 10.0u"ft", 15.0u"ft", 20.0u"ft")]
    leg = WallLineDemand(1, (0.0u"ft", 0.0u"ft"), (20.0u"ft", 0.0u"ft"),
                         8.0u"inch", 10.0u"ft", samples)
    soil = Soil(2.0ksf, 18.0u"kN/m^3", 30.0, 0.0u"kPa", 25.0u"MPa"; ks=25_000.0u"kN/m^3")
    opts = StripParams(material=RC_3000_60, check_development=false)

    plain = design_footing(StripFooting(), [leg], soil; opts=opts)
    loads = footing_loads(; walls=[leg])
    via = design_footing(StripFooting(), loads, soil; opts=opts)
    @test _same(plain, via)
end

@testset "footing_loads rejects misaligned inputs" begin
    d = FoundationDemand(1; Pu=100.0kip, Ps=70.0kip)
    @test_throws DimensionMismatch footing_loads(; demands=[d], positions=[])
    a = FootingAction(:D, newtons(70.0u"kip"), 0.0, 0.0)
    # Service filled, strength empty.
    @test_throws ArgumentError footing_loads(; demands=[d], positions=[(0.0u"m", 0.0u"m")],
                                             column_service=[[a]])
end
