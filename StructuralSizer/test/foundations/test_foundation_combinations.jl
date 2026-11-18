# ASCE 7-22 §2.3 and §2.4 at the footing, and a spread plan that grows
# when a service moment is present.
# corpus: asce-7-22, PDF pages 68–70 and 182–183.

using StructuralSizer
using Test
using Unitful

const SS = StructuralSizer

@testset "foundation combination factors" begin
    D = FootingAction(:D, 1.0e6, 0.0, 0.0)
    L = FootingAction(:L, 4.0e5, 0.0, 0.0)
    roof = FootingAction(:Lr, 0.0, 0.0, 0.0)
    wind = [FootingAction(:W, 0.0, 5.0e5, 0.0)]
    qe = [FootingAction(:QE, 0.0, 8.0e5, 0.0)]
    kw = (roof=:Lr, rho=1.0, SDS=0.5)

    service = foundation_combination_actions(
        asce7_asd_foundation_combinations, D, L, roof, wind, qe; kw...)
    strength = foundation_combination_actions(
        asce7_strength_combinations, D, L, roof, wind, qe; kw...)

    asd7 = only(filter(a -> a.label == :asd_06D_06W, service))
    @test asd7.P ≈ 0.6 * D.P
    @test asd7.Mx ≈ 0.6 * wind[1].Mx

    # §2.4.5 combo 8: 0.7 Eh and 0.7 Ev. Ev = 0.2 SDS D on the vertical
    # force only. No 25% overturning reduction (§12.13.4 is a permission).
    asd8 = only(filter(a -> a.label == :asd_D_E, service))
    Ev = 0.2 * 0.5 * D.P
    @test asd8.P ≈ D.P + 0.7 * Ev
    @test asd8.Mx ≈ 0.7 * qe[1].Mx

    # Combo 10 reverses Ev.
    asd10 = only(filter(a -> a.label == :asd_06D_E, service))
    @test asd10.P ≈ 0.6 * D.P - 0.7 * Ev
    @test asd10.Mx ≈ 0.7 * qe[1].Mx

    # Strength combo 7: 0.9D − Ev + Eh.
    str7 = only(filter(a -> a.label == :strength_0_9D_1_0E, strength))
    @test str7.P ≈ 0.9 * D.P - Ev
    @test str7.Mx ≈ qe[1].Mx

    # §2.3.1 combo 5 and §2.4.1 combo 7a never share a wind and an earthquake.
    @test !any(a -> a.label == :asd_06D_06W && a.Mx == qe[1].Mx, service)

    both = LoadCombination(; name=:both, D=1.0, W=0.6, E=0.7)
    @test_throws ArgumentError foundation_combination_actions(
        [both], D, L, roof, wind, qe; kw...)

    # Snow in combo 4a is 0.75 × 0.7, not 0.7 and not 0.75.
    @test SS.asd_D_075L.S ≈ 0.75 * 0.7
    @test SS.asd_D_075L_W.W ≈ 0.75 * 0.6
end

@testset "spread plan grows for a service moment" begin
    demand = FoundationDemand(1; Pu=912.0kip, Ps=670.0kip,
        c1=18.0u"inch", c2=18.0u"inch", shape=:rectangular)
    soil = Soil(5.37ksf, 18.0u"kN/m^3", 30.0, 0.0u"kPa", 25.0u"MPa")
    opts = SpreadParams(material=RC_3000_60, bar_size=8, cover=3.0u"inch",
                        min_depth=12.0u"inch", depth_increment=1.0u"inch",
                        size_increment=1.0u"inch", fc_col=5000.0u"psi")
    plain = design_footing(SpreadFooting(), demand, soil; opts)
    @test 130.0 <= ustrip(u"inch", plain.B) <= 138.0
    @test 30.0 <= ustrip(u"inch", plain.D) <= 34.0

    # Service moment past the kern of the gravity plan. Strength stays
    # concentric so punching is the same check on the larger plan.
    M = 1400.0kip * u"ft"
    service = [FootingAction(:svc, ustrip(u"N", 670.0kip), ustrip(u"N*m", M), 0.0)]
    strength = [FootingAction(:str, ustrip(u"N", 912.0kip), 0.0, 0.0)]
    grown = design_footing(SpreadFooting(), demand, soil; opts,
                           service_actions=service, strength_actions=strength)
    @test grown.B > plain.B
    qe = SS._eccentric_soil_pressure(670.0kip, M, 0.0kip * u"ft", grown.B, grown.L_ftg)
    @test qe.q_min ≥ 0.0u"kPa"
    @test qe.q_max ≤ soil.qa
end
