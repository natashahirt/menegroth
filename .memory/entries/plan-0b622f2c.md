---
id: plan-0b622f2c
type: plan
project: menegroth
parent_id: plan-a79eb74f
title: 'Optimization control layer: relaxation bounds + Pareto fronts + cost-aware
  fidelity scheduler'
node_label: Optimization control layer (relaxation/Pareto/scheduler)
tags: sizing,architecture,optimization,relaxation,optimality-criteria,pareto,multi-objective,fidelity,scheduler,lower-bound,plan
status: active
open_threads: 0
success: 'null'
files: docs/sizing-map/optimization-architecture.md@1e1fef5, docs/sizing-map/README.md@1e1fef5,
  docs/sizing-map/architecture.md@1e1fef5
session_id: sess-61ea56aa
created_at: '2026-11-24T14:59:51.642828+00:00'
updated_at: '2026-11-24T14:59:51.642828+00:00'
has_child_rationale: User confirmed the design and asked for a detailed plan write-up
---
New companion doc `docs/sizing-map/optimization-architecture.md` (2026-11-24): the control layer that drives architecture.md's owners/round-controller. Extends, does not replace, the existing component model + two-tier fidelity. Motivated by the 30-story dual-system run showing continuous `Asap.Section` sizing is ~free (OC + cached reduced factor, 3-5 solves).

Three pillars, each extending an existing objective:
- A. Continuous-relaxation layer: continuous section props + optimality-criteria/dual update -> a CERTIFIED LOWER BOUND (objective(continuous*) <= catalog* <= detailed*) and a WARM START. Projection = bounded discrete search in a +/-1-2 catalog-step band around the warm start (NOT snap-up, which is coupling-blind). Anti-ratchet: vars anchored to the bound, may shrink; hybrid cycle-guard stays as fallback. Sharpens O4 (lightweight -> measured gap). Already-built engine: resize_for_drift!, Asap drift_participation, RigidLinkFactorCache.
- B. Multi-objective/Pareto: vector objective functional (every element reports marginal objective per unit of each var); trace the RELAXED Pareto front by continuation (warm-start neighbor weights), project only chosen front points to discrete. Generalizes O7; needs plan.md 2.5 (rebar in every RC objective) so OC weights = marginal carbon, not volume. Honest: discrete front != continuous; relaxed front SEEDS discrete points, each gap-certified.
- C. Cost-aware (value-of-information) scheduler: per-subsystem fidelity ladder F0..Fk; run F0/global to convergence first (settles the coupling graph cheaply, kills staleness ratchets); build SURROGATES from cheap evals (punching-vs-column-size, rib-deflection-vs-depth); invoke true expensive model (fine FEA, rib grillage, second-order, bracing) only near optimum / near binding constraints, warm-started, then refit. Escalate when expected gain > solve cost. Deepens O5. Sits on Phase-7 superelements/coarse-to-fine/caching as the policy layer.

Safety (O1) preserved by contract: relaxation + surrogates only GUIDE; every reported design terminates in the unchanged independent full-fidelity verifier; a test must enforce the relaxation path never writes a final size. Second-order, strength floors, A<->I coupling absorbed in verify. e0c0 payoff: continuous seed breaks discrete tie-break symmetry deterministically (unique continuous optimum).

Work packages: Workstream R (R.1-R.4 relaxation+bound+band), Workstream P (P.1-P.3 vector objective+fronts), C.1-C.4 (ladder+scheduler+surrogates+global-F0 coupling, extends Workstream F/Phase 7). Depends on plan.md Phase 2 (registry/owner interface/verifier) + Phase 1 baseline. FIRST PROVING SLICE: global F0 relaxation warm-starting the existing member MIP on a mid-rise (B2/B3), single objective, report (i) sizes identical-or-lighter, (ii) beam-column pass-count collapse, (iii) optimality gap. Open sign-offs: multi-lambda scheme, VOI metric vs move-limit rule, surrogate model class + error bands, scaling-law fit quality, non-convex objective handling. NOT YET IMPLEMENTED — design doc only.
