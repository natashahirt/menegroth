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
    # Phase 1: the transverse grade is now a required MATERIAL input (ACI 318-19
    # §11.5.4.3) — supply the Grade-60 fyt this known-answer assumes (fy from above,
    # in Pa) so there is no silent default and `cap` is matched exactly.
    chk = check_wall_inplane_shear(ws, conc, 800e3u"N", 6.0u"m"; fyt=fy*u"Pa")
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
    # Phase 1: supply the Grade-60 transverse fyt the spWall oracle assumes (no
    # silent Grade-60 default). fy = 60_000·_PSI (above), so this matches `cap`.
    chk  = check_wall_inplane_shear(ws, conc, (121 * _KIP)u"N", hw * u"m"; fyt=fy*u"Pa")
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

@testset "spWall worked example — out-of-plane slender wall (ACI 318-19 §11.8)" begin
    # StructurePoint "Reinforced Concrete Tilt-Up Wall Panel (ACI 318-19)"
    # (corpus: sp-de-tilt-up-wall-aci19). §11.8 alternative method, per 15-ft
    # design strip: f'c=4000 psi, fy=60 ksi, h=6.25 in, lc=29.5 ft, e=3.0 in,
    # As=7.04 in² (16 #6, single central layer), d=3.13 in.
    # Reported: Ase=7.76 in², c=0.896 in, Icr=353.56 in⁴, Kb=97.64 kip,
    #   Mua=24.77, Mu=61.00, Mcr=46.32, φMn=95.89 kip-ft, Δu=9.995 in, Δs=0.247 in.
    fc = 4000 * _PSI; fy = 60_000 * _PSI; Es = 29e6 * _PSI
    b  = 180 * _IN;   h = 6.25 * _IN;  d = 3.13 * _IN
    lc = 29.5 * _FT;  e = 3.0 * _IN;   As = 7.04 * _IN^2
    Pua = 20.64 * _KIP; Pum = 43.49 * _KIP; wu = 0.204 * _KIP / _FT
    KIPFT = _KIP * 12 * _IN

    s = oop_slender_wall_strength_si(fc, fy, Es, b, h, d, lc, e, As, Pua, Pum, wu)
    @test isapprox(s.Ase / _IN^2, 7.76;   rtol=1e-2)          # §R11.8.3.1 effective steel
    @test isapprox(s.c   / _IN,   0.896;  rtol=2e-2)          # neutral axis
    @test isapprox(s.Icr / _IN^4, 353.56; rtol=2e-2)          # §11.8.3.1(c)
    @test isapprox(s.Kb  / _KIP,  97.64;  rtol=2e-2)          # 48·Ec·Icr/(5·lc²)
    @test isapprox(s.Mua / KIPFT, 24.77;  rtol=1e-2)          # first-order (§11.8.3.1)
    @test isapprox(s.Mu  / KIPFT, 61.00;  rtol=2e-2)          # magnified (Eq. 11.8.3.1(d))
    @test isapprox(s.Mcr / KIPFT, 46.32;  rtol=1e-2)          # §24.2.3.5
    @test isapprox(s.φMn / KIPFT, 95.89;  rtol=1e-2)          # tension-controlled
    @test isapprox(s.Δu  / _IN,   9.995;  rtol=2e-2)          # §11.8.3.1(b)
    @test s.tension_controlled && s.φ == 0.90 && s.stable
    @test s.φMn > s.Mu && s.φMn > s.Mcr                       # gates (b)+(c) satisfied

    # Service mid-height deflection (bilinear, Table 11.8.4.1): Msa=20.32 ft-kip,
    # Ps=26.24 kip ⇒ Δcr=0.550 in, Δs=0.247 in (≤ lc/150 = 2.36 in).
    Msa = 20.32 * KIPFT; Ps = 26.24 * _KIP
    svc = oop_service_deflection_si(Msa, Ps, s.Mcr, s.Mn, s.Ec, s.Ig, s.Icr, lc)
    @test isapprox(svc.Δcr / _IN, 0.550; rtol=2e-2)
    @test isapprox(svc.Δs  / _IN, 0.247; rtol=5e-2)
    @test svc.converged && svc.Δs ≤ lc / 150

    # Applicability gates: §11.8.1.1(d) Pu ≤ 0.06 f'c Ag (38.66 ≤ 240 psi) → all hold.
    g = oop_slender_wall_gates(s, fc, b, h, lc, Pum; Δs=svc.Δs)
    @test isapprox(g.σ_axial / _PSI, 38.66; rtol=2e-2)
    @test isapprox(g.σ_limit / _PSI, 240.0; rtol=1e-9)
    @test g.gate_b && g.gate_c && g.gate_d && g.gate_e && g.applicable

    # Demand-coupled CheckResult (Unitful public API) WITH service loads, so the
    # mandatory §11.8.1.1(e) Δs≤lc/150 gate is exercised end-to-end: φMn=95.89 >
    # Mu=61.00 and Δs=0.247 ≤ 2.36 in ⇒ pass. The service wind ws is set to
    # reproduce the documented Msa=20.32 kip-ft from ws·lc²/8 + Pa·e/2 with the
    # documented Pa=7.20 kip (roof service dead load).
    op_Pa = 7.20 * _KIP                                    # service axial at top
    op_ws = ((20.32 * KIPFT) - op_Pa * e / 2) * 8 / lc^2   # ⇒ Msa = 20.32 kip-ft
    chk = check_wall_out_of_plane_slender(RC_4000_60, b*u"m", h*u"m", d*u"m",
              lc*u"m", e*u"m", As*u"m^2", Pua*u"N", Pum*u"N", wu*u"N/m";
              ws=op_ws*u"N/m", Pa=op_Pa*u"N", Ps=Ps*u"N")
    @test chk.passed
    @test isapprox(chk.ratio, 61.00 / 95.89; atol=0.03)
    @test chk.code_clause == "ACI 318-19 11.8"
    @test chk.name == "out-of-plane slender wall (P-Δ)"    # gate (e) verified

    # Fail-safe: omitting service loads must NOT silently pass gate (e). The check
    # warns and the result name flags §11.8.1.1(e) as unverified (strength still
    # governs; never a silent full pass).
    chk_ns = @test_logs (:warn,) match_mode=:any check_wall_out_of_plane_slender(
                 RC_4000_60, b*u"m", h*u"m", d*u"m", lc*u"m", e*u"m", As*u"m^2",
                 Pua*u"N", Pum*u"N", wu*u"N/m")
    @test occursin("NOT verified", chk_ns.name)
    @test chk_ns.code_clause == "ACI 318-19 11.8"
end

@testset "out-of-plane slender wall — applicability gates as a safety boundary" begin
    fc = 4000 * _PSI; fy = 60_000 * _PSI; Es = 29e6 * _PSI
    b  = 180 * _IN;   h = 6.25 * _IN;  d = 3.13 * _IN
    lc = 29.5 * _FT;  e = 3.0 * _IN
    Pua = 20.64 * _KIP; Pum = 43.49 * _KIP; wu = 0.204 * _KIP / _FT

    # A SHORT panel (lc = 10 ft) keeps Kb high enough that the P-Δ magnifier is
    # stable, so the softer applicability gates below govern in isolation (on a
    # tall panel these same demands trip the more fundamental instability gate
    # first — see the P-Δ case).
    lc_short = 10 * _FT

    # (c) φMn < Mcr: too little steel ⇒ design strength below cracking ⇒ FAIL,
    # never a silent pass. As = 1.0 in² (≪ 7.04) drops φMn under Mcr.
    chk_c = check_wall_out_of_plane_slender(RC_4000_60, b*u"m", h*u"m", d*u"m",
                lc_short*u"m", e*u"m", (1.0*_IN^2)u"m^2", Pua*u"N", Pum*u"N", wu*u"N/m")
    @test !chk_c.passed
    @test chk_c.code_clause == "ACI 318-19 11.8.1.1(c)"

    # (b) not tension-controlled: high axial deepens the neutral axis so εt drops
    # below εty+0.003 ⇒ the §11.8 method is inapplicable ⇒ FAIL.
    chk_b = check_wall_out_of_plane_slender(RC_4000_60, b*u"m", h*u"m", d*u"m",
                lc_short*u"m", e*u"m", (7.04*_IN^2)u"m^2", Pua*u"N", (300*_KIP)u"N", wu*u"N/m")
    @test !chk_b.passed
    @test chk_b.code_clause == "ACI 318-19 11.8.1.1(b)"

    # P-Δ instability: a very tall panel drives Pum → 0.75·Kb, the magnifier
    # denominator ≤ 0 ⇒ runaway second-order moment ⇒ FAIL (not Inf masquerading
    # as capacity).
    chk_pd = check_wall_out_of_plane_slender(RC_4000_60, b*u"m", h*u"m", d*u"m",
                (100.0*_FT)u"m", e*u"m", (7.04*_IN^2)u"m^2", Pua*u"N", Pum*u"N", wu*u"N/m")
    @test !chk_pd.passed
    @test chk_pd.code_clause == "ACI 318-19 11.8.3.1"

    # Unit-safety guard (shared with the P–M check): a plain Concrete needs
    # Unitful fy/Es; bare numbers are rejected.
    conc = Concrete(25e9u"Pa", (fc)u"Pa", 2400u"kg/m^3", 0.2, 0.1)
    @test_throws ErrorException check_wall_out_of_plane_slender(conc, b*u"m", h*u"m",
                d*u"m", lc*u"m", e*u"m", (7.04*_IN^2)u"m^2", Pua*u"N", Pum*u"N", wu*u"N/m")
end

@testset "§11.5.3 empirical bearing wall — hand calc + applicability gates" begin
    # Self-consistency hand calc of Eq. (11.5.3.1) + full gate coverage. (The
    # primary independent numeric oracle is McCormac Ex. 18.1 — see the textbook
    # oracle testset below; this case exercises k = 1.0 and every gate.)
    #   f'c = 4000 psi, 8 in wall, 12 in strip, clear height lc = 15 ft, braced
    #   pinned–pinned (k = 1.0), φ = 0.65.
    #     k·lc/(32·h) = 180/256 = 0.703125
    #     R  = 1 − 0.703125² = 0.505615
    #     Pn = 0.55·4000·96·R = 106.79 kip ;  φPn = 0.65·Pn = 69.41 kip
    fc = 4000 * _PSI
    lc = 15 * _FT; h = 8 * _IN; b = 12 * _IN; Ag = b * h
    cap = wall_empirical_axial_capacity_si(fc, lc, h, Ag; k=1.0, φ=0.65)
    @test isapprox(cap.slender, 180 / 256; rtol=1e-9)
    @test isapprox(cap.R, 1 - (180 / 256)^2; rtol=1e-9)
    @test isapprox(cap.Pn / _KIP, 106.79; atol=0.05)
    @test isapprox(cap.φPn / _KIP, 69.41; atol=0.05)

    # Effective length factor table (Table 11.5.3.2).
    @test wall_empirical_k(:restrained) == 0.8
    @test wall_empirical_k(:pinned)     == 1.0
    @test wall_empirical_k(:cantilever) == 2.0
    @test_throws ErrorException wall_empirical_k(:bogus)

    conc = Concrete(24.855e9u"Pa", (fc)u"Pa", 2400u"kg/m^3", 0.2, 0.1)
    ws   = WallSection(b*u"m", h*u"m")

    # Passing strength check: Pu = 60 kip < φPn = 69.41 kip.
    chk = check_wall_bearing_empirical(ws, conc, (60*_KIP)u"N"; e=0.0u"m",
                                       lc=lc*u"m", boundary=:pinned)
    @test chk.passed
    @test isapprox(chk.capacity / _KIP, 69.41; atol=0.05)
    @test isapprox(chk.ratio, 60 / 69.41; atol=1e-3)
    @test chk.code_clause == "ACI 318-19 11.5.3.1"

    # Failing strength check: Pu = 80 kip > φPn.
    chk_hi = check_wall_bearing_empirical(ws, conc, (80*_KIP)u"N"; e=0.0u"m",
                                          lc=lc*u"m", boundary=:pinned)
    @test !chk_hi.passed && chk_hi.code_clause == "ACI 318-19 11.5.3.1"

    # Gate (§11.5.3.1) middle-third: e > h/6 ⇒ method inapplicable ⇒ FAIL.
    chk_e = check_wall_bearing_empirical(ws, conc, (60*_KIP)u"N"; e=(h/5)*u"m",
                                         lc=lc*u"m", boundary=:pinned)
    @test !chk_e.passed && chk_e.code_clause == "ACI 318-19 11.5.3.1"

    # Slenderness gate: k·lc/(32·h) ≥ 1 (lc = 32·h) ⇒ no usable capacity ⇒ FAIL.
    chk_s = check_wall_bearing_empirical(ws, conc, (60*_KIP)u"N"; e=0.0u"m",
                                         lc=(32*h)*u"m", boundary=:pinned)
    @test !chk_s.passed && chk_s.ratio ≥ 1.0

    # Minimum-thickness gate (Table 11.3.1.1): 3 in wall < max(4in, min(lw,lc)/25).
    ws_thin = WallSection(b*u"m", (3*_IN)*u"m")
    chk_t = check_wall_bearing_empirical(ws_thin, conc, (60*_KIP)u"N"; e=0.0u"m",
                                         lc=lc*u"m", boundary=:pinned)
    @test !chk_t.passed && chk_t.code_clause == "ACI 318-19 11.3.1.1"
    # 7.5 in foundation floor: an 8 in wall clears the 4 in floor but not with a
    # short unsupported dimension; confirm the foundation floor is applied.
    @test isapprox(wall_min_thickness_si(10*_FT, lc; foundation=true), 0.1905; rtol=1e-9)
    @test isapprox(wall_min_thickness_si(1.0, 1.0; foundation=false), 0.1016; rtol=1e-9)

    # Tension guard: the bearing method is compression-only. Net tension (Pu<0)
    # must FAIL as inapplicable, never pass on a negative utilization ratio.
    chk_ten = check_wall_bearing_empirical(ws, conc, (-10*_KIP)u"N"; e=0.0u"m",
                                           lc=lc*u"m", boundary=:pinned)
    @test !chk_ten.passed && chk_ten.code_clause == "ACI 318-19 11.5.3"

    # Middle-third gate is sign-agnostic: a NEGATIVE eccentricity with |e| > h/6
    # must also FAIL (guards against an unsigned-`e` fail-open).
    chk_en = check_wall_bearing_empirical(ws, conc, (60*_KIP)u"N"; e=(-h/5)*u"m",
                                          lc=lc*u"m", boundary=:pinned)
    @test !chk_en.passed && chk_en.code_clause == "ACI 318-19 11.5.3.1"

    # `lu` (unsupported horizontal length) governs the min-thickness rule. For a
    # tall wall the default (lw = 12 in strip) lets thickness pass so slenderness
    # governs; supplying the TRUE unsupported length (lu = 30 ft) trips the
    # Table 11.3.1.1 thickness gate instead — the kwarg is a real safety lever.
    chk_lu_def = check_wall_bearing_empirical(ws, conc, (60*_KIP)u"N"; e=0.0u"m",
                                              lc=(30*_FT)*u"m", boundary=:pinned)
    @test !chk_lu_def.passed && chk_lu_def.code_clause == "ACI 318-19 11.5.3.1"
    chk_lu = check_wall_bearing_empirical(ws, conc, (60*_KIP)u"N"; e=0.0u"m",
                                          lc=(30*_FT)*u"m", lu=(30*_FT)*u"m", boundary=:pinned)
    @test !chk_lu.passed && chk_lu.code_clause == "ACI 318-19 11.3.1.1"
end

@testset "§11.5.3 empirical bearing wall — McCormac Ex. 18.1 textbook oracle" begin
    # Independent numeric oracle: McCormac & Brown, Design of Reinforced Concrete
    # 9th ed., Example 18.1 (ACI 318 §14.5.2 Eq. 14-1 = ACI 318-19 §11.5.3.1).
    # ZK extraction: mccormac-de-bearing-wall-empirical-aci318-11.
    #   Precast roof beams @ 7 ft o.c., bearing 10 in; wall braced top/bottom +
    #   rotation-restrained at footing ⇒ k = 0.8; lc = 16 ft; f'c = 3000 psi;
    #   beam reaction D = 30 k, L = 18 k. Textbook results: h_min = 7.68 in,
    #   effective length = 42 in, Ag = 8×42 = 336 in², φPnw = 230.6 k > Pu = 64.8 k.
    fc = 3000 * _PSI; lc = 16 * _FT; h = 8 * _IN

    # Minimum thickness (§14.5.3.1 / Table 11.3.1.1): (1/25)·16 ft = 7.68 in.
    @test isapprox(wall_min_thickness_si(20*_FT, lc), 7.68*_IN; rtol=1e-4)

    # Effective horizontal length per concentrated load (§14.2.4):
    # min(84 in c/c, 10 + 4·8 = 42 in) = 42 in ⇒ Ag = 8 × 42 = 336 in².
    l_eff = min(84*_IN, (10 + 4*8)*_IN)
    @test isapprox(l_eff, 42*_IN; rtol=1e-12)
    Ag = h * l_eff

    # Design axial strength — the oracle. k = 0.8 (Table 18.1, restrained).
    cap = wall_empirical_axial_capacity_si(fc, lc, h, Ag; k=0.8, φ=0.65)
    @test isapprox(cap.slender, 0.60; atol=1e-3)      # k·lc/32h = 153.6/256
    @test isapprox(cap.R, 0.64; atol=1e-3)            # 1 − 0.60²
    @test isapprox(cap.φPn / _KIP, 230.6; atol=0.15)  # McCormac: 230.6 k

    # Factored beam reaction and the full demand-coupled check.
    Pu = (1.2*30 + 1.6*18) * _KIP
    @test isapprox(Pu / _KIP, 64.8; rtol=1e-12)
    conc_mc = Concrete(24.855e9u"Pa", fc*u"Pa", 2400u"kg/m^3", 0.2, 0.1)
    ws_mc   = WallSection((l_eff)*u"m", h*u"m")
    chk = check_wall_bearing_empirical(ws_mc, conc_mc, Pu*u"N"; e=0.0u"m",
                                       lc=lc*u"m", lu=(20*_FT)*u"m", boundary=:restrained)
    @test chk.passed
    @test isapprox(chk.capacity / _KIP, 230.6; atol=0.15)
    @test isapprox(chk.ratio, 64.8 / 230.6; atol=2e-3)
    @test chk.code_clause == "ACI 318-19 11.5.3.1"
end

