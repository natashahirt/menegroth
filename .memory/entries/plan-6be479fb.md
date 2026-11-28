---
id: plan-6be479fb
type: plan
project: menegroth
parent_id: plan-bff9aa9f
title: 'Member-stage exact speed wins: #10 hoist P-M/catalog/plan-group memo, #4 content-addressed
  FEA cache, #13 parallel per-member design'
node_label: 'Member-stage exact speed wins: #10 hoist P-M/catal'
tags: ''
status: active
open_threads: 0
success: 'null'
files: ''
session_id: sess-2f0d388b
created_at: '2026-11-20T22:35:14.490339+00:00'
updated_at: '2026-11-20T22:35:14.490339+00:00'
---
Overnight autonomous speed pass on the flat-plate member stage, grounded in docs/sizing-map/member-stage-fixpoint.md §6 and audit-2026-11-18/speed.md §3. All EXACT (bit-identical) levers only; approximations (#1 fixed mesh, #3 predict-confirm, #5 coarse tier) stay gated.

Plan / order (lowest risk first):
1. #10 Hoist P-M capacity caches + catalog + plan-groups. In SY/workflow/flat_plate_column_check.jl the 4 helpers (_stack/_grow/_fit/joint) each rebuild _column_catalog + precompute_capacities! over the whole RC catalog every settle round, and _fit recomputes _catalog_plan_groups INSIDE its per-column loop. The filled ACIColumnCapacityCache is a pure fn of (catalog sections, fc/fy/Es/εcu, objective, include_biaxial) and is read-only during is_feasible → safe to memoize + share (also enables #13). Add a locked content-addressed memo validated by StructuralSizer.cache_matches + identity guards (catalog/material/objective ===). Expected 1.5-3x on member stage; biggest on DDM/fast tier where MIP dominates.
2. #4 Content-addressed FEA slab cache: key mesh+factor by fea_mesh_key CONTENT, not slab_idx; memo whole-slab result on (key,h,E,stub sections,loads). Exact. Skips the 3 identical first-floor builds and unchanged stale-slab redesigns.
3. #13 Parallel per-member column/slab design against a frozen analysis snapshot (Jacobi + one reconcile), bit-identical to sequential (reconcile max is order-independent, spawns write disjoint members). Only where determinism contract is preserved.

Validation: core/test_flat_plate_member_stage.jl (299) must stay bit-identical; design_graph equivalence+incremental; then profile_design_building_stages.jl on the now-converging core office for before/after. Running overnight, verification cycles OK.

Brainstorm backlog (keep adding): single-section cache in _rc_section_check also rebuilds 1 diagram/column/call; _joint_feasible local caches still per-call; _catalog_plan_groups could be memoized globally; consider a run-scoped MemberStageCaches provider object as the clean long-term home instead of module globals.
