---
id: plan-a7ebaacc
type: plan
project: menegroth
parent_id: plan-35f67705
title: 'Irregular slabs: general-polygon rib networks, demand-grown solid heads, framed
  openings'
node_label: Irregular rib floors
tags: waffle,grillage,solid-head,openings,irregular-geometry,load-routing,plan
status: active
open_threads: 11
success: 'null'
files: StructuralSynthesizer/src/analyze/slabs/slabs/rib_grillage.jl@7da1320, StructuralSizer/src/slabs/codes/concrete/waffle/rib_network.jl@7da1320,
  StructuralSizer/src/slabs/codes/concrete/waffle/rib_tributary.jl@7da1320, StructuralSynthesizer/src/analyze/framing/joist_geometry.jl@7da1320,
  StructuralSynthesizer/src/analyze/asap/asap/load_routing.jl@7da1320, StructuralSynthesizer/src/core/utils_building_skeleton.jl@7da1320
session_id: sess-474b9583
created_at: '2026-11-10T00:41:49.711325+00:00'
updated_at: '2026-11-17T23:02:30.526309+00:00'
---
Gap review (2026-11-09): waffle rib layout, grillage, and solid-head cut stop at quadrilaterals (grillage already handles skewed quads via per-bay isotropic skeleton; only the solid-head fallback check is rectangle-only). Per-cell tributaries already handle any polygon, holes, one-way axis.

User decisions:
- Rib layout: orthogonal module grid (two families, angle + spacings) clipped to any outline (concave, holes), PLUS arbitrary user rib lines (any direction, curved) through the same general network. Isoparametric stays for quads.
- Partial bays: a cut bay smaller than half a module stays a ribbed void unless a column head claims it (form it with a smaller pan). Larger cut bays stay ribbed and are checked per bay against ACI 318-11 §8.13 (corpus check at implementation).
- Solid heads: demand-driven growth of whole modules around each column, only in the direction where a check fails (rib one-way shear at head face, punching at d/2 outside head outline with gamma_v, rib hogging compression just outside head). Monotone growth, frame re-solved each step. Not tied to panel corners.
- Openings in joist/ribbed floors: opening edges become trimmer/header members; joists and ribs clipped to them.
- One-way strip routing: on a joist-aligned rectangle the uniform strip and the joist cut match (member force, girder-end shear, column-base reaction), including a 1 m remainder bay and a rectangle turned 20°. Locked in `test_joist_strip_equivalence.jl`. The strip shortcut is redundant and can be removed once the smoke runner and probes that call it are moved onto the joist cut.

Phases:
0. Probe find_faces! with a dangling beam stub and a disconnected inner beam ring; fix confirmed issues (inner ring -> hole of outer face; stub splitting nothing -> clear error). Delete unused validate_and_split_slab/decompose_to_rectangles; fix API/chat strings misstating shape limits.
1. General RibNetwork (StructuralSizer): rib lines clipped to polygon with holes, bays = arrangement faces, per-bay isotropic skeleton tributaries; generators = isoparametric (quad), modular grid, custom lines. Port materialize/joist_geometry, rib_grillage, rib sizing (lambda_s, §8.13 per bay), rib deflection, detailing.
2. Solid heads as module sets per column, grown by demand; punching via critical_section_properties on the head outline + geometry_classification (free edge / re-entrant); retire or generalize the rectangle-only solid_head_check fallback.
3. Framed openings: trimmers/headers, clipped joists/ribs, routing.
4. Strip-routing equivalence test -> delete or keep.
5. Tests + seven-system regression only when the user authorizes.