@testset "§11.5.3 empirical bearing wall — Asap FEA cross-check" begin
    # Beyond the McCormac Ex. 18.1 numeric oracle above, independently cross-check
    # the two physical ingredients of Eq. (11.5.3.1) with an Asap FEA of the panel:
    #   (1) a shell (membrane) model reproduces the axial stiffness E·Ag — the
    #       material/area basis of the 0.55·f'c·Ag squash term;
    #   (2) a beam-column (frame) model reproduces the elastic (Euler) buckling
    #       load, the ACI φPn sits safely below it, and both the ACI knock-down
    #       and the FE buckling load fall off together with wall height.
    fc = 4000 * _PSI
    E  = 57000 * sqrt(4000) * _PSI          # ACI §19.2.2.1(b)
    ν  = 0.2; G = E / (2 * (1 + ν))
    b  = 12 * _IN; h = 8 * _IN
    Ag = b * h; Iweak = b * h^3 / 12; Istrong = h * b^3 / 12

    # Shell membrane axial stiffness (mixed Model solve — 1.12-safe RHS).
    function shell_axial_EA(b, lc, h, E, ν, P; nx=3, ny=18)
        nodes = Asap.Node[]
        for j in 0:ny, i in 0:nx
            push!(nodes, Asap.Node([i*b/nx*u"m", j*lc/ny*u"m", 0.0u"m"], :free))
        end
        for (idx, nd) in enumerate(nodes)
            nd.nodeID = idx; nd.globalID = collect((idx-1)*6+1 : idx*6)
            nd.dof .= [true, true, false, false, false, false]      # membrane only
        end
        node(i, j) = nodes[j*(nx+1) + i + 1]
        for i in 0:nx; node(i, 0).dof[2] = false; end               # base v = 0
        node(0, 0).dof[1] = false                                   # remove x rigid body
        els = Asap.ShellTri3[]
        for j in 0:ny-1, i in 0:nx-1
            n1 = node(i,j); n2 = node(i+1,j); n3 = node(i,j+1); n4 = node(i+1,j+1)
            push!(els, Asap.ShellTri3((n1, n2, n4), h*u"m", E*u"Pa", ν))
            push!(els, Asap.ShellTri3((n1, n4, n3), h*u"m", E*u"Pa", ν))
        end
        for el in els
            Asap.process!(el); el.globalID = vcat([n.globalID for n in el.nodes]...)
        end
        ntop = nx + 1
        loads = Asap.AbstractLoad[Asap.NodeForce(node(i, ny), [0.0, -P/ntop, 0.0]u"N") for i in 0:nx]
        model = Asap.Model(nodes, els, loads)
        Asap.process!(model); Asap.solve!(model)
        δ = sum(model.u[node(i, ny).globalID[2]] for i in 0:nx) / ntop
        return P * lc / abs(δ)
    end

    # Frame beam-column elastic buckling (pinned-pinned, weak axis).
    function frame_buckling_Pcr(lc, A, Ix, Iy, E, G, P_applied; n_elem=12)
        sec = Asap.Section(A*u"m^2", E*u"Pa", G*u"Pa", Ix*u"m^4", Iy*u"m^4", 1e-4*u"m^4")
        nodes = Asap.Node[]
        for i in 0:n_elem
            z  = i * lc / n_elem
            fx = i == 0      ? :pinned :
                 i == n_elem ? [false, false, true, true, true, true] : :free
            push!(nodes, Asap.Node([0.0u"m", 0.0u"m", z*u"m"], fx))
        end
        els = [Asap.Element(nodes[i], nodes[i+1], sec, :col) for i in 1:n_elem]
        loads = Asap.AbstractLoad[Asap.NodeForce(nodes[end], [0.0, 0.0, -P_applied]u"N")]
        res = Asap.solve_buckling!(Asap.Model(nodes, els, loads); n=4)
        res.n_modes < 1 && error("no frame buckling mode")
        return res.load_factors[1] * P_applied
    end

    lc = 15 * _FT
    EA_fea = shell_axial_EA(b, lc, h, E, ν, 1.0e6)
    @test isapprox(EA_fea, E * Ag; rtol=0.05)                       # (1) material basis

    Pcr_fea   = frame_buckling_Pcr(lc, Ag, Istrong, Iweak, E, G, 1.0e6)
    Pcr_euler = π^2 * E * Iweak / lc^2
    @test isapprox(Pcr_fea, Pcr_euler; rtol=0.05)                   # (2) FE ≈ Euler

    cap = wall_empirical_axial_capacity_si(fc, lc, h, Ag; k=1.0, φ=0.65)
    @test cap.φPn < Pcr_fea                                         # strength below buckling
    @test cap.Pn  < Pcr_fea
    # Conservative fraction ≈ 0.12; a tight band around it would catch a dropped
    # 0.55 or φ (the hand-calc atol=0.05 kip is the primary regression guard).
    @test 0.08 < cap.φPn / Pcr_fea < 0.20

    # Knock-down and FE buckling both fall monotonically with slenderness.
    Rs = Float64[]; Pcrs = Float64[]
    for lc_ft in (10.0, 15.0, 20.0)
        lci = lc_ft * _FT
        push!(Rs, wall_empirical_axial_capacity_si(fc, lci, h, Ag; k=1.0).R)
        push!(Pcrs, frame_buckling_Pcr(lci, Ag, Istrong, Iweak, E, G, 1.0e6))
    end
    @test issorted(Rs; rev=true)
    @test issorted(Pcrs; rev=true)
end

@testset "reduced diaphragm: symmetric core (S2)" begin
    k = 1e7
    walls = [WallLine(1, 0.0, -5.0, 0.0, k, 1), WallLine(2, 0.0, 5.0, 0.0, k, 1),
             WallLine(3, -5.0, 0.0, pi/2, k, 1), WallLine(4, 5.0, 0.0, pi/2, k, 1)]
    # TRUE plate center: walls are symmetric about the origin, so the floor plate is
    # centered at (0, 0) in the WallLine frame. Supplies the corner-drift / torsion
    # certification geometry (res.torsion is Inf / fail-closed without it).
    ev = ReducedDiaphragmEvaluator(story_heights=[3.0], plan_halfwidth=(5.0, 5.0),
                                   plate_center=(0.0, 0.0), accidental_ecc=0.0)
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
    # Symmetric core ⇒ TRUE plate center at the origin; supplies the twist geometry so
    # res.torsion is the EXACT corner amplification (not the fail-closed Inf sentinel).
    ev = ReducedDiaphragmEvaluator(story_heights=[3.0], plan_halfwidth=(5.0, 5.0),
                                   plate_center=(0.0, 0.0), accidental_ecc=0.05)
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

# ==============================================================================
# Phase 1 wall-hardening regression tests (fail-closed behavior)
# ==============================================================================
# These lock in four safety fixes: (1) the in-plane shear check resolves the
# transverse steel yield fyt from the MATERIAL and throws when it is missing — no
# silent Grade-60 default; (2) reduced-tier drift is a TRUE per-story interstory
# value, not cumulative-from-base; (3) a singular / under-braced story stiffness
# FAILS CLOSED (SingularStiffnessError) instead of returning a pinv/K+εI fabricated
# displacement; (4) the FEM tier WITHHOLDS unvalidated upper-story shear (NaN +
# membership in `wall_forces_withheld`) rather than surfacing a plausible-but-wrong
# demand.

@testset "Phase 1: transverse steel grade flows through in-plane shear (ACI 318-19 §11.5.4.3)" begin
    # Eq. (11.5.4.3): Vn = (αc·λ·√f'c + ρt·fyt)·Acv. `fyt` (transverse / horizontal
    # web steel yield) is now a MATERIAL input — there is NO silent Grade-60 default.
    # A higher transverse grade must raise ONLY the steel term ρt·fyt, increasing
    # φVn and lowering the utilization at a fixed demand (direction per §11.5.4.3).
    conc4 = Concrete(25e9u"Pa", (4000 * _PSI)u"Pa", 2400u"kg/m^3", 0.2, 0.1)
    ws    = WallSection((216 * _IN)u"m", (10 * _IN)u"m"; ρl=0.00344, ρt=0.0025)
    hw    = (54 * _FT)u"m"
    Vu    = (121 * _KIP)u"N"

    # Known-answer capacities straight from the bare-SI core (psi/in internally).
    cap60 = wall_shear_capacity_si(4000*_PSI, 60_000*_PSI, 216*_IN, 10*_IN, 0.0025, 54*_FT)
    cap75 = wall_shear_capacity_si(4000*_PSI, 75_000*_PSI, 216*_IN, 10*_IN, 0.0025, 54*_FT)
    # Grade 60 reproduces the spWall oracle φVn = 447.92 k. Grade 75 scales ONLY the
    # steel contribution: φVc = 204.92 fixed, φVs: 243.00 → 243.00·(75/60) = 303.75.
    @test isapprox(cap60.ϕVn, 447.92 * _KIP; rtol=2e-3)
    @test isapprox(cap75.ϕVn, (204.92 + 243.00 * 75/60) * _KIP; rtol=2e-3)
    @test cap75.ϕVn > cap60.ϕVn                                    # higher grade ⇒ more capacity

    # (a) The grade flows via a ReinforcedConcreteMaterial's `transverse` tie grade.
    chk60 = check_wall_inplane_shear(ws, ReinforcedConcreteMaterial(conc4, Rebar_60), Vu, hw)
    chk75 = check_wall_inplane_shear(ws, ReinforcedConcreteMaterial(conc4, Rebar_75), Vu, hw)
    @test isapprox(chk60.capacity, cap60.ϕVn; rtol=1e-6)
    @test isapprox(chk75.capacity, cap75.ϕVn; rtol=1e-6)
    @test chk75.capacity > chk60.capacity                         # Grade 75 ⇒ larger φVn
    @test chk75.ratio    < chk60.ratio                            # same Vu ⇒ lower utilization
    @test isapprox(chk75.ratio, (121 * _KIP) / cap75.ϕVn; rtol=1e-6)

    # (b) fyt reads the TRANSVERSE field only: longitudinal Gr75 + transverse Gr60
    #     must still give the Grade-60 capacity (guards a wrong-field regression).
    rc_split = ReinforcedConcreteMaterial(conc4, Rebar_75, Rebar_60)
    @test isapprox(check_wall_inplane_shear(ws, rc_split, Vu, hw).capacity, cap60.ϕVn; rtol=1e-6)

    # (c) An explicit Unitful fyt= on a plain Concrete matches the material path.
    @test isapprox(check_wall_inplane_shear(ws, conc4, Vu, hw; fyt=(75_000*_PSI)u"Pa").capacity,
                   cap75.ϕVn; rtol=1e-6)

    # FAIL CLOSED: a plain Concrete with NO transverse grade must THROW (never a
    # silent Grade-60 default), and a BARE (non-Unitful) fyt is rejected as a
    # ksi/Pa unit-mismatch footgun.
    @test_throws ErrorException check_wall_inplane_shear(ws, conc4, Vu, hw)
    @test_throws ErrorException check_wall_inplane_shear(ws, conc4, Vu, hw; fyt=75.0)
end

@testset "Phase 1: reduced drift is per-story interstory, not cumulative (S2 multistory)" begin
    # Two identical symmetric cores stacked. Each story is an INDEPENDENT 3-DOF
    # shear-building spring, so drift[s] is that story's OWN relative translation
    # over its height — NOT an absolute / cumulative-from-base displacement. This
    # extends the single-story known answer (res.drift[1] ≈ δx/h) to multistory.
    k = 1e7; h = 3.0; Fx = 1e5
    mkstory(s) = [WallLine(10s+1, 0.0, -5.0, 0.0, k, s), WallLine(10s+2, 0.0, 5.0, 0.0, k, s),
                  WallLine(10s+3, -5.0, 0.0, pi/2, k, s), WallLine(10s+4, 5.0, 0.0, pi/2, k, s)]
    walls = vcat(mkstory(1), mkstory(2))
    ev = ReducedDiaphragmEvaluator(story_heights=[h, h], plan_halfwidth=(5.0, 5.0),
                                   accidental_ecc=0.0)
    res = evaluate_lateral(ev, walls, [StoryLoad(1, Fx, 0.0, 0.0, 0.0),
                                       StoryLoad(2, Fx, 0.0, 0.0, 0.0)])

    # Story 1 resists the CUMULATIVE base shear 2·Fx; story 2 only its own Fx.
    # Two X-walls per story ⇒ ΣkX = 2k, so each story's own spring displacement is
    # δ_s = V_s / (2k) (the Y-walls carry no Fx).
    δ1 = (2Fx) / (2k)      # = 0.010 m
    δ2 = Fx    / (2k)      # = 0.005 m
    @test isapprox(res.story_disp[1, 1], δ1; rtol=1e-6)
    @test isapprox(res.story_disp[2, 1], δ2; rtol=1e-6)

    # Per-story interstory drift: drift[s] = δ_s / h.
    @test isapprox(res.drift[1], δ1 / h; rtol=1e-6)
    @test isapprox(res.drift[2], δ2 / h; rtol=1e-6)
    # The drift ratio tracks the STORY-SHEAR ratio (2Fx : Fx), proving per-story.
    @test isapprox(res.drift[1] / res.drift[2], (2Fx) / Fx; rtol=1e-6)
    @test res.drift[2] < res.drift[1]
    # If drift were (wrongly) cumulative-from-base, drift[2] would be (δ1+δ2)/h,
    # 3× its true per-story value — assert it is NOT that.
    @test !isapprox(res.drift[2], (δ1 + δ2) / h; rtol=1e-3)
end

@testset "Phase 1: degenerate / under-braced layout FAILS CLOSED (SingularStiffnessError)" begin
    # A laterally under-braced story has a rank-deficient 3×3 stiffness. The fix
    # removes the pinv / K+εI fallback and raises SingularStiffnessError instead of
    # returning a fabricated displacement — NEVER a silent finite number.
    SSE = StructuralSizer.SingularStiffnessError   # not exported; reference by module
    ev = ReducedDiaphragmEvaluator(story_heights=[3.0], plan_halfwidth=(5.0, 5.0),
                                   accidental_ecc=0.0)
    loads = [StoryLoad(1, 1e5, 1e5, 0.0, 0.0)]

    # Under-braced: all walls parallel to X ⇒ NO Y restraint ⇒ singular K.
    underbraced = [WallLine(1, 0.0, -5.0, 0.0, 1e7, 1), WallLine(2, 0.0, 5.0, 0.0, 1e7, 1)]
    @test_throws SSE evaluate_lateral(ev, underbraced, loads)
    # The analytic sensitivity must fail closed on the SAME layout (no K+εI fudge).
    @test_throws SSE story_drift_sensitivity(ev, underbraced, loads, 1)
    # A single wall is also degenerate (rank-1 K).
    @test_throws SSE evaluate_lateral(ev, [WallLine(1, 0.0, 0.0, 0.0, 1e7, 1)], loads)

    # Guard does NOT false-positive: a well-braced layout still solves to finite drift.
    braced = [WallLine(1, 0.0, -5.0, 0.0, 1e7, 1), WallLine(2, 0.0, 5.0, 0.0, 1e7, 1),
              WallLine(3, -5.0, 0.0, pi/2, 1e7, 1), WallLine(4, 5.0, 0.0, pi/2, 1e7, 1)]
    rb = evaluate_lateral(ev, braced, loads)
    @test all(isfinite, rb.drift) && all(>(0.0), rb.drift)

    # FEM tier: a single straight wall whose only floor node is the (brand-new)
    # diaphragm master leaves that master with NO connecting diaphragm shell (the
    # fan triangles over two collinear top nodes are degenerate and skipped), so its
    # DOFs have zero stiffness ⇒ global K non-positive-definite ⇒ must ALSO fail
    # closed via `_assert_fem_nonsingular` rather than Asap's silent LDLᵀ/LU fallback.
    femev = FEMLateralEvaluator(story_heights=[3.0], mesh_div=1, plan_halfwidth=(5.0, 5.0))
    flat  = [WallPanel(1, -2.0, 0.0, 2.0, 0.0, 0.0, 3.0, 0.3, 25e9, 0.2, 1)]
    @test_throws SSE evaluate_lateral(femev, flat, loads)
end

@testset "Phase 1: FEM withholds unvalidated upper-story shear (NaN sentinel)" begin
    # Two symmetric cores stacked (continuous walls via shared nodes at z = H).
    # Base-story panels get an EXACT base-reaction-recovered demand; upper-story
    # panels have no multistory oracle, so their shear is WITHHELD: wall_forces[id]
    # = NaN AND id ∈ wall_forces_withheld. A consumer must never read a withheld id
    # as a passing (e.g. zero) demand.
    E = 25e9; ν = 0.2; t = 0.3; H = 3.0; Fx = 1e5
    base = WallPanel[
        WallPanel(1, -2.0, -5.0,  2.0, -5.0, 0.0,  H, t, E, ν, 1),
        WallPanel(2, -2.0,  5.0,  2.0,  5.0, 0.0,  H, t, E, ν, 1),
        WallPanel(3, -5.0, -2.0, -5.0,  2.0, 0.0,  H, t, E, ν, 1),
        WallPanel(4,  5.0, -2.0,  5.0,  2.0, 0.0,  H, t, E, ν, 1),
    ]
    upper = WallPanel[
        WallPanel(5, -2.0, -5.0,  2.0, -5.0, H, 2H, t, E, ν, 2),
        WallPanel(6, -2.0,  5.0,  2.0,  5.0, H, 2H, t, E, ν, 2),
        WallPanel(7, -5.0, -2.0, -5.0,  2.0, H, 2H, t, E, ν, 2),
        WallPanel(8,  5.0, -2.0,  5.0,  2.0, H, 2H, t, E, ν, 2),
    ]
    femev = FEMLateralEvaluator(story_heights=[H, H], mesh_div=3, plan_halfwidth=(5.0, 5.0))
    res = evaluate_lateral(femev, vcat(base, upper),
                           [StoryLoad(1, Fx, 0.0, 0.0, 0.0), StoryLoad(2, Fx, 0.0, 0.0, 0.0)])

    # Upper-story panels: withheld + NaN sentinel (fail closed — unknown, not zero).
    for id in (5, 6, 7, 8)
        @test id in res.wall_forces_withheld
        @test isnan(res.wall_forces[id])
    end
    # Base-story panels: validated, FINITE, not withheld.
    for id in (1, 2, 3, 4)
        @test !(id in res.wall_forces_withheld)
        @test isfinite(res.wall_forces[id])
    end
    # The base X-walls carry the (finite) in-plane shear; exact base-reaction
    # recovery equilibrates the total applied base shear 2·Fx.
    @test res.wall_forces[1] > 0 && res.wall_forces[2] > 0
    @test isapprox(res.wall_forces[1] + res.wall_forces[2], 2Fx; rtol=0.1)
end

# ==============================================================================
# Phase 1 FIX verification — optimizer robustness vs. fail-closed evaluator
# ==============================================================================
# The reduced evaluator FAILS CLOSED on a singular / under-braced story
# (SingularStiffnessError). That throw is correct for the direct CHECK path, but
# the Ipopt layout optimizer drives the unloaded direction's walls to the density
# floor on a UNI-DIRECTIONAL lateral case, so a normal iterate can hit a
# (near-)singular K. The fix catches SingularStiffnessError at the optimizer
# boundary ONLY (objective_fn → finite penalty, constraint_fns → infeasible
# sentinel) so Ipopt steers away instead of the whole solve aborting (the P0).
# The three testsets below verify, in order:
#   (1) the end-to-end Ipopt solve COMPLETES (returns a status) on that
#       uni-directional case and the selected layout is itself non-singular;
#   (2) the DIRECT evaluate_lateral path on a genuinely singular layout STILL
#       throws (fail-closed preserved) — only the optimizer call sites penalize;
#   (3) the non-dimensionalized conditioning gate is SCALE-INVARIANT: a huge-
#       footprint well-braced layout is not falsely rejected, a small one still
#       passes, and a genuinely under-braced layout still throws at any scale.

