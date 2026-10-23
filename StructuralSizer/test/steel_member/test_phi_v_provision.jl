# =============================================================================
# AISC 360-16 φv per-provision selection + composite signed Mux
# =============================================================================

using Test
using Unitful
using StructuralSizer
using Asap: kip, ksi

@testset "AISC φv per provision" begin
    mat = A992_Steel
    lim = 2.24 * sqrt(mat.E / mat.Fy)
    w_g21a = W("W14X82")   # stocky rolled web: h/tw ≤ 2.24√(E/Fy)
    w_slim = W("W16X26")   # light beam: h/tw above the §G2.1(a) limit
    @test w_g21a.λ_w <= lim
    @test w_slim.λ_w > lim

    Vn_s = get_Vn(w_g21a, mat; axis=:strong)
    Vn_w = get_Vn(w_g21a, mat; axis=:weak)
    @test AISCChecker().ϕ_v === nothing
    # AISC 360-16 §G2.1(a) — corpus: aisc-360-16, page 127
    @test get_ϕVn(w_g21a, mat; axis=:strong) ≈ 1.00 * Vn_s rtol=1e-12
    # AISC 360-16 §G1(a) — corpus: aisc-360-16, page 126 (weak-axis §G6)
    @test get_ϕVn(w_g21a, mat; axis=:weak) ≈ 0.90 * Vn_w rtol=1e-12
    # Rolled but outside §G2.1(a), and built-up: φv = 0.90
    Vn_slim = get_Vn(w_slim, mat; axis=:strong)
    @test get_ϕVn(w_slim, mat; axis=:strong) ≈ 0.90 * Vn_slim rtol=1e-12
    Vn_bu = get_Vn(w_g21a, mat; axis=:strong, rolled=false)
    @test get_ϕVn(w_g21a, mat; axis=:strong, rolled=false) ≈ 0.90 * Vn_bu rtol=1e-12
    # Explicit override
    @test get_ϕVn(w_g21a, mat; axis=:strong, ϕ=0.75) ≈ 0.75 * Vn_s rtol=1e-12

    hss = HSS("HSS20X12X1/2")
    @test get_ϕVn(hss, mat) ≈ 0.90 * get_Vn(hss, mat) rtol=1e-12
    # AISC 360-16 §G5 / §G1(a) — corpus: aisc-360-16, page 126
    hss_r = HSSRoundSection(6.625u"inch", 0.280u"inch"; name="HSS6.625X0.280")
    @test get_ϕVn(hss_r, mat) ≈ 0.90 * get_Vn(hss_r, mat) rtol=1e-12
end

@testset "Composite Mux_pos / Mux_neg faces" begin
    section = W("W21X55")
    material = A992_Steel
    slab = SolidSlabOnBeam(
        7.5u"inch", 4.0ksi, 3644.0ksi, 145.0u"lb/ft^3",
        29000.0ksi, 10.0u"ft", 10.0u"ft",
    )
    anchor = HeadedStudAnchor(0.75u"inch", 5.0u"inch", 65.0ksi, 50.0ksi,
                              7850.0u"kg/m^3")
    L_beam = 45.0u"ft"
    ctx = CompositeContext(slab, anchor, L_beam; shored=true)
    checker = AISCChecker()
    cache = create_cache(checker, 1)
    precompute_capacities!(checker, cache, [section], material, MinWeight())
    geom = SteelMemberGeometry(L_beam; Lb=10.0u"ft")

    Mu_ok = ustrip(u"N*m", uconvert(u"N*m", 200.0kip * u"ft"))
    Mu_huge = ustrip(u"N*m", uconvert(u"N*m", 5000.0kip * u"ft"))
    Vu = ustrip(u"N", uconvert(u"N", 40.0kip))

    d_ok = MemberDemand(1; Mux=Mu_ok, Mux_pos=Mu_ok, Mux_neg=0.0, Vu_strong=Vu)
    d_hog = MemberDemand(1; Mux=Mu_huge, Mux_pos=Mu_ok, Mux_neg=Mu_huge, Vu_strong=Vu)
    @test is_feasible(checker, cache, 1, section, material, d_ok, geom, ctx)
    @test !is_feasible(checker, cache, 1, section, material, d_hog, geom, ctx)
end

