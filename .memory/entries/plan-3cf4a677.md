---
id: plan-3cf4a677
type: plan
project: menegroth
parent_id: plan-0501eab9
title: 2024 plans swept across the sized floor systems, with a scene and a report
  each
node_label: 2024 floor sweep
tags: slab,geometry,scene,report
status: active
open_threads: 1
success: 'null'
files: scripts/runners/sdf_floor_sweep.jl@fa7d31f, StructuralSynthesizer/src/scene/variants.jl@fa7d31f,
  viewer/src/main.ts@fa7d31f, viewer/src/style.css@fa7d31f
session_id: sess-5e262cd2
created_at: '2026-11-12T14:21:47.329997+00:00'
updated_at: '2026-11-12T14:36:24.501170+00:00'
has_child_rationale: The user asked to view these plans across the floor systems and
  to keep a report of each one.
---
Five 2024 Slab Design Factors plans are being designed as every floor system this codebase sizes: one-way concrete, two-way concrete, waffle at 1.25 m pans, flat plate, flat slab, composite 3VLI deck, and a vault. Timber, post-tensioned, hollow-core, and non-composite deck are left out because their sizers throw UnsupportedFloorSystemError.

Plans: nova/e2c1 (uniform 3.9 m panels, so a 1.25 m pan fits three times and the offcut is under half a module), grid/x1y1, topology/r2c1, star/e0c0, special/rhombus_8x12.

Each solved design is a variant in viewer/public/sdf_<plan>.mgscene. A right-click on the slab lists every solved system of that plan by name. A right-click on a beam still lists only designs that change the beam alone. Reports are engineering_report plus diagnostics at logs/sdf_floor_sweep/<plan>/<system>.txt, with summary.csv beside them. Four sizing iterations.
