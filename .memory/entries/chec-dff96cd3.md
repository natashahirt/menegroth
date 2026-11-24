---
id: chec-dff96cd3
type: checkpoint
project: menegroth
parent_id: chec-662a0bd0
title: 'Asap drift_participation generalized: arbitrary/differential/batched virtual
  loads + rigid-link reduced-factor support'
node_label: Asap drift participation generalized
tags: asap,drift,participation,virtual-work,rigid-link,optimality-criteria,inter-story-drift
status: active
open_threads: 0
success: 'null'
files: external/Asap/src/Model/analysis/drift_participation.jl@6637391, external/Asap/src/Asap.jl@6637391,
  external/Asap/test/integration_and_api/test_drift_participation.jl@6637391
session_id: sess-870039a1
created_at: '2026-11-24T02:21:32.395162+00:00'
updated_at: '2026-11-24T02:21:32.395162+00:00'
has_child_rationale: Extends the single-DOF drift-participation query into the general
  virtual-load primitive the dual drift governor/resizer needs
---
Generalized Asap's `drift_participation` (previously single absolute free-DOF only) into the full virtual-load sensitivity primitive, addressing the three gaps that blocked the dual-system drift governor:

1. **Arbitrary virtual-load vector** `drift_participation(model, v::AbstractVector; links)` — any linear displacement functional δ = vᵀu_r, same exact extraction c_e = u_{v,e}ᵀ K_e u_{r,e}.
2. **Differential (inter-story) drift** `drift_participation(model, dof_top, dof_bottom; links)` — virtual load +1/−1, the governing ASCE 7-22 §12.8.6 inter-story Δ, not just absolute roof/floor displacement.
3. **Batched multi-RHS** `drift_participation(model, V::AbstractMatrix; links)` → `BatchedDriftParticipation` with `c[e,k]`, one back-substitution for all columns (per-story multi-λ sizing: 40–80 story/direction constraints at the cost of one solve).
4. **Rigid-link (rigid-diaphragm) support** via `links` kwarg — the blocker: a dual system with a concrete core + rigid diaphragm solves in the reduced master/slave space (`Krr = GᵀSG`); the old query used the unreduced factor and dimension-mismatched. Now routes the virtual load through Gᵀ, solves on the cached *reduced* factor (`_get_reduced_factorization!`), and recovers u_v = G·u_retained — same condensation as `solve!(model, links)`. The diaphragm-master translation IS the story DOF.

Struct change: dropped the now-meaningless `dof` field from `DriftParticipation` (δ is now a general functional value). Added `BatchedDriftParticipation` (δ::Vector, c::Matrix, nonframe::Vector), exported both.

**Backward compatible**: existing `drift_participation(model, dof)` and `(model, node, dir)` overloads preserved; `.δ`/`.c`/`.nonframe`/`.element_ids` unchanged. Already-built resizer (StructuralSizer drift_optimality.jl / drift_governor.jl, chec-8dbd4e63/chec-6056dbcd) still green: 65/65. These call drift_participation per-story in loops WITHOUT `links` — the new batched/differential/rigid-link forms are the direct upgrade path for them (multi-story dual models with a rigid core currently can't use the right factor).

**Tests**: Asap test_drift_participation.jl 35/35 (added differential-DOF exact-decomposition, batched-matches-single, rigid-diaphragm-through-reduced-factor with Σc_e = δ and nonframe≈0 since rigid links store no strain energy). StructuralSizer drift suites 65/65.

NOTE: parent-session summary was stale — the single/multi-constraint resizer and drift governor (4a/4b) were already built (chec-8dbd4e63, chec-7177d564, chec-6056dbcd). This checkpoint is the Asap-side primitive they should be rewired onto for the rigid-diaphragm high-rise proof.