@testset "Unshored I3.1b construction checks hogging envelope" begin
    # AISC 360-16 §I3.1b — corpus: aisc-360-16, page 151
    # Steel alone must support all pre-composite loads, including hogging.
    # Mux_pos = 100 kip-ft < φMn_const ≈ 300 < Mux_neg = 400 must FAIL.
    section = W("W21X55")
    material = A992_Steel
    slab = SolidSlabOnBeam(
        7.5u"inch", 4.0ksi, 3644.0ksi, 145.0u"lb/ft^3",
        29000.0ksi, 10.0u"ft", 10.0u"ft",
    )
    anchor = HeadedStudAnchor(0.75u"inch", 5.0u"inch", 65.0ksi, 50.0ksi,
                              7850.0u"kg/m^3")
    L_beam = 45.0u"ft"
    # Lb_const chosen so Chapter F φMn sits between 100 and 400 kip-ft.
    Lb_const = 20.0u"ft"
    ϕMn_const = ustrip(u"N*m", get_ϕMn(section, material; Lb=Lb_const, Cb=1.0,
                                       axis=:strong, ϕ=0.9))
    Mux_pos = ustrip(u"N*m", uconvert(u"N*m", 100.0kip * u"ft"))
    Mux_neg = ustrip(u"N*m", uconvert(u"N*m", 400.0kip * u"ft"))
    @test Mux_pos < ϕMn_const < Mux_neg

    ctx = CompositeContext(slab, anchor, L_beam; shored=false, Lb_const=Lb_const)
    checker = AISCChecker()
    cache = create_cache(checker, 1)
    precompute_capacities!(checker, cache, [section], material, MinWeight())
    # Short span so hogging Chapter F (Lb_neg = L) reaches φMp and does not
    # mask the construction-stage failure.
    geom = SteelMemberGeometry(3.0u"ft"; Lb=3.0u"ft")
    Vu = ustrip(u"N", uconvert(u"N", 40.0kip))
    demand = MemberDemand(1; Mux=Mux_neg, Mux_pos=Mux_pos, Mux_neg=Mux_neg,
                          Vu_strong=Vu)
    @test !is_feasible(checker, cache, 1, section, material, demand, geom, ctx)

    # Same sagging with hogging below φMn_const still passes construction.
    Mux_neg_ok = ustrip(u"N*m", uconvert(u"N*m", 200.0kip * u"ft"))
    d_ok = MemberDemand(1; Mux=Mux_neg_ok, Mux_pos=Mux_pos, Mux_neg=Mux_neg_ok,
                        Vu_strong=Vu)
    @test is_feasible(checker, cache, 1, section, material, d_ok, geom, ctx)
end

@testset "Composite I3.2b hogging: steel-only vs plastic rebar" begin
    # AISC 360-16 §I3.2b — corpus: aisc-360-16, page 151
    # Default: Chapter F steel alone with Lb_neg = span L (bottom flange).
    # Alternative plastic hogging only when ctx.neg_moment (I3.2b(b) studs
    # in the negative-moment region) AND Asr/Fysr, plus I3.2b(a) brace.
    # Asr > 0 alone is not I3.2b(b).
    section = W("W21X55")
    material = A992_Steel
    @test is_compact(section, material)
    slab = SolidSlabOnBeam(
        7.5u"inch", 4.0ksi, 3644.0ksi, 145.0u"lb/ft^3",
        29000.0ksi, 10.0u"ft", 10.0u"ft",
    )
    anchor = HeadedStudAnchor(0.75u"inch", 5.0u"inch", 65.0ksi, 50.0ksi,
                              7850.0u"kg/m^3")
    L_beam = 45.0u"ft"
    # Deck-brace Lb = 3 ft reaches φMp; hogging uses Lb_neg = L = 45 ft.
    geom = SteelMemberGeometry(L_beam; Lb=3.0u"ft")
    checker = AISCChecker()
    cache = create_cache(checker, 1)
    precompute_capacities!(checker, cache, [section], material, MinWeight())

    ϕMp = 0.9 * ustrip(u"N*m", material.Fy * section.Zx)
    ϕMn_neg_L = ustrip(u"N*m", get_ϕMn(section, material; Lb=L_beam, Cb=1.0,
                                       axis=:strong, ϕ=0.9))
    @test ϕMn_neg_L < ϕMp
    Asr = 4 * 0.31u"inch^2"
    Fysr = 60.0ksi
    Mn_comp = get_Mn_negative(section, material, Asr, Fysr)
    ϕMn_comp = 0.9 * ustrip(u"N*m", Mn_comp)
    @test ϕMn_comp > ϕMp

    Mux_pos = 0.50 * ϕMp
    Vu = ustrip(u"N", uconvert(u"N", 40.0kip))

    # P1a: shored, Asr=0, Mux_neg ≈ 0.99 φMp at Lb=3 ft must FAIL
    # because Lb_neg = L = 45 ft.
    Mux_near_Mp = 0.99 * ϕMp
    d_near_Mp = MemberDemand(1; Mux=Mux_near_Mp, Mux_pos=Mux_pos,
                             Mux_neg=Mux_near_Mp, Vu_strong=Vu)
    ctx_steel = CompositeContext(slab, anchor, L_beam; shored=true)
    @test !is_feasible(checker, cache, 1, section, material, d_near_Mp, geom, ctx_steel)

    # P1b: Asr > 0 without neg_moment is not I3.2b(b). Midway Mux_neg
    # (above φMp, below composite φMn) must FAIL.
    Mux_mid = 0.5 * (ϕMp + ϕMn_comp)
    demand = MemberDemand(1; Mux=Mux_mid, Mux_pos=Mux_pos, Mux_neg=Mux_mid,
                          Vu_strong=Vu)
    ctx_rebar = CompositeContext(slab, anchor, L_beam; shored=true,
                                 Asr=Asr, Fysr=Fysr)
    @test !is_feasible(checker, cache, 1, section, material, demand, geom, ctx_rebar)

    # Even with neg_moment, Lb_neg = L = 45 ft > Lp fails I3.2b(a) Lb≤Lp.
    ctx_flag_long = CompositeContext(slab, anchor, L_beam; shored=true,
                                     Asr=Asr, Fysr=Fysr, neg_moment=true)
    @test !is_feasible(checker, cache, 1, section, material, demand, geom, ctx_flag_long)

    # Edge: Asr = 0 even with Fysr set stays on Chapter F (no alternative).
    ctx_zero = CompositeContext(slab, anchor, L_beam; shored=true,
                                Asr=0.0u"inch^2", Fysr=Fysr)
    @test !is_feasible(checker, cache, 1, section, material, demand, geom, ctx_zero)

    # Short span: Lb_neg = L ≤ Lp, so I3.2b alternative is available
    # only when neg_moment is set.
    L_short = 3.0u"ft"
    geom_s = SteelMemberGeometry(L_short; Lb=3.0u"ft")
    ctx_noflag = CompositeContext(slab, anchor, L_short; shored=true,
                                  Asr=Asr, Fysr=Fysr)
    ctx_flag = CompositeContext(slab, anchor, L_short; shored=true,
                                Asr=Asr, Fysr=Fysr, neg_moment=true)
    @test !is_feasible(checker, cache, 1, section, material, demand, geom_s, ctx_noflag)
    @test is_feasible(checker, cache, 1, section, material, demand, geom_s, ctx_flag)

    # Edge: demand above both capacities still fails with the I3.2b flag.
    Mux_over = 1.05 * ϕMn_comp
    d_over = MemberDemand(1; Mux=Mux_over, Mux_pos=Mux_pos, Mux_neg=Mux_over,
                          Vu_strong=Vu)
    @test !is_feasible(checker, cache, 1, section, material, d_over, geom_s, ctx_flag)