# Shared ground structure: a symmetric 4-wall core (2 X-walls at y=±5, 2 Y-walls
# at x=±5), single story. Candidate order fixes the density-vector layout:
#   x[1],x[2] → X-walls (resist X-translation + torsion)
#   x[3],x[4] → Y-walls (resist Y-translation + torsion)
# Driving x[3]=x[4]=ρ_min removes all Y restraint ⇒ the 3×3 story K is singular
# in its Y-translation mode (X-walls have no Y component: b=[1,0,−y]).
function _phase1fix_core_candidates()
    geom = [(0.0, -5.0, 0.0), (0.0, 5.0, 0.0), (-5.0, 0.0, pi/2), (5.0, 0.0, pi/2)]
    return [WallCandidate(i, x, y, θ, 4.0, 3.0, 1, 25e9, 0.2, 28e6, 60e6*6.895,
                          2400.0, 0.1, 0.4, 0.0025)
            for (i, (x, y, θ)) in enumerate(geom)]
end

@testset "Phase 1 fix: uni-directional Ipopt solve completes (P0 regression)" begin
    SSE = StructuralSizer.SingularStiffnessError
    cand = _phase1fix_core_candidates()
    # UNI-DIRECTIONAL lateral load (Fx only) with walls in BOTH directions. With
    # accidental eccentricity the Fx load induces a torsional moment Mz, so the
    # Y-walls carry no direct shear yet are still required for torsional stability
    # — exactly the case where the optimizer thins the Y-direction toward singular.
    ev    = ReducedDiaphragmEvaluator(story_heights=[3.0], plan_halfwidth=(5.0, 5.0),
                                      accidental_ecc=0.05)
    loads = [StoryLoad(1, 5.0e5, 0.0, 0.0, 0.0)]           # uni-directional (Fx only)

    # --- Deterministic bridge test: the optimizer-boundary functions must map a
    # singular iterate to a finite penalty / infeasible sentinel, NOT throw. This
    # pins the catch independently of whether Ipopt happens to probe a singular x.
    PEN  = StructuralSizer.OPTIMIZER_SINGULAR_OBJECTIVE_PENALTY
    INF  = StructuralSizer.OPTIMIZER_INFEASIBLE_CONSTRAINT
    probC = WallLayoutNLPProblem(cand, ev, loads; objective=MinCarbon())
    probD = WallLayoutNLPProblem(cand, ev, loads; objective=MinDrift())
    x_sing = [0.5, 0.5, probC.ρ_min, probC.ρ_min]          # Y-walls at floor ⇒ singular K
    # Sanity: the SAME densities make the DIRECT evaluator throw (so the sentinels
    # below are genuinely exercising the catch, not a non-singular shortcut).
    @test_throws SSE evaluate_lateral(ev, StructuralSizer._walls_from_density(probC, x_sing), loads)
    g_sing = constraint_fns(probC, x_sing)
    @test all(isfinite, g_sing)                            # no NaN/Inf leaked from the throw
    @test all(==(INF), g_sing)                             # every constraint = infeasible sentinel
    @test objective_fn(probD, x_sing) == PEN               # MinDrift objective → finite penalty
    @test isfinite(objective_fn(probD, x_sing))

    # --- End-to-end P0 regression: the full Ipopt solve must COMPLETE (return a
    # status) WITHOUT a SingularStiffnessError escaping and aborting the solve.
    result = solve_wall_layout(probC; maxiter=150)
    @test result.status isa Symbol                         # returned a status ⇒ did not crash
    @test isfinite(result.objective_value)
    @test length(result.minimizer) == length(cand)

    # --- Guard against a bogus near-singular optimum: re-validate the SELECTED
    # layout through the THROWING direct path. A singular optimum would raise here.
    walls_opt = StructuralSizer._walls_from_density(probC, result.minimizer)
    verdict = try
        evaluate_lateral(ev, walls_opt, loads)
        :nonsingular
    catch e
        e isa SSE ? :singular : rethrow()
    end
    @test verdict == :nonsingular                          # selected layout is itself stable
end

@testset "Phase 1 fix: direct check stays fail-closed while optimizer boundary penalizes" begin
    # The optimizer-boundary catch must NOT weaken the direct fail-closed contract:
    # on the very same singular densities, the DIRECT evaluate_lateral path still
    # throws, while objective_fn / constraint_fns (optimizer call sites) do not.
    SSE = StructuralSizer.SingularStiffnessError
    cand  = _phase1fix_core_candidates()
    ev    = ReducedDiaphragmEvaluator(story_heights=[3.0], plan_halfwidth=(5.0, 5.0),
                                      accidental_ecc=0.05)
    loads = [StoryLoad(1, 5.0e5, 0.0, 0.0, 0.0)]
    probC = WallLayoutNLPProblem(cand, ev, loads; objective=MinCarbon())
    probD = WallLayoutNLPProblem(cand, ev, loads; objective=MinDrift())
    x_sing = [0.5, 0.5, probC.ρ_min, probC.ρ_min]
    walls_sing = StructuralSizer._walls_from_density(probC, x_sing)

    # (direct path) genuinely singular layout ⇒ STILL throws (fail-closed preserved)
    @test_throws SSE evaluate_lateral(ev, walls_sing, loads)
    @test_throws SSE story_drift_sensitivity(ev, walls_sing, loads, 1)
    # (optimizer boundary) same layout ⇒ penalize, never throw
    @test constraint_fns(probC, x_sing) == fill(StructuralSizer.OPTIMIZER_INFEASIBLE_CONSTRAINT,
                                                n_constraints(probC))
    @test objective_fn(probD, x_sing) == StructuralSizer.OPTIMIZER_SINGULAR_OBJECTIVE_PENALTY

    # An independently-constructed under-braced layout (parallel walls only, no
    # transverse restraint) under a bi-directional demand must also fail closed.
    yonly = [WallLine(1, -5.0, 0.0, pi/2, 1e7, 1), WallLine(2, 5.0, 0.0, pi/2, 1e7, 1)]
    @test_throws SSE evaluate_lateral(ev, yonly, [StoryLoad(1, 1e5, 1e5, 0.0, 0.0)])
end

@testset "Phase 1 fix: conditioning gate is scale-invariant (non-dimensionalized rcond)" begin
    # The raw 3×3 story K is mixed-unit, so a bare λ_min/λ_max scales like 1/L_ref²
    # with plan size and would FALSELY reject a large-footprint but perfectly well-
    # braced layout. The fix non-dimensionalizes the rotational DOF (S=diag(1,1,
    # 1/L_ref)) so the conditioning verdict is INVARIANT to plan scale. Here a
    # symmetric core gives a scale-free normalized rcond ≈ 0.25 at every footprint.
    SSE = StructuralSizer.SingularStiffnessError
    mkbraced(D, k) = [WallLine(1, 0.0, -D, 0.0, k, 1), WallLine(2, 0.0, D, 0.0, k, 1),
                      WallLine(3, -D, 0.0, pi/2, k, 1), WallLine(4, D, 0.0, pi/2, k, 1)]
    loads = [StoryLoad(1, 1e5, 1e5, 0.0, 0.0)]             # bi-directional (both modes loaded)

    # Small (5 m), realistic-large (500 m), and extreme (2·10⁴ m) half-footprints.
    # At D = 2·10⁴ the UN-normalized rcond ≈ 1/D² ≈ 2.5·10⁻⁹ ≤ SINGULAR_STIFFNESS_RCOND
    # (1e-8) would trip the gate; the non-dimensionalized test must NOT. The small
    # case must pass too — i.e. the gate's verdict is consistent across plan scale.
    drifts = Float64[]
    for D in (5.0, 500.0, 2.0e4)
        ev  = ReducedDiaphragmEvaluator(story_heights=[3.0], plan_halfwidth=(D, D),
                                        accidental_ecc=0.05)
        res = evaluate_lateral(ev, mkbraced(D, 1e7), loads)   # must NOT throw at any scale
        @test all(isfinite, res.drift)
        @test all(>(0.0), res.drift)
        push!(drifts, res.drift[1])
    end
    # Verdict (pass) identical across all three scales.
    @test length(drifts) == 3 && all(isfinite, drifts)

    # The normalization does not DISABLE the gate: a genuinely under-braced layout
    # (X-walls only ⇒ no Y restraint) still fails closed even at the huge footprint.
    Dbig = 2.0e4
    evbig = ReducedDiaphragmEvaluator(story_heights=[3.0], plan_halfwidth=(Dbig, Dbig),
                                      accidental_ecc=0.0)
    xonly_big = [WallLine(1, 0.0, -Dbig, 0.0, 1e7, 1), WallLine(2, 0.0, Dbig, 0.0, 1e7, 1)]
    @test_throws SSE evaluate_lateral(evbig, xonly_big, loads)
end

# ==============================================================================
# Direction-complete lateral-stability fix — verification tests
# ==============================================================================
# The reduced wall-layout optimizer could previously return a layout stable ONLY
# in the loaded direction: a near-dead orthogonal bracing mode produces a tiny
# drift in the single applied direction but a huge drift in the unloaded one, so
# a direction-aligned drift check wrongly accepts a collapse mechanism. The fix
# makes the drift stability constraint DIRECTION-COMPLETE — per story it sweeps
# the applied resultant MAGNITUDE into BOTH +X and +Y (each with the accidental-
# torsion companion) and takes the MAX interstory drift
# (`direction_complete_interstory_drift`) — demotes the rcond throw to a numerical
# backstop, makes `solve_wall_layout` RE-VALIDATE the selected layout (returning
# `feasible::Bool` + `status`, with `status=:infeasible`/`feasible=false` when a
# principal direction fails), and makes drift/torsion ORIGIN-INVARIANT via the
# center of rigidity. The four testsets below verify, in order:
#   (1) P0 REGRESSION — a near-dead-Y layout (the critic's construction) is
#       infeasible in +Y even though +X alone looks fine, and can no longer be
#       returned as a feasible `solve_wall_layout` solution;
#   (2) a genuinely well-braced bidirectional layout is NOT falsely rejected, at
#       both a small and a large footprint, and drift/utilization is origin-
#       invariant under a large translation;
#   (3) the fail-closed contract is preserved (a genuinely singular layout still
#       throws `SingularStiffnessError` on the direct path);
#   (4) a pure-torsional-soft (concurrent-wall) layout is characterized.

@testset "Direction-complete: near-dead-Y layout is INFEASIBLE (P0 regression)" begin
    # The critic's exact near-dead-Y construction. Two strong X-walls at y = ±5
    # (k = kx) brace X-translation and torsion; a single near-dead Y-wall at the
    # origin (k = 1e-7·kx) nominally braces Y but is ~7 orders too soft. Under an
    # X-ONLY design load the layout LOOKS fine in the loaded direction, but its
    # orthogonal (+Y) diaphragm-translation mode is a near-zero-stiffness
    # mechanism. The direction-complete drift must expose +Y as wildly infeasible
    # while +X stays tiny — proving the fix catches what the OLD single-direction
    # (X-aligned) drift check would have wrongly accepted.
    SSE = StructuralSizer.SingularStiffnessError
    const_dcid = StructuralSizer.direction_complete_interstory_drift
    kx = 1e8
    ky = 1e-7 * kx                                   # near-dead Y restraint (= 10 N/m)
    walls = [WallLine(1, 0.0, -5.0, 0.0, kx, 1),
             WallLine(2, 0.0,  5.0, 0.0, kx, 1),
             WallLine(3, 0.0,  0.0, pi/2, ky, 1)]
    # Two X-walls at y = ±5 and the near-dead Y pier at the origin are symmetric about
    # the origin ⇒ TRUE plate center (0, 0). Supplies the corner-drift geometry so the
    # survivor re-validation certifies the +Y mechanism (status :infeasible, dir :Y)
    # rather than failing closed with :geometry_required.
    ev = ReducedDiaphragmEvaluator(story_heights=[3.0], plan_halfwidth=(0.0, 5.0),
                                   plate_center=(0.0, 0.0), accidental_ecc=0.05)
    drift_limit = 0.02                               # ASCE 7-22 Tbl 12.12-1 default (VERIFY)
    loads = [StoryLoad(1, 1e5, 0.0, 0.0, 0.0)]       # X-ONLY design load

    # --- Direction-complete drift: BOTH principal directions are swept. The +Y
    # near-dead mode yields a large FINITE drift (no throw — this is below the
    # rcond backstop, 1e-7·kx keeps K non-singular), so the per-story MAX becomes
    # hugely infeasible.
    dc = const_dcid(ev, walls, loads)
    @test dc.directions == [:X, :Y]
    @test all(isfinite, dc.drift)                    # finite drift, not a fail-closed throw
    uX = dc.drift[1, 1] / drift_limit
    uY = dc.drift[1, 2] / drift_limit
    @test uX < 0.1                                   # +X alone is tiny (≈ 0.0083)
    @test uY > 1.0e4                                 # +Y utilization ≫ 1 (≈ 1.7e5): a mechanism
    worst_util = maximum(dc.drift) / drift_limit
    @test worst_util > 1.0                           # ⇒ layout is INFEASIBLE

    # --- The OLD single-direction logic would have WRONGLY accepted this: the
    # direct X-only `evaluate_lateral` drift is well under the limit (the +X value
    # above), so an X-aligned drift check alone sees a "passing" layout.
    res = evaluate_lateral(ev, walls, loads)
    @test res.drift[1] / drift_limit < 0.1           # single-direction check would PASS

    # --- A `solve_wall_layout` problem built from this near-dead-Y geometry can no
    # longer return the collapse-under-Y layout as feasible. The Y candidate is a
    # physically near-dead pier (lw = 0.05 m, t_max = 0.02 m ⇒ k_max ≈ 2e2 N/m);
    # even driven to ρ = 1 it cannot brace +Y, so the survivor re-validation
    # refuses the selected layout.
    strongX(id, y) = WallCandidate(id, 0.0, y, 0.0, 4.0, 3.0, 1, 25e9, 0.2, 28e6,
                                   60e6*6.895, 2400.0, 0.1, 0.4, 0.0025)
    deadY = WallCandidate(3, 0.0, 0.0, pi/2, 0.05, 3.0, 1, 25e9, 0.2, 28e6,
                          60e6*6.895, 2400.0, 0.1, 0.02, 0.0025)
    cands = [strongX(1, -5.0), strongX(2, 5.0), deadY]
    prob = WallLayoutNLPProblem(cands, ev, loads; objective=MinCarbon(),
                                drift_limit=drift_limit)
    sol = solve_wall_layout(prob; maxiter=200)
    @test sol.feasible == false                      # NOT returned as a feasible solution
    @test sol.status == :infeasible
    @test sol.revalidation.ok == false
    @test sol.revalidation.worst_util > 1.0          # dead-direction drift ≫ limit
    @test sol.revalidation.failing.direction == :Y   # the +Y mechanism is what fails
end

@testset "Direction-complete: well-braced NOT falsely rejected, scale/origin invariant" begin
    # A genuinely well-braced symmetric core (2 X-walls at y = ±D, 2 Y-walls at
    # x = ±D) must PASS the direction-complete stability verdict at BOTH a small
    # (D = 5 m) and a large (D = 500 m) footprint — the non-dimensionalized
    # conditioning backstop must not reject a large-but-sound plan, and the
    # direction-complete drift utilization must stay ≤ 1 at every scale.
    const_dcid = StructuralSizer.direction_complete_interstory_drift
    drift_limit = 0.02
    mkbraced(D, k) = [WallLine(1, 0.0, -D, 0.0, k, 1), WallLine(2, 0.0, D, 0.0, k, 1),
                      WallLine(3, -D, 0.0, pi/2, k, 1), WallLine(4, D, 0.0, pi/2, k, 1)]
    loads = [StoryLoad(1, 1e5, 1e5, 0.0, 0.0)]       # bi-directional (both modes loaded)

    utils = Float64[]
    for D in (5.0, 500.0)
        ev = ReducedDiaphragmEvaluator(story_heights=[3.0], plan_halfwidth=(D, D),
                                       plate_center=(0.0, 0.0), accidental_ecc=0.05)
        dc = const_dcid(ev, mkbraced(D, 1e8), loads)
        @test all(isfinite, dc.drift)
        wu = maximum(dc.drift) / drift_limit
        @test wu <= 1.0                              # well-braced ⇒ feasible verdict
        push!(utils, wu)
    end
    # Stability verdict is SCALE-INVARIANT: identical worst utilization at 5 m and
    # 500 m footprints (the normalized conditioning gate removes the plan-scale
    # dependence that an un-normalized rcond would introduce).
    @test isapprox(utils[1], utils[2]; rtol=1e-9)

    # --- ORIGIN INVARIANCE: translating the whole layout AND the loads by a large
    # arbitrary offset must leave drift/torsion/utilization unchanged, because drift
    # is referenced to the center of rigidity (which translates with the layout),
    # not to the arbitrary input origin.
    D = 5.0; k = 1e8; off = (250.0, -300.0)          # large arbitrary plan offset [m]
    # Origin invariance requires translating the TRUE plate center JOINTLY with the
    # walls+loads: the untranslated core is centered at (0, 0), the translated one at
    # `off`. Two evaluators carry the two frames' plate centers.
    ev0 = ReducedDiaphragmEvaluator(story_heights=[3.0], plan_halfwidth=(D, D),
                                    plate_center=(0.0, 0.0), accidental_ecc=0.05)
    evT = ReducedDiaphragmEvaluator(story_heights=[3.0], plan_halfwidth=(D, D),
                                    plate_center=(off[1], off[2]), accidental_ecc=0.05)
    w0 = mkbraced(D, k)
    l0 = [StoryLoad(1, 1e5, 0.7e5, 0.0, 0.0)]        # asymmetric load ⇒ genuine torsion
    wT = [WallLine(w.id, w.x + off[1], w.y + off[2], w.θ, w.k, w.story) for w in w0]
    lT = [StoryLoad(l.story, l.Fx, l.Fy, l.ex + off[1], l.ey + off[2]) for l in l0]

    d0 = const_dcid(ev0, w0, l0).drift
    dT = const_dcid(evT, wT, lT).drift
    @test isapprox(d0, dT; atol=1e-12)               # direction-complete drift invariant
    e0 = evaluate_lateral(ev0, w0, l0)
    eT = evaluate_lateral(evT, wT, lT)
    @test isapprox(e0.drift[1], eT.drift[1]; atol=1e-12)        # primal drift invariant
    @test isapprox(e0.torsion[1], eT.torsion[1]; atol=1e-9)     # torsion amplification invariant

    # --- End-to-end: `solve_wall_layout` must ACCEPT a genuinely well-braced
    # layout as feasible (feasible = true, worst_util ≤ 1) at both footprints. A
    # MinDrift objective keeps the layout stiff (rather than thinning it to the
    # carbon-optimal drift boundary), isolating the re-validation gate: it must not
    # false-reject a sound bidirectional design.
    for D in (5.0, 500.0)
        cb = [WallCandidate(1, 0.0, -D, 0.0, 4.0, 3.0, 1, 25e9, 0.2, 28e6, 60e6*6.895,
                            2400.0, 0.1, 0.4, 0.0025),
              WallCandidate(2, 0.0,  D, 0.0, 4.0, 3.0, 1, 25e9, 0.2, 28e6, 60e6*6.895,
                            2400.0, 0.1, 0.4, 0.0025),
              WallCandidate(3, -D, 0.0, pi/2, 4.0, 3.0, 1, 25e9, 0.2, 28e6, 60e6*6.895,
                            2400.0, 0.1, 0.4, 0.0025),
              WallCandidate(4,  D, 0.0, pi/2, 4.0, 3.0, 1, 25e9, 0.2, 28e6, 60e6*6.895,
                            2400.0, 0.1, 0.4, 0.0025)]
        ev = ReducedDiaphragmEvaluator(story_heights=[3.0], plan_halfwidth=(D, D),
                                       plate_center=(0.0, 0.0), accidental_ecc=0.05)
        pb = WallLayoutNLPProblem(cb, ev, [StoryLoad(1, 5e4, 5e4, 0.0, 0.0)];
                                  objective=MinDrift(), drift_limit=drift_limit)
        rb = solve_wall_layout(pb; maxiter=200)
        @test rb.feasible == true                    # well-braced ⇒ accepted
        @test rb.revalidation.worst_util <= 1.0      # comfortably inside the drift limit
    end
