---
id: deci-a0f4d98f
type: decision
project: menegroth
parent_id: plan-f6511c0b
title: 'Phase B fork verdicts: atomic fixpoint node + beam-only fine nodes; column
  MIP split & flat-plate override deferred'
node_label: 'Phase B fork verdicts: atomic fixpoint node + beam'
tags: ''
status: active
open_threads: 0
success: 'null'
files: ''
session_id: sess-5e025de3
created_at: '2026-07-15T01:49:52.105464+00:00'
updated_at: '2026-07-15T01:49:52.105464+00:00'
---
Recon ([Phase B recon] explore) resolved the three architectural forks:

FORK 1 beam-column fixpoint (_size_beams_columns! design_workflow.jl:1265-1383): tol=0.05 relative per-column axial-demand convergence, max_iterations default 20, plus post-loop P-Delta (re-calls size_columns!) and fire-coating branches. Beam-group changes feed back into all column demands. VERDICT: model :members as ONE ATOMIC fixpoint DAG node (whole-node memo). Per-beam-group skip INSIDE the loop is NOT exact-first-safe. Monotonic column growth applies to flat-plate slab sizing, not this loop.

FORK 2 per-column-group MIP split (size_columns! utils.jl:2808-2945 -> optimize_discrete, discrete_mip.jl:296-301): separable only when n_max_sections==0 (default), but global sum(z)<=n_max_sections couples groups when set, and demands are inter-iteration coupled. VERDICT: per-column-group DAG split NOT exact-first-safe. FALLBACK: column sizing stays atomic inside the fixpoint; only beam groups go fine.

FORK 3 flat-plate column override: column catalog/objective flows via prepare-affecting params.columns; flat-plate :members stage is only _reconcile_columns! (no catalog). VERDICT: OUT OF SCOPE for Phase B (needs a new non-prepare-affecting slab-stage override field + size_flat_plate! plumbing).

CHOSEN PHASE B SCOPE: internal refactor threading resolve_member_group_override(params, gid) into the BATCHED size_beams! API (per-group catalog kwarg in StructuralSizer api.jl) inside the atomic fixpoint node; size_columns! stays one global call per iter; remove the fail-loud guard only for the now-honored beam path and re-gate exact-first. Do NOT switch to size_member_group! (optimize_binary_search) as the production beam path without a byte-identity gate vs size_beams!. Deferred: per-column-group MIP nodes, flat-plate per-group catalog overrides.

GUARD/LOAD ORDER: constructor (design_types.jl:1100-1117) cannot call _assert_member_group_overrides_unsupported (design_workflow.jl:92-107) under include order; helper must move to design_types.jl next to _is_effective (this is the concurrent P2 task).