end

@testset "I3.2b hogging Chapter F uses Cb=1 not sagging Cb" begin
    # Break case: W21X55 A992, Lp=6.15 ft, L=10 ft, Lb=3 ft, Cb=1.67,
    # shored=true, Mux_neg≈432 kip-ft (between φMn(Cb=1)=401.9 and φMp=463.5)
    # currently PASSES with sagging Cb; must FAIL.
    # AISC 360-16 §I3.2b(a) p.151: compact AND adequately braced per Chapter F
    # = Lb≤Lp (Eq. F2-5), not Cb-inflated Mn reaching Mp.
    # AISC 360-16 §F2.2 Eq. F2-5 — corpus: aisc-360-16, page 104
    # ENGINEERING JUDGMENT: hogging uses Cb_neg=1.0 (no bottom-flange Cb field).
    section = W("W21X55")
    material = A992_Steel
    @test is_compact(section, material)
    Lp = get_Lp_Lr(section, material).Lp
    @test isapprox(ustrip(u"ft", Lp), 6.15; atol=0.05)

    L = 10.0u"ft"
    Lb = 3.0u"ft"
    Cb = 1.67
    @test L > Lp

    ϕMn_Cb1 = ustrip(u"N*m", get_ϕMn(section, material; Lb=L, Cb=1.0,
                                     axis=:strong, ϕ=0.9))
    ϕMn_Cb167 = ustrip(u"N*m", get_ϕMn(section, material; Lb=L, Cb=Cb,
                                       axis=:strong, ϕ=0.9))
    ϕMp = 0.9 * ustrip(u"N*m", material.Fy * section.Zx)
    kipft = uconvert(u"N*m", 1.0kip * u"ft")
    @test isapprox(ϕMn_Cb1 / ustrip(u"N*m", kipft), 401.9; atol=1.0)
    @test isapprox(ϕMp / ustrip(u"N*m", kipft), 463.5; atol=1.0)

    Mux_neg = ustrip(u"N*m", uconvert(u"N*m", 432.0kip * u"ft"))
    @test ϕMn_Cb1 < Mux_neg < ϕMp
    @test ϕMn_Cb167 > Mux_neg  # sagging-Cb inflation is what used to pass

    slab = SolidSlabOnBeam(
        7.5u"inch", 4.0ksi, 3644.0ksi, 145.0u"lb/ft^3",
        29000.0ksi, 10.0u"ft", 10.0u"ft",
    )
    anchor = HeadedStudAnchor(0.75u"inch", 5.0u"inch", 65.0ksi, 50.0ksi,
                              7850.0u"kg/m^3")
    ctx = CompositeContext(slab, anchor, L; shored=true)
    checker = AISCChecker()
    cache = create_cache(checker, 1)
    precompute_capacities!(checker, cache, [section], material, MinWeight())
    geom = SteelMemberGeometry(L; Lb=Lb, Cb=Cb)
    Mux_pos = 0.50 * ϕMp
    Vu = ustrip(u"N", uconvert(u"N", 40.0kip))
    demand = MemberDemand(1; Mux=Mux_neg, Mux_pos=Mux_pos, Mux_neg=Mux_neg,
                          Vu_strong=Vu)
    @test !is_feasible(checker, cache, 1, section, material, demand, geom, ctx)
end

