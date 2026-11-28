---
id: chec-487dde4d
type: checkpoint
project: menegroth
parent_id: chec-2958a041
title: 'Phase D stability Stage 3b: column-strip footing global stability integrated
  (52 tests green)'
node_label: 'Phase D stability Stage 3b: column-strip footing g'
tags: ''
status: active
open_threads: 0
success: 'null'
files: StructuralSizer/src/foundations/stability.jl@4eb53eb, StructuralSizer/src/foundations/codes/aci/strip_footing.jl@4eb53eb,
  StructuralSizer/test/foundations/test_stability.jl@4eb53eb
session_id: sess-0ec522a3
created_at: '2026-11-27T04:40:20.568425+00:00'
updated_at: '2026-11-27T04:40:20.568425+00:00'
---
Integrated sliding/overturning/uplift into the column-strip designer (design_footing(::StripFooting, demands, positions, soil)).

Key mechanism: _strip_combo_moments already aggregates per-combination ΣP, M_along (strip axis), M_across across all columns — the whole-strip rigid-body quantities. New _strip_aggregate_actions(column_service, positions, x_bar, strip_axis) builds one FootingAction per combination: ΣP, M_along→Mx slot (pairs with L), M_across→My slot (pairs with B), ΣHx, ΣHy (summed base shears; sliding uses hypot magnitude so global axes are fine). These feed the shared footing_stability_utils on the final (B,L,h).

Width floor: new _stability_min_width(actions, soil, stab, L, h_floor, min_B, incr) grows only B (strip L is fixed by span) until sliding+uplift pass at min_depth. Folded into B_floor inside the dev loop. The subsequent kern/bearing sizing only grows B and L further, so the reported utils on the final plan are ≤ the floor-gated values.

Design decision: both plan-floor finders (_stability_min_square_side and _stability_min_width) now gate on sliding+uplift ONLY, not overturning. The ACI 336.2R §3.2.1 kern requirement (e≤L/6) enforced by bearing/plan sizing is stricter than the overturning limit (e≤L/2), so a compression combo passing bearing already passes overturning. Overturning stays in the reported envelope + folded into utilization. Shared _stability_floor_ok / _stability_floor_error helpers.

Result: checks populated with sliding/overturning/uplift, folded into governing utilization. Opt-in (opts.stability !== nothing && service actions exist); NaN when off, exact backward-compat otherwise.

Tests: 52 green (test_stability.jl + test_strip_aci.jl); regression test_strip_unequal_c_across + test_wall_strip + test_spread_aci 66 green.

NOT done — wall-footing stability (design_footing(::StripFooting, legs::Vector{WallLineDemand})): the wall path uses WallLineDemand.samples carrying only Ps/Pu/s with NO horizontal-shear channel and no FootingAction. Adding sliding there needs a new horizontal-demand field on the wall line model — a separate decision, flagged to user, not guessed.
