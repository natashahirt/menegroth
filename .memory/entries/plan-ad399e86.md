---
id: plan-ad399e86
type: plan
project: menegroth
parent_id: plan-93ed2402
title: Framing load-path fidelity + waffle via integrated ribs
node_label: Framing load-path + waffle ribs
tags: framing,load-path,fem,tributary,waffle,t-beam,aci-318,non-convex,coordinator
status: active
open_threads: 0
success: 'null'
files: ''
session_id: sess-529375ba
created_at: '2026-07-19T17:17:43.559115+00:00'
updated_at: '2026-07-19T17:17:43.559115+00:00'
---
Coordinator run scoping four workstreams that harden the framing load path and then deliver waffle sizing via integrated concrete ribs.

**Foundation:**
- **#5 Non-convex joist layout**: clip joist center-lines to the true (concave-safe) slab interior using `_get_slab_boundary_vertices` + `_point_in_simple_polygon_vec`, so no joist crosses a re-entrant corner or lands outside the plate. (populate.jl)
- **#1/#2 Joist->girder load path in the FEM**: KEY FINDING — sizing Mu/Vu come from the solved Asap model (`member_group_demands`), NOT from `beam.tributary_profile`; under default `:cell_tributary` routing auto-joists carry no slab load. Fix at the FEM load model (`to_asap!`/`sync_asap!`) so joists carry the slab tributary and girder demands follow from the elastic solve (true continuous-beam reactions #1 + concentrated landing effects #2). Also encode ACI 318-19 §6.5.4 (1.15x first-interior-support) + discrete point-load bookkeeping in the cascade as the design-layer approximation.

**Waffle (first-cut, after foundation):**
- Give waffle sizing result a `rib_grid`; wire `_waffle_rib_grid` -> `joist_geometry(::Waffle)` -> `derive_framing_level(:waffle)`; teach `_pattern_joist_lines(::IsoparametricPattern)` to use real rib lines (both orthogonal directions); materialize ribs as integrated T-beam RC members (rib web + slab flange via `effective_flange_width`, ACI §6.3.2) and size as T-beams from FEM demands. Verify geometry end-to-end on a simple rectangular grid. Full ACI §8.8 two-way DDM/EFM analysis deferred.

**Grounding:** ACI 318-19 §6.5.4/Table 6.5.4 (approx. continuous shears), §8.8 (two-way joist systems), §6.3.2 (T-beam effective flange). StructurePoint waffle example (`sp-de-two-way-waffle-slab-aci318-14`) available as oracle.

Decisions taken (user skipped the questions, delegating to recommendations): fem_primary for #1/#2; first_cut for waffle; reuse existing geometry helpers for #5. Rigor: high.