@testset "explain_feasibility CompositeContext matches is_feasible" begin
    section = W("W21X55")
    material = A992_Steel
    slab = SolidSlabOnBeam(
        7.5u"inch", 4.0ksi, 3644.0ksi, 145.0u"lb/ft^3",
        29000.0ksi, 10.0u"ft", 10.0u"ft",
    )
    anchor = HeadedStudAnchor(0.75u"inch", 5.0u"inch", 65.0ksi, 50.0ksi,
                              7850.0u"kg/m^3")
    checker = AISCChecker()
    cache = create_cache(checker, 1)
    precompute_capacities!(checker, cache, [section], material, MinWeight())
    Vu = ustrip(u"N", uconvert(u"N", 40.0kip))

    # Construction P0: unshored hogging envelope fails I3.1b both-face.
    Lb_const = 20.0u"ft"
    ϕMn_const = ustrip(u"N*m", get_ϕMn(section, material; Lb=Lb_const, Cb=1.0,
                                       axis=:strong, ϕ=0.9))
    Mux_pos_c = ustrip(u"N*m", uconvert(u"N*m", 100.0kip * u"ft"))
    Mux_neg_c = ustrip(u"N*m", uconvert(u"N*m", 400.0kip * u"ft"))
    @test Mux_pos_c < ϕMn_const < Mux_neg_c
    ctx_c = CompositeContext(slab, anchor, 45.0u"ft"; shored=false, Lb_const=Lb_const)
    geom_c = SteelMemberGeometry(3.0u"ft"; Lb=3.0u"ft")
    d_c = MemberDemand(1; Mux=Mux_neg_c, Mux_pos=Mux_pos_c, Mux_neg=Mux_neg_c,
                       Vu_strong=Vu)
    feas_c = is_feasible(checker, cache, 1, section, material, d_c, geom_c, ctx_c)
    expl_c = explain_feasibility(checker, cache, 1, section, material, d_c, geom_c, ctx_c)
    @test feas_c == false
    @test expl_c.passed == feas_c
    @test any(c -> c.name == "construction_flexure" && !c.passed, expl_c.checks)

    # Same construction case with hogging below φMn_const still passes.
    Mux_neg_ok = ustrip(u"N*m", uconvert(u"N*m", 200.0kip * u"ft"))
    d_ok = MemberDemand(1; Mux=Mux_neg_ok, Mux_pos=Mux_pos_c, Mux_neg=Mux_neg_ok,
                        Vu_strong=Vu)
    feas_ok = is_feasible(checker, cache, 1, section, material, d_ok, geom_c, ctx_c)
    expl_ok = explain_feasibility(checker, cache, 1, section, material, d_ok, geom_c, ctx_c)
    @test feas_ok
    @test expl_ok.passed == feas_ok

    # Hogging P0: L=10 ft > Lp, Cb=1.67, Mux_neg=432 kip-ft must FAIL.
    L = 10.0u"ft"
    ϕMp = 0.9 * ustrip(u"N*m", material.Fy * section.Zx)
    Mux_neg = ustrip(u"N*m", uconvert(u"N*m", 432.0kip * u"ft"))
    ctx_h = CompositeContext(slab, anchor, L; shored=true)
    geom_h = SteelMemberGeometry(L; Lb=3.0u"ft", Cb=1.67)
    d_h = MemberDemand(1; Mux=Mux_neg, Mux_pos=0.50 * ϕMp, Mux_neg=Mux_neg,
                       Vu_strong=Vu)
    feas_h = is_feasible(checker, cache, 1, section, material, d_h, geom_h, ctx_h)
    expl_h = explain_feasibility(checker, cache, 1, section, material, d_h, geom_h, ctx_h)
    @test feas_h == false
    @test expl_h.passed == feas_h
    @test any(c -> c.name == "flexure_neg" && !c.passed, expl_h.checks)
end

