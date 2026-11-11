---
id: chec-ac48f14e
type: checkpoint
project: menegroth
parent_id: plan-2d4158d0
title: 'Joint search slice 1: per-slab thickness/column/stud search behind punching_strategy
  = :joint_search'
node_label: Joint search slice 1
tags: flat-plate,punching,search,carbon,shear-studs
status: active
open_threads: 0
success: 'null'
files: StructuralSizer/src/slabs/codes/concrete/flat_plate/pipeline/joint_search.jl@86da39a,
  StructuralSizer/src/slabs/codes/concrete/flat_plate/pipeline/iteration.jl@86da39a,
  StructuralSizer/src/slabs/codes/concrete/flat_plate/pipeline.jl@86da39a, StructuralSizer/src/slabs/options.jl@86da39a,
  StructuralSizer/test/slabs/test_joint_search.jl@86da39a, StructuralSizer/test/runtests.jl@86da39a,
  StructuralSynthesizer/test/sizing/slabs/test_flat_plate_joint_search.jl@86da39a,
  StructuralSynthesizer/test/runtests.jl@86da39a, docs/flat-plate-joint-sizing-plan.md@6fd630b
session_id: sess-d893d542
created_at: '2026-11-11T18:50:36.026856+00:00'
updated_at: '2026-11-11T18:50:36.026856+00:00'
---
Done (slice 1, per slab):
- pipeline/joint_search.jl: generic `joint_thickness_scan` (closures; lower-bound stop; 1% tie rule with preference), `material_objective` (Volume/Weight/Carbon/Cost), binding `joint_search` that scales one analysis to each half-inch (thickness_jump.jl), rejects thicknesses failing phase_a_depth_passes, wall reaction punching, or strip-design adequacy, and per column picks the cheapest of smallest bare-passing size and stud options (solve_column_for_punching direction, _try_reinforcement). Terms: slab concrete + placed strip rebar (_direction_placed_volume), column story segment concrete + max(As_total, 0.01Ag) steel, stud shank steel (Av_per_line x lines x (h-2cover)) x stud_weight.
- iteration.jl Phase B: when :joint_search and the scale applies, scan from the analysis, install sizes; changed h restarts Phase A; changed sizes re-analyze; confirmation accepts studs only where the search chose them, otherwise rescans with floors = installed sizes (monotone). Wall punching failure rescans instead of the bare-column thickening jump. Drop panels, pattern loading, edge-beam bt from h fall back to the resolver (= grow_columns). Trace events: outcome joint_search / joint_confirmed.
- options: joint_studs (default true; needs headed-stud reinforcement), stud_weight (default 1.0), objective default flipped MinVolume -> MinCarbon (also size_flat_plate_optimized default).

Tests: Sizer test_joint_search (+thickness_jump, punching_reinforcement) 147/147; Synth test_flat_plate_joint_search 23/23; Sizer optimizer + Eq 13-7 1011 passed (fallback file needs Synth env); Sizer size_flat_plate + flat_plate 191/191; Synth flat_plate_member_stage + pure_methods 347/347.

Fixture (3x3, 30 ft bays, 12 in start, DDM): grow and joint-without-studs both 12 in slab, columns 16/19.5/21 (search reproduces the walk); joint with studs 12 in, columns 12/16/20, studs at 8 of 16, carbon 98,101 vs 98,703 kgCO2e (-0.6%).

Next (slice 2, not started): top-down slab order for :joint_search, stored per-column floor (column above + member-stage size) so the search can shrink below installed sizes, commit pass with columns fixed for shared-column floors, then core office v8 comparison.
