---
id: deci-dc24c1ed
type: decision
project: menegroth
parent_id: deci-1a699cbf
title: 'PIVOT: reduced tier cannot certify eccentric drift without plate geometry
  — do the data-model fix (plumb plate center + CoM)'
node_label: 'pivot: data-model fix'
tags: walls,phase1,phase3,stability,drift,torsion,data-model,reduced-evaluator,plate-geometry,decision,pivot,safety
status: active
open_threads: 0
success: 'null'
files: ''
session_id: sess-80f08b9f
created_at: '2026-10-22T00:08:47.453461+00:00'
updated_at: '2026-10-22T00:08:47.453461+00:00'
---
After 6 adversarial rounds, PROVEN from multiple independent angles: the reduced tier (ReducedDiaphragmEvaluator) CANNOT rigorously certify eccentric/non-orthogonal corner drift or torsion, because it stores plan_halfwidth (plate SIZE) but NOT the plate POSITION relative to the walls, and NO center of mass. Without the plate position in the wall frame, the true occupant corners cannot be located or bounded.

FAILED in-scope attempts (each with a concrete counterexample):
- Round 4/5: anchor corners to WALL CENTROID -> crit5 eccentric service core at 1.51*DL returned feasible=true.
- Round 6 (conservative bound r_bound=hypot(2hx,2hy)): rev6 — for non-orthogonal walls with stiffness disparity the CR escapes the plate (CR=(-53,76) for a 20x10 plate), layout at 1.16*DL passed; crit6 — the (0,0) STRUCT DEFAULT fallback measures radius from origin not CR (1.27*DL passed) and a plan_halfwidth smaller than the wall spread is never validated (1.85*DL passed). The premise 'CR within walls' hull within plate' is false; 'plate contains walls and is origin-centered' is not guaranteed by the data model.

CONCLUSION: the missing input is GEOMETRIC, not algorithmic. No in-scope patch is rigorous. The reduced tier's FRAME-INDEPENDENT checks remain SOUND and are retained: translational mechanism floor lambda_min(K_tt) >= F_s/(h*DL), per-wall shear, fail-closed singular (_solve_spd / SingularStiffnessError), eigenstructure translational block. What is unsound WITHOUT plate geometry: corner-drift / torsional-amplification certification.

USER DECISION (datamodel_now): do the data-model fix NOW (pull the diaphragm-geometry slice of Phase 3 forward). Add the TRUE plate geometry (plate center + extent, or the 4 occupant-corner coordinates) and the center of mass to ReducedDiaphragmEvaluator in the SAME coordinate frame as the walls; thread it through every call site that builds the evaluator; make corner drift EXACTLY computable (max over the 4 true corners of |u_corner|/h, u_corner = [ux - phi*cy, uy + phi*cx] about the actual CR); use the true max CR-to-corner lever for r_ref/torsion; apply the lateral resultant at the true center of mass so the natural CoM->CR eccentricity is captured; FAIL CLOSED when geometry is absent (no silent wall-centroid / (0,0) default). The Phase 10 unified-FEM survivor check remains the final authority. NEXT: explore to scope the struct + all construction sites + where plate geometry and mass live in the building/skeleton/design data model, then design a coordinator graph (explore -> engineer(s) -> reviewer/critic/tester).