@testset "6-arg is_feasible/explain hogging when composite is wired" begin
    # P0: MIP/size_beams call the 6-arg path. Wiring CompositeContext onto
    # demand.composite (no explicit ctx argument) must FAIL the same
    # W21X55 / L=10 ft / Cb=1.67 / Mux_neg=432 kip-ft case as the 8-arg.
    # AISC 360-16 §I3.2b — corpus: aisc-360-16, page 151
    # AISC 360-16 §F2.2 Eq. F2-5 — corpus: aisc-360-16, page 104
    # ENGINEERING JUDGMENT: hogging uses Cb_neg=1.0 (no bottom-flange Cb field).
    section = W("W21X55")
    material = A992_Steel
    L = 10.0u"ft"
    slab = SolidSlabOnBeam(
        7.5u"inch", 4.0ksi, 3644.0ksi, 145.0u"lb/ft^3",
        29000.0ksi, 10.0u"ft", 10.0u"ft",
    )
    anchor = HeadedStudAnchor(0.75u"inch", 5.0u"inch", 65.0ksi, 50.0ksi,
                              7850.0u"kg/m^3")
    ctx = CompositeContext(slab, anchor, L; shored=true)
    checker = AISCChecker()
    cache = create_cache(checker, 1)
    precompute_capacities!(checker, cache, [section], material, MinWeight())
    geom = SteelMemberGeometry(L; Lb=3.0u"ft", Cb=1.67)
    ϕMp = 0.9 * ustrip(u"N*m", material.Fy * section.Zx)
    Mux_neg = ustrip(u"N*m", uconvert(u"N*m", 432.0kip * u"ft"))
    Vu = ustrip(u"N", uconvert(u"N", 40.0kip))
    demand = MemberDemand(1; Mux=Mux_neg, Mux_pos=0.50 * ϕMp, Mux_neg=Mux_neg,
                          Vu_strong=Vu, composite=ctx)
    @test demand.composite === ctx

    # Six-arg call — no explicit ctx argument.
    feas = is_feasible(checker, cache, 1, section, material, demand, geom)
    expl = explain_feasibility(checker, cache, 1, section, material, demand, geom)
    @test feas == false
    @test expl.passed == false
    @test any(c -> c.name == "flexure_neg" && !c.passed, expl.checks)

    # Sentinel from SteelBeamOptions.composite=true (no slab data).
    d_sent = MemberDemand(1; Mux=Mux_neg, Mux_pos=0.50 * ϕMp, Mux_neg=Mux_neg,
                          Vu_strong=Vu, composite=true)
    feas_s = is_feasible(checker, cache, 1, section, material, d_sent, geom)
    expl_s = explain_feasibility(checker, cache, 1, section, material, d_sent, geom)
    @test feas_s == false
    @test expl_s.passed == false
    @test any(c -> c.name == "flexure_neg" && !c.passed, expl_s.checks)
end

@testset "I3.1b construction does not weaken vs unsigned Mux" begin
    # If |Mux| exceeds max(Mux_pos, Mux_neg), still check the larger value.
    # AISC 360-16 §I3.1b — corpus: aisc-360-16, page 151
    section = W("W21X55")
    material = A992_Steel
    slab = SolidSlabOnBeam(
        7.5u"inch", 4.0ksi, 3644.0ksi, 145.0u"lb/ft^3",
        29000.0ksi, 10.0u"ft", 10.0u"ft",
    )
    anchor = HeadedStudAnchor(0.75u"inch", 5.0u"inch", 65.0ksi, 50.0ksi,
                              7850.0u"kg/m^3")
    Lb_const = 20.0u"ft"
    ϕMn_const = ustrip(u"N*m", get_ϕMn(section, material; Lb=Lb_const, Cb=1.0,
                                       axis=:strong, ϕ=0.9))
    Mux_face = ustrip(u"N*m", uconvert(u"N*m", 100.0kip * u"ft"))
    Mux_env = ustrip(u"N*m", uconvert(u"N*m", 400.0kip * u"ft"))
    @test Mux_face < ϕMn_const < Mux_env

    ctx = CompositeContext(slab, anchor, 45.0u"ft"; shored=false, Lb_const=Lb_const)
    checker = AISCChecker()
    cache = create_cache(checker, 1)
    precompute_capacities!(checker, cache, [section], material, MinWeight())
    geom = SteelMemberGeometry(3.0u"ft"; Lb=3.0u"ft")
    Vu = ustrip(u"N", uconvert(u"N", 40.0kip))
    demand = MemberDemand(1; Mux=Mux_env, Mux_pos=Mux_face, Mux_neg=Mux_face,
                          Vu_strong=Vu)
    @test !is_feasible(checker, cache, 1, section, material, demand, geom, ctx)
    expl = explain_feasibility(checker, cache, 1, section, material, demand, geom, ctx)
    @test expl.passed == false
    @test any(c -> c.name == "construction_flexure" && !c.passed, expl.checks)
end

@testset "size_beams MIP wires composite hogging (6-arg path)" begin
    # Production entry: SteelBeamOptions.composite must reject W21X55 at
    # L=10 ft, Lb=3 ft, Cb=1.67, Mux_neg=432 kip-ft via the 6-arg MIP screen.
    # AISC 360-16 §I3.2b — corpus: aisc-360-16, page 151
    section = W("W21X55")
    L = 10.0u"ft"
    geom = SteelMemberGeometry(L; Lb=3.0u"ft", Cb=1.67)
    Mu = [432.0kip * u"ft"]
    Vu = [40.0kip]
    opts = SteelBeamOptions(
        composite=true,
        custom_catalog=[section],
        deflection_limit=nothing,
        total_deflection_limit=nothing,
    )
    @test_throws ArgumentError size_beams(Mu, Vu, [geom], opts; Mux_neg=Mu)

    slab = SolidSlabOnBeam(
        7.5u"inch", 4.0ksi, 3644.0ksi, 145.0u"lb/ft^3",
        29000.0ksi, 10.0u"ft", 10.0u"ft",
    )
    anchor = HeadedStudAnchor(0.75u"inch", 5.0u"inch", 65.0ksi, 50.0ksi,
                              7850.0u"kg/m^3")
    ctx = CompositeContext(slab, anchor, L; shored=true)
    @test_throws ArgumentError size_beams(Mu, Vu, [geom], opts;
                                          Mux_neg=Mu, composite=ctx)

    # Direct optimize_discrete 6-arg screen with composite wired on demand.
    checker = AISCChecker()
    Mux_neg = ustrip(u"N*m", uconvert(u"N*m", 432.0kip * u"ft"))
    ϕMp = 0.9 * ustrip(u"N*m", A992_Steel.Fy * section.Zx)
    Vu_N = ustrip(u"N", uconvert(u"N", 40.0kip))
    demand = MemberDemand(1; Mux=Mux_neg, Mux_pos=0.50 * ϕMp, Mux_neg=Mux_neg,
                          Vu_strong=Vu_N, composite=ctx)
    @test_throws ArgumentError optimize_discrete(
        checker, [demand], [geom], [section], A992_Steel;
        objective=MinWeight(), output_flag=0)
