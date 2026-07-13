# ==============================================================================
# Shear-wall efficiency foundation — known-answer tests (plan S1/S2/S4)
# ==============================================================================
# Validates the differentiable analytic stiffness, the reduced rigid-diaphragm
# evaluator, its analytic sensitivities, and the ACI 318-19 in-plane shear
# capacity. The StructurePoint spWall worked example (corpus:
# sp-de-shear-wall-aci19) is used directly as a numeric known-answer oracle
# (see "spWall worked example" testset below); its exact reported values
# (φVc = 204.92, φVs = 243.00, φVn = 447.92 kips) are reproduced to <0.2 %.

# US-customary → SI conversion factors used by the corpus-oracle tests.
const _PSI = 6894.757      # Pa per psi
const _KIP = 4448.2216     # N per kip (1000 lbf)
const _IN  = 0.0254        # m per inch
const _FT  = 0.3048        # m per foot

@testset "analytic wall stiffness (S1)" begin
    E = 25e9; ν = 0.2; lw = 4.0; H = 3.0
    # In-plane stiffness is LINEAR in thickness (flexural & shear flexibility ∝ 1/t).
    k1 = wall_stiffness_from_thickness_si(0.20, lw, E, ν, H)
    k2 = wall_stiffness_from_thickness_si(0.40, lw, E, ν, H)
    @test isapprox(k2, 2k1; rtol=1e-10)
    # Closed-form derivative equals k/t.
    @test isapprox(dwall_stiffness_dthickness_si(0.20, lw, E, ν, H), k1 / 0.20; rtol=1e-10)
    # ACI 318-19 Table 6.6.3.1.1(a): cracked (0.35 Ig) softer than uncracked (0.70 Ig).
    kc = wall_stiffness_from_thickness_si(0.2, lw, E, ν, H; cracked=true)
    ku = wall_stiffness_from_thickness_si(0.2, lw, E, ν, H; cracked=false)
    @test ku > kc
    # Unitful section API agrees with the bare-SI core.
    ws = WallSection(4.0u"m", 0.2u"m")
    c  = Concrete(25e9u"Pa", 28e6u"Pa", 2400u"kg/m^3", 0.2, 0.1)
    @test isapprox(ustrip(u"N/m", wall_lateral_stiffness(ws, c, 3.0u"m")), kc; rtol=1e-8)
end

@testset "ACI 318-19 in-plane shear capacity (S1)" begin
    # Hand calc: Acv = t·lw, αc from hw/lw, Vn = (αc·λ·√f'c + ρt·fy)·Acv (psi, in).
    fc = 28e6; fy = 60e6 * 6.895; lw = 4.0; t = 0.3; ρt = 0.0025
    # hw/lw = 1.5 → αc = 3.0 (upper plateau).
    cap = wall_shear_capacity_si(fc, fy, lw, t, ρt, 6.0)
    @test cap.αc == 3.0
    # hw/lw = 2.0 → αc = 2.0 (lower plateau); linear between.
    @test wall_shear_capacity_si(fc, fy, lw, t, ρt, 8.0).αc == 2.0
    @test isapprox(wall_shear_capacity_si(fc, fy, lw, t, ρt, 7.0).αc, 2.5; rtol=1e-9)
    # φ = 0.75 relationship and positive, bounded capacity.
    @test isapprox(cap.ϕVn, 0.75 * cap.Vn; rtol=1e-9)
    @test cap.Vn <= cap.Vn_max + 1e-6
    @test cap.ϕVn > 0
    # Demand-decoupled CheckResult carries the governing clause.
    ws = WallSection(4.0u"m", 0.3u"m")
    conc = Concrete(25e9u"Pa", 28e6u"Pa", 2400u"kg/m^3", 0.2, 0.1)
    chk = check_wall_inplane_shear(ws, conc, 800e3u"N", 6.0u"m")
    @test chk.code_clause == "ACI 318-19 11.5.4.3"
    @test isapprox(chk.ratio, 800e3 / cap.ϕVn; rtol=1e-3)
end