end

@testset "Direction-complete: fail-closed preserved (singular layout still throws)" begin
    # Demoting the rcond throw to a backstop must NOT weaken the fail-closed
    # contract: a GENUINELY singular / under-braced layout (all walls parallel to
    # X ⇒ zero Y restraint ⇒ rank-deficient 3×3 K) must still raise
    # SingularStiffnessError on the direct `evaluate_lateral` path, never a
    # fabricated finite displacement.
    SSE = StructuralSizer.SingularStiffnessError
    ev = ReducedDiaphragmEvaluator(story_heights=[3.0], plan_halfwidth=(5.0, 5.0),
                                   accidental_ecc=0.0)
    underbraced = [WallLine(1, 0.0, -5.0, 0.0, 1e7, 1), WallLine(2, 0.0, 5.0, 0.0, 1e7, 1)]
    @test_throws SSE evaluate_lateral(ev, underbraced, [StoryLoad(1, 1e5, 1e5, 0.0, 0.0)])
    # And the analytic sensitivity fails closed on the same layout (no K+εI fudge).
    @test_throws SSE story_drift_sensitivity(ev, underbraced, [StoryLoad(1, 1e5, 1e5, 0.0, 0.0)], 1)
end

@testset "Direction-complete: pure-torsional-soft (concurrent walls) characterization" begin
    # EXPLORATORY: characterize a layout with NO torsional restraint — two walls
    # (one X, one Y) BOTH passing through the plan origin. Each wall's geometry
    # vector has a zero moment arm (b = [cx, cy, cy·x − cx·y] with x = y = 0), so
    # the story K has NO rotational stiffness (K33 = 0): the twist DOF is a pure
    # mechanism even though both translational directions ARE braced.
    #
    # OBSERVED / DOCUMENTED BEHAVIOR: the rank-deficient rotational mode makes K
    # singular, so `evaluate_lateral` fails CLOSED with SingularStiffnessError —
    # the torsional mechanism is refused, not papered over with a fabricated
    # displacement. This holds WITH accidental eccentricity (a real applied twist)
    # AND with it OFF (the degeneracy is in K itself, independent of the load), so
    # the intended fail-closed behavior is unambiguous and is asserted here.
    SSE = StructuralSizer.SingularStiffnessError
    concurrent = [WallLine(1, 0.0, 0.0, 0.0, 1e7, 1), WallLine(2, 0.0, 0.0, pi/2, 1e7, 1)]
    load = [StoryLoad(1, 1e5, 1e5, 0.0, 0.0)]
    ev_ecc = ReducedDiaphragmEvaluator(story_heights=[3.0], plan_halfwidth=(5.0, 5.0),
                                       accidental_ecc=0.05)
    ev_noecc = ReducedDiaphragmEvaluator(story_heights=[3.0], plan_halfwidth=(5.0, 5.0),
                                         accidental_ecc=0.0)
    @test_throws SSE evaluate_lateral(ev_ecc, concurrent, load)    # applied twist → fail-closed
    @test_throws SSE evaluate_lateral(ev_noecc, concurrent, load)  # degeneracy is in K itself
end

# ==============================================================================
# Eigenstructure lateral-stability gate — verification tests
# ==============================================================================
# Lateral stability for the reduced tier is now DEFINED by the stiffness
# EIGENSTRUCTURE, not the (twist-blind) center-of-rigidity drift:
#   * TRANSLATIONAL floor — λmin(K_tt) ≥ F_s/(h·DL) (the SOFTEST translational mode,
#     subsuming the +X/+Y sweep and closing the √2 diagonal-weak-mode gap);
#   * TORSIONAL floor — K_theta_cr (Schur complement of K_tt, the condensed twist
#     stiffness about the center of rigidity) ≥ F_s·e_acc·r_ref/(h·DL).
# The optimizer folds util_trans/util_tors into the drift/torsion constraint slots,
# and `solve_wall_layout`'s survivor re-validation re-checks the FULL set
# (drift + torsion + eigen + shear), returning feasible::Bool + status. The five
# testsets below verify, in order:
#   (1) P0 TORSIONAL regression — a tightly-clustered symmetric core whose twist
#       stiffness is a mechanism (util_tors ≫ 1) even though its direction-complete
#       DRIFT utilization is tiny — proving the old drift-only metric was blind to
#       the spinning diaphragm, which `solve_wall_layout` now refuses;
#   (2) DIAGONAL regression — λmin(K_tt) reads the TRUE weak diagonal mode (no
#       axis-only √2 under-measure);
#   (3) a near-dead-Y layout is STILL rejected (feasible = false);
#   (4) a well-braced bidirectional core is NOT falsely rejected at a small OR a
#       large footprint, and the verdict is scale- and origin-invariant;
#   (5) fail-closed is preserved — a genuinely singular/under-braced layout and a
#       concurrent-walls (zero-arm) torsional mechanism both throw.

@testset "Eigenstructure (1): clustered-core TORSIONAL mechanism is INFEASIBLE (P0)" begin
    # crit3's clustered-core construction. Four stiff piers (k = 1e8) clustered a
    # tiny d = 0.0141 m from the plan center — two along X (θ = 0) at y = ±d, two
    # along Y (θ = π/2) at x = ±d — on a 20×20 m plan (plan_halfwidth = (10, 10)).
    # The translational block is strong (K_tt = diag(2k, 2k)), but the torsional
    # arms are microscopic, so the condensed torsional stiffness collapses to
    #   K_theta_cr = Σ k·arm² = 4·k·d² = 4·1e8·0.0141² ≈ 79524 N·m.
    # Under F_s = 1e6 N the diaphragm can SPIN: the torsional eigen-utilization is
    # ≫ 1 while the (twist-blind) direction-complete DRIFT utilization stays tiny —
    # exactly the hole the old drift-only metric missed.
    SSE     = StructuralSizer.SingularStiffnessError
    eig_fn  = StructuralSizer.eigenstructure_stability
    dcid_fn = StructuralSizer.direction_complete_interstory_drift
    k = 1e8
    d = 0.0141
    h = 3.0
    drift_limit = 0.02
    walls = [WallLine(1, 0.0,  d, 0.0,  k, 1),   # X-wall, arm −d
             WallLine(2, 0.0, -d, 0.0,  k, 1),   # X-wall, arm +d
             WallLine(3,  d, 0.0, pi/2, k, 1),   # Y-wall, arm +d
             WallLine(4, -d, 0.0, pi/2, k, 1)]   # Y-wall, arm −d
    # Clustered piers are symmetric about the origin ⇒ TRUE plate center (0, 0); supplies
    # the twist geometry so util_tors is the EXACT torsional floor (not the Inf sentinel)
    # and solve_wall_layout certifies the spin as :infeasible (not :geometry_required).
    ev = ReducedDiaphragmEvaluator(story_heights=[h], plan_halfwidth=(10.0, 10.0),
                                   plate_center=(0.0, 0.0), accidental_ecc=0.05)
    loads = [StoryLoad(1, 1e6, 0.0, 0.0, 0.0)]   # F_s = 1e6 N (X-only)

    # --- Eigenstructure gate: the TORSIONAL mode is infeasible (util_tors ≫ 1),
    #     with K_theta_cr ≈ 79524 N·m, while the TRANSLATIONAL mode is comfortable.
    eig = eig_fn(ev, walls, loads, drift_limit)
    @test isapprox(eig.K_theta_cr[1], 79524.0; rtol=2e-3)   # 4·k·d² condensed twist stiffness
    @test eig.util_tors[1] > 1.0                            # torsional mechanism exposed
    @test eig.util_tors[1] > 1.0e2                          # ≫ 1 (≈ 2964): a spinning diaphragm
    @test eig.util_trans[1] < 1.0                           # translation is fine (≈ 0.083)

    # --- The OLD drift-only metric was BLIND to this: the direction-complete drift
    #     utilization (CR translation, independent of φ) is tiny (< ~0.1), so a
    #     drift-only check would have WRONGLY accepted the spinning core.
    dc = dcid_fn(ev, walls, loads)
    @test all(isfinite, dc.drift)
    @test maximum(dc.drift) / drift_limit < 0.1            # drift-only util small (≈ 0.083)

    # --- solve_wall_layout on this geometry can no longer return the spinning
    #     diaphragm as feasible. The clustered arms are geometric — no density can
    #     lift K_theta_cr to adequacy — so the survivor re-validation refuses it.
    mkcand(id, x, y, θ) = WallCandidate(id, x, y, θ, 4.0, h, 1, 25e9, 0.2, 28e6,
                                        60e6*6.895, 2400.0, 0.1, 0.4, 0.0025)
    cands = [mkcand(1, 0.0,  d, 0.0), mkcand(2, 0.0, -d, 0.0),
             mkcand(3,  d, 0.0, pi/2), mkcand(4, -d, 0.0, pi/2)]
    prob = WallLayoutNLPProblem(cands, ev, loads; objective=MinCarbon(),
                                drift_limit=drift_limit)
    sol = solve_wall_layout(prob; maxiter=200)
    @test sol.feasible == false                            # spinning diaphragm NOT returned
    @test sol.status == :infeasible
    @test sol.revalidation.ok == false
    @test sol.revalidation.worst_util > 1.0               # torsional mode ≫ limit
end

@testset "Eigenstructure (2): DIAGONAL weak mode read exactly (no √2 under-measure)" begin
    # A strong brace along the 45° diagonal (k = 1e10, θ = π/4) and a weak brace
    # along the orthogonal 135° diagonal (k = 1e8, θ = 3π/4). The two unit axes are
    # orthonormal, so the translational block's eigenpairs are EXACTLY {1e10, 1e8}
    # along {45°, 135°}. The old axis-only (+X/+Y) sweep measured K11 = K22 =
    # (1e10 + 1e8)/2 = 5.05e9 — ~50× stiffer than the true weak mode — so it
    # UNDER-measured the real diagonal drift. λmin(K_tt) now reports the true 1e8.
    spec_fn = StructuralSizer._translational_block_spectrum
    asm_fn  = StructuralSizer._assemble_story_K
    walls = [WallLine(1,  3.0, 0.0, pi/4,   1e10, 1),     # strong along 45°
             WallLine(2, -3.0, 0.0, 3pi/4,  1e8,  1)]     # weak along 135°
    K = asm_fn(walls)
    spec = spec_fn(K)
    @test isapprox(spec.λmin, 1e8;  rtol=1e-5)            # TRUE weak diagonal mode
    @test isapprox(spec.λmax, 1e10; rtol=1e-5)            # strong diagonal mode
    # The weak eigenvector points along the 135° diagonal (|vx| = |vy| = 1/√2).
    @test isapprox(abs(spec.vmin[1]), 1/sqrt(2); rtol=1e-4)
    @test isapprox(abs(spec.vmin[2]), 1/sqrt(2); rtol=1e-4)
    # The axis-only sweep would read K11, K22 ≫ λmin ⇒ it UNDER-measures the weak
    # mode by ~50× here (the √2+ diagonal gap the eigen-spectrum now closes).
    @test K[1, 1] > 10 * spec.λmin
    @test K[2, 2] > 10 * spec.λmin
end

@testset "Eigenstructure (3): near-dead-Y layout is STILL rejected (feasible = false)" begin
    # Two strong X-walls (k_max large) at y = ±5 brace X + torsion; a single
    # near-dead Y pier at the origin (lw = 0.05 m, t_max = 0.02 m ⇒ k_max ≈ 2e2 N/m)
    # nominally braces Y but is ~7 orders too soft. Even driven to ρ = 1 it cannot
    # brace +Y, so the softest translational eigenvalue is a mechanism and the
    # survivor re-validation must refuse the selected layout.
    drift_limit = 0.02
    # Symmetric about the origin ⇒ TRUE plate center (0, 0); supplies the twist geometry
    # so the survivor re-validation rejects the +Y mechanism as :infeasible.
    ev = ReducedDiaphragmEvaluator(story_heights=[3.0], plan_halfwidth=(0.0, 5.0),
                                   plate_center=(0.0, 0.0), accidental_ecc=0.05)
    loads = [StoryLoad(1, 1e5, 0.0, 0.0, 0.0)]            # X-only design load
    strongX(id, y) = WallCandidate(id, 0.0, y, 0.0, 4.0, 3.0, 1, 25e9, 0.2, 28e6,
                                   60e6*6.895, 2400.0, 0.1, 0.4, 0.0025)
    deadY = WallCandidate(3, 0.0, 0.0, pi/2, 0.05, 3.0, 1, 25e9, 0.2, 28e6,
                          60e6*6.895, 2400.0, 0.1, 0.02, 0.0025)
    cands = [strongX(1, -5.0), strongX(2, 5.0), deadY]
    prob = WallLayoutNLPProblem(cands, ev, loads; objective=MinCarbon(),
                                drift_limit=drift_limit)
    sol = solve_wall_layout(prob; maxiter=200)
    @test sol.feasible == false                           # near-dead Y ⇒ NOT returned
    @test sol.status == :infeasible
    @test sol.revalidation.worst_util > 1.0               # dead-direction mode ≫ limit
end

@testset "Eigenstructure (4): well-braced NOT falsely rejected; scale/origin invariant" begin
    # A genuinely well-braced symmetric core (2 X-walls at y = ±D, 2 Y-walls at
    # x = ±D) must PASS the eigenstructure gate at BOTH a small (D = 5 m) and a
    # large (D = 500 m) footprint, with util_trans, util_tors < 1 — and the
    # dimensionless utilizations must be IDENTICAL across scale (both demand floors
    # and the condensed stiffnesses scale with D together, so the ratios cancel).
    eig_fn  = StructuralSizer.eigenstructure_stability
    dcid_fn = StructuralSizer.direction_complete_interstory_drift
    drift_limit = 0.02
    k = 1e9
    mkbraced(D) = [WallLine(1, 0.0, -D, 0.0,  k, 1), WallLine(2, 0.0, D, 0.0,  k, 1),
                   WallLine(3, -D, 0.0, pi/2, k, 1), WallLine(4, D, 0.0, pi/2, k, 1)]
    loads = [StoryLoad(1, 5e4, 5e4, 0.0, 0.0)]           # bi-directional (both modes loaded)

    utr = Float64[]; uto = Float64[]
    for D in (5.0, 500.0)
        ev  = ReducedDiaphragmEvaluator(story_heights=[3.0], plan_halfwidth=(D, D),
                                        plate_center=(0.0, 0.0), accidental_ecc=0.05)
        eig = eig_fn(ev, mkbraced(D), loads, drift_limit)
        @test eig.util_trans[1] < 1.0                    # well-braced ⇒ translation OK
        @test eig.util_tors[1]  < 1.0                    # well-braced ⇒ twist OK
        push!(utr, eig.util_trans[1]); push!(uto, eig.util_tors[1])
    end
    # SCALE INVARIANCE: identical eigen-utilizations at 5 m and 500 m footprints.
    @test isapprox(utr[1], utr[2]; rtol=1e-9)
    @test isapprox(uto[1], uto[2]; rtol=1e-9)

    # --- ORIGIN INVARIANCE: translating the whole layout AND the loads by a large
    #     arbitrary offset leaves the eigen-utilizations, direction-complete drift,
    #     and torsion amplification UNCHANGED (K_tt is origin-free, K_theta_cr is the
    #     Schur complement about the CR, which translates with the layout).
    D = 5.0; off = (250.0, -300.0)
    # Origin invariance: translate the TRUE plate center JOINTLY with the walls+loads.
    # Untranslated core centered at (0, 0); translated core at `off`.
    ev0 = ReducedDiaphragmEvaluator(story_heights=[3.0], plan_halfwidth=(D, D),
                                    plate_center=(0.0, 0.0), accidental_ecc=0.05)
    evT = ReducedDiaphragmEvaluator(story_heights=[3.0], plan_halfwidth=(D, D),
                                    plate_center=(off[1], off[2]), accidental_ecc=0.05)
    w0 = mkbraced(D)
    l0 = [StoryLoad(1, 1e5, 0.7e5, 0.0, 0.0)]           # asymmetric ⇒ genuine torsion
    wT = [WallLine(w.id, w.x + off[1], w.y + off[2], w.θ, w.k, w.story) for w in w0]
    lT = [StoryLoad(l.story, l.Fx, l.Fy, l.ex + off[1], l.ey + off[2]) for l in l0]
    e0 = eig_fn(ev0, w0, l0, drift_limit); eT = eig_fn(evT, wT, lT, drift_limit)
    @test isapprox(e0.util_trans[1], eT.util_trans[1]; rtol=1e-9)
    @test isapprox(e0.util_tors[1],  eT.util_tors[1];  rtol=1e-9)
    @test isapprox(dcid_fn(ev0, w0, l0).drift, dcid_fn(evT, wT, lT).drift; atol=1e-12)
    r0 = evaluate_lateral(ev0, w0, l0); rT = evaluate_lateral(evT, wT, lT)
    @test isapprox(r0.torsion[1], rT.torsion[1]; rtol=1e-9)

    # --- End-to-end: solve_wall_layout ACCEPTS the sound bidirectional core as
    #     feasible (feasible = true, worst_util ≤ 1) at BOTH footprints. A MinDrift
    #     objective keeps it stiff, isolating the re-validation gate from the
    #     carbon-driven thinning so it must not false-reject a well-braced design.
    for D in (5.0, 500.0)
        cb = [WallCandidate(1, 0.0, -D, 0.0, 4.0, 3.0, 1, 25e9, 0.2, 28e6, 60e6*6.895,
                            2400.0, 0.1, 0.4, 0.0025),
              WallCandidate(2, 0.0,  D, 0.0, 4.0, 3.0, 1, 25e9, 0.2, 28e6, 60e6*6.895,
                            2400.0, 0.1, 0.4, 0.0025),
              WallCandidate(3, -D, 0.0, pi/2, 4.0, 3.0, 1, 25e9, 0.2, 28e6, 60e6*6.895,
                            2400.0, 0.1, 0.4, 0.0025),
              WallCandidate(4,  D, 0.0, pi/2, 4.0, 3.0, 1, 25e9, 0.2, 28e6, 60e6*6.895,
                            2400.0, 0.1, 0.4, 0.0025)]
        ev = ReducedDiaphragmEvaluator(story_heights=[3.0], plan_halfwidth=(D, D),
                                       plate_center=(0.0, 0.0), accidental_ecc=0.05)
        pb = WallLayoutNLPProblem(cb, ev, [StoryLoad(1, 5e4, 5e4, 0.0, 0.0)];
                                  objective=MinDrift(), drift_limit=drift_limit)
        rb = solve_wall_layout(pb; maxiter=200)
        @test rb.feasible == true                        # well-braced ⇒ accepted
        @test rb.revalidation.worst_util <= 1.0          # comfortably within limits
    end
end