end

@testset "6-arg hogging is independent of composite sentinel" begin
    # P0: MemberDemand default composite=nothing / SteelBeamOptions()
    # composite=false must FAIL W21X55 at Mux_neg=432 kip-ft.
    # AISC 360-16 §F2.2 — corpus: aisc-360-16, page 103
    # ENGINEERING JUDGMENT: hogging uses Cb_neg=1.0 (no bottom-flange Cb field).
    section = W("W21X55")
    material = A992_Steel
    L = 10.0u"ft"
    geom = SteelMemberGeometry(L; Lb=3.0u"ft", Cb=1.67)
    checker = AISCChecker()
    cache = create_cache(checker, 1)
    precompute_capacities!(checker, cache, [section], material, MinWeight())
    ϕMp = 0.9 * ustrip(u"N*m", material.Fy * section.Zx)
    Mux_neg = ustrip(u"N*m", uconvert(u"N*m", 432.0kip * u"ft"))
    Vu = ustrip(u"N", uconvert(u"N", 40.0kip))

    # Default composite=nothing (MemberDemand constructor).
    d_default = MemberDemand(1; Mux=Mux_neg, Mux_pos=0.50 * ϕMp, Mux_neg=Mux_neg,
                             Vu_strong=Vu)
    @test d_default.composite === nothing
    feas_d = is_feasible(checker, cache, 1, section, material, d_default, geom)
    expl_d = explain_feasibility(checker, cache, 1, section, material, d_default, geom)
    @test feas_d == false
    @test expl_d.passed == false
    @test any(c -> c.name == "flexure_neg" && !c.passed, expl_d.checks)

    # Explicit composite=false.
    d_false = MemberDemand(1; Mux=Mux_neg, Mux_pos=0.50 * ϕMp, Mux_neg=Mux_neg,
                           Vu_strong=Vu, composite=false)
    feas_f = is_feasible(checker, cache, 1, section, material, d_false, geom)
    expl_f = explain_feasibility(checker, cache, 1, section, material, d_false, geom)
    @test feas_f == false
    @test expl_f.passed == false
    @test any(c -> c.name == "flexure_neg" && !c.passed, expl_f.checks)

    # optimize_discrete 6-arg screen without a composite payload.
    @test_throws ArgumentError optimize_discrete(
        checker, [d_default], [geom], [section], material;
        objective=MinWeight(), output_flag=0)

    # size_beams SteelBeamOptions() default (composite=false).
    Mu = [432.0kip * u"ft"]
    Vu_u = [40.0kip]
    opts_default = SteelBeamOptions(
        custom_catalog=[section],
        deflection_limit=nothing,
        total_deflection_limit=nothing,
    )
    @test opts_default.composite == false
    @test_throws ArgumentError size_beams(Mu, Vu_u, [geom], opts_default; Mux_neg=Mu)

    # P2: composite=[nothing] must not override opts.composite=true.
    opts_comp = SteelBeamOptions(
        composite=true,
        custom_catalog=[section],
        deflection_limit=nothing,
        total_deflection_limit=nothing,
    )
    @test_throws ArgumentError size_beams(Mu, Vu_u, [geom], opts_comp;
                                          Mux_neg=Mu, composite=[nothing])

    # Sagging-only (Mux_neg=0) still passes — hogging is not a phantom demand.
    d_sag = MemberDemand(1; Mux=Mux_neg, Mux_pos=0.50 * ϕMp, Mux_neg=0.0,
                         Vu_strong=Vu)
    @test is_feasible(checker, cache, 1, section, material, d_sag, geom)

    # P1: NLP Mux_neg uses hogging Chapter F geometry (Lb=L, Cb=1.0).
    Mux_u = [432.0kip * u"ft"]
    Mux_use, geoms_use = StructuralSizer._nlp_hogging_demands(Mux_u, Mux_u, [geom])
    @test to_meters(geoms_use[1].Lb) ≈ to_meters(L)
    @test geoms_use[1].Cb == 1.0
    @test to_newton_meters(Mux_use[1]) ≈ Mux_neg
end