@testset "spWall worked example — shear (ACI 318-19 §11.5.4)" begin
    # StructurePoint "Reinforced Concrete Shear Wall (ACI 318-19)", Step 5
    # (corpus: sp-de-shear-wall-aci19). 5-story wall:
    #   f'c = 4000 psi, fyt = 60 ksi, t = 10 in, lw = 18 ft (= 216 in),
    #   ρt = 0.0025, hw = 54 ft ⇒ hw/lw = 3.0 ⇒ αc = 2.0.
    # Reported: φVc = 204.92, φVs = 243.00, φVn = 447.92 kips; Vu = 121 kips.
    fc = 4000 * _PSI; fy = 60_000 * _PSI
    lw = 216 * _IN;   t  = 10 * _IN
    ρt = 0.0025;      hw = 54 * _FT
    cap = wall_shear_capacity_si(fc, fy, lw, t, ρt, hw)

    @test isapprox(cap.αc, 2.0; atol=1e-9)                       # hw/lw = 3 ≥ 2
    # Combined design shear φVn = 447.92 kips.
    @test isapprox(cap.ϕVn, 447.92 * _KIP; rtol=2e-3)
    @test isapprox(cap.Vn, (447.92 / 0.75) * _KIP; rtol=2e-3)    # Vn = 597.23 kips
    # Concrete contribution alone (ρt = 0) ⇒ φVc = 204.92 kips.
    cap_c = wall_shear_capacity_si(fc, fy, lw, t, 0.0, hw)
    @test isapprox(cap_c.ϕVn, 204.92 * _KIP; rtol=2e-3)
    # Steel contribution = combined − concrete ⇒ φVs = 243.00 kips.
    @test isapprox(cap.ϕVn - cap_c.ϕVn, 243.00 * _KIP; rtol=2e-3)
    # §11.5.4.2 cap (8√f'c·Acv) does not govern here (Vn = 597 < 1093 kips).
    @test cap.Vn < cap.Vn_max

    # Demand-decoupled check at the reported Vu = 121 kips passes comfortably.
    ws   = WallSection(lw * u"m", t * u"m"; ρl=0.00344, ρt=ρt)
    conc = Concrete(25e9u"Pa", (4000 * _PSI)u"Pa", 2400u"kg/m^3", 0.2, 0.1)
    chk  = check_wall_inplane_shear(ws, conc, (121 * _KIP)u"N", hw * u"m")
    @test chk.passed
    @test isapprox(chk.ratio, 121 / 447.92; rtol=3e-3)          # utilization ≈ 0.27
    @test chk.code_clause == "ACI 318-19 11.5.4.3"

    # Minimum web reinforcement (Step 2): ρt = 0.0025, and for hw/lw = 3.0 the
    # §11.6.2(a) longitudinal minimum collapses to the 0.0025 floor.
    minr = check_wall_min_reinforcement(ws; hw=hw * u"m")
    @test all(c.passed for c in minr)
    @test isapprox(minr[1].demand, 0.0025; atol=1e-9)           # ρl,min floor
    @test isapprox(minr[2].demand, 0.0025; atol=1e-9)           # ρt,min
end

@testset "§11.5.4.2 shear cap = 8√f'c·Acv (ACI 318-11 §11.9.3, d=0.8lw)" begin
    fc = 28e6; fy = 60_000 * _PSI; lw = 4.0; t = 0.3
    # Force the cap to govern with a very high (unphysical) transverse ratio.
    cap = wall_shear_capacity_si(fc, fy, lw, t, 0.05, 2.0)      # hw/lw = 0.5, αc = 3
    fc_psi = fc / _PSI; Acv_in2 = (lw / _IN) * (t / _IN)
    # 8·√f'c·Acv is in lbf; convert with N-per-lbf (= _KIP/1000).
    @test isapprox(cap.Vn_max, 8.0 * sqrt(fc_psi) * Acv_in2 * (_KIP / 1000); rtol=1e-9)
    @test isapprox(cap.Vn, cap.Vn_max; rtol=1e-9)              # capped
    # Edition equivalence: 8·√f'c·(lw·t) == 10·√f'c·(0.8·lw)·t.
    @test isapprox(8.0 * sqrt(fc_psi) * (lw / _IN) * (t / _IN),
                   10.0 * sqrt(fc_psi) * (0.8 * lw / _IN) * (t / _IN); rtol=1e-12)
end

