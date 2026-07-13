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