@testset "size_steel_w_beam_nlp hogging Chapter F (Lb=L, Cb=1.0)" begin
    # P1: deck-braced sagging Lb/Cb must not size 432 kip-ft against φMp.
    # AISC 360-16 §F2.2 — corpus: aisc-360-16, page 103.
    # ENGINEERING JUDGMENT: hogging Cb=1.0 (no bottom-flange Cb field).
    section = W("W21X55")
    material = A992_Steel
    L = 10.0u"ft"
    geom = SteelMemberGeometry(L; Lb=3.0u"ft", Cb=1.67)
    Mu = 432.0kip * u"ft"
    Vu = 40.0kip
    opts = NLPWOptions(require_compact=true, min_depth=20.0u"inch",
                       max_depth=22.0u"inch", min_web_thickness=0.4u"inch")

    # Constructor (default Mux_neg=Mu) must use hogging Lb/Cb.
    p = SteelWBeamNLPProblem(Mu, Vu, geom, opts)
    @test p.Lb_in ≈ to_inches(L)
    @test p.Cb == 1.0
    @test p.Mu_kipft ≈ 432.0 atol=1e-6

    # Mux_neg=0 is sagging-only — keep deck-braced Lb/Cb.
    p_sag = SteelWBeamNLPProblem(Mu, Vu, geom, opts; Mux_neg=0.0)
    @test p_sag.Lb_in ≈ to_inches(3.0u"ft")
    @test p_sag.Cb == 1.67

    ϕMn_deck = ustrip(u"N*m", get_ϕMn(section, material; Lb=3.0u"ft", Cb=1.67,
                                      axis=:strong, ϕ=0.9))
    ϕMn_hog = ustrip(u"N*m", get_ϕMn(section, material; Lb=L, Cb=1.0,
                                     axis=:strong, ϕ=0.9))
    Mux_Nm = ustrip(u"N*m", uconvert(u"N*m", Mu))
    @test ϕMn_hog < Mux_Nm < ϕMn_deck

    result = size_steel_w_beam_nlp(Mu, Vu, geom, opts)
    ϕMn_result = ustrip(u"N*m", get_ϕMn(result.section, material; Lb=L, Cb=1.0,
                                        axis=:strong, ϕ=0.9))
    @test ϕMn_result >= Mux_Nm
end

@testset "6-arg H1 hogging uses ϕMn_neg not sagging ϕMnx" begin
    # P1: W21X55 Mux=Mux_neg=390 kip-ft, Pu_c=0.10 φPn, composite=nothing
    # used to pass H1 on sagging ϕMnx then Pu-blind hogging.
    # AISC 360-16 §H1.1 Eqs. H1-1a/H1-1b — corpus: aisc-360-16, page 133.
    # AISC 360-16 §F2.2 — corpus: aisc-360-16, page 103.
    # ENGINEERING JUDGMENT: hogging Cb=1.0 (no bottom-flange Cb field).
    section = W("W21X55")
    material = A992_Steel
    L = 10.0u"ft"
    geom = SteelMemberGeometry(L; Lb=3.0u"ft", Cb=1.67)
    checker = AISCChecker()
    cache = create_cache(checker, 1)
    precompute_capacities!(checker, cache, [section], material, MinWeight())

    ϕPn = min(
        ustrip(u"N", get_ϕPn(section, material, L; axis=:strong)),
        ustrip(u"N", get_ϕPn(section, material, L; axis=:weak)),
        ustrip(u"N", get_ϕPn(section, material, L; axis=:torsional)),
    )
    Pu_c = 0.10 * ϕPn
    Mux = ustrip(u"N*m", uconvert(u"N*m", 390.0kip * u"ft"))
    Vu = ustrip(u"N", uconvert(u"N", 40.0kip))
    ϕMn_neg = ustrip(u"N*m", get_ϕMn(section, material; Lb=L, Cb=1.0,
                                     axis=:strong, ϕ=0.9))
    ϕMn_sag = ustrip(u"N*m", get_ϕMn(section, material; Lb=3.0u"ft", Cb=1.67,
                                     axis=:strong, ϕ=0.9))
    ϕMny = ustrip(u"N*m", get_ϕMn(section, material; axis=:weak, ϕ=0.9))
    @test ϕMn_neg > Mux  # Pu-blind hogging would pass
    @test ϕMn_sag > Mux
    ur_neg = StructuralSizer.check_PMxMy_interaction(Pu_c, Mux, 0.0, ϕPn, ϕMn_neg, ϕMny)
    @test ur_neg > 1.0   # H1 with hogging Mcx fails

    demand = MemberDemand(1; Pu_c=Pu_c, Mux=Mux, Mux_pos=Mux, Mux_neg=Mux,
                          Vu_strong=Vu, composite=nothing)
    @test demand.composite === nothing
    @test !is_feasible(checker, cache, 1, section, material, demand, geom)
    @test_throws ArgumentError optimize_discrete(
        checker, [demand], [geom], [section], material;
        objective=MinWeight(), output_flag=0)

    expl = explain_feasibility(checker, cache, 1, section, material, demand, geom)
    @test expl.passed == false
    @test any(c -> c.name == "flexure_neg" && !c.passed, expl.checks)
    # P2: unsigned H1 is not the flexure story when hogging governs.
    @test expl.governing_check != "pm_interaction_compression"
    @test expl.governing_check == "flexure_neg"
end