@testset "§11.6.2(a) hw/lw-dependent longitudinal min reinforcement" begin
    # Squat wall (hw/lw = 1.0) with ρt = 0.005 raises the longitudinal minimum:
    #   ρl,min = 0.0025 + 0.5·(2.5 − 1.0)·(0.005 − 0.0025) = 0.004375.
    ws = WallSection(4.0u"m", 0.3u"m"; ρl=0.003, ρt=0.005)
    minr = check_wall_min_reinforcement(ws; hw=4.0u"m")
    @test isapprox(minr[1].demand, 0.004375; atol=1e-9)
    @test !minr[1].passed                       # ρl = 0.003 < 0.004375
    @test minr[2].passed                        # ρt = 0.005 ≥ 0.0025
    @test minr[1].code_clause == "ACI 318-19 11.6.2(a)"
    # Without hw the coupling term collapses to the 0.0025 floor (ρl passes).
    @test all(c.passed for c in check_wall_min_reinforcement(ws))
end

@testset "spWall worked example — axial-flexure P-M (ACI 318-19 §22.2)" begin
    # StructurePoint "Reinforced Concrete Shear Wall (ACI 318-19)", Sections 3-4
    # (corpus: sp-de-shear-wall-aci19, lines 350-543). Cardenas closed form:
    #   f'c=4000 psi, fy=60 ksi, Es=29000 ksi, t=10 in, lw=18 ft (=216 in),
    #   ρl=0.00344 (#5@18" both faces, Ast=7.44 in²); Nu=207 kips, Mu=4665 kip-ft.
    # Reported: ω=0.0517, α=0.0240, c=19.78 in, T=405.52 kips, Mn=5342 kip-ft,
    #           φMn=4808 kip-ft (tension-controlled, φ=0.90).
    fc = 4000 * _PSI; fy = 60_000 * _PSI; Es = 29e6 * _PSI
    lw = 216 * _IN;   t  = 10 * _IN;      ρl = 0.00344
    Nu = 207 * _KIP
    KIPFT = _KIP * 12 * _IN                      # N·m per kip-ft

    r = wall_axial_flexure_capacity_si(fc, fy, Es, lw, t, ρl, Nu)
    @test isapprox(r.ω, 0.0517; rtol=5e-3)
    @test isapprox(r.α, 0.0240; rtol=1e-2)
    @test isapprox(r.β1, 0.85; atol=1e-9)                    # Table 22.2.2.4.3, f'c=4000
    @test isapprox(r.c / _IN, 19.78; rtol=1e-2)              # neutral axis
    @test isapprox(r.T / _KIP, 405.52; rtol=1e-2)            # tension resultant
    @test isapprox(r.Mn / KIPFT, 5342.0; rtol=1e-2)          # nominal moment
    @test isapprox(r.φMn / KIPFT, 4808.0; rtol=1e-2)         # design moment
    @test r.tension_controlled && r.φ == 0.90               # εt ≫ εty+0.003
    @test isapprox(r.εty, 0.00207; rtol=1e-2)               # Eq. 5.3.1f
    @test r.εt > r.εty + 0.003

    # Demand-decoupled CheckResult: φMn=4808 > Mu=4665 ⇒ adequate.
    ws  = WallSection(lw * u"m", t * u"m"; ρl=ρl, ρt=0.0025)
    Mu  = 4665 * KIPFT
    chk = check_wall_inplane_flexure(ws, RC_4000_60, Nu * u"N", Mu * u"N*m")
    @test chk.passed
    @test isapprox(chk.ratio, 4665 / 4808; atol=0.02)       # utilization ≈ 0.971
    @test chk.code_clause == "ACI 318-19 22.2 / Table 21.2.2"

    # Independent method: strain-compatibility interaction diagram must agree to
    # ~5% AND be no less conservative than the Cardenas closed form used for the
    # check (the diagram is the spColumn-style, less-conservative curve).
    Ast = ρl * lw * t
    d = wall_moment_capacity_at_axial_si(fc, fy, Es, lw, t, Ast, Nu; nlayers=200)
    @test isapprox(d.φMn / KIPFT, r.φMn / KIPFT; rtol=0.05)
    @test d.φMn >= r.φMn * 0.99                              # Cardenas conservative
    @test d.φ == 0.90
