---
id: plan-bff9aa9f
type: plan
project: menegroth
parent_id: plan-051e653d
title: 'Building solve speed: Phase 0 determinism, Tier 1 exact caches, Tier 2 gated'
node_label: 'Building solve speed: Phase 0 determinism, Tier 1 '
tags: performance,caching,asap,fea,column-mip,design-building
status: active
open_threads: 0
success: 'null'
files: ''
session_id: sess-60601e5d
created_at: '2026-10-26T15:01:59.124568+00:00'
updated_at: '2026-10-26T15:01:59.124568+00:00'
---
Speed up design_building from the measured hot spots, then add caches that leave results byte-identical. Tier 2 changes results and waits for engineering sign-off.

Measured (medium office, 3 stories, logs/profile_asap2.log):
- Flat plate FEA: 567 s, 90.6% inside Asap. update! is 46% (of which _update_S_values! is 38%, a serial scatter over an abstract shell element vector). Shell meshing is 33.5%, built once per slab. populate_load! 7.8%. One-way shear extraction 7.5%.
- Flat plate DDM: 4.1 s, 61% in optimize_discrete JuMP model build and solve, not the feasibility screen.
- A cold FEA run was 360 s and a warm run 567 s. Suspected cause: DelaunayTriangulation uses Random.default_rng().

Phase 0: seed the mesher RNG; add counters; pin Asap; record a baseline for default, flat_ddm, flat_fea, and steel.

Tier 1 (byte-identical, gated on run_all_gates and the speedup invariant diff):
- 1A: typed barrier and precomputed CSC positions in _update_S_values!; spatial index for _needs_refine; function barrier in populate_load!; bounding-box prefilter in one-way shear; skip the restore solve only after proving qu is bitwise the envelope.
- 1B: one shared column P-M cache on the cold graph path; skip the catalog cache under NLP; SizingMemo around optimize_discrete; RC NLP demand memo; pass cache and mip_start on the beam/frame path.
- 1C: defer per-slab Asap.process! to the level sync; :shared snapshots as the DesignSession default; one FEAModelCache owner with a geometry key so meshes survive across runs.
- Fix _binary_search_feasible so a heaviest section that fails max_depth does not report the group infeasible, and the back-scan does not miss a lighter feasible section. Do not route RC or W-shape columns to binary search; feasibility is not monotone in catalog order.

Tier 2 (sign-off, not this implementation):
- 2A zoned local remesh near columns.
- 2B per-group argmin instead of the MIP when n_max_sections is 0; tie-break still needs a decision.
- 2C order-independent two-pass column design, then 2D typical-floor dedupe and 2E monotone warm starts.

Plan file: building_solve_speed_plan_81aef461. Parent speed work is plan-051e653d.
