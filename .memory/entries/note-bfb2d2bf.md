---
id: note-bfb2d2bf
type: note
project: menegroth
parent_id: menegroth
title: 'Full 3-plan x 4-system sweep: only concrete_rib solves; steel fails 3 distinct
  ways'
node_label: 'Full 3-plan x 4-system sweep: only concrete_rib so'
tags: ''
status: active
open_threads: 0
success: 'null'
files: ''
session_id: sess-f20fc186
created_at: '2026-11-27T21:12:06.801284+00:00'
updated_at: '2026-11-27T21:12:06.801284+00:00'
---
sweep CSV logs/sdf_nova_topology/systems_20261127_110057.csv (ran to completion; earlier kill of the sweep PID did not take, so it finished in background ~5h and starved the diagnostic probes of CPU).

Result grid (plans: topology/r2c1, nova/e1c1, topology/r7c1):
- concrete_rib: SOLVED on all 3 (r2c1 critical Slab5 non_convergence ratio 1.0 all_checks=false; e1c1 Beam179 flexure 0.998; r7c1 Beam14 flexure 0.977).
- steel_deck, steel_rib_composite, bare_steel: FAILED on all 3.

Three distinct steel failure causes:
1) LONG-SPAN LIVE-LOAD DEFLECTION (geometry) - kills steel_deck + steel_rib_composite on effectively every plan. Even W14X257 fails deflection_ll (per-element composite inertia, L/360): r2c1 ratio 2.75/2.21, r7c1 2.84/2.84, e1c1 steel_rib_composite 1.98. Driven by long chord spans from sparse columns (12 m on r2c1, ~15.6 m = 2x7.81 m on r7c1). Confirms+extends find-15661aa7 plan-wide. Concrete two-way rib survives because load spans two ways to 4 supports.
2) bare_steel CODE BUG (not geometry) - all 3 plans same error: 'N frame elements carry stiffness from an earlier section. Rebuild the model after installing sections (update_analysis!(struc,:stiffness)) before reading its forces.' Errors fast (162-612s). Independent, fixable.
3) nova/e1c1 steel_deck - composite stud ANCHORAGE gap: group 7 flexure_pos 3.64, shear_anchors ratio Inf ('deck anchorage spacing not supplied'), L=5 m Lb=1.25 m.

Note: composite-deck fix (deci-299b3a50) DID work in that steel_rib_composite no longer runs the 10.5h story-shell loop; it now fails fast on the same genuine long-span deflection limit as steel_deck. The real blocker for steel floors on these plans is long chord spans, not the composite path.
