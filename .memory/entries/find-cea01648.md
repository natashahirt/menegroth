---
id: find-cea01648
type: finding
project: menegroth
parent_id: find-be4cf63c
title: 'STOP again: the strip/mat per-combination foundation gap is ALSO already closed
  (foundation Phase A+B, 2026-11-26, chec-4d790ca0). Not a real open gap.'
node_label: 'STOP again: the strip/mat per-combination foundati'
tags: ''
status: active
open_threads: 0
success: 'null'
files: docs/sizing-map/README.md@96bef85
session_id: sess-f5367ced
created_at: '2026-11-26T17:40:06.814082+00:00'
updated_at: '2026-11-26T17:40:06.814082+00:00'
---
Deep recon of the strip/mat footing demand path contradicts this morning's framing that strip/mat 'collapse load combinations'. Reality on integration/2026-11-18:

- `foundation_actions_at(struc, idx)` (foundation_reactions.jl:105) is keyed by SUPPORT INDEX, not footing type. Once `ordinary_wall_stage.jl:504` sets `foundation_lateral` (rigid-diaphragm masters present), it serves every ASCE 7-22 §2.3/§2.4 service+strength combination to ALL footing types.
- size_isolated.jl passes `_aligned_column_actions(...)` -> `column_service`/`column_strength` into `footing_loads` for BOTH strip and mat (not just spread).
- StructuralSizer consumes them per combination k: strip_footing.jl `_strip_strength_steel`/`_strip_strength_cases_ok` loop `for k in eachindex(first(column_strength))`; mat_footing.jl `_mat_actions_fit`/`_mat_strength_sets` build one FoundationDemand set per combination via `_demand_for_action(demands[j], column_strength[j][k])`. The plan grows until every combination is in the kern with q_max<=qa (design_footing(::MatFoundation) docstring).
- `_lateral_column_demand`'s single-demand collapse (gov moment + max service P) is only the mat CENTROID SEED and the gravity-only fallback; it is overridden per combination whenever column_strength is populated. Centroid is the geometric column/wall box center, not load-weighted, so the collapsed P/M never governs when actions exist.

This landed with foundation Phase A+B (chec-4d790ca0, ~commit 61579f8) on 2026-11-26 — _grow_until_fit + _grow_strip_plan_for_actions + _mat_opts_for_actions.

What ACTUALLY remains (deferred Phase C/D, explicitly gated on the foundation inputs the user chose to HOLD): ACI 336.2R 20% column-load-variation rule, per-combination flexible-section (Winkler) envelopes, sliding / net-tension / uplift demands (need soil friction + passive inputs), ASCE 7-22 §12.13.4 overturning reduction, and grade-wall nodes reading lateral (they still read gravity-only, wall_groups.jl:418-424).

Action taken: corrected sizing-map README sign-off item 4 (was 'PARTIALLY RESOLVED spread only' -> 'RESOLVED for spread/strip/mat; two narrow held pieces remain'). No code written — avoided re-implementing already-live work (same trap as find-be4cf63c this morning).
