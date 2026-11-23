---
id: deci-62d877ec
type: decision
project: menegroth
parent_id: plan-382ddd12
title: Drift-driven sizing = virtual-work drift participation (optimality criteria),
  not iterate-and-resolve; explicit assumptions recorded
node_label: Drift-driven sizing = virtual-work drift participa
tags: ''
status: active
open_threads: 0
success: 'null'
files: ''
session_id: sess-69780ed3
created_at: '2026-11-23T18:49:22.870327+00:00'
updated_at: '2026-11-23T18:49:22.870327+00:00'
---
DECISION: drift drives beam/column/core stiffness via the unit-load (virtual-work) drift-participation / optimality-criteria method (Baker 1990; Chan/Grierson/Sherbourne 1995; Charney), chosen over naive step-up-and-resolve because it is BOTH more material-efficient AND lower-compute on this codebase.

FORMULATION. For a drift DOF, apply a virtual unit load; by the unit-load theorem the drift is a separable sum over members:
  δ = Σ_e c_e / s_e,  c_e = ∫_e (F_e f_e)/E dx  (flexure: ∫ M·m/E dx; axial: ∫ N·n/E dx),
where s_e is the member's drift stiffness variable (I for flexural, A for braces, I_wall for the core), F_e/f_e are real/virtual internal forces. Min weight W=Σ w_e s_e s.t. Σ c_e/s_e ≤ δ_allow gives the optimality criterion
  s_e* = sqrt(λ c_e / w_e),  sqrt(λ) = (1/δ_allow) Σ_k sqrt(c_k w_k),
i.e. a closed-form redesign from ONE real + ONE virtual solve. Core (walls) enters the same sum → principled frame-vs-core split replaces the current standalone wall-thickness heuristic.

ASSUMPTIONS (each must stay auditable; this is safety-critical seismic/wind sizing):
1. First-order sensitivity: c_e computed with F_e, f_e held fixed within a resize step; force redistribution captured only by re-solving between outer iterations. Linear-elastic, E constant per material.
2. Separability: δ = Σ c_e/s_e holds for the chosen stiffness variable (I flexural / A axial / I_wall core). Shear/panel-zone flexibility deferred (flag; add as extra terms later).
3. Weight model w_e = marginal dw/dI along each member's allowed (I,weight) catalog Pareto frontier (NOT a global constant — steel I~d² across depths). Continuous update then snap-up to discrete catalog.
4. Strength floor: drift sizing never drops a member below its strength-governed size; s_e_final = snap_up(max(s_e_strength, s_e_drift)). Strength-passive members freeze (active-set) but keep their c_e in the constraint.
5. P-Δ handled as the story-stability θ / B2 multiplier on elastic drift (ASCE 7-22 §12.8.7 / AISC 360 App.8), NOT by re-forming geometric stiffness in the drift solve — keeps K SPD and reuses the Cholesky factor. Assumes θ ≤ θmax (§12.8.7).
6. Drift constraints: seismic δx = Cd·δxe/Ie vs Table 12.12-1 Δa (ASCE 7-22 §12.8.6, §12.12.1); wind serviceability ~h/400 (common practice, NOT an ASCE 7 strength limit). Each is one row in the (multi-)constraint set.
7. Damped update s_new = s_old^(1-η)·s_opt^η, η≈0.5, to stabilize redistribution; expect ~5 outer iters.
8. MVP = single governing constraint + single λ + active set; generalize to multi-story (multi-λ dual, Chan/Grierson) and wind as added constraint rows — no new machinery.

COMPUTE BASIS (validated against Asap factorization_cache.jl): virtual load = extra RHS on the cached Cholesky factor (factorize!/solve_factorized!); a resize is a value-only change → in-place cholesky! reuses the symbolic fill-reducing ordering (skips the dominant cost); frame-only drift via the existing exclude_shells variant; P-Δ via geometric_stiffness variant exists but we avoid it per assumption 5. Per outer iter ≈ 1 in-place refactor + (1+n_constraint) back-subs + closed-form resize.

ARCHITECTURE (architecture-contracts.mdc): FE sensitivity primitives — assemble, factor-reuse, real+virtual solve, per-element c_e extraction — live in Asap (new 'drift participation' query extending exclude_shells + factor cache). Optimality update, catalog snap, strength floor, active set, outer loop live in StructuralSizer/Synthesizer.

BUILD ORDER: (1) Asap drift-participation query (virtual unit-load solve on cached factor + per-element c_e), tested against hand-calc cantilever tip deflection + portal-frame sway; (2) single-constraint optimality loop; (3) multi-story + wind; (4) prove on 20–40 story steel-MF + RC-core. Prerequisite for pulling real c_e in anger: DualSystem behavior hooks (assembled+solved steel dual model).

FIRST STEP NOW: build + test the Asap drift-participation query (self-contained, hand-calc verifiable).