end

@testset "wall P-M physical behavior + edge cases" begin
    fc = 4000 * _PSI; fy = 60_000 * _PSI; Es = 29e6 * _PSI
    lw = 216 * _IN; t = 10 * _IN; ρl = 0.006
    KIPFT = _KIP * 12 * _IN

    # More axial (compression) ⇒ deeper neutral axis and higher moment capacity
    # in the tension-controlled regime (axial closes cracks).
    r0  = wall_axial_flexure_capacity_si(fc, fy, Es, lw, t, ρl, 0.0)
    r1  = wall_axial_flexure_capacity_si(fc, fy, Es, lw, t, ρl, 300 * _KIP)
    @test r1.c > r0.c
    @test r1.Mn > r0.Mn
    @test r0.Mn > 0

    # More longitudinal steel ⇒ more moment capacity.
    rmore = wall_axial_flexure_capacity_si(fc, fy, Es, lw, t, 0.010, 0.0)
    @test rmore.Mn > r0.Mn

    # β1 tracks f'c per Table 22.2.2.4.3 (0.85 at ≤4000, 0.65 at ≥8000 psi).
    r8 = wall_axial_flexure_capacity_si(8000*_PSI, fy, Es, lw, t, ρl, 0.0)
    @test isapprox(r8.β1, 0.65; atol=1e-9)
    r6 = wall_axial_flexure_capacity_si(6000*_PSI, fy, Es, lw, t, ρl, 0.0)
    @test isapprox(r6.β1, 0.75; atol=1e-9)

    # Strain-compat interaction: pure-bending capacity (Nu=0) is positive and the
    # solved axial matches the requested target (root-find sanity).
    Ast = ρl * lw * t
    dpb = wall_moment_capacity_at_axial_si(fc, fy, Es, lw, t, Ast, 0.0; nlayers=100)
    @test dpb.Mn > 0
    dhi = wall_moment_capacity_at_axial_si(fc, fy, Es, lw, t, Ast, 500 * _KIP; nlayers=100)
    @test isapprox(wall_pm_at_c_si(fc, fy, Es, lw, t, Ast, dhi.c; nlayers=100).Pn,
                   500 * _KIP; rtol=1e-2)

    # A plain Concrete requires explicit fy/Es (guard against silent wrong steel).
    ws = WallSection(lw*u"m", t*u"m"; ρl=ρl, ρt=0.0025)
    conc = Concrete(25e9u"Pa", (fc)u"Pa", 2400u"kg/m^3", 0.2, 0.1)
    @test_throws ErrorException check_wall_inplane_flexure(ws, conc, 0.0, 1.0e6)
    # Safety: bare (unitless) fy/Es are REJECTED (ksi/Pa mismatch footgun).
    @test_throws ErrorException check_wall_inplane_flexure(ws, conc, 0.0, 1.0e6; fy=60.0, Es=29000.0)
    # Unitful fy/Es are the one accepted spelling.
    chk = check_wall_inplane_flexure(ws, conc, 0.0, 1.0e6;
                                     fy=(60_000*_PSI)u"Pa", Es=(29e6*_PSI)u"Pa")
    @test chk.capacity > 0

    # ACI 318-19 §22.4.2.1 axial cap: an over-compressed wall fails on AXIAL,
    # not on the moment term. Nu just above φ·0.80·P0 must fail with that clause.
    ax = wall_pure_axial_capacity_si(fc, fy, lw, t, ρl)
    φPn_max = 0.65 * ax.Pn_max
    chk_hi = check_wall_inplane_flexure(ws, RC_4000_60, (1.05*φPn_max)u"N", 1.0u"N*m")
    @test !chk_hi.passed
    @test chk_hi.code_clause == "ACI 318-19 22.4.2.1"
    # Just below the cap with negligible moment passes.
    chk_lo = check_wall_inplane_flexure(ws, RC_4000_60, (0.5*φPn_max)u"N", 1.0u"N*m")
    @test chk_lo.code_clause == "ACI 318-19 22.2 / Table 21.2.2"

    # Diagram solver fails safe (converged=false, φMn=0) above the squash load.
    Ast2 = ρl * lw * t
    over = wall_moment_capacity_at_axial_si(fc, fy, Es, lw, t, Ast2, 100*ax.P0; nlayers=60)
    @test over.converged == false
    @test over.φMn == 0.0
