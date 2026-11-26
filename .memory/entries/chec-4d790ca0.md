---
id: chec-4d790ca0
type: checkpoint
project: menegroth
parent_id: plan-8b00b305
title: 'Phase B done: shared _grow_until_fit plan combinator, behavior-neutral across
  all 5 grow loops'
node_label: 'Phase B done: shared _grow_until_fit plan combinat'
tags: ''
status: active
open_threads: 0
success: 'null'
files: StructuralSizer/src/foundations/codes/aci/plan_engine.jl@61579f8, StructuralSizer/src/foundations/codes/aci/_aci.jl@61579f8,
  StructuralSizer/src/foundations/codes/aci/spread_footing.jl@61579f8, StructuralSizer/src/foundations/codes/aci/strip_footing.jl@61579f8,
  StructuralSizer/src/foundations/codes/aci/mat_footing.jl@61579f8, StructuralSizer/src/foundations/codes/aci/wall_strip_footing.jl@61579f8
session_id: sess-33a1e212
created_at: '2026-11-26T04:49:27.003525+00:00'
updated_at: '2026-11-26T04:49:27.003525+00:00'
---
Phase B extracted the one genuinely-duplicated piece of the four plan engines: the bounded grow-until-every-combination-fits control loop. The geometry math and code citations stay verbatim in each designer.

New: StructuralSizer/src/foundations/codes/aci/plan_engine.jl — _grow_until_fit(plan0; step, max_iters=80, onfail). step(plan) returns (true, result) when the plan fits or (false, next_plan) to grow; after max_iters, onfail(plan) throws. Documents once the increment cap + the 'refuse rather than apply ACI 336.2R §3.2.1 partial contact' policy. Included first in codes/aci/_aci.jl.

Adopted at all 5 eccentric grow sites (each keeps its own step/onfail closure with its citation + dimension-specific message):
- spread_footing.jl _spread_plan_for_actions (square B grows one side; payload carries built cases, no recompute)
- strip_footing.jl _grow_strip_plan_for_actions (:lengthen vs :widen about x_bar)
- mat_footing.jl _mat_opts_for_actions (overhang state; rebuilds plan per increment, reuses plan0 at seed)
- wall_strip_footing.jl _grow_wall_plan straight (B,Lf length-vs-width) and corner (widen-only)

Verified green via StructuralSizer server (recompiled cleanly, so new include loaded): spread_aci, strip_aci, wall_footing, wall_strip, mat_rigid_statics, mat_aci, mat_walls, corner_punching, strip_unequal_c_across, foundation_combinations, foundation_safety_9_15, and the Phase-A footing_loads equivalence (7). No regressions anywhere.

NOT touched: wall_plan.jl _size_wall_plan (gravity-only plan, different routine). Phases C (unify strip/wall analysis-method option to the typed AbstractMatMethod mat uses — a breaking StripParams API change) and D (per-combination flexible-section envelopes + 20% column-load variation rule, needs user inputs for sliding/tension demands) are deferred for user sign-off: both change safety-critical dispatch/behavior, unlike A and B which were behavior-neutral.