@testset "Eigenstructure (5): fail-closed preserved (singular + zero-arm torsion refused)" begin
    # Demoting the rcond throw to a backstop must NOT weaken the fail-closed
    # contract. Two genuine mechanisms must still be REFUSED, both via the direct
    # `evaluate_lateral` path AND via the load-independent guards in the
    # eigenstructure gate itself:
    #   (a) an under-braced translational mechanism (all walls ∥ X ⇒ no Y restraint
    #       ⇒ λmin(K_tt) = 0);
    #   (b) a concurrent-walls torsional mechanism (one X, one Y BOTH through the
    #       plan origin ⇒ zero moment arms ⇒ K_theta_cr = 0, the diaphragm spins
    #       freely even though both translational directions are braced).
    SSE    = StructuralSizer.SingularStiffnessError
    eig_fn = StructuralSizer.eigenstructure_stability
    drift_limit = 0.02
    ev = ReducedDiaphragmEvaluator(story_heights=[3.0], plan_halfwidth=(5.0, 5.0),
                                   accidental_ecc=0.05)

    # (a) under-braced translational mechanism — direct path AND eigen gate throw.
    underbraced = [WallLine(1, 0.0, -5.0, 0.0, 1e7, 1), WallLine(2, 0.0, 5.0, 0.0, 1e7, 1)]
    bidir = [StoryLoad(1, 1e5, 1e5, 0.0, 0.0)]
    @test_throws SSE evaluate_lateral(ev, underbraced, bidir)
    @test_throws SSE eig_fn(ev, underbraced, bidir, drift_limit)

    # (b) concurrent-walls (zero-arm) torsional mechanism — refused regardless of
    #     load (the twist DOF is a mechanism in K itself), by both paths.
    concurrent = [WallLine(1, 0.0, 0.0, 0.0, 1e7, 1), WallLine(2, 0.0, 0.0, pi/2, 1e7, 1)]
    @test_throws SSE evaluate_lateral(ev, concurrent, bidir)
    @test_throws SSE eig_fn(ev, concurrent, bidir, drift_limit)
    ev0 = ReducedDiaphragmEvaluator(story_heights=[3.0], plan_halfwidth=(5.0, 5.0),
                                    accidental_ecc=0.0)
    @test_throws SSE eig_fn(ev0, concurrent, bidir, drift_limit)   # load-independent
end

# ==============================================================================
# crit4 fix — EXACT max-corner interstory drift (ASCE 7-22 §12.12.1)
# ==============================================================================
# crit4 proved a P1 (round-4 red team): the eigenstructure gate certifies STIFFNESS
# exactly, but the bridge from the stiffness floor to the DRIFT LIMIT assumed the
# center of rigidity sat at the plan center — r_ref = hypot(hx, hy) and the torsion
# corners taken at CR ± (hx, hy). For a stiffness-ECCENTRIC layout the true CR-to-
# corner lever is larger, so the serviceability bound was placed on the twist-BLIND
# CR-translation drift plus a SATURATING torsion ratio (capped at 1.5) — permitting a
# true corner drift above the limit. ASCE 7-22 §12.12.1 bounds the amplified design
# story drift AT THE LOCATION (the building edge, incl. diaphragm rotation per
# §12.8.6.5) to Δ_a.
#
# CURRENT FIX (supersedes the round-4 wall-centroid proxy AND the round-5 conservative
# r_bound = hypot(2·hx, 2·hy) `_lever_bound` fail-safe — both REMOVED): the twist
# metrics are now EXACT. They anchor the four occupant corners to the TRUE floor-plate
# center `ReducedDiaphragmEvaluator.plate_center` (supplied per fixture) and evaluate
# the rigid-diaphragm displacement at each corner p = plate_center ± (hx, hy) directly:
# corner_drift = max_p hypot(δx − φ·p_y, δy + φ·p_x)/h — no slack, correct even when the
# CR lies outside the plate. Without plate_center the metrics FAIL CLOSED to Inf (never
# a wall-centroid / origin / plate-span proxy). The crit4 assertions below are UPDATED
# to the EXACT numbers (e.g. corner_util ≈ 1.135× here, vs the old conservative ~1.68×).
#
# The current fix (lateral_evaluator.jl + layout_problem.jl):
#   * `direction_complete_interstory_drift` returns `corner_drift` — the EXACT max-corner
#     interstory drift over the four TRUE occupant corners `plate_center ± (hx, hy)`, the
#     physical UNCAPPED torsional drift at the building edges; the prior CR-translation-
#     only `.drift` field is preserved for serviceability / origin-invariant known-answer
#     tests;
#   * `eigenstructure_stability`'s torsional floor uses the EXACT CR-to-corner lever
#     r_ref = max_corner hypot(corner − CR);
#   * `constraint_fns` / `solve_wall_layout` survivor re-validation check `corner_drift`
#     AND the `res.torsion/torsion_limit` amplification ratio (δ_max EXACT over the four
#     TRUE corners) as a feasibility GATE, returning feasible::Bool + status (:infeasible),
#     with `revalidation.worst_util` / `.failing` resolved in priority order
#     (drift → eigen floors → torsion → shear).
#
# The four testsets below verify, in order:
#   (1) P1a REGRESSION — the eccentric-CR probe (CR xr ≈ 6.861) is now INFEASIBLE
#       because the EXACT max-corner drift exceeds DL (~1.135×), even though the
#       CR-translation `.drift` the old metric bounded was ≤ DL;
#   (2) the eccentric torsional floor reads the EXACT CR-to-corner lever
#       r_ref = hypot(hx + |xr|, hy) ≈ 17.59 m, not the old plan half-diagonal (11.18 m)
#       nor the removed conservative plate-span bound hypot(2hx, 2hy) ≈ 22.36 m;
#   (3) a SYMMETRIC well-braced core is UNCHANGED — feasible, worst_util ≤ 1, at a
#       small AND a large footprint, origin- and scale-invariant (no false reject);
#   (4) the prior mechanisms (near-dead-Y, crit3 clustered-core torsion, diagonal)
#       are STILL rejected and fail-closed (SingularStiffnessError) is preserved.

@testset "crit4 (1): eccentric-CR max-corner drift is INFEASIBLE (P1a regression)" begin
    # crit4's exact P1a construction (reproducer:
    # scripts/runners/attack_wall_eigenstructure_gate.jl). A 20 m × 10 m plan
    # (plan_halfwidth = (10, 5)): two X-walls at y = ±5 (k = 1.3·KUNIT) brace X and
    # torsion; two Y-walls at x = ±7 with a 100:1 strong/weak stiffness ratio
    # (3·KUNIT at +7, 0.03·KUNIT at −7) push the center of rigidity to xr ≈ 6.861 m
    # (near the +x plan edge). A pure-Y design resultant applied AT the CR (so the
    # DESIGN eccentricity is ~0; the twist comes only from the code's own accidental
    # eccentricity) loads the layout to the CR-translation drift limit.
    dcid_fn = StructuralSizer.direction_complete_interstory_drift
    tol = StructuralSizer.SURVIVOR_DRIFT_UTIL_TOL
    KUNIT = wall_stiffness_from_thickness_si(0.3, 5.0, 25e9, 0.2, 3.0; cracked=true)
    DL = 0.02                                        # ASCE 7-22 Table 12.12-1 typical (VERIFY)
    walls = [WallLine(1, 0.0, -5.0, 0.0,  1.3*KUNIT, 1),
             WallLine(2, 0.0,  5.0, 0.0,  1.3*KUNIT, 1),
             WallLine(3,  7.0, 0.0, pi/2, 3.0*KUNIT, 1),   # strong Y-wall (+x)
             WallLine(4, -7.0, 0.0, pi/2, 0.03*KUNIT, 1)]  # weak   Y-wall (−x)
    # The PLATE is centered at the origin (plan_halfwidth (10, 5) ⇒ corners (±10, ±5)):
    # the eccentricity is in the STIFFNESS (CR at xr ≈ 6.861), NOT the plate geometry, so
    # the TRUE plate center is (0, 0). Supplies the EXACT corner-drift / torsion geometry.
    ev = ReducedDiaphragmEvaluator(story_heights=[3.0], plan_halfwidth=(10.0, 5.0),
                                   plate_center=(0.0, 0.0), accidental_ecc=0.05)
    K = StructuralSizer._assemble_story_K(walls)
    xr, yr = StructuralSizer._center_of_rigidity(K)
    @test isapprox(xr, 6.861; atol=2e-3)             # eccentric CR near the +x plan edge
    @test isapprox(yr, 0.0;   atol=1e-9)
    # Pure-Y resultant at the CR, scaled so the CR-translation drift sits at DL
    # (softest translational mode util = 1): the serviceability bound is exactly met.
    λmin = StructuralSizer._translational_block_spectrum(K).λmin
    Fy = DL * λmin * 3.0
    loads = [StoryLoad(1, 0.0, Fy, xr, yr)]

    dc = dcid_fn(ev, walls, loads)
    @test dc.directions == [:X, :Y]
    @test all(isfinite, dc.corner_drift)

    # --- OLD metric PASSES: both the CR-translation serviceability drift (the
    #     `.drift` field, swept in both directions) and the direct primal drift are
    #     ≤ DL — exactly why the previous bound accepted this unsafe layout.
    @test maximum(dc.drift) / DL <= 1.0 + tol        # CR-translation (both dirs) ≤ DL
    res = evaluate_lateral(ev, walls, loads)
    @test res.drift[1] / DL < 1.0                    # direct primal (pure-Y) ≈ 0.86 ≤ DL

    # --- NEW metric FAILS: the EXACT max-corner interstory drift exceeds DL. Each corner
    #     p = plate_center ± (hx, hy) displaces by (δx − φ·p_y, δy + φ·p_x); corner_drift
    #     is the max over the four TRUE occupant corners of hypot(disp)/h — EXACT (no
    #     slack), correct even though the CR sits near the +x plate edge. This is the
    #     physical ASCE 7-22 §12.12.1 quantity (edges incl. diaphragm rotation, §12.8.6.5).
    #     The exact lever hypot(hx + |xr|, hy) = hypot(16.861, 5) ≈ 17.587 m yields
    #     corner_util ≈ 1.135× DL (the earlier conservative r_bound = hypot(2hx, 2hy)
    #     over-stated this at ~1.68×; the exact metric is tighter but still INFEASIBLE).
    corner_util = maximum(dc.corner_drift) / DL
    @test corner_util > 1.0                          # INFEASIBLE on the exact max-corner drift
    @test isapprox(corner_util, 1.1348; atol=0.01)   # ≈ 1.135× DL (EXACT eccentric lever)
    @test corner_util > maximum(dc.drift) / DL       # corner ≫ twist-blind CR translation

    # --- End-to-end: solve_wall_layout can no longer return this eccentric layout
    #     as feasible. Candidates reproduce the ρ=1 stiffness RATIOS (kx:kys:kyw =
    #     1.3:3:0.03 via linear-in-thickness t_max), so the STIFFEST achievable
    #     build still has corner drift > DL — no density can re-center the CR, so the
    #     survivor re-validation refuses it on the drift bound.
    mkc(id, x, y, θ, t_max) =
        WallCandidate(id, x, y, θ, 5.0, 3.0, 1, 25e9, 0.2, 28e6, 60e6*6.895,
                      2400.0, 0.1, t_max, 0.0025)
    cands = [mkc(1, 0.0, -5.0, 0.0,  0.1733), mkc(2, 0.0, 5.0, 0.0, 0.1733),
             mkc(3, 7.0, 0.0, pi/2, 0.4),     mkc(4, -7.0, 0.0, pi/2, 0.004)]
    prob0 = WallLayoutNLPProblem(cands, ev, [StoryLoad(1, 0.0, 1.0, 0.0, 0.0)];
                                 objective=MinCarbon(), drift_limit=DL)
    walls1 = StructuralSizer._walls_from_density(prob0, fill(1.0, 4))   # fully-built
    K1 = StructuralSizer._assemble_story_K(walls1)
    xr1, yr1 = StructuralSizer._center_of_rigidity(K1)
    @test isapprox(xr1, 6.861; atol=2e-3)            # candidate CR matches the probe
    λmin1 = StructuralSizer._translational_block_spectrum(K1).λmin
    Fy1 = DL * λmin1 * 3.0
    prob = WallLayoutNLPProblem(cands, ev, [StoryLoad(1, 0.0, Fy1, xr1, yr1)];
                                objective=MinCarbon(), drift_limit=DL)
    sol = solve_wall_layout(prob; maxiter=200)
    @test sol.feasible == false                      # NOT returned as feasible
    @test sol.status == :infeasible
    @test sol.revalidation.ok == false
    @test sol.revalidation.worst_util > 1.0          # beyond DL
    @test sol.revalidation.failing.mode == :drift    # caught on the EXACT max-corner drift
    @test sol.revalidation.failing.direction == :X   # +X canonical case governs the EXACT corner drift
end

@testset "crit4 (2): eccentric torsional floor uses the EXACT CR-to-corner lever" begin
    # The eigenstructure TORSIONAL floor requires K_theta_cr ≥ F_s·e_acc·r_ref/(h·DL),
    # with r_ref the CR-to-extreme-corner lever. The current fix evaluates r_ref EXACTLY:
    # r_ref = max_corner hypot(corner − CR) over the four TRUE occupant corners
    # plate_center ± (hx, hy) = hypot(hx + |xr − cx|, hy + |yr − cy|) = hypot(16.861, 5) ≈
    # 17.587 m (plate_center = (0, 0) here). This is SMALLER than the removed conservative
    # plate-span bound r_bound = hypot(2·hx, 2·hy) = hypot(20, 10) ≈ 22.361 m but LARGER
    # than the old CR-centered half-diagonal hypot(10, 5) = 11.180 m. Back out the r_ref
    # the floor actually used from util_tors and confirm it is the EXACT eccentric lever.
    eig_fn = StructuralSizer.eigenstructure_stability
    KUNIT = wall_stiffness_from_thickness_si(0.3, 5.0, 25e9, 0.2, 3.0; cracked=true)
    DL = 0.02; acc = 0.05; h = 3.0; hx = 10.0; hy = 5.0
    walls = [WallLine(1, 0.0, -5.0, 0.0,  1.3*KUNIT, 1),
             WallLine(2, 0.0,  5.0, 0.0,  1.3*KUNIT, 1),
             WallLine(3,  7.0, 0.0, pi/2, 3.0*KUNIT, 1),
             WallLine(4, -7.0, 0.0, pi/2, 0.03*KUNIT, 1)]
    # TRUE plate center is (0, 0) — the plate is origin-centered; only the CR is eccentric.
    ev = ReducedDiaphragmEvaluator(story_heights=[h], plan_halfwidth=(hx, hy),
                                   plate_center=(0.0, 0.0), accidental_ecc=acc)
    K = StructuralSizer._assemble_story_K(walls)
    xr, yr = StructuralSizer._center_of_rigidity(K)
    cx, cy = (0.0, 0.0)                               # TRUE plate center (not the wall centroid)
    r_exact = hypot(hx + abs(xr - cx), hy + abs(yr - cy))  # EXACT CR-to-corner lever
    r_bound = hypot(2hx, 2hy)                         # removed conservative plate-span bound
    r_old   = hypot(hx, hy)                           # old (plan-centered) half-diagonal
    @test isapprox(r_exact, 17.587; atol=2e-2)       # EXACT eccentric lever hypot(hx+|xr|, hy)
    @test isapprox(r_bound, 22.361; atol=2e-2)       # removed conservative bound (≥ r_exact)
    @test isapprox(r_old,   11.180; atol=2e-2)       # old (plan-centered) under-estimate
    @test r_bound > r_exact > r_old                  # EXACT lever sits between the two

    # Pure-Y resultant (F_s = Fy); util_tors scales with F_s and K_theta_cr is
    # load-independent, so the r_ref the floor used cancels F_s when backed out:
    #   util_tors = F_s·e_acc·r_ref/(h·DL·K_theta_cr)  ⇒  r_ref = util_tors·K_theta_cr·h·DL/(F_s·e_acc).
    Fy = 1.0e6
    loads = [StoryLoad(1, 0.0, Fy, xr, yr)]
    eig = eig_fn(ev, walls, loads, DL)
    e_acc = acc * max(2hx, 2hy)                       # = 0.05·20 = 1.0 (larger plan dim)
    r_ref_implied = eig.util_tors[1] * eig.K_theta_cr[1] * h * DL / (Fy * e_acc)
    @test isapprox(r_ref_implied, r_exact; rtol=1e-3) # floor uses the EXACT CR-to-corner lever
    @test !isapprox(r_ref_implied, r_old;   rtol=0.1) # NOT the old 11.18 m half-diagonal
    @test !isapprox(r_ref_implied, r_bound; rtol=0.1) # NOR the removed 22.36 m conservative bound
end

@testset "crit4 (3): symmetric well-braced core UNCHANGED (no false rejection)" begin
    # For a symmetric core the CR sits at the plan center (= wall centroid), so the
    # true corners pc ± (hx, hy) coincide with the old CR ± (hx, hy): the new
    # `corner_drift` safety bound must leave a genuinely well-braced design feasible
    # with worst_util ≤ 1 at a small AND a large footprint — a regression guard
    # against the corner-drift change causing a false-positive rejection.
    dcid_fn = StructuralSizer.direction_complete_interstory_drift
    DL = 0.02
    mkbraced(D, k) = [WallLine(1, 0.0, -D, 0.0,  k, 1), WallLine(2, 0.0, D, 0.0,  k, 1),
                      WallLine(3, -D, 0.0, pi/2, k, 1), WallLine(4, D, 0.0, pi/2, k, 1)]
    loads = [StoryLoad(1, 5e4, 5e4, 0.0, 0.0)]       # bi-directional

    cutils = Float64[]
    for D in (5.0, 500.0)
        ev = ReducedDiaphragmEvaluator(story_heights=[3.0], plan_halfwidth=(D, D),
                                       plate_center=(0.0, 0.0), accidental_ecc=0.05)
        dc = dcid_fn(ev, mkbraced(D, 1e9), loads)
        @test all(isfinite, dc.corner_drift)
        cu = maximum(dc.corner_drift) / DL
        @test cu <= 1.0                              # well-braced ⇒ corner drift ≤ DL
        push!(cutils, cu)
    end
    # SCALE INVARIANCE: identical corner-drift utilization at 5 m and 500 m.
    @test isapprox(cutils[1], cutils[2]; rtol=1e-9)

    # ORIGIN INVARIANCE: translating layout + loads AND the TRUE plate center JOINTLY by a
    # large arbitrary offset leaves the EXACT corner_drift unchanged (corners are anchored
    # to plate_center, which translates with the layout). Two evaluators carry the two
    # frames' plate centers: (0, 0) untranslated, `off` translated.
    D = 5.0; off = (250.0, -300.0)
    ev0 = ReducedDiaphragmEvaluator(story_heights=[3.0], plan_halfwidth=(D, D),
                                    plate_center=(0.0, 0.0), accidental_ecc=0.05)
    evT = ReducedDiaphragmEvaluator(story_heights=[3.0], plan_halfwidth=(D, D),
                                    plate_center=(off[1], off[2]), accidental_ecc=0.05)
    w0 = mkbraced(D, 1e9)
    l0 = [StoryLoad(1, 1e5, 0.7e5, 0.0, 0.0)]        # asymmetric ⇒ genuine torsion
    wT = [WallLine(w.id, w.x + off[1], w.y + off[2], w.θ, w.k, w.story) for w in w0]
    lT = [StoryLoad(l.story, l.Fx, l.Fy, l.ex + off[1], l.ey + off[2]) for l in l0]
    @test isapprox(dcid_fn(ev0, w0, l0).corner_drift,
                   dcid_fn(evT, wT, lT).corner_drift; atol=1e-12)

    # End-to-end: solve_wall_layout ACCEPTS the sound bidirectional core as feasible
    # (worst_util ≤ 1) at both footprints. MinDrift keeps it stiff, isolating the
    # re-validation gate from carbon-driven thinning so it cannot false-reject.
    for D in (5.0, 500.0)
        cb = [WallCandidate(1, 0.0, -D, 0.0, 4.0, 3.0, 1, 25e9, 0.2, 28e6, 60e6*6.895,
                            2400.0, 0.1, 0.4, 0.0025),
              WallCandidate(2, 0.0,  D, 0.0, 4.0, 3.0, 1, 25e9, 0.2, 28e6, 60e6*6.895,
                            2400.0, 0.1, 0.4, 0.0025),
              WallCandidate(3, -D, 0.0, pi/2, 4.0, 3.0, 1, 25e9, 0.2, 28e6, 60e6*6.895,
                            2400.0, 0.1, 0.4, 0.0025),
              WallCandidate(4,  D, 0.0, pi/2, 4.0, 3.0, 1, 25e9, 0.2, 28e6, 60e6*6.895,
                            2400.0, 0.1, 0.4, 0.0025)]
        ev = ReducedDiaphragmEvaluator(story_heights=[3.0], plan_halfwidth=(D, D),
                                       plate_center=(0.0, 0.0), accidental_ecc=0.05)
        pb = WallLayoutNLPProblem(cb, ev, [StoryLoad(1, 5e4, 5e4, 0.0, 0.0)];
                                  objective=MinDrift(), drift_limit=DL)
        rb = solve_wall_layout(pb; maxiter=200)
        @test rb.feasible == true                    # well-braced ⇒ accepted
        @test rb.revalidation.worst_util <= 1.0      # comfortably within limits
    end
