---
id: deci-bc4e27e2
type: decision
project: menegroth
parent_id: plan-a79eb74f
title: 'Architecture direction: unify column + rib (+beam/wall) capacity caching under
  ONE content-addressed catalog + owner interface'
node_label: 'Architecture direction: unify column + rib (+beam/'
tags: ''
status: active
open_threads: 0
success: 'null'
files: docs/sizing-map/architecture.md@21f8bd3
session_id: sess-a2c7af45
created_at: '2026-11-21T19:10:46.850753+00:00'
updated_at: '2026-11-21T19:10:46.850753+00:00'
---
User (2026-11-21) designated this agent the architecture owner for the full-scale sizing redesign and asked to fold in the PARALLEL rib-sizing speed work (separate agent) as a first-class input.

Synthesis: the parallel rib Tier1/Tier2 and this session's column #19/#20 are two instances of ONE abstraction. They should converge on a single substrate in Part B, not two ad-hoc memos.

Mapping (rib work -> architecture.md component):
- rib 'build the per-story candidate catalog once' == the 7.12 cache level 'P-M diagrams and section capacities per section and material'; column twin = _memo_capacity_cache + _memo_plan_groups.
- rib 'vectorized min-carbon lookup per piece' == the Phase 2/3 OWNER interface (requirements in -> lightest feasible value out); column twin = _lightest_passing_group/_lightest_in_group.
- rib 'precompute all capacities once per member stage (threaded)' == WP 7.1 (hoist caches out of loops) + 7.13 (deterministic parallelism).
- rib care point 'bf (ACI 318 8.12 effective flange width) must be bucketed exactly or conservatively' == the 7.12 'content-addressed keys: canonical fingerprint of EVERYTHING the result depends on'. Column key = section defining fields + material + objective + checker(member vs 10.12 joint); rib key = + bf + stirrup flag.

Direction for Part B: define ONE shared 'capacity catalog' (content-addressed, code-version-stamped per 7.12) + ONE 'owner picks min-carbon feasible candidate from a catalog' interface; columns, ribs, beams, walls all implement it. Shared verification contract for any caching/vectorization change = the design-twice byte-compare equivalence harness (equiv_col_catalog_slot.jl template; proved #20 bit-identical). A cache/vectorization key that is looser than the capacity's true dependence set is THE failure mode (bf for ribs, plan-size+material+objective for columns).

Status: direction, not yet implemented. To be written into the Part B design note and reconciled with the other agent's rib landing.