@testset "CompositeContext Chapter I H1 hogging+Pu is infeasible" begin
    # Leftover: CompositeContext used to skip H1, so W21X55 at Mux_neg≈390 kip-ft
    # and Pu=0.1 φPn came back OPTIMAL. AISC 360-16 §H1.1 Eqs. H1-1a/H1-1b
    # (corpus: aisc-360-16, page 133); hogging Mcx is I3.2b / Chapter F
    # (corpus: aisc-360-16, page 151). shored=true isolates H1 from I3.1b.
    section = W("W21X55")
    material = A992_Steel
    L = 10.0u"ft"
    geom = SteelMemberGeometry(L; Lb=3.0u"ft", Cb=1.67)
    slab = SolidSlabOnBeam(
        7.5u"inch", 4.0ksi, 3644.0ksi, 145.0u"lb/ft^3",
        29000.0ksi, 10.0u"ft", 10.0u"ft")
    anchor = HeadedStudAnchor(0.75u"inch", 5.0u"inch", 65.0ksi, 50.0ksi,
                              7850.0u"kg/m^3")
    ctx = CompositeContext(slab, anchor, L; shored=true)
    checker = AISCChecker()
    cache = create_cache(checker, 1)
    precompute_capacities!(checker, cache, [section], material, MinWeight())

    ϕPn = min(
        ustrip(u"N", get_ϕPn(section, material, L; axis=:strong)),
        ustrip(u"N", get_ϕPn(section, material, L; axis=:weak)),
        ustrip(u"N", get_ϕPn(section, material, L; axis=:torsional)),
    )
    Pu_c = 0.10 * ϕPn
    Mux_neg_Nm = ustrip(u"N*m", uconvert(u"N*m", 390.0kip * u"ft"))
    Vu = ustrip(u"N", uconvert(u"N", 40.0kip))
    ϕMn_neg = ustrip(u"N*m", get_ϕMn(section, material; Lb=L, Cb=1.0,
                                     axis=:strong, ϕ=0.9))
    ϕMny = ustrip(u"N*m", get_ϕMn(section, material; axis=:weak, ϕ=0.9))
    @test ϕMn_neg > Mux_neg_Nm   # Pu-blind hogging would pass
    ur_neg = StructuralSizer.check_PMxMy_interaction(
        Pu_c, Mux_neg_Nm, 0.0, ϕPn, ϕMn_neg, ϕMny)
    @test ur_neg > 1.0           # H1 with hogging Mcx fails

    demand = MemberDemand(1; Pu_c=Pu_c, Mux=Mux_neg_Nm, Mux_pos=Mux_neg_Nm,
                          Mux_neg=Mux_neg_Nm, Vu_strong=Vu, composite=ctx)
    @test demand.composite isa CompositeContext
    @test !is_feasible(checker, cache, 1, section, material, demand, geom)
    @test_throws ArgumentError optimize_discrete(
        checker, [demand], [geom], [section], material;
        objective=MinWeight(), output_flag=0)

    expl = explain_feasibility(checker, cache, 1, section, material, demand, geom)
    @test expl.passed == false
    @test any(c -> c.name == "flexure_neg" && !c.passed, expl.checks)

    # Happy path: Pu=0 and a smaller Mux_neg still pass Chapter I flexure.
    Mux_ok = ustrip(u"N*m", uconvert(u"N*m", 200.0kip * u"ft"))
    @test Mux_ok < ϕMn_neg
    d_ok = MemberDemand(1; Pu_c=0.0, Mux=Mux_ok, Mux_pos=Mux_ok, Mux_neg=Mux_ok,
                        Vu_strong=Vu, composite=ctx)
    @test is_feasible(checker, cache, 1, section, material, d_ok, geom)
    res_ok = optimize_discrete(
        checker, [d_ok], [geom], [section], material;
        objective=MinWeight(), output_flag=0)
    @test string(res_ok.status) == "OPTIMAL"

    # Edge: Pu=0.1 φPn with Mux_neg=0 is sagging-only — hogging H1 is not a
    # phantom demand. Composite I3.2a Mcx is larger than steel-alone hogging.
    d_sag = MemberDemand(1; Pu_c=Pu_c, Mux=Mux_ok, Mux_pos=Mux_ok, Mux_neg=0.0,
                         Vu_strong=Vu, composite=ctx)
    @test is_feasible(checker, cache, 1, section, material, d_sag, geom)
end

@testset "H1.2 tension with hogging" begin
    # AISC 360-16 §H1.2 (corpus: aisc-360-16, page 134): Eqs. H1-1a/H1-1b
    # with Pc = φt Pn. Pr/Pc = 0.60 and Mrx/Mcx = 0.60 on the hogging face:
    # 0.60 + (8/9)*0.60 = 1.133. Sagging Mr = 0, so the sagging tension
    # check stays at 0.60. Compression is zero, so both compression checks
    # stay at 0.60 (H1-1b).
    urs = StructuralSizer._h1_pm_utilizations(
        0.0, 0.60, 0.0, 0.60, 0.0,
        1.0, 1.0, 1.0, 1.0, 1.0)
    @test urs.ur_t ≈ 0.60 atol=1e-12
    @test urs.ur_c_neg ≈ 0.60 atol=1e-12
    @test urs.ur_t_neg ≈ 0.60 + (8 / 9) * 0.60 atol=1e-12
    @test urs.ur_t_neg > 1.0
end