end

@testset "crit4 (4): prior mechanisms still rejected; fail-closed preserved" begin
    # Demoting the saturating torsion ratio and binding `corner_drift` instead must
    # NOT weaken the prior rejections. Re-verify through the CURRENT code paths
    # (corner_drift / eigen floors / solve_wall_layout) that:
    #   (a) a near-dead-Y layout is still INFEASIBLE;
    #   (b) the crit3 clustered-core torsional mechanism is still INFEASIBLE — now
    #       caught DIRECTLY by the max-corner drift AND the eigen torsional floor;
    #   (c) the diagonal weak mode is read exactly by λmin(K_tt) (no √2 under-measure);
    #   (d) a genuinely singular / under-braced layout still fails closed.
    SSE     = StructuralSizer.SingularStiffnessError
    dcid_fn = StructuralSizer.direction_complete_interstory_drift
    eig_fn  = StructuralSizer.eigenstructure_stability
    DL = 0.02

    # (a) near-dead-Y: a single near-dead Y pier at the origin cannot brace +Y.
    evY = ReducedDiaphragmEvaluator(story_heights=[3.0], plan_halfwidth=(0.0, 5.0),
                                    plate_center=(0.0, 0.0), accidental_ecc=0.05)
    loadsY = [StoryLoad(1, 1e5, 0.0, 0.0, 0.0)]
    strongX(id, y) = WallCandidate(id, 0.0, y, 0.0, 4.0, 3.0, 1, 25e9, 0.2, 28e6,
                                   60e6*6.895, 2400.0, 0.1, 0.4, 0.0025)
    deadY = WallCandidate(3, 0.0, 0.0, pi/2, 0.05, 3.0, 1, 25e9, 0.2, 28e6,
                          60e6*6.895, 2400.0, 0.1, 0.02, 0.0025)
    solY = solve_wall_layout(
        WallLayoutNLPProblem([strongX(1, -5.0), strongX(2, 5.0), deadY], evY, loadsY;
                             objective=MinCarbon(), drift_limit=DL); maxiter=200)
    @test solY.feasible == false
    @test solY.status == :infeasible
    @test solY.revalidation.worst_util > 1.0

    # (b) crit3 clustered-core torsion: four stiff piers a tiny d = 0.0141 m from the
    #     plan center. The condensed twist stiffness collapses, so BOTH the max-corner
    #     drift and the eigen torsional floor blow up (≫ 1) while the CR-translation
    #     drift stays tiny — the hole the old drift-only metric missed is now closed
    #     by corner_drift directly as well as the eigen floor.
    k = 1e8; d = 0.0141
    evC = ReducedDiaphragmEvaluator(story_heights=[3.0], plan_halfwidth=(10.0, 10.0),
                                    plate_center=(0.0, 0.0), accidental_ecc=0.05)
    wC = [WallLine(1, 0.0,  d, 0.0,  k, 1), WallLine(2, 0.0, -d, 0.0,  k, 1),
          WallLine(3,  d, 0.0, pi/2, k, 1), WallLine(4, -d, 0.0, pi/2, k, 1)]
    loadsC = [StoryLoad(1, 1e6, 0.0, 0.0, 0.0)]
    dcC = dcid_fn(evC, wC, loadsC)
    egC = eig_fn(evC, wC, loadsC, DL)
    @test maximum(dcC.drift) / DL < 0.1              # CR-translation drift tiny (twist-blind)
    @test maximum(dcC.corner_drift) / DL > 1.0e2     # max-corner drift exposes the spin
    @test egC.util_tors[1] > 1.0e2                   # eigen torsional floor ≫ 1
    @test egC.util_trans[1] < 1.0                    # translation is fine
    mkcand(id, x, y, θ) = WallCandidate(id, x, y, θ, 4.0, 3.0, 1, 25e9, 0.2, 28e6,
                                        60e6*6.895, 2400.0, 0.1, 0.4, 0.0025)
    solC = solve_wall_layout(
        WallLayoutNLPProblem([mkcand(1, 0.0, d, 0.0), mkcand(2, 0.0, -d, 0.0),
                              mkcand(3, d, 0.0, pi/2), mkcand(4, -d, 0.0, pi/2)],
                             evC, loadsC; objective=MinCarbon(), drift_limit=DL); maxiter=200)
    @test solC.feasible == false
    @test solC.status == :infeasible
    @test solC.revalidation.worst_util > 1.0

    # (c) diagonal weak mode: λmin(K_tt) reads the TRUE 1e8 weak diagonal, not the
    #     axis-only (K11+K22)/2 ≈ 5.05e9 that a +X/+Y sweep would under-measure.
    spec = StructuralSizer._translational_block_spectrum(
        StructuralSizer._assemble_story_K(
            [WallLine(1,  3.0, 0.0, pi/4,  1e10, 1),
             WallLine(2, -3.0, 0.0, 3pi/4, 1e8,  1)]))
    @test isapprox(spec.λmin, 1e8;  rtol=1e-5)
    @test isapprox(spec.λmax, 1e10; rtol=1e-5)

    # (d) fail-closed: a genuinely singular / under-braced layout (all walls ∥ X ⇒
    #     no Y restraint) still throws on the direct path AND the eigen gate.
    evS = ReducedDiaphragmEvaluator(story_heights=[3.0], plan_halfwidth=(5.0, 5.0),
                                    accidental_ecc=0.05)
    underbraced = [WallLine(1, 0.0, -5.0, 0.0, 1e7, 1), WallLine(2, 0.0, 5.0, 0.0, 1e7, 1)]
    bidir = [StoryLoad(1, 1e5, 1e5, 0.0, 0.0)]
    @test_throws SSE evaluate_lateral(evS, underbraced, bidir)
    @test_throws SSE eig_fn(evS, underbraced, bidir, DL)
end

# ==============================================================================
# crit5 fix — EXACT corner drift anchored at the TRUE plate center
# ==============================================================================
# crit5 (round-5 red team) proved a P0: the round-4 "true max-corner" metric anchored
# the four plan corners at the WALL GEOMETRIC CENTROID `pc` as a proxy for the plan
# CENTER. For an eccentric service core (lateral walls clustered at one plate end) the
# wall centroid coincides with the center of rigidity, so the corners pc ± (hx, hy)
# miss the TRUE far plate corner and the corner-drift / torsional-lever metrics
# UNDER-state the twist — permitting a layout whose real far corner drifts ~1.5× over
# the ASCE 7-22 §12.12.1 limit to be accepted as feasible.
#
# The fix makes the reduced tier EXACT: `ReducedDiaphragmEvaluator` now carries the TRUE
# floor-plate center `plate_center` (in the WallLine frame), and the twist metrics
# evaluate the rigid-diaphragm displacement at the four ACTUAL occupant corners
# plate_center ± (hx, hy) directly — corner_drift = max_p hypot(δx − φ·p_y, δy + φ·p_x)/h
# and r_ref = max_corner hypot(corner − CR). This LOCATES the far corner (no slack, no
# over-rejection) and is correct even when the CR lies outside the plate. When
# plate_center is absent the metrics FAIL CLOSED to Inf and solve_wall_layout returns
# status = :geometry_required — never a wall-centroid / origin / plate-span proxy (the
# earlier conservative r_bound = hypot(2·hx, 2·hy) `_lever_bound` fail-safe is REMOVED).
# The torsion ratio `res.torsion` (δ_max EXACT over the four corners) remains an
# independent feasibility GATE in `constraint_fns` / `solve_wall_layout`.
#
# The three testsets below verify, in order:
#   (1) P0 ECCENTRIC-CORE regression — crit5's clustered-core construction is now
#       INFEASIBLE (EXACT corner_drift ≈ 1.49× DL, solve_wall_layout feasible = false),
#       and the torsion ratio independently flags it (res.torsion ≫ limit);
#   (2) NO OVER-REJECTION — a symmetric well-braced compact core is STILL feasible
#       (worst_util ≈ 0.667 < 1) at a small AND a large footprint, scale-invariant;
#   (3) all prior mechanisms STILL rejected via the EXACT paths, fail-closed preserved,
#       and the EXACT metric / verdict is ORIGIN-invariant (plate_center translates
#       jointly with the walls+loads).

# Deterministic worst utilization mirroring `solve_wall_layout`'s survivor re-validation
# (EXACT max-corner drift + eigenstructure floors + torsion ratio), evaluated directly
# on a fixed WallLine layout so it is independent of the optimizer.
function _conservative_worst_util(ev, walls, loads, DL; torsion_limit=1.5)
    res = evaluate_lateral(ev, walls, loads)
    dc  = StructuralSizer.direction_complete_interstory_drift(ev, walls, loads)
    eig = StructuralSizer.eigenstructure_stability(ev, walls, loads, DL)
    drift_worst = maximum(dc.corner_drift) / DL
    eig_worst   = max(maximum(eig.util_trans), maximum(eig.util_tors))
    tors_worst  = maximum(res.torsion) / torsion_limit
    return max(drift_worst, eig_worst, tors_worst)
end

@testset "crit5 (1): eccentric service core is INFEASIBLE (P0 regression)" begin
    # crit5's exact eccentric-core construction (reproducer:
    # scripts/runners/crit5_eccentric_core_corner_drift.jl, confirm_via_revalidation).
    # A 40 m × 20 m plate (plan_halfwidth = (20, 10)) centered at the origin, with the
    # lateral core CLUSTERED at x = XC = −15 m: four Y-walls spread in x for torsional
    # stiffness and four X-walls, all within the left-side core footprint. The floor
    # MASS acts at the plate center (0, 0), but the stiffness / center of rigidity sits
    # at the core (xr ≈ −15), a textbook torsionally-irregular layout. A pure +Y design
    # resultant at the plate center is scaled (Fy = 3.763e6 N) so the TRUE far-corner
    # (+20, +10) interstory drift ≈ 1.49 × DL — over the ASCE 7-22 §12.12.1 limit.
    #
    # The OLD centroid-anchored metric MISSED the far corner (its box spans
    # x ∈ [−35, +5]) and accepted this layout. With the TRUE plate center (0, 0) supplied,
    # the EXACT corner-drift evaluates the real (+20, +10) corner directly, so the
    # corner-drift slot and the torsion ratio BOTH now reject it.
    dcid_fn = StructuralSizer.direction_complete_interstory_drift
    H = 3.0; HX = 20.0; HY = 10.0; XC = -15.0; DL = 0.02
    mk(id, x, y, θ) = WallCandidate(id, x, y, θ, 1.5, H, 1, 25e9, 0.2, 60e6,
                                    60e6*6.895, 2400.0, 0.1, 0.6, 0.025)
    cands = [mk(1, XC - 3.0, -6.0, pi/2), mk(2, XC + 3.0, -6.0, pi/2),
             mk(3, XC - 3.0,  6.0, pi/2), mk(4, XC + 3.0,  6.0, pi/2),
             mk(5, XC - 3.0, -6.0, 0.0),  mk(6, XC - 3.0,  6.0, 0.0),
             mk(7, XC + 3.0, -6.0, 0.0),  mk(8, XC + 3.0,  6.0, 0.0)]
    # The 40×20 m PLATE is centered at the origin (mass at (0, 0)); only the CORE /
    # center of rigidity is eccentric (clustered at x = −15). The TRUE plate center is
    # therefore (0, 0) — supplying it lets the EXACT corner drift reach the far (+20, +10)
    # occupant corner the old centroid-anchored box missed (crit5's P0).
    ev = ReducedDiaphragmEvaluator(story_heights=[H], plan_halfwidth=(HX, HY),
                                   plate_center=(0.0, 0.0), accidental_ecc=0.05)
    Fy = 3.763e6
    prob = WallLayoutNLPProblem(cands, ev, [StoryLoad(1, 0.0, Fy, 0.0, 0.0)];
                                objective=MinCarbon(), drift_limit=DL, torsion_limit=1.5)
    walls = StructuralSizer._walls_from_density(prob, ones(length(cands)))
    res = evaluate_lateral(ev, walls, prob.loads)
    dc  = dcid_fn(ev, walls, prob.loads)

    # --- The twist-BLIND CR-translation drift stays small (~0.10 × DL) — the hole the
    #     old drift-only / centroid-anchored metrics fell through on this eccentric core.
    @test maximum(dc.drift) / DL < 0.2

    # --- EXACT corner drift now EXCEEDS DL ⇒ story INFEASIBLE. Anchored at the TRUE plate
    #     center (0, 0), the far occupant corner (+20, +10) is reached directly (the old
    #     centroid-anchored box, spanning x ∈ [−35, +5], missed it — crit5's P0).
    corner_util = maximum(dc.corner_drift) / DL
    @test corner_util > 1.0                          # INFEASIBLE on the EXACT max-corner drift
    @test isapprox(corner_util, 1.495; atol=0.02)    # ≈ 1.49 × DL (EXACT far-corner drift)
    @test corner_util > maximum(dc.drift) / DL       # corner ≫ twist-blind CR translation

    # --- The torsion ratio independently flags it: δ_max is EXACT over the four TRUE
    #     corners anchored at plate_center, so res.torsion = δ_max/δ_avg ≫ torsion_limit (= 1.5).
    @test res.torsion[1] > prob.torsion_limit        # torsion ratio gate independently fails
    @test isapprox(res.torsion[1], 14.715; rtol=2e-2) # ≈ 14.7 (EXACT far-corner lever)
    @test res.torsion[1] / prob.torsion_limit > 1.0  # the folded torsion slot is infeasible

    # --- End-to-end: solve_wall_layout can no longer return this eccentric core as
    #     feasible. The clustered-core eccentricity is geometric — no density can
    #     re-center the CR — so the survivor re-validation refuses the selected layout.
    sol = solve_wall_layout(prob; maxiter=200)
    @test sol.feasible == false                      # was feasible=true before the fix
    @test sol.status == :infeasible
    @test sol.revalidation.ok == false
    @test sol.revalidation.worst_util > 1.0          # beyond DL / torsion_limit
end

@testset "crit5 (2): symmetric well-braced core NOT over-rejected (scale invariant)" begin
    # Regression guard that the 2×-conservative lever r_bound = hypot(2hx, 2hy) does NOT
    # make an ADEQUATE symmetric core infeasible. For a symmetric core the CR sits at
    # the plan center with ~zero accidental twist, so the conservative corner drift is
    # dominated by the pure CR translation and stays well under DL — the over-rejection
    # risk of the conservative bound is bounded. Verified at a small (D = 5 m) AND a
    # large (D = 500 m) footprint, and the deterministic worst utilization is IDENTICAL
    # across scale (both the demand floors and the stiffnesses scale with D together).
    DL = 0.02

    # Deterministic (optimizer-free) worst_util on a fixed well-braced WallLine core:
    # must be < 1 and SCALE-INVARIANT.
    k = 1e9
    mkwalls(D) = [WallLine(1, 0.0, -D, 0.0,  k, 1), WallLine(2, 0.0, D, 0.0,  k, 1),
                  WallLine(3, -D, 0.0, pi/2, k, 1), WallLine(4, D, 0.0, pi/2, k, 1)]
    loads = [StoryLoad(1, 5e4, 5e4, 0.0, 0.0)]       # bi-directional (both modes loaded)
    wus = Float64[]
    for D in (5.0, 500.0)
        ev = ReducedDiaphragmEvaluator(story_heights=[3.0], plan_halfwidth=(D, D),
                                       plate_center=(0.0, 0.0), accidental_ecc=0.05)
        wu = _conservative_worst_util(ev, mkwalls(D), loads, DL)
        @test wu < 1.0                               # adequate core NOT over-rejected
        push!(wus, wu)
    end
    @test isapprox(wus[1], wus[2]; rtol=1e-9)        # SCALE-INVARIANT worst_util

    # End-to-end: solve_wall_layout ACCEPTS the sound symmetric core as feasible with
    # worst_util < 1 at BOTH footprints (a MinDrift objective keeps it stiff, isolating
    # the re-validation gate from carbon-driven thinning).
    for D in (5.0, 500.0)
        cb = [WallCandidate(1, 0.0, -D, 0.0, 4.0, 3.0, 1, 25e9, 0.2, 28e6, 60e6*6.895,
                            2400.0, 0.1, 0.4, 0.0025),
              WallCandidate(2, 0.0,  D, 0.0, 4.0, 3.0, 1, 25e9, 0.2, 28e6, 60e6*6.895,
                            2400.0, 0.1, 0.4, 0.0025),
              WallCandidate(3, -D, 0.0, pi/2, 4.0, 3.0, 1, 25e9, 0.2, 28e6, 60e6*6.895,
                            2400.0, 0.1, 0.4, 0.0025),
              WallCandidate(4,  D, 0.0, pi/2, 4.0, 3.0, 1, 25e9, 0.2, 28e6, 60e6*6.895,
                            2400.0, 0.1, 0.4, 0.0025)]
        ev = ReducedDiaphragmEvaluator(story_heights=[3.0], plan_halfwidth=(D, D),
                                       plate_center=(0.0, 0.0), accidental_ecc=0.05)
        pb = WallLayoutNLPProblem(cb, ev, [StoryLoad(1, 5e4, 5e4, 0.0, 0.0)];
                                  objective=MinDrift(), drift_limit=DL)
        rb = solve_wall_layout(pb; maxiter=200)
        @test rb.feasible == true                    # adequate core accepted
        @test rb.revalidation.worst_util < 1.0       # comfortably within the limits
    end
