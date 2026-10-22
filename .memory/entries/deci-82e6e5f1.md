---
id: deci-82e6e5f1
type: decision
project: menegroth
parent_id: deci-893edf58
title: Direction-complete drift as the layout-stability guarantee (reduced tier)
node_label: direction-complete stability
tags: walls,phase1,stability,layout,optimizer,drift,safety,decision
status: active
open_threads: 1
success: 'null'
files: ''
session_id: sess-2a77de09
created_at: '2026-10-21T10:30:27.875261+00:00'
updated_at: '2026-10-21T14:27:42.128899+00:00'
---
Critic (crit2) proved a latent SAFETY P0 in the layout optimizer: singular detection is a threshold CLIFF (throws only at scaled rcond<=1e-8), and the drift constraint only catches a weak lateral mode if the applied LOAD excites it. Under a single-direction (X-only) load the orthogonal (Y) translation mode is unexcited, so a near-singular layout (rcond in (1e-8,~1e-7]) is accepted as a feasible optimum (drift 1.7e-4) yet collapses under an equal Y load (drift 3.3e3, ~167000x limit). solve_wall_layout returns optimize_continuous(p) with NO survivor re-validation (layout_problem.jl:333); FEM guard is exact-PD only. Largely PRE-EXISTING (not a Phase 1 regression) and not wired to production, but a real gap. Confirmed the critic's probe drives the real evaluate_lateral WITH accidental_ecc=0.05, so accidental torsion does NOT save it (X-walls' lever arm resists the torsion; nothing excites Y).

USER CHOSE option C scoped SELF-CONTAINED (reduced tier only). ELEGANT FIX (root cause = stability inferred indirectly instead of enforced directly):
1. DIRECTION-COMPLETE DRIFT as the stability constraint: per story, take the applied lateral resultant magnitude and re-apply it in each principal direction (+X, +Y) with accidental-torsion companions (+/-ecc); require max interstory drift over ALL cases <= drift limit. A mechanism in ANY direction then shows up as excessive drift regardless of the design load direction, caught by the existing (physical, ASCE-grounded) drift limit — no arbitrary threshold; differentiable/graceful for Ipopt. ENGINEERING JUDGMENT: both-direction mechanism-prevention sweep (motivated by ASCE 7-22 §12.5 direction-of-loading); accidental torsion stays cited §12.8.4.2.2. Do NOT invent ASCE orthogonal-load MAGNITUDES (that is Phase 6) — reuse the supplied design magnitude swept in direction.
2. Demote rcond throw to a pure NUMERICAL backstop (keep so Cholesky never factorizes a singular K; fail-closed default preserved for the check path) — direction-complete drift now DEFINES stability.
3. SURVIVOR RE-VALIDATION: solve_wall_layout runs the direction-complete check on the SELECTED layout and refuses to return it (throw / infeasible) if any direction fails.
4. CENTER-OF-RIGIDITY lever arms (or Schur complement of the rotational DOF) so torsional response + any conditioning metric are ORIGIN-invariant; retire the origin-invariance docstring overclaim honestly.
SCOPE: ASCE directional-load magnitudes -> Phase 6; unified-FEM survivor cross-check -> Phase 10 (tracked). Deferred deep items remain the Phase 10 acceptance gate.