end

@testset "reduced diaphragm: symmetric core (S2)" begin
    k = 1e7
    walls = [WallLine(1, 0.0, -5.0, 0.0, k, 1), WallLine(2, 0.0, 5.0, 0.0, k, 1),
             WallLine(3, -5.0, 0.0, pi/2, k, 1), WallLine(4, 5.0, 0.0, pi/2, k, 1)]
    ev = ReducedDiaphragmEvaluator(story_heights=[3.0], plan_halfwidth=(5.0, 5.0),
                                   accidental_ecc=0.0)
    Fx = 1e5
    res = evaluate_lateral(ev, walls, [StoryLoad(1, Fx, 0.0, 0.0, 0.0)])
    δx = res.story_disp[1, 1]
    @test isapprox(δx, Fx / (2k); rtol=1e-6)                     # V = Σk·δ
    @test isapprox(res.drift[1], δx / 3.0; rtol=1e-6)
    @test isapprox(res.wall_forces[1] + res.wall_forces[2], Fx; rtol=1e-6)
    @test isapprox(res.wall_forces[1], res.wall_forces[2]; rtol=1e-9)   # equal split, no torsion
    @test isapprox(res.wall_forces[3], 0.0; atol=1.0)                   # transverse walls unloaded
    @test res.torsion[1] ≈ 1.0 atol=1e-6
end

@testset "reduced diaphragm: accidental eccentricity → torsion (S2)" begin
    k = 1e7
    walls = [WallLine(1, 0.0, -5.0, 0.0, k, 1), WallLine(2, 0.0, 5.0, 0.0, k, 1),
             WallLine(3, -5.0, 0.0, pi/2, k, 1), WallLine(4, 5.0, 0.0, pi/2, k, 1)]
    ev = ReducedDiaphragmEvaluator(story_heights=[3.0], plan_halfwidth=(5.0, 5.0),
                                   accidental_ecc=0.05)
    res = evaluate_lateral(ev, walls, [StoryLoad(1, 1e5, 0.0, 0.0, 0.0)])
    @test isapprox(res.wall_forces[1] + res.wall_forces[2], 1e5; rtol=1e-6)  # equilibrium holds
    @test !isapprox(res.wall_forces[1], res.wall_forces[2]; rtol=1e-3)       # unequal (torsion)
    @test res.torsion[1] > 1.0
end

@testset "reduced diaphragm: analytic sensitivity vs FD (S2)" begin
    k0 = 1e7
    mk(kv) = [WallLine(1, 0.0, -5.0, 0.0, kv, 1), WallLine(2, 0.0, 5.0, 0.0, kv, 1),
              WallLine(3, -5.0, 0.0, pi/2, kv, 1), WallLine(4, 5.0, 0.0, pi/2, kv, 1)]
    ev = ReducedDiaphragmEvaluator(story_heights=[3.0], plan_halfwidth=(5.0, 5.0),
                                   accidental_ecc=0.0)
    loads = [StoryLoad(1, 1e5, 0.0, 0.0, 0.0)]
    sens = story_drift_sensitivity(ev, mk(k0), loads, 1)
    h = k0 * 1e-6
    wp = mk(k0); wp[1] = WallLine(1, 0.0, -5.0, 0.0, k0 + h, 1)
    wm = mk(k0); wm[1] = WallLine(1, 0.0, -5.0, 0.0, k0 - h, 1)
    fd = (evaluate_lateral(ev, wp, loads).drift[1] -
          evaluate_lateral(ev, wm, loads).drift[1]) / (2h)
    @test isapprox(sens[1], fd; rtol=1e-4)
    @test sens[1] < 0    # a stiffer wall reduces drift
end

