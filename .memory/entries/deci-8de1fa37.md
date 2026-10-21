---
id: deci-8de1fa37
type: decision
project: menegroth
parent_id: deci-1f380940
title: Bound true max-corner interstory drift (ASCE 7-22 12.12.1), actual-CR levers
node_label: true-corner drift bound
tags: walls,phase1,stability,drift,torsion,eccentric-cr,asce,safety,decision
status: active
open_threads: 0
success: 'null'
files: ''
session_id: sess-5d44ebd3
created_at: '2026-10-21T15:21:59.303843+00:00'
updated_at: '2026-10-21T15:21:59.303843+00:00'
---
crit4 proved a P1 (2 findings, one root cause; reproducer scripts/runners/attack_wall_eigenstructure_gate.jl): the eigenstructure gate certifies STIFFNESS exactly (reviewer confirmed Schur block-diagonal at CR), but the bridge from stiffness floor to the DRIFT LIMIT assumes the center of rigidity sits at the plan center — r_ref=hypot(hx,hy) and _torsion_amplification corners at CR+/-(hx,hy). For a stiffness-ECCENTRIC layout the true CR-to-corner lever is hypot(hx+|xr|,hy+|yr|), up to ~2x larger. Consequences: (P1a) solve_wall_layout returns feasible=TRUE for a layout whose true corner interstory drift is 1.11xDL — because the serviceability bound is placed on CR-TRANSLATION drift (blind to twist) plus a SATURATING torsion ratio capped at 1.5, which by construction permits corner drift up to ~1.5xDL; (P1b) the anti-mechanism torsional floor itself is understated up to 2x for eccentric CR. ASCE 7-22 §12.12.1 bounds the amplified design story drift AT THE LOCATION (the corner, incl torsion) to Delta_a — the code was bounding the WRONG quantity. Fails UNCONSERVATIVELY on exactly the eccentric layouts a torsional gate exists to police. All collapse MECHANISMS are caught (3 prior P0s fixed); this is a drift-limit/serviceability accuracy bug, not a returned mechanism.

USER CHOSE fix_now (Extension 4). DESIGN (reduced tier; lateral_evaluator.jl + layout_problem.jl):
1. Replace the CR-translation-only drift serviceability bound with the TRUE MAX-CORNER interstory drift: per story and per direction-complete case, disp(p) = [ux - phi*py, uy + phi*px] at each TRUE plan corner p in {(+/-hx, +/-hy)} (equivalently CR-translation + phi x (p - actual CR)); max-corner drift ratio = max over corners of hypot(ux-phi*py, uy+phi*px)/h; bound <= DL. Sweep over the +X/+Y design-resultant cases with the SAME accidental-torsion companion (ASCE 7-22 §12.8.4.2.2). This captures torsional amplification DIRECTLY, uncapped, relative to the ACTUAL CR — implements ASCE 7-22 §12.12.1 (drift at the location). Demote the saturating torsion RATIO from the drift safety bound (keep only for irregularity reporting if desired).
2. Fix r_ref in the eigenstructure TORSIONAL floor to the true max CR-to-corner distance max_p hypot(px-xr, py-yr); keep eigenstructure floors (min-eig K_tt, K_theta_cr with corrected r_ref) as the LOAD-INDEPENDENT anti-mechanism backstop (F_s~0 stories, stiffness guarantee).
3. Survivor re-validation re-checks max-corner drift + eigenstructure floors + per-wall shear; feasible=false on any violation.
4. Optimizer constraint_fns uses max-corner drift as the drift-slot utilization (smooth enough: hypot+max, as before).
Verify: crit4 P1a probe (20x10 plan, X-walls y=+/-5, Y-walls x=+9 strong/x=-9 weak, CR xr=6.861) now INFEASIBLE (corner drift ~1.11xDL); eccentric floor-only case r_ref=17.587 (was 11.180) so util_tors reflects true lever; symmetric well-braced core unchanged (CR at center); near-dead-Y, torsional clustered, diagonal still caught; origin invariance preserved; all prior tests pass. Engineer to confirm the §12.12.1 clause via corpus MCP before pinning. Phase 10 unified-FEM survivor remains FINAL authority; no ASCE load magnitudes invented (Phase 6).