end

@testset "crit5 (3): prior mechanisms still rejected; fail-closed + origin-invariance" begin
    # The conservative r_bound supersession must NOT weaken any prior rejection, must
    # keep the fail-closed contract, and the conservative metric/verdict must be
    # ORIGIN-invariant. Re-verified through the CURRENT code paths that:
    #   (a) the crit4 eccentric-CR probe is STILL INFEASIBLE (conservative corner drift);
    #   (b) a near-dead-Y layout is STILL rejected;
    #   (c) the crit3 clustered-core torsional mechanism is STILL rejected;
    #   (d) the diagonal weak mode is read exactly by λmin(K_tt) (no √2 under-measure);
    #   (e) a genuinely singular / under-braced layout STILL fails closed; and
    #   (f) the conservative corner_drift AND the deterministic worst_util verdict are
    #       ORIGIN-invariant (translate layout + loads ⇒ identical values).
    SSE     = StructuralSizer.SingularStiffnessError
    dcid_fn = StructuralSizer.direction_complete_interstory_drift
    eig_fn  = StructuralSizer.eigenstructure_stability
    DL = 0.02

    # (a) crit4 eccentric-CR (xr ≈ 6.861): conservative corner drift > DL.
    KUNIT = wall_stiffness_from_thickness_si(0.3, 5.0, 25e9, 0.2, 3.0; cracked=true)
    wE = [WallLine(1, 0.0, -5.0, 0.0,  1.3*KUNIT, 1),
          WallLine(2, 0.0,  5.0, 0.0,  1.3*KUNIT, 1),
          WallLine(3,  7.0, 0.0, pi/2, 3.0*KUNIT, 1),
          WallLine(4, -7.0, 0.0, pi/2, 0.03*KUNIT, 1)]
    evE = ReducedDiaphragmEvaluator(story_heights=[3.0], plan_halfwidth=(10.0, 5.0),
                                    plate_center=(0.0, 0.0), accidental_ecc=0.05)
    KE = StructuralSizer._assemble_story_K(wE)
    xrE, yrE = StructuralSizer._center_of_rigidity(KE)
    λminE = StructuralSizer._translational_block_spectrum(KE).λmin
    loadsE = [StoryLoad(1, 0.0, DL * λminE * 3.0, xrE, yrE)]
    @test maximum(dcid_fn(evE, wE, loadsE).corner_drift) / DL > 1.0   # still INFEASIBLE

    # (b) near-dead-Y: a single near-dead Y pier at the origin cannot brace +Y.
    evY = ReducedDiaphragmEvaluator(story_heights=[3.0], plan_halfwidth=(0.0, 5.0),
                                    plate_center=(0.0, 0.0), accidental_ecc=0.05)
    loadsY = [StoryLoad(1, 1e5, 0.0, 0.0, 0.0)]
    strongX(id, y) = WallCandidate(id, 0.0, y, 0.0, 4.0, 3.0, 1, 25e9, 0.2, 28e6,
                                   60e6*6.895, 2400.0, 0.1, 0.4, 0.0025)
    deadY = WallCandidate(3, 0.0, 0.0, pi/2, 0.05, 3.0, 1, 25e9, 0.2, 28e6,
                          60e6*6.895, 2400.0, 0.1, 0.02, 0.0025)
    solY = solve_wall_layout(
        WallLayoutNLPProblem([strongX(1, -5.0), strongX(2, 5.0), deadY], evY, loadsY;
                             objective=MinCarbon(), drift_limit=DL); maxiter=200)
    @test solY.feasible == false
    @test solY.revalidation.worst_util > 1.0

    # (c) crit3 clustered-core torsion: four stiff piers a tiny d = 0.0141 m from the
    #     plan center ⇒ condensed twist stiffness collapses; corner drift AND the eigen
    #     torsional floor blow up while the CR-translation drift stays tiny.
    k = 1e8; d = 0.0141
    evC = ReducedDiaphragmEvaluator(story_heights=[3.0], plan_halfwidth=(10.0, 10.0),
                                    plate_center=(0.0, 0.0), accidental_ecc=0.05)
    wC = [WallLine(1, 0.0,  d, 0.0,  k, 1), WallLine(2, 0.0, -d, 0.0,  k, 1),
          WallLine(3,  d, 0.0, pi/2, k, 1), WallLine(4, -d, 0.0, pi/2, k, 1)]
    loadsC = [StoryLoad(1, 1e6, 0.0, 0.0, 0.0)]
    @test maximum(dcid_fn(evC, wC, loadsC).corner_drift) / DL > 1.0e2   # spin exposed
    @test eig_fn(evC, wC, loadsC, DL).util_tors[1] > 1.0e2              # eigen floor ≫ 1

    # (d) diagonal weak mode: λmin(K_tt) reads the TRUE 1e8 weak diagonal.
    spec = StructuralSizer._translational_block_spectrum(
        StructuralSizer._assemble_story_K(
            [WallLine(1,  3.0, 0.0, pi/4,  1e10, 1),
             WallLine(2, -3.0, 0.0, 3pi/4, 1e8,  1)]))
    @test isapprox(spec.λmin, 1e8;  rtol=1e-5)
    @test isapprox(spec.λmax, 1e10; rtol=1e-5)

    # (e) fail-closed: a genuinely singular / under-braced layout (all walls ∥ X ⇒ no Y
    #     restraint) still throws on the direct path AND the eigen gate.
    evS = ReducedDiaphragmEvaluator(story_heights=[3.0], plan_halfwidth=(5.0, 5.0),
                                    accidental_ecc=0.05)
    underbraced = [WallLine(1, 0.0, -5.0, 0.0, 1e7, 1), WallLine(2, 0.0, 5.0, 0.0, 1e7, 1)]
    bidir = [StoryLoad(1, 1e5, 1e5, 0.0, 0.0)]
    @test_throws SSE evaluate_lateral(evS, underbraced, bidir)
    @test_throws SSE eig_fn(evS, underbraced, bidir, DL)

    # (f) ORIGIN INVARIANCE of the EXACT metric: translating the eccentric core + loads
    #     AND the TRUE plate center JOINTLY by a large arbitrary offset leaves the EXACT
    #     corner_drift AND the deterministic worst_util verdict UNCHANGED (the corners
    #     plate_center ± (hx, hy) translate WITH the walls, so the displacement field at
    #     each physical corner is unchanged).
    H = 3.0; HX = 20.0; HY = 10.0; XC = -15.0
    mkw(ky, kx) = [WallLine(1, XC - 3.0, -6.0, pi/2, ky, 1), WallLine(2, XC + 3.0, -6.0, pi/2, ky, 1),
                   WallLine(3, XC - 3.0,  6.0, pi/2, ky, 1), WallLine(4, XC + 3.0,  6.0, pi/2, ky, 1),
                   WallLine(5, XC,       -6.0, 0.0,  kx, 1), WallLine(6, XC,        6.0, 0.0,  kx, 1)]
    # Translate the TRUE plate center JOINTLY with the walls+loads: untranslated plate
    # centered at (0, 0), translated plate at `off`.
    off = (250.0, -300.0)
    evO = ReducedDiaphragmEvaluator(story_heights=[H], plan_halfwidth=(HX, HY),
                                    plate_center=(0.0, 0.0), accidental_ecc=0.05)
    evOT = ReducedDiaphragmEvaluator(story_heights=[H], plan_halfwidth=(HX, HY),
                                     plate_center=(off[1], off[2]), accidental_ecc=0.05)
    w0 = mkw(3.0e8, 3.0e8)
    l0 = [StoryLoad(1, 0.0, 3.763e6, 0.0, 0.0)]
    wT = [WallLine(w.id, w.x + off[1], w.y + off[2], w.θ, w.k, w.story) for w in w0]
    lT = [StoryLoad(l.story, l.Fx, l.Fy, l.ex + off[1], l.ey + off[2]) for l in l0]
    @test isapprox(dcid_fn(evO, w0, l0).corner_drift,
                   dcid_fn(evOT, wT, lT).corner_drift; atol=1e-12)
    wu0 = _conservative_worst_util(evO, w0, l0, DL)
    wuT = _conservative_worst_util(evOT, wT, lT, DL)
    @test wu0 > 1.0                                  # eccentric core infeasible (EXACT metric)
    @test isapprox(wu0, wuT; rtol=1e-9)              # verdict/worst_util origin-invariant
end

# ==============================================================================
# geometry-required FAIL-CLOSED — the plate_center === nothing contract
# ==============================================================================
# The reduced tier now CARRIES the TRUE plate center; without it the twist-sensitive
# corner-drift / torsion certification cannot locate the occupant corners and MUST fail
# closed. This testset locks the two halves of that contract:
#   (1) an OTHERWISE-FEASIBLE well-braced layout, built with the DEFAULT
#       `plate_center === nothing`, is REFUSED — solve_wall_layout returns
#       feasible = false AND status = :geometry_required (NOT a silent feasible pass,
#       which would be a VERDICT-FAIL safety breach);
#   (2) a gross translational MECHANISM is STILL rejected even without plate_center,
#       because the frame-independent translational / singular floors do NOT depend on
#       the geometry — the geometry gate withholds only the TWIST certification.
@testset "geometry-required: plate_center === nothing fails closed (not a silent pass)" begin
    SSE = StructuralSizer.SingularStiffnessError
    eig_fn = StructuralSizer.eigenstructure_stability
    DL = 0.02

    # (1) A genuinely well-braced symmetric core (would be feasible WITH plate_center,
    #     cf. crit5 (2)) is refused when plate_center is absent (the struct DEFAULT).
    cb = [WallCandidate(1, 0.0, -5.0, 0.0, 4.0, 3.0, 1, 25e9, 0.2, 28e6, 60e6*6.895,
                        2400.0, 0.1, 0.4, 0.0025),
          WallCandidate(2, 0.0,  5.0, 0.0, 4.0, 3.0, 1, 25e9, 0.2, 28e6, 60e6*6.895,
                        2400.0, 0.1, 0.4, 0.0025),
          WallCandidate(3, -5.0, 0.0, pi/2, 4.0, 3.0, 1, 25e9, 0.2, 28e6, 60e6*6.895,
                        2400.0, 0.1, 0.4, 0.0025),
          WallCandidate(4,  5.0, 0.0, pi/2, 4.0, 3.0, 1, 25e9, 0.2, 28e6, 60e6*6.895,
                        2400.0, 0.1, 0.4, 0.0025)]
    # DEFAULT plate_center === nothing (not supplied): twist certification unavailable.
    ev_nogeom = ReducedDiaphragmEvaluator(story_heights=[3.0], plan_halfwidth=(5.0, 5.0),
                                          accidental_ecc=0.05)
    @test ev_nogeom.plate_center === nothing          # the fail-closed precondition
    pb = WallLayoutNLPProblem(cb, ev_nogeom, [StoryLoad(1, 5e4, 5e4, 0.0, 0.0)];
                              objective=MinDrift(), drift_limit=DL)
    sol = solve_wall_layout(pb; maxiter=200)
    @test sol.feasible == false                       # NOT a silent feasible pass
    @test sol.status == :geometry_required            # the dedicated fail-closed status
    @test sol.revalidation.failing.mode == :geometry_required

    # (2) The frame-INDEPENDENT floors still reject a gross mechanism WITHOUT plate_center:
    #     two parallel X-walls leave Y-translation an unrestrained mechanism, so the
    #     singular / translational floor throws regardless of the (absent) twist geometry.
    underbraced = [WallLine(1, 0.0, -5.0, 0.0, 1e7, 1), WallLine(2, 0.0, 5.0, 0.0, 1e7, 1)]
    bidir = [StoryLoad(1, 1e5, 1e5, 0.0, 0.0)]
    @test_throws SSE evaluate_lateral(ev_nogeom, underbraced, bidir)
    @test_throws SSE eig_fn(ev_nogeom, underbraced, bidir, DL)   # mechanism floor is geometry-free
end

# ==============================================================================
# EXACT corner-drift regressions WITH the true plate_center supplied
# ==============================================================================
# Two layouts the removed conservative/centroid proxies could MIS-handle are now
# certified EXACTLY once the true plate_center is supplied:
#   (1) rev6 — a strongly NON-ORTHOGONAL layout whose center of rigidity escapes the
#       plate (CR ≈ (−53, 76), far OUTSIDE the ±20 × ±10 plate). The EXACT corner metric
#       is correct even then and reports the true far-corner drift ≈ 1.16× DL ⇒ INFEASIBLE;
#   (2) a crit5-style eccentric service core whose TRUE far corner drifts ≈ 1.49× DL
#       (anchored at the real plate center) ⇒ INFEASIBLE.
@testset "EXACT corner drift WITH plate_center: rev6 + eccentric core INFEASIBLE" begin
    dcid_fn = StructuralSizer.direction_complete_interstory_drift
    DL = 0.02

    # (1) rev6 non-orthogonal CR-outside-plate (reproducer:
    #     scripts/runners/review_verify_reproducer.jl, worst-breach layout). The plate is
    #     centered at the origin (±20 × ±10 ⇒ plate_center (0, 0)); the angled walls push
    #     the CR to ≈ (−53, 76), far outside the plate. The EXACT corner drift evaluates
    #     the four TRUE occupant corners directly, so it is correct despite the CR escaping
    #     the plate and the layout is correctly INFEASIBLE.
    ev = ReducedDiaphragmEvaluator(story_heights=[3.0], plan_halfwidth=(20.0, 10.0),
                                   plate_center=(0.0, 0.0), accidental_ecc=0.05)
    walls = [WallLine(1, 12.8135, 5.0583, 2.35599, 1.1308e7, 1),
             WallLine(2, 18.7749, 7.0527, 2.11040, 7.8990e6, 1),
             WallLine(3, -3.1547, 2.4018, 2.30842, 3.8254e3, 1),
             WallLine(4, 10.0054, -6.3296, 1.11546, 1.0348e1, 1),
             WallLine(5, -19.3582, -2.2333, 2.06246, 2.6123e7, 1)]
    loads = [StoryLoad(1, -9.6450e3, 2.4935e4, -7.7016, -9.9339)]
    cr = StructuralSizer._center_of_rigidity(StructuralSizer._assemble_story_K(walls))
    @test cr[1] < -20.0 && cr[2] > 10.0               # CR escapes the ±20 × ±10 plate
    @test isapprox(cr[1], -53.37; atol=0.5)           # CR ≈ (−53, 76) (non-orthogonal)
    @test isapprox(cr[2],  75.63; atol=0.5)
    corner_util = maximum(dcid_fn(ev, walls, loads).corner_drift) / DL
    @test corner_util > 1.0                           # INFEASIBLE despite CR outside plate
    @test isapprox(corner_util, 1.160; atol=0.02)     # EXACT far-corner drift ≈ 1.16× DL

    # (2) crit5-style eccentric service core (8 walls clustered at x = −15 on a ±20 × ±10
    #     plate): the TRUE far corner (+20, +10) drifts ≈ 1.49× DL ⇒ INFEASIBLE.
    H = 3.0; HX = 20.0; HY = 10.0; XC = -15.0
    mk(id, x, y, θ) = WallCandidate(id, x, y, θ, 1.5, H, 1, 25e9, 0.2, 60e6,
                                    60e6*6.895, 2400.0, 0.1, 0.6, 0.025)
    cands = [mk(1, XC - 3.0, -6.0, pi/2), mk(2, XC + 3.0, -6.0, pi/2),
             mk(3, XC - 3.0,  6.0, pi/2), mk(4, XC + 3.0,  6.0, pi/2),
             mk(5, XC - 3.0, -6.0, 0.0),  mk(6, XC - 3.0,  6.0, 0.0),
             mk(7, XC + 3.0, -6.0, 0.0),  mk(8, XC + 3.0,  6.0, 0.0)]
    evE = ReducedDiaphragmEvaluator(story_heights=[H], plan_halfwidth=(HX, HY),
                                    plate_center=(0.0, 0.0), accidental_ecc=0.05)
    probE = WallLayoutNLPProblem(cands, evE, [StoryLoad(1, 0.0, 3.763e6, 0.0, 0.0)];
                                 objective=MinCarbon(), drift_limit=DL, torsion_limit=1.5)
    wallsE = StructuralSizer._walls_from_density(probE, ones(length(cands)))
    cuE = maximum(dcid_fn(evE, wallsE, probE.loads).corner_drift) / DL
    @test cuE > 1.0                                   # INFEASIBLE on the EXACT far-corner drift
    @test isapprox(cuE, 1.495; atol=0.02)             # ≈ 1.49× DL (true (+20,+10) corner)
    solE = solve_wall_layout(probE; maxiter=200)
    @test solE.feasible == false
    @test solE.status == :infeasible
    @test solE.revalidation.worst_util > 1.0
end

# ==============================================================================
# crit7 fix — ENCLOSURE GUARD (walls ⊆ plate), fail-closed `:geometry_inconsistent`
# ==============================================================================
# The reduced tier's EXACT four-corner drift / torsion metrics are exact ONLY over the
# plate rectangle `plate_center ± plan_halfwidth`, and exact for the TRUE occupant
# diaphragm ONLY when that rectangle ENCLOSES every drift-relevant point. `plate_center`
# and `plan_halfwidth` are two FREE, caller-supplied fields; nothing else cross-checks
# them against the wall positions. An UNDER-COVERING plate (the core half-extent mistaken
# for the full floor) would make BOTH plate-anchored gates (corner drift AND the
# `res.torsion` amplification ratio) silently UNDER-state the real edge drift while the
# only plate-independent gate (`util_trans`) is twist-blind — the exact formula then fails
# OPEN. crit7's fail-closed ENCLOSURE GUARD `_plate_encloses_walls(ev, walls_s)` enforces
# the CHECKABLE proxy WALLS ⊆ plate: when any story's walls fall OUTSIDE the plate the
# twist-sensitive metrics FAIL CLOSED to `Inf` (exactly as for a missing `plate_center`),
# and `solve_wall_layout` refuses the layout with the DISTINCT, more-debuggable
# `status = :geometry_inconsistent` (vs `:geometry_required` for a missing plate).
#
# RESIDUAL (documented, NOT caught here): a plate that encloses the walls but is declared
# SMALLER than the true occupant diaphragm (walls ⊆ plate ⊂ occupants) — delegated to the
# caller contract + the Phase 10 unified-FEM survivor check (true geometry, final authority).
# crit7's EXACT numbers (plate_center = (−15, 0), plan_halfwidth = (3, 9)) place the Y-walls
# at x = −18 / −12 EXACTLY ON the plate boundary (walls ⊆ plate), so the guard does NOT fire
# on those — that is the documented residual. To EXERCISE the guard the walls must GENUINELY
# poke out: plan_halfwidth = (2, 9) with the same walls at x = −18 / −12 (plate x-range
# [−17, −13]) makes both Y-walls fall OUTSIDE.
#
# Shared fixture geometry (reused across the crit7 testsets): a well-braced 4-wall core
# centered at XC = −15 — Y-walls (θ = π/2) at x = XC ± 3 = {−18, −12}, X-walls (θ = 0) at
# y = ±6 — so the core spans x ∈ [−18, −12], symmetric about (−15, 0) ⇒ CR = (−15, 0).
const _CRIT7_XC = -15.0
# WallCandidate factory (density-independent positions; stiff t_max so a MinDrift solve
# keeps the core dense). Mirrors the crit5/geometry-required candidate property block.
_crit7_cand(id, x, y, θ) = WallCandidate(id, x, y, θ, 4.0, 3.0, 1, 25e9, 0.2, 28e6,
                                         60e6 * 6.895, 2400.0, 0.1, 0.4, 0.0025)
