---
id: note-5ffc6ea7
type: note
project: menegroth
parent_id: plan-4caf2683
title: Graph and legacy flat plates match columns; footings differ
node_label: Graph and legacy flat plates match columns; footin
tags: columns,flat-plate,foundations,equivalence
status: active
open_threads: 0
success: 'null'
files: ''
session_id: sess-c573fb8f
created_at: '2026-11-25T04:45:37.283280+00:00'
updated_at: '2026-11-25T04:45:37.283280+00:00'
has_child_rationale: The equivalence failure is not the column trim
---
Design-graph equivalence (`design_graph/test_design_graph_equivalence.jl`) failed 8 flat-plate invariants after the column trim. Beam/column matched.

The trim is not the split. On both the ordinary flat plate and the per-story plate, the trim trace is `unchanged`. Every column is 10x10 with 4#5 (As = 1.24 in²) on both the graph path and the legacy stage loop, and the slab thickness is 7.205 in on both. Footing concrete is not: about 21.4 m³ on the graph path and 14.5 m³ on the legacy path (per-story: 28.1 vs 27.1 m³). The executors disagree on the forces the footings see.

Flat-plate member tests passed 299/299. Frame-section floor tests passed 173/173 after the row F test objective was aligned with the walk (concrete plus rebar).
