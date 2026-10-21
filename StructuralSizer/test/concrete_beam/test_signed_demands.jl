# =============================================================================
# Signed RC beam demands: Mu_neg default, hogging adequacy, tension Nu
# =============================================================================
# Hand-calc oracles use ACI 318-11 Whitney block + flexure_phi and
# §11.2.2.3 Eq. (11-8). f'c = 4000 psi so β1 = 0.85.
# =============================================================================

using Test
using Unitful
using StructuralSizer
using Asap: kip, ksi

const FC_PSI = 4000.0
const FY_PSI = 60000.0
const εCU = 0.003  # ACI 318-11 §10.2.3

function _oracle_φMn(b_in, d_in, As_in)
    a = As_in * FY_PSI / (0.85 * FC_PSI * b_in)
    c = a / 0.85
    εt = c > 0 ? εCU * (d_in - c) / c : 0.0
    φ = flexure_phi(εt)
    Mn_kipft = As_in * FY_PSI * (d_in - a / 2) / 12_000.0
    return φ * Mn_kipft, εt
end

@testset "Signed RC beam demands" begin

    @testset "Mu_neg / Mux_neg default to unsigned envelope" begin
        d = RCBeamDemand(1; Mu=150.0, Vu=30.0)
        @test d.Mu == 150.0
        @test d.Mu_neg == 150.0
        d2 = RCBeamDemand(1; Mu=150.0, Mu_neg=80.0, Vu=30.0)
        @test d2.Mu_neg == 80.0
        m = MemberDemand(1; Mux=50e3)
        @test m.Mux_pos == 50e3
        @test m.Mux_neg == 50e3
        m2 = MemberDemand(1; Mux=50e3, Mux_pos=40e3, Mux_neg=20e3)
        @test m2.Mux_pos == 40e3
        @test m2.Mux_neg == 20e3
    end

    @testset "Rectangular hogging adequacy vs hand calc" begin
        sec = RCBeamSection(b=12u"inch", h=20u"inch", bar_size=8, n_bars=3)
        # 3#8 top-steel candidate (same cover / #3 stirrup as the catalog)
        db = ustrip(u"inch", rebar(8).diameter)
        Ab = ustrip(u"inch^2", rebar(8).A)
        d_stir = ustrip(u"inch", rebar(3).diameter)
        d_top = 20.0 - 1.5 - d_stir - db / 2
        As = 3 * Ab
        As_min = max(3.0 * sqrt(FC_PSI) * 12.0 * d_top / FY_PSI,
                     200.0 * 12.0 * d_top / FY_PSI)
        @test As ≥ As_min
        φMn_hand, εt_hand = _oracle_φMn(12.0, d_top, As)
        @test εt_hand ≥ 0.004

        top = required_top_steel(sec, φMn_hand; fc=4.0, fy=60.0)
        @test top !== nothing
        @test top.φMn ≥ φMn_hand * (1 - 1e-9)
        @test top.φMn ≈ _oracle_φMn(12.0, top.d_top, top.As)[1] rtol=1e-9

        checker = ACIBeamChecker(; fy_ksi=60.0, fyt_ksi=60.0)
        cache = create_cache(checker, 1)
        precompute_capacities!(checker, cache, [sec], NWC_4000, MinVolume())
        geom = ConcreteMemberGeometry(20.0u"ft")
        @test cache.φMn_neg[1] ≥ φMn_hand * (1 - 1e-6)

        ok = RCBeamDemand(1; Mu=1.0, Mu_neg=0.99 * cache.φMn_neg[1], Vu=1.0)
        bad = RCBeamDemand(1; Mu=1.0, Mu_neg=1.01 * cache.φMn_neg[1], Vu=1.0)
        @test is_feasible(checker, cache, 1, sec, NWC_4000, ok, geom)
        @test !is_feasible(checker, cache, 1, sec, NWC_4000, bad, geom)
    end

    @testset "T-beam hogging uses web width (rectangular)" begin
        rect = RCBeamSection(b=12u"inch", h=20u"inch", bar_size=8, n_bars=3)
        tbm = RCTBeamSection(bw=12u"inch", h=20u"inch", bf=48u"inch", hf=5u"inch",
                             bar_size=8, n_bars=3)
        checker = ACIBeamChecker(; fy_ksi=60.0, fyt_ksi=60.0)
        cache = create_cache(checker, 2)
        precompute_capacities!(checker, cache, [rect, tbm], NWC_4000, MinVolume())
        @test cache.φMn_neg[1] ≈ cache.φMn_neg[2] rtol=1e-9

        db = ustrip(u"inch", rebar(8).diameter)
        Ab = ustrip(u"inch^2", rebar(8).A)
        d_stir = ustrip(u"inch", rebar(3).diameter)
        d_top = 20.0 - 1.5 - d_stir - db / 2
        φMn_hand, _ = _oracle_φMn(12.0, d_top, 3 * Ab)
        @test cache.φMn_neg[2] ≥ φMn_hand * (1 - 1e-6)

        geom = ConcreteMemberGeometry(20.0u"ft")
        ok = RCBeamDemand(1; Mu=1.0, Mu_neg=0.99 * cache.φMn_neg[2], Vu=1.0)
        bad = RCBeamDemand(1; Mu=1.0, Mu_neg=1.01 * cache.φMn_neg[2], Vu=1.0)
        @test is_feasible(checker, cache, 2, tbm, NWC_4000, ok, geom)
        @test !is_feasible(checker, cache, 2, tbm, NWC_4000, bad, geom)
    end

    @testset "Tension Nu reduces Vc (ACI 318-11 Eq. 11-8)" begin
        b = 12.0u"inch"
        d = 17.56u"inch"
        fc = 4000.0u"psi"
        Ag = 12.0 * 20.0  # in²
        Nu = -50.0kip     # tension

        Vc0 = Vc_beam(b, d, fc)
        Vc_t = Vc_beam(b, d, fc; Nu=Nu, Ag=Ag * u"inch^2")
        # Eq. (11-8): Vc = 2(1 + Nu/(500 Ag)) λ √f'c bw d, Nu/Ag in psi
        axial = 1 + ustrip(u"lbf", Nu) / (500 * Ag)
        @test axial ≈ 1 - 50_000 / (500 * 240) rtol=1e-12
        @test ustrip(u"lbf", Vc_t) ≈ axial * ustrip(u"lbf", Vc0) rtol=1e-9
        @test Vc_t < Vc0

        # Floor: Vc ≥ 0 when |Nu| is large
        Vc_floor = Vc_beam(b, d, fc; Nu=-200.0kip, Ag=Ag * u"inch^2")
        @test ustrip(u"lbf", Vc_floor) == 0.0

        # Checker: Vu between φ(8√fc bd) and φ(10√fc bd) fails only in tension
        # that zeros Vc (|Nu| ≥ 0.5 Ag kip).
        sec = RCBeamSection(b=12u"inch", h=20u"inch", bar_size=8, n_bars=3)
        d_in = ustrip(u"inch", sec.d)
        b_in = 12.0
        sqrt_fc = sqrt(FC_PSI)
        φVs_max = 0.75 * 8 * sqrt_fc * b_in * d_in / 1000.0
        φVn0 = 0.75 * 10 * sqrt_fc * b_in * d_in / 1000.0
        Vu_mid = 0.5 * (φVs_max + φVn0)
        @test φVs_max < Vu_mid < φVn0

        checker = ACIBeamChecker(; fy_ksi=60.0, fyt_ksi=60.0)
        cache = create_cache(checker, 1)
        precompute_capacities!(checker, cache, [sec], NWC_4000, MinVolume())
        geom = ConcreteMemberGeometry(20.0u"ft")
        d0 = RCBeamDemand(1; Mu=1.0, Mu_neg=1.0, Vu=Vu_mid, Nu=0.0)
        dt = RCBeamDemand(1; Mu=1.0, Mu_neg=1.0, Vu=Vu_mid, Nu=-120.0)
        @test is_feasible(checker, cache, 1, sec, NWC_4000, d0, geom)
        @test !is_feasible(checker, cache, 1, sec, NWC_4000, dt, geom)

        # Edge: compression (Eq. 11-4) raises Vc above the no-axial value.
        # ACI 318-11 §11.2.1.2 — corpus: aci-318-11, page 168
        Vc_c = Vc_beam(b, d, fc; Nu=50.0kip, Ag=Ag * u"inch^2")
        @test Vc_c > Vc0
        axial_c = 1 + 50_000 / (2000 * Ag)
        @test ustrip(u"lbf", Vc_c) ≈ axial_c * ustrip(u"lbf", Vc0) rtol=1e-9
    end

    # ------------------------------------------------------------------
    # Continuous 3-span: ACI 318-11 §8.3.3 approximate moments
    # (corpus: aci-318-11, page 113). Equal spans, uniform wu, prismatic,
    # discontinuous end integral with support, more than two spans.
    # Negative moment at the first interior support governs.
    # ------------------------------------------------------------------
    @testset "3-span continuous: negative moment governs" begin
        ln_ft = 30.0
        wu_klf = 3.5
        # ACI 318-11 §8.3.3 — corpus: aci-318-11, page 113
        Mu     = wu_klf * ln_ft^2 / 14   # end-span +, integral support
        Mu_neg = wu_klf * ln_ft^2 / 10   # first-interior −, >2 spans
        Vu     = 1.15 * wu_klf * ln_ft / 2  # end member at first interior
        @test Mu ≈ 225.0 rtol=1e-12
        @test Mu_neg ≈ 315.0 rtol=1e-12
        @test Vu ≈ 60.375 rtol=1e-12
        @test Mu_neg > Mu                      # hogging governs
        @test Mu_neg / Mu ≈ 14 / 10 rtol=1e-12

        geom = ConcreteMemberGeometry(ln_ft * u"ft")
        checker = ACIBeamChecker(; fy_ksi=60.0, fyt_ksi=60.0)

        # Rectangular: catalog 5#8 in 12×20 covers sagging (φMn=255.3 > 225)
        # but hogging section-adequacy (φMn_neg=253.7) is below 315.
        # Without the Mu_neg check this section would be accepted.
        rect = RCBeamSection(b=12u"inch", h=20u"inch", bar_size=8, n_bars=5)
        cache_r = create_cache(checker, 1)
        precompute_capacities!(checker, cache_r, [rect], NWC_4000, MinVolume())
        @test cache_r.φMn[1] ≥ Mu
        @test cache_r.φMn_neg[1] < Mu_neg
        d_pos = RCBeamDemand(1; Mu=Mu, Mu_neg=0.0, Vu=Vu)
        d_3sp = RCBeamDemand(1; Mu=Mu, Mu_neg=Mu_neg, Vu=Vu)
        @test is_feasible(checker, cache_r, 1, rect, NWC_4000, d_pos, geom)
        @test !is_feasible(checker, cache_r, 1, rect, NWC_4000, d_3sp, geom)

        # T-beam, same web: flange boosts sagging (ACI 318-11 §10.2 Whitney
        # on bf) but hogging uses bw only, so negative still governs.
        tbm = RCTBeamSection(bw=12u"inch", h=20u"inch", bf=48u"inch", hf=5u"inch",
                             bar_size=8, n_bars=6)
        cache_t = create_cache(checker, 1)
        precompute_capacities!(checker, cache_t, [tbm], NWC_4000, MinVolume())
        @test cache_t.φMn[1] > cache_r.φMn[1]          # flange helps sagging
        @test cache_t.φMn_neg[1] ≈ cache_r.φMn_neg[1] rtol=1e-9
        @test cache_t.φMn[1] ≥ Mu
        @test cache_t.φMn_neg[1] < Mu_neg
        @test is_feasible(checker, cache_t, 1, tbm, NWC_4000, d_pos, geom)
        @test !is_feasible(checker, cache_t, 1, tbm, NWC_4000, d_3sp, geom)

        # Edge: unsigned default Mu_neg=Mu is conservative (both faces at 225)
        # and this 12×20 5#8 still passes — only the 1.4× hogging envelope fails.
        d_def = RCBeamDemand(1; Mu=Mu, Vu=Vu)
        @test d_def.Mu_neg == Mu
        @test is_feasible(checker, cache_r, 1, rect, NWC_4000, d_def, geom)
    end

    @testset "3-span discrete size_beams rejects hogging-inadequate catalog" begin
        ln_ft = 30.0
        wu_klf = 3.5
        Mu     = wu_klf * ln_ft^2 / 14
        Mu_neg = wu_klf * ln_ft^2 / 10
        Vu     = 1.15 * wu_klf * ln_ft / 2
        small = RCBeamSection(b=12u"inch", h=20u"inch", bar_size=8, n_bars=5)
        large = RCBeamSection(b=12u"inch", h=24u"inch", bar_size=9, n_bars=4)
        geoms = [ConcreteMemberGeometry(ln_ft * u"ft")]
        opts = ConcreteBeamOptions(custom_catalog=[small, large],
                                   deflection_limit=nothing)

        r_pos = size_beams([Mu * kip * u"ft"], [Vu * kip], geoms, opts;
                           Mu_neg=[0.0])
        @test ustrip(u"inch", r_pos.sections[1].h) ≈ 20.0
        @test r_pos.sections[1].n_bars == 5

        r_3sp = size_beams([Mu * kip * u"ft"], [Vu * kip], geoms, opts;
                           Mu_neg=[Mu_neg])
        @test ustrip(u"inch", r_3sp.sections[1].h) ≈ 24.0
        @test r_3sp.sections[1].n_bars == 4

        # Edge: catalog containing only the hogging-inadequate section throws
        # (optimize_discrete screens to empty).
        opts_small = ConcreteBeamOptions(custom_catalog=[small],
                                         deflection_limit=nothing)
        @test_throws ArgumentError size_beams([Mu * kip * u"ft"], [Vu * kip],
                                              geoms, opts_small; Mu_neg=[Mu_neg])
    end

    @testset "NLP shear uses signed Nu (Eq. 11-4 / 11-8)" begin
        # ACI 318-11 §11.2.1.2 Eq. (11-4) / §11.2.2.3 Eq. (11-8) —
        # corpus: aci-318-11, pages 168 / 170. Vc ≥ 0.
        opts = NLPBeamOptions()
        p_probe = RCBeamNLPProblem(1.0kip * u"ft", 1.0kip, opts)
        b = 12.0
        h = 20.0
        d = h - p_probe.cover_offset_in
        sqrt_fc = sqrt(FC_PSI)
        φVs_max = 0.75 * 8 * sqrt_fc * b * d / 1000.0
        φVn0 = 0.75 * 10 * sqrt_fc * b * d / 1000.0
        Vu_mid = 0.5 * (φVs_max + φVn0)
        @test φVs_max < Vu_mid < φVn0

        p0 = RCBeamNLPProblem(1.0kip * u"ft", Vu_mid * kip, opts; Nu=0.0)
        pt = RCBeamNLPProblem(1.0kip * u"ft", Vu_mid * kip, opts; Nu=-120.0kip)
        pc = RCBeamNLPProblem(1.0kip * u"ft", Vu_mid * kip, opts; Nu=50.0kip)
        x = [b, h, 0.012]
        c0 = constraint_fns(p0, x)
        ct = constraint_fns(pt, x)
        cc = constraint_fns(pc, x)
        @test c0[2] < 1.0
        @test ct[2] > 1.0
        @test cc[2] < c0[2]

        # Floor: large tension zeros Vc (Eq. 11-8, Vc ≥ 0) so φVn = φ Vs,max.
        p_floor = RCBeamNLPProblem(1.0kip * u"ft", Vu_mid * kip, opts; Nu=-200.0kip)
        @test constraint_fns(p_floor, x)[2] ≈ Vu_mid / φVs_max rtol=1e-6

        # Batch API accepts signed Nu; public default Mu_neg = Mu is unchanged.
        rs = size_rc_beams_nlp([1.0kip * u"ft"], [1.0kip], opts;
                               Mu_neg=[0.0], Nu=[-20.0kip])
        @test length(rs) == 1
        @test rs[1].status in (:optimal, :feasible, :infeasible)

        # T-beam NLP: same Vu_mid on the web, conservative Ag split.
        bf = 48.0u"inch"
        hf = 5.0u"inch"
        tp0 = RCTBeamNLPProblem(1.0kip * u"ft", Vu_mid * kip, bf, hf, opts; Nu=0.0)
        tpt = RCTBeamNLPProblem(1.0kip * u"ft", Vu_mid * kip, bf, hf, opts; Nu=-120.0kip)
        tpc = RCTBeamNLPProblem(1.0kip * u"ft", Vu_mid * kip, bf, hf, opts; Nu=50.0kip)
        xt = [b, h, 0.012]
        @test constraint_fns(tp0, xt)[2] < 1.0
        @test constraint_fns(tpt, xt)[2] > 1.0
        @test constraint_fns(tpc, xt)[2] < constraint_fns(tp0, xt)[2]

        trs = size_rc_tbeams_nlp([1.0kip * u"ft"], [1.0kip], bf, hf, opts;
                                 Mu_neg=[0.0], Nu=[-20.0kip])
        @test length(trs) == 1
        @test trs[1].status in (:optimal, :feasible, :infeasible)
    end
end
