---
id: chec-dbcf5ca8
type: checkpoint
project: menegroth
parent_id: plan-40b3c357
title: Fixed-mesh prototype implemented + runs end-to-end; small-plate correctness
  PASS (both variants FLOOR_DESIGN_SUCCEEDED). Medium-office drift measurement in
  flight.
node_label: Fixed-mesh prototype implemented + runs end-to-end
tags: ''
status: active
open_threads: 0
success: 'null'
files: scripts/runners/ab_fixed_mesh_accuracy.jl@d626e55
session_id: sess-d6673768
created_at: '2026-11-27T05:32:28.910947+00:00'
updated_at: '2026-11-27T05:32:28.910947+00:00'
---
Implemented the full fixed_mesh prototype (opt-in, production default off), lint-clean, runs end-to-end.

Files changed:
- slabs/types/analysis_methods.jl: FEA(; fixed_mesh=false, fixed_mesh_cap=nothing) + validation + new(...).
- fea/building.jl with_fea_source: carry the two new fields.
- fea/cache.jl: fea_mesh_key cap-aware (drop c1/c2/shape under fixed_mesh); FEAModelCache.patch_zone::Vector{Tuple{Int,Int}} (+ constructor; reset clears it).
- fea/model.jl: build_slab_shell_patches cap-sized oriented square patch; build_slab_shell_mesh fine ~0.0254m fenced refine (col-independent); helpers _in_oriented_rect/_point_in_current_col/_owning_cap_column/_assign_and_retag_fixed_patches!/_retag_fixed_patches!; _build_fea_slab_model builds+seed-retags patch_zone before first solve, returns it; _update_and_resolve! re-tags fenced zone to current footprints before the by-id E loop (+kwargs fixed_mesh, struc).
- fea/precompute.jl _build_or_update_fea!: thread fixed_mesh/fixed_mesh_cap into key+build+update, store cache.patch_zone.
- fea/run.jl: resolve cap (method.fixed_mesh_cap or 36in fallback warn), pass through.
- scripts/runners/ab_fixed_mesh_accuracy.jl: A/B harness (warmup + remesh + fixed), per-floor status + as-designed punching DCR (+/-2% flag) + factorizations/mesh_rng + wall-clock.

Results (small 3x3x1 plate, logs/ab_fixed_mesh_small2.log): BOTH variants FLOOR_DESIGN_SUCCEEDED (world-age capture fixed). Warm wall-clock remesh 19.6s vs fixed 25.7s -- EXPECTED: this low-load plate's columns never grow (mesh_rng=10, factorizations=12 identical both), so there is no remesh to avoid and the fixed mesh's finer fenced zone is pure overhead. The speed win only appears with column growth -> medium office.

KNOWN GAPS:
1. DCR NaN on the small plate: its slab design path didn't emit Phase-B punching_ratios to the top-level tc (single-floor converged without a B-decision event). The medium office emits them (proven by ab_flat_fea_punching.jl) -> measuring there now (logs/ab_fixed_mesh_medium.log).
2. Edge-strip cap subtlety (note-4c103bb8): under fixed_mesh the key no longer changes on growth, so the mesh (incl. the edge overhang band sized from floor_slab_edges at SEED columns) is NOT rebuilt -> grown EDGE/CORNER columns keep the seed-width band. The medium A/B edge/corner punching DCR is exactly the test of whether this is within +/-2%.
3. Design-equivalence (final column sizes + slab h) not yet compared directly from struc -- add as a robust acceptance check beyond trace DCR.

NEXT: read medium A/B (speed win + per-floor DCR drift vs approved +/-2%/+/-3%/unchanged band); if edge drift exceeds band, add cap-based edge-strip (Phase-2 item). No production default flip until signed off.
