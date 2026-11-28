---
id: chec-2c6f594a
type: checkpoint
project: menegroth
parent_id: plan-6be479fb
title: '#10 landed: run-level memo for column capacity caches + catalog + plan-groups;
  299/299 member-stage tests bit-identical'
node_label: '#10 landed: run-level memo for column capacity cac'
tags: ''
status: active
open_threads: 0
success: 'null'
files: ''
session_id: sess-2f0d388b
created_at: '2026-11-20T23:04:11.467479+00:00'
updated_at: '2026-11-20T23:04:11.467479+00:00'
---
Implemented speed.md #10 (exact) in SY/workflow/flat_plate_column_check.jl:
- Added a content-addressed, lock-guarded memo at module scope: _memo_column_catalog (standard catalog built once per (shape,catalog); custom returned as-is), _memo_capacity_cache (filled ACIColumnCapacityCache keyed by objectid(catalog/material/objective)+biaxial+fy+Es, validated by StructuralSizer.cache_matches and ===-identity guards before reuse), _memo_plan_groups (catalog plan-size groups keyed by catalog+cache+cap).
- Routed the 3 helpers (_stack/_grow/_fit) and the budget-length call onto the memo. Crucially _fit previously rebuilt _catalog_plan_groups INSIDE its per-column loop; now memoized once per (catalog,cache,cap).
- Kept the per-call `caches` dict only for §10.12 joint checks (unchanged). _column_catalog retained (still used by pipeline_spec.jl).

Correctness: a filled ACIColumnCapacityCache is a pure fn of its inputs and is read-only during is_feasible/explain_feasibility, so sharing is exact; cache_matches re-validates fc/fy/Es + weak-axis diagrams; identity guards defeat objectid reuse and objective changes (which cache_matches ignores). Verified bit-identical: core/test_flat_plate_member_stage.jl 299/299 PASS (1523s). No behavior change, only eliminated redundant precompute_capacities! rebuilds per settle round and per-column plan-group recomputation.

Next: stage profiler for absolute numbers; then single-section cache in _rc_section_check (same infra), then assess #4/#13.
