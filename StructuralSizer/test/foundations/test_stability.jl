using StructuralSizer
using StructuralSizer: FootingAction, footing_stability_utils,
    _action_sliding_util, _action_overturning_util, _action_uplift_util,
    _stability_min_square_side, _passive_coefficient
using Unitful
using Test

# =============================================================================
# Global stability: sliding / overturning / uplift
# =============================================================================
# Demand basis: ASCE 7-22 §2.4.1 comb. 7a / §2.4.5 comb. 10 (corpus: asce-7-22).
# Resistance basis: Bowles 5e Eq. (4-3) + Table 4-5 (corpus:
# textbook-bowles-foundation-analysis-design-5e).
# =============================================================================

@testset "Global stability (sliding/overturning/uplift)" begin
    # ϕ = 30°, cohesionless, γ = 18 kN/m³. Defaults: δ = 0.5·30 = 15°,
    # cₐ = 0.6·0 = 0, passive on, γ_c = 23.6 kN/m³, 0.6D self-weight factor.
    soil = Soil(150.0u"kPa", 18.0u"kN/m^3", 30.0, 0.0u"kPa", 25.0u"MPa")
    stab = StabilityParams()
    B = 2.0u"m"; L = 2.0u"m"; h = 0.5u"m"

    @testset "passive coefficient Kp = tan²(45+φ/2)" begin
        @test _passive_coefficient(30.0) ≈ 3.0 atol = 1e-6   # tan²(60°)
        @test _passive_coefficient(0.0)  ≈ 1.0 atol = 1e-12
    end

    @testset "sliding utilization (hand calc)" begin
        # P = 1000 kN compression, H = 100 kN along x.
        # Friction = 1000·tan(15°) = 267.95 kN; passive Pp = ½·3·18·0.5²·2 = 13.5 kN.
        # R = 281.45 kN → util = 100 / 281.45 = 0.3553.
        a = FootingAction(:c7a, 1000e3, 0.0, 0.0, 100e3, 0.0)
        @test _action_sliding_util(a, B, L, h, soil, stab) ≈ 0.3553 atol = 2e-3

        # No horizontal demand → no sliding utilization.
        a0 = FootingAction(:grav, 1000e3, 0.0, 0.0, 0.0, 0.0)
        @test _action_sliding_util(a0, B, L, h, soil, stab) == 0.0

        # Resultant uses hypot(Hx, Hy): (60, 80) kN → 100 kN, same as above.
        a2 = FootingAction(:c7a_diag, 1000e3, 0.0, 0.0, 60e3, 80e3)
        @test _action_sliding_util(a2, B, L, h, soil, stab) ≈ 0.3553 atol = 2e-3
    end

    @testset "sliding under uplift: only passive resists" begin
        # Net uplift (V ≤ 0): friction and adhesion vanish, passive remains.
        # Pp = 13.5 kN, H = 10 kN → util = 10/13.5 = 0.7407.
        a = FootingAction(:uplift_h, -50e3, 0.0, 0.0, 10e3, 0.0)
        @test _action_sliding_util(a, B, L, h, soil, stab) ≈ 10e3 / 13.5e3 atol = 2e-3

        # Passive excluded + uplift + horizontal → no resistance → Inf.
        stab_np = StabilityParams(include_passive = false)
        @test _action_sliding_util(a, B, L, h, soil, stab_np) == Inf
    end

    @testset "adhesion term on cohesive soil" begin
        # Clay: ϕ = 0 (no friction), c = 50 kPa. cₐ = 0.6·50·(2·2) = 120 kN.
        # Kp = 1 → Pp = ½·1·18·0.25·2 = 4.5 kN. R = 124.5 kN; H = 60 kN.
        clay = Soil(150.0u"kPa", 18.0u"kN/m^3", 0.0, 50.0u"kPa", 20.0u"MPa")
        a = FootingAction(:c7a, 800e3, 0.0, 0.0, 60e3, 0.0)
        @test _action_sliding_util(a, B, L, h, clay, stab) ≈ 60e3 / 124.5e3 atol = 3e-3
    end

    @testset "overturning utilization (resultant eccentricity)" begin
        # Mx = 500 kN·m, P = 1000 kN → ex = 0.5 m, L/2 = 1 m → util_x = 0.5.
        a = FootingAction(:c7a, 1000e3, 500e3, 0.0, 0.0, 0.0)
        @test _action_overturning_util(a, B, L) ≈ 0.5 atol = 1e-9
        # Uplift action: overturning is handled by the uplift check → 0 here.
        au = FootingAction(:up, -100e3, 500e3, 0.0, 0.0, 0.0)
        @test _action_overturning_util(au, B, L) == 0.0
    end

    @testset "uplift utilization (self-weight resistance)" begin
        # W = 0.6·23.6·(2·2·0.5) = 28.32 kN. Tension 200 kN → util = 7.06 (fails).
        a = FootingAction(:up, -200e3, 0.0, 0.0, 0.0, 0.0)
        @test _action_uplift_util(a, B, L, h, stab) ≈ 200e3 / 28.32e3 atol = 1e-2
        # Compression → no uplift.
        ac = FootingAction(:grav, 500e3, 0.0, 0.0, 0.0, 0.0)
        @test _action_uplift_util(ac, B, L, h, stab) == 0.0
    end

    @testset "envelope takes the worst combination" begin
        actions = [
            FootingAction(:grav, 1000e3, 0.0, 0.0, 0.0, 0.0),
            FootingAction(:c7a, 1000e3, 500e3, 0.0, 100e3, 0.0),
        ]
        u = footing_stability_utils(actions, B, L, h, soil, stab)
        @test u.sliding ≈ 0.3553 atol = 2e-3
        @test u.overturning ≈ 0.5 atol = 1e-9
        @test u.uplift == 0.0
    end

    @testset "min square side grows until stability passes; monotone in H" begin
        si = 3.0u"inch"; min_B = 1.0u"m"; h0 = 0.5u"m"
        light = [FootingAction(:c7a, 1000e3, 0.0, 0.0, 50e3, 0.0)]
        heavy = [FootingAction(:c7a, 1000e3, 0.0, 0.0, 300e3, 0.0)]
        B_light = _stability_min_square_side(light, soil, stab, h0, min_B, si)
        B_heavy = _stability_min_square_side(heavy, soil, stab, h0, min_B, si)
        @test B_heavy ≥ B_light
        # At the returned size the governing action must actually pass sliding.
        @test _action_sliding_util(heavy[1], B_heavy, B_heavy, h0, soil, stab) ≤ 1.0 + 1e-9

        # Unresolvable (uplift + horizontal, passive off) throws, never silently passes.
        bad = [FootingAction(:up_h, -100e3, 0.0, 0.0, 50e3, 0.0)]
        @test_throws ErrorException _stability_min_square_side(
            bad, soil, StabilityParams(include_passive = false), h0, min_B, si; cap = 20)
    end

    @testset "spread integration: backward-compatible + reports checks" begin
        demand = FoundationDemand(1; Pu = 912.0u"kip", Ps = 670.0u"kip",
            c1 = 18.0u"inch", c2 = 18.0u"inch", shape = :rectangular)
        soil2 = Soil(5.37u"kip/ft^2", 18.0u"kN/m^3", 30.0, 0.0u"kPa", 25.0u"MPa")
        mkopts(stability) = SpreadParams(material = RC_3000_60, bar_size = 8,
            cover = 3.0u"inch", min_depth = 12.0u"inch", size_increment = 3.0u"inch",
            fc_col = 5000.0u"psi", stability = stability)

        P_svc = ustrip(u"N", 670.0u"kip")
        P_str = ustrip(u"N", 912.0u"kip")
        P_c7a = ustrip(u"N", 0.6 * 400.0u"kip")   # 0.6D on the counteracting action

        # Gravity-only service/strength actions, stability ON vs OFF: with no
        # horizontal shear or uplift the plan and result are identical, and the
        # stability checks all report 0 (not NaN).
        svc = [FootingAction(:asd, P_svc, 0.0, 0.0, 0.0, 0.0)]
        str = [FootingAction(:str, P_str, 0.0, 0.0, 0.0, 0.0)]
        off = design_footing(SpreadFooting(), demand, soil2;
            opts = mkopts(nothing), service_actions = svc, strength_actions = str)
        on = design_footing(SpreadFooting(), demand, soil2;
            opts = mkopts(StabilityParams()), service_actions = svc, strength_actions = str)
        @test on.B ≈ off.B
        @test on.D ≈ off.D
        @test on.checks.sliding == 0.0
        @test on.checks.uplift == 0.0

        # Add horizontal shear on a counteracting (0.6D) action → sliding is
        # computed, finite, and folded into the governing utilization.
        svc_h = [FootingAction(:asd, P_svc, 0.0, 0.0, 0.0, 0.0),
                 FootingAction(:c7a, P_c7a, 0.0, 0.0, 120e3, 0.0)]
        res_h = design_footing(SpreadFooting(), demand, soil2;
            opts = mkopts(StabilityParams()), service_actions = svc_h, strength_actions = str)
        @test isfinite(res_h.checks.sliding)
        @test res_h.checks.sliding > 0.0
        @test res_h.utilization ≥ res_h.checks.sliding - 1e-9

        # A horizontal shear just above the friction ceiling (V·tanδ ≈ 64 kip
        # for this 0.6D = 240 kip action) forces the plan to grow so the passive
        # term closes the gap — the footing cannot shrink. (For cohesionless
        # soil, friction is V-limited and size-independent, so growth is driven
        # by the passive term; a much larger H would be infeasible by size.)
        svc_big = [FootingAction(:asd, P_svc, 0.0, 0.0, 0.0, 0.0),
                   FootingAction(:c7a, P_c7a, 0.0, 0.0, 300e3, 0.0)]
        res_big = design_footing(SpreadFooting(), demand, soil2;
            opts = mkopts(StabilityParams()), service_actions = svc_big, strength_actions = str)
        @test res_big.B ≥ res_h.B
        @test res_big.checks.sliding ≤ 1.0 + 1e-6   # grown until it passes
    end
end