_crit7_cands() = [_crit7_cand(1, _CRIT7_XC - 3.0, 0.0, pi/2),   # x = −18 (Y-wall)
                  _crit7_cand(2, _CRIT7_XC + 3.0, 0.0, pi/2),   # x = −12 (Y-wall)
                  _crit7_cand(3, _CRIT7_XC, -6.0, 0.0),         # X-wall
                  _crit7_cand(4, _CRIT7_XC,  6.0, 0.0)]         # X-wall
# Stiff WallLine mirror of the same core for direct (optimizer-free) metric checks.
_crit7_walls() = [WallLine(1, _CRIT7_XC - 3.0, 0.0, pi/2, 1e9, 1),
                  WallLine(2, _CRIT7_XC + 3.0, 0.0, pi/2, 1e9, 1),
                  WallLine(3, _CRIT7_XC, -6.0, 0.0, 1e9, 1),
                  WallLine(4, _CRIT7_XC,  6.0, 0.0, 1e9, 1)]

@testset "crit7 (1): enclosure guard FIRES on a genuine walls-outside under-covering plate" begin
    encl   = StructuralSizer._plate_encloses_walls
    dcid   = StructuralSizer.direction_complete_interstory_drift
    eig_fn = StructuralSizer.eigenstructure_stability
    DL = 0.02
    XC = _CRIT7_XC
    walls = _crit7_walls()                            # Y-walls at x = −18 / −12
    loads = [StoryLoad(1, 5e4, 5e4, XC, 0.0)]         # mass at the core center

    # UNDER-COVERING plate: plan_halfwidth = (2, 9) ⇒ plate x-range [−17, −13]. The Y-walls
    # at x = −18 (< −17) and x = −12 (> −13) GENUINELY poke out (not merely on-boundary).
    ev = ReducedDiaphragmEvaluator(story_heights=[3.0], plan_halfwidth=(2.0, 9.0),
                                   plate_center=(XC, 0.0), accidental_ecc=0.05)
    @test encl(ev, walls) == false                    # WALLS ⊄ plate ⇒ guard fires

    # Twist-sensitive metrics FAIL CLOSED to Inf (certification unavailable), exactly as for
    # a missing plate_center — never a silent under-stated finite value.
    @test evaluate_lateral(ev, walls, loads).torsion[1] == Inf
    @test all(isinf, dcid(ev, walls, loads).corner_drift)   # corner-drift certification Inf
    @test eig_fn(ev, walls, loads, DL).util_tors[1] == Inf  # torsional floor Inf

    # End-to-end: solve_wall_layout REFUSES with the DISTINCT :geometry_inconsistent status.
    # The enclosure gate fires on the (density-independent) wall positions before any drift
    # verdict, so worst_util / the twist certification are Inf / unavailable.
    prob = WallLayoutNLPProblem(_crit7_cands(), ev, loads;
                                objective=MinDrift(), drift_limit=DL)
    sol = solve_wall_layout(prob; maxiter=200)
    @test sol.feasible == false                        # a genuine walls-outside plate is refused
    @test sol.status == :geometry_inconsistent         # DISTINCT from :geometry_required
    @test sol.status != :geometry_required
    @test sol.revalidation.failing.mode == :geometry_inconsistent
    @test sol.revalidation.worst_util == Inf           # twist certification unavailable
end

@testset "crit7 (2): ENCLOSING plate for the SAME walls is judged on REAL drift (NOT :geometry_inconsistent)" begin
    DL = 0.02
    XC = _CRIT7_XC
    walls = _crit7_walls()
    loads = [StoryLoad(1, 5e4, 5e4, XC, 0.0)]

    # ENCLOSING plate: plan_halfwidth = (3, 9) ⇒ plate x-range [−18, −12]; the Y-walls at
    # x = −18 / −12 sit EXACTLY ON the boundary ⇒ WALLS ⊆ plate ⇒ guard does NOT fire. The
    # verdict is then decided by the REAL (finite) drift / torsion metrics, not geometry.
    ev = ReducedDiaphragmEvaluator(story_heights=[3.0], plan_halfwidth=(3.0, 9.0),
                                   plate_center=(XC, 0.0), accidental_ecc=0.05)
    @test StructuralSizer._plate_encloses_walls(ev, walls) == true
    @test isfinite(evaluate_lateral(ev, walls, loads).torsion[1])   # certification AVAILABLE

    # This core is symmetric about the plate center (CR = plate_center = (−15, 0)) and stiff,
    # so with a MinDrift objective it is genuinely ADEQUATE: feasible = true, worst_util < 1,
    # and CRUCIALLY the status is a REAL-physics verdict, NOT the geometry fail-closed.
    prob = WallLayoutNLPProblem(_crit7_cands(), ev, loads;
                                objective=MinDrift(), drift_limit=DL)
    sol = solve_wall_layout(prob; maxiter=200)
    @test sol.status != :geometry_inconsistent         # judged on drift, not the enclosure guard
    @test sol.status != :geometry_required
    @test sol.feasible == true                         # the enclosing adequate core is accepted
    @test sol.revalidation.worst_util < 1.0            # real drift / torsion within limits
end

@testset "crit7 (3): a wall EXACTLY on the plate edge (w.x = cx + hx) PASSES the guard" begin
    # crit7's documented-residual geometry: plate_center = (−15, 0), plan_halfwidth = (3, 9).
    # The Y-walls land EXACTLY on x = cx ∓ hx = {−18, −12}; an on-boundary wall is ENCLOSED
    # (within tol = 1e-9 + 1e-9·hypot(hx, hy)), so the guard must NOT falsely fail it.
    XC = _CRIT7_XC
    ev = ReducedDiaphragmEvaluator(story_heights=[3.0], plan_halfwidth=(3.0, 9.0),
                                   plate_center=(XC, 0.0), accidental_ecc=0.05)
    walls = _crit7_walls()                             # x = cx − hx and x = cx + hx exactly
    loads = [StoryLoad(1, 5e4, 5e4, XC, 0.0)]
    @test StructuralSizer._plate_encloses_walls(ev, walls) == true   # on-edge is enclosed
    @test isfinite(evaluate_lateral(ev, walls, loads).torsion[1])    # not falsely failed closed

    # Contrast: a wall a hair (1 mm) OUTSIDE the same edge DOES fail closed — the boundary
    # tolerance absorbs floating-point noise but NOT a genuine plan-scale over-hang.
    walls_out = [WallLine(1, XC - 3.0 - 1e-3, 0.0, pi/2, 1e9, 1),
                 walls[2], walls[3], walls[4]]
    @test StructuralSizer._plate_encloses_walls(ev, walls_out) == false
end

@testset "crit7 (4): zero-halfwidth relaxation — on-axis enclosed, off-axis / negative fail closed" begin
    # The engineer relaxed hx ≤ 0 to fail closed only on a NEGATIVE half-extent: a ZERO
    # half-extent is left to the per-wall bounds (encloses on-axis walls, fails off-axis).
    # Mirrors the near-dead-Y fixtures that use plan_halfwidth = (0, 5) (a thin axis plate).
    encl = StructuralSizer._plate_encloses_walls
    ev = ReducedDiaphragmEvaluator(story_heights=[3.0], plan_halfwidth=(0.0, 5.0),
                                   plate_center=(0.0, 0.0), accidental_ecc=0.05)
    # ON-axis walls (all at x = cx = 0): the zero x half-extent still ENCLOSES them, because
    # the per-wall bound |w.x − cx| ≤ hx + tol holds within tol for x = cx.
    onaxis = [WallLine(1, 0.0, -5.0, 0.0,  1e8, 1),
              WallLine(2, 0.0,  5.0, 0.0,  1e8, 1),
              WallLine(3, 0.0,  0.0, pi/2, 1e8, 1)]
    @test encl(ev, onaxis) == true                     # legitimately degenerate thin plan certifiable

    # An OFF-axis wall (x = 2 ≠ cx) under the zeroed x half-extent FAILS CLOSED: a genuinely
    # spread layout declared under a zero-extent plate is still caught by the per-wall bounds.
    offaxis = [WallLine(1, 0.0, -5.0, 0.0,  1e8, 1),
               WallLine(2, 0.0,  5.0, 0.0,  1e8, 1),
               WallLine(3, 2.0,  0.0, pi/2, 1e8, 1)]    # x = 2 ⊄ zero-width plate
    @test encl(ev, offaxis) == false

    # A NEGATIVE half-extent is a nonsensical / inverted plate ⇒ treated as NON-enclosing
    # (fail closed) even for the on-axis walls — the relaxation is strictly for hx == 0.
    evneg = ReducedDiaphragmEvaluator(story_heights=[3.0], plan_halfwidth=(-1.0, 5.0),
                                      plate_center=(0.0, 0.0), accidental_ecc=0.05)
    @test encl(evneg, onaxis) == false
end

@testset "crit7 (5): NO over-rejection — symmetric well-braced ENCLOSING core stays feasible" begin
    # Guard that the enclosure gate does NOT reject a sound layout whose walls ARE inside the
    # plate. Symmetric core at the origin (2 X-walls at y = ±D, 2 Y-walls at x = ±D) on a
    # plate that EXACTLY encloses it (plan_halfwidth = (D, D), walls on the edges). Mirrors
    # crit5 (2)'s feasible D = 5 m core.
    DL = 0.02; D = 5.0
    cb = [WallCandidate(1, 0.0, -D,  0.0,  4.0, 3.0, 1, 25e9, 0.2, 28e6, 60e6*6.895,
                        2400.0, 0.1, 0.4, 0.0025),
          WallCandidate(2, 0.0,  D,  0.0,  4.0, 3.0, 1, 25e9, 0.2, 28e6, 60e6*6.895,
                        2400.0, 0.1, 0.4, 0.0025),
          WallCandidate(3, -D,  0.0, pi/2, 4.0, 3.0, 1, 25e9, 0.2, 28e6, 60e6*6.895,
                        2400.0, 0.1, 0.4, 0.0025),
          WallCandidate(4,  D,  0.0, pi/2, 4.0, 3.0, 1, 25e9, 0.2, 28e6, 60e6*6.895,
                        2400.0, 0.1, 0.4, 0.0025)]
    ev = ReducedDiaphragmEvaluator(story_heights=[3.0], plan_halfwidth=(D, D),
                                   plate_center=(0.0, 0.0), accidental_ecc=0.05)
    loads = [StoryLoad(1, 5e4, 5e4, 0.0, 0.0)]
    pb = WallLayoutNLPProblem(cb, ev, loads; objective=MinDrift(), drift_limit=DL)
    # The ±D walls on a ±D plate are enclosed (on-boundary), so the guard must not fire.
    @test StructuralSizer._plate_encloses_walls(ev, StructuralSizer._walls_from_density(pb, ones(4))) == true
    sol = solve_wall_layout(pb; maxiter=200)
    @test sol.feasible == true                         # adequate enclosing core accepted
    @test sol.status != :geometry_inconsistent
    @test sol.revalidation.worst_util < 1.0            # comfortably within the limits
end

@testset "crit7 (6): missing plate_center stays :geometry_required (distinct from :geometry_inconsistent)" begin
    # The two fail-closed modes must remain DISTINCT: a MISSING plate center cannot locate the
    # corners at all (:geometry_required), whereas a PRESENT-but-under-covering plate is a
    # cross-check failure (:geometry_inconsistent). Same walls, same under-covering extent.
    DL = 0.02; XC = _CRIT7_XC
    loads = [StoryLoad(1, 5e4, 5e4, XC, 0.0)]

    # (a) plate_center ABSENT (struct DEFAULT) ⇒ :geometry_required.
    ev_missing = ReducedDiaphragmEvaluator(story_heights=[3.0], plan_halfwidth=(2.0, 9.0),
                                           accidental_ecc=0.05)
    @test ev_missing.plate_center === nothing          # the fail-closed precondition
    prob_missing = WallLayoutNLPProblem(_crit7_cands(), ev_missing, loads;
                                        objective=MinDrift(), drift_limit=DL)
    sol_missing = solve_wall_layout(prob_missing; maxiter=200)
    @test sol_missing.feasible == false
    @test sol_missing.status == :geometry_required
    @test sol_missing.revalidation.failing.mode == :geometry_required

    # (b) SAME under-covering extent but WITH plate_center ⇒ :geometry_inconsistent.
    ev_incons = ReducedDiaphragmEvaluator(story_heights=[3.0], plan_halfwidth=(2.0, 9.0),
                                          plate_center=(XC, 0.0), accidental_ecc=0.05)
    prob_incons = WallLayoutNLPProblem(_crit7_cands(), ev_incons, loads;
                                       objective=MinDrift(), drift_limit=DL)
    sol_incons = solve_wall_layout(prob_incons; maxiter=200)
    @test sol_incons.feasible == false
    @test sol_incons.status == :geometry_inconsistent
    @test sol_incons.status != sol_missing.status      # the two fail-closed modes are DISTINCT
end

@testset "crit7 (7): SAME walls + HONEST enclosing plate ⇒ judged on the METRIC path (NOT geometry refusal)" begin
    # Companion to crit7 (1): the EXACT SAME core (Y-walls at x = −18 / −12, X-walls at
    # y = ±6, mass at the core center) that FAILED CLOSED with `:geometry_inconsistent`
    # under the under-covering (2, 9) plate is here handed an HONEST, genuinely ENCLOSING
    # plate — center (0, 0), half (20, 10) ⇒ x ∈ [−20, 20], y ∈ [−10, 10]. The walls
    # (x ∈ {−18, −15, −12}, y ∈ {−6, 0, 6}) are all INSIDE it, so the enclosure guard does
    # NOT fire and the verdict is decided by the REAL (finite) corner-drift / torsion
    # metrics — proving geometry REFUSAL (crit7 (1)) and the metric check are DISTINCT paths
    # for one and the same layout. The core is eccentric (CR = (−15, 0)) relative to the
    # honest plate center (0, 0), so the physical judgment is a drift/torsion decision, not a
    # geometry fail-closed.
    DL = 0.02; XC = _CRIT7_XC
    walls = _crit7_walls()                            # Y-walls at x = −18 / −12 (as crit7 (1))
    loads = [StoryLoad(1, 5e4, 5e4, XC, 0.0)]         # identical loads to crit7 (1)

    # HONEST enclosing plate (0, 0) / (20, 10): the SAME walls now sit INSIDE it (contrast
    # crit7 (1)'s under-covering (2, 9) plate, where x = −18 / −12 poked out).
    ev = ReducedDiaphragmEvaluator(story_heights=[3.0], plan_halfwidth=(20.0, 10.0),
                                   plate_center=(0.0, 0.0), accidental_ecc=0.05)
    @test StructuralSizer._plate_encloses_walls(ev, walls) == true    # guard does NOT fire (crit7 (1) was false)

    # Twist certification is AVAILABLE (finite), NOT failed closed to `Inf` as in crit7 (1):
    # the metric path is live, so feasibility is a REAL drift/torsion decision.
    @test isfinite(evaluate_lateral(ev, walls, loads).torsion[1])
    @test all(isfinite,
              StructuralSizer.direction_complete_interstory_drift(ev, walls, loads).corner_drift)

    # End-to-end: solve_wall_layout takes the METRIC path, NOT the geometry fail-closed.
    prob = WallLayoutNLPProblem(_crit7_cands(), ev, loads;
                                objective=MinDrift(), drift_limit=DL)
    sol = solve_wall_layout(prob; maxiter=200)
    @test sol.status != :geometry_inconsistent         # NOT the crit7 (1) geometry refusal …
    @test sol.status != :geometry_required             # … and NOT the missing-plate refusal
    @test isfinite(sol.revalidation.worst_util)        # a FINITE metric util (crit7 (1) was Inf)
    # Whatever the verdict, it is a METRIC decision: a feasible pass, or an `:infeasible`
    # rejection on a real drift/torsion/eigen/shear mode — never the geometry fail-closed.
    if sol.feasible == false
        @test sol.status == :infeasible
        @test sol.revalidation.failing.mode ∉ (:geometry_inconsistent, :geometry_required)
    end
end

@testset "crit7 (8): guard does NOT over-reject a CR-OUTSIDE-plate layout whose walls are INSIDE" begin
    # The enclosure guard keys on the CHECKABLE proxy WALLS ⊆ plate — NOT on CR ⊆ plate — so
    # a torsionally-soft but legitimate layout whose center of rigidity escapes the plate must
    # NOT be spuriously failed closed. Reuses the rev6 non-orthogonal construction (reproducer:
    # scripts/runners/review_verify_reproducer.jl): angled walls push the CR to ≈ (−53, 76),
    # far OUTSIDE the ±20 × ±10 plate, yet every wall is INSIDE it. The guard must pass, the
    # twist metrics stay FINITE (certification available), and the layout is judged on the EXACT
    # corner drift — rejected on DRIFT only because it is over-limit here (≈ 1.16× DL), never by
    # the geometry guard.
    dcid_fn = StructuralSizer.direction_complete_interstory_drift
    DL = 0.02
    ev = ReducedDiaphragmEvaluator(story_heights=[3.0], plan_halfwidth=(20.0, 10.0),
                                   plate_center=(0.0, 0.0), accidental_ecc=0.05)
    walls = [WallLine(1, 12.8135, 5.0583, 2.35599, 1.1308e7, 1),
             WallLine(2, 18.7749, 7.0527, 2.11040, 7.8990e6, 1),
             WallLine(3, -3.1547, 2.4018, 2.30842, 3.8254e3, 1),
             WallLine(4, 10.0054, -6.3296, 1.11546, 1.0348e1, 1),
             WallLine(5, -19.3582, -2.2333, 2.06246, 2.6123e7, 1)]
    loads = [StoryLoad(1, -9.6450e3, 2.4935e4, -7.7016, -9.9339)]

    # CR escapes the plate, but ALL walls are strictly inside it.
    cr = StructuralSizer._center_of_rigidity(StructuralSizer._assemble_story_K(walls))
    @test cr[1] < -20.0 && cr[2] > 10.0                          # CR OUTSIDE the ±20 × ±10 plate
    @test all(-20.0 <= w.x <= 20.0 && -10.0 <= w.y <= 10.0 for w in walls)   # walls INSIDE

    # The enclosure guard keys on WALLS ⊆ plate, so it does NOT fire on a CR-outside layout.
    @test StructuralSizer._plate_encloses_walls(ev, walls) == true

    # Twist certification is AVAILABLE (finite) — NOT failed closed to `Inf`: the layout is
    # handed to the EXACT metric path, correct even though the CR sits outside the plate.
    @test isfinite(evaluate_lateral(ev, walls, loads).torsion[1])
    dc = dcid_fn(ev, walls, loads)
    @test all(isfinite, dc.corner_drift)

    # Judged on DRIFT: here the EXACT far-corner drift is over-limit (≈ 1.16× DL), so the layout
    # is (correctly) rejected on the DRIFT metric — NOT by the enclosure guard.
    corner_util = maximum(dc.corner_drift) / DL
    @test corner_util > 1.0                                     # rejected on drift, because over-limit
    @test isapprox(corner_util, 1.160; atol=0.02)              # EXACT far-corner drift (metric path)
end
