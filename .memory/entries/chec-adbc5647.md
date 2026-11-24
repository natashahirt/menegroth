---
id: chec-adbc5647
type: checkpoint
project: menegroth
parent_id: chec-dff96cd3
title: Drift governor rewired onto batched + rigid-link drift_participation; rigid-diaphragm
  sizing now correct
node_label: Drift governor rewired to batched+rigid-link
tags: drift,governor,resizer,rigid-link,batched,participation,optimality-criteria
status: active
open_threads: 0
success: 'null'
files: StructuralSizer/src/optimize/drift_governor.jl@18dffec, StructuralSizer/test/optimize/test_drift_governor.jl@18dffec
session_id: sess-37be74bb
created_at: '2026-11-24T02:33:14.807407+00:00'
updated_at: '2026-11-24T02:33:14.807407+00:00'
has_child_rationale: Consumes the generalized Asap drift_participation (chec-dff96cd3)
  so the resizer works on rigid-diaphragm dual models and in one solve per outer iter
---
Rewired `resize_for_drift!` (StructuralSizer/src/optimize/drift_governor.jl) onto the generalized Asap primitive (chec-dff96cd3):

- **Batched participation**: replaced the per-DOF `drift_participation(model, d).c` cache + Julia linear-combine loop with a single `drift_participation(model, V; links)` call. `V` (nDOFs×m) is built once (DOFs/coeffs are fixed across outer iters), one column per constraint = Σ_i coeffs[i]·e_{dofs[i]}. One multi-RHS back-substitution covers all m limits per outer iteration instead of one virtual solve per unique DOF.
- **Rigid-diaphragm support (the real fix)**: added `links` kwarg. Both the re-solve (`dosolve!()` routes to `solve!(model, links)`) AND the participation query now run on the reduced master/slave system, so the diaphragm-master story DOFs the constraints reference are consistent between solve and sensitivity. Previously the governor called the unreduced `solve!(model)` and `drift_participation` without links — wrong factor for any rigid-core dual high-rise.

Math unchanged for the no-links path (bdp.c[e,j] = Σ_i coeffs_i·participation.c[e] by linearity = old cfull[e]); background accounting identical (`drift_of(con) - sum(C[:,j])`, sized members only). `drift_optimality.jl` needed NO change — it's pure (consumes the C matrix) and already matches BatchedDriftParticipation.c.

**Tests**: StructuralSizer drift suites 71/71 (was 65; +6 new rigid-diaphragm governor testset: two columns tied to a master, constraint + participation on the reduced system, halving the master drift → symmetric columns grow ~2×, converges). Lints clean.

Next: (4d) wire the governor into the DualSystem stage on a 20–40 story steel-MF + RC-core model with a rigid diaphragm (now that links flow through), using the core as fixed background (δ_eff = δ_allow − nonframe).
