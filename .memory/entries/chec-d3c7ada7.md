---
id: chec-d3c7ada7
type: checkpoint
project: menegroth
parent_id: plan-a7ebaacc
title: The one-way strip and the joist cut agree on rectangles
node_label: strip matches the cut
tags: joists,load-routing,tributary
status: active
open_threads: 0
success: 'null'
files: StructuralSynthesizer/test/analyze/test_joist_strip_equivalence.jl@6980ce8,
  StructuralSynthesizer/test/runtests.jl@6980ce8, StructuralSizer/src/slabs/codes/concrete/waffle/rib_arrangement.jl@6980ce8
session_id: sess-f4eb37da
created_at: '2026-11-12T12:00:36.815623+00:00'
updated_at: '2026-11-12T12:00:36.815623+00:00'
has_child_rationale: The rectangle strip was the reference for the joist-cut load
  path.
---
On a joist-aligned rectangle the uniform one-way strip and the joist cut put the same force on each member, the same shear at each girder end, and the same reaction at each column base.

Checked in `test_joist_strip_equivalence.jl` (150 assertions): an 8 m × 6 m bay with joists at 2 m, a 5.2 m × 9 m bay whose last gap is 1 m, and the 8 m × 6 m bay turned 20°. Totals match the slab pressure times the area.

The strip shortcut in `load_routing.jl` is therefore redundant. It stays until `scripts/runners/run_joist_load_transfer_smoke.jl` and the strip probes, which still call `_framed_slab_strip_geometry`, are moved onto the joist cut.