@testset "layout NLP problem wiring (S4)" begin
    # A minimal ground structure: build the problem and exercise the
    # AbstractNLPProblem interface (objective/constraints are finite & smooth).
    cand = [WallCandidate(i, x, y, θ, 4.0, 3.0, 1, 25e9, 0.2, 28e6, 60e6*6.895,
                          2400.0, 0.1, 0.4, 0.0025)
            for (i, (x, y, θ)) in enumerate([(0.0,-5.0,0.0), (0.0,5.0,0.0),
                                             (-5.0,0.0,pi/2), (5.0,0.0,pi/2)])]
    ev = ReducedDiaphragmEvaluator(story_heights=[3.0], plan_halfwidth=(5.0, 5.0))
    loads = [StoryLoad(1, 1e5, 0.0, 0.0, 0.0)]
    prob = WallLayoutNLPProblem(cand, ev, loads; objective=MinCarbon())
    @test n_variables(prob) == 4
    @test n_constraints(prob) == 2 * 1 + 4        # drift + torsion + per-wall strength
    lo, hi = variable_bounds(prob)
    @test all(hi .== 1.0)
    x0 = initial_guess(prob)
    @test length(x0) == 4
    obj = objective_fn(prob, x0)
    @test obj > 0 && isfinite(obj)                # carbon linear in density
    # MinCarbon is monotone in density.
    @test objective_fn(prob, fill(1.0, 4)) > objective_fn(prob, fill(0.5, 4))
    g = constraint_fns(prob, x0)
    @test length(g) == n_constraints(prob)
    @test all(isfinite, g)
    # Objective swap requires only a new AbstractObjective (not solver/problem).
    prob_d = WallLayoutNLPProblem(cand, ev, loads; objective=MinDrift())
    @test isfinite(objective_fn(prob_d, x0))
    prob_w = WallLayoutNLPProblem(cand, ev, loads;
                                  objective=WeightedLayoutObjective(1.0, 1.0, 1e3, 0.02))
    @test isfinite(objective_fn(prob_w, x0))
end

@testset "FEM evaluator vs reduced-model oracle (S3)" begin
    # Symmetric 4-wall core, 1 story. FEM (Asap shells + stiff diaphragm) must
    # equilibrate the applied shear and agree with the reduced model on the load
    # split; drift is the same order (FEM stiffer for these squat piers).
    E = 25e9; ν = 0.2; t = 0.3; H = 3.0; lw = 4.0
    panels = WallPanel[
        WallPanel(1, -2.0, -5.0,  2.0, -5.0, 0.0, H, t, E, ν, 1),
        WallPanel(2, -2.0,  5.0,  2.0,  5.0, 0.0, H, t, E, ν, 1),
        WallPanel(3, -5.0, -2.0, -5.0,  2.0, 0.0, H, t, E, ν, 1),
        WallPanel(4,  5.0, -2.0,  5.0,  2.0, 0.0, H, t, E, ν, 1),
    ]
    femev = FEMLateralEvaluator(story_heights=[H], mesh_div=3, plan_halfwidth=(5.0, 5.0))
    Fx = 1e5
    res = evaluate_lateral(femev, panels, [StoryLoad(1, Fx, 0.0, 0.0, 0.0)])
    @test res.drift[1] > 0 && isfinite(res.drift[1])
    # Base-reaction recovery ⇒ X-walls equilibrate the applied shear (exact).
    @test isapprox(res.wall_forces[1] + res.wall_forces[2], Fx; rtol=0.05)
    @test isapprox(res.wall_forces[1], res.wall_forces[2]; rtol=0.05)     # symmetric split
    @test res.wall_forces[3] < 0.02 * Fx && res.wall_forces[4] < 0.02 * Fx # transverse ~0
    @test res.torsion[1] ≈ 1.0 atol=1e-3                                  # symmetric

    # Cross-check drift against the reduced model (gross stiffness, same order).
    k = wall_stiffness_from_thickness_si(t, lw, E, ν, H; cracked=false)
    rwalls = [WallLine(1, 0.0, -5.0, 0.0, k, 1), WallLine(2, 0.0, 5.0, 0.0, k, 1),
              WallLine(3, -5.0, 0.0, pi/2, k, 1), WallLine(4, 5.0, 0.0, pi/2, k, 1)]
    redev = ReducedDiaphragmEvaluator(story_heights=[H], plan_halfwidth=(5.0, 5.0),
                                      accidental_ecc=0.0)
    rdrift = evaluate_lateral(redev, rwalls, [StoryLoad(1, Fx, 0.0, 0.0, 0.0)]).drift[1]
    @test 0.3 < res.drift[1] / rdrift < 1.3
end
