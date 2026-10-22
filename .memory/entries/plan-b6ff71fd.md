---
id: plan-b6ff71fd
type: plan
project: menegroth
parent_id: plan-a2a6128f
title: 'Phase 3 implementation: wall storage, :walls member init, enclosure at initialize!'
node_label: 'Phase 3 implementation: wall storage, :walls membe'
tags: ''
status: active
open_threads: 3
success: 'null'
files: ''
session_id: sess-f3dde776
created_at: '2026-10-22T15:54:31.132828+00:00'
updated_at: '2026-10-22T15:54:39.893322+00:00'
---
Phase 3 of plan-a2a6128f, scoped to the data model and the construction-time bridge. Not the lateral pipeline (Phase 6/7).

Wave 1 — data model:
- BuildingStructure.walls::Vector{Wall{T}} (constructors in structure.jl only; call sites use BuildingStructure(skel)).
- BuildingDesign.walls sidecar keyed by wall index, holding per-direction/per-combination records. No single governing demand. No ACI factors.
- APIEdgeGroups.walls (default empty) so JSON can declare wall polylines.

Wave 2 — skeleton wiring + bridge:
- initialize_members! branches on groups_edges[:walls]. A :walls edge must NOT fall through to Beam.
- Plan endpoints (x1,y1,x2,y2) from GeometryCache.vertex_coords, the same datum story_plate_geometry reads.
- base.L is the pier/story HEIGHT from story elevations, not the plan edge length. Fail closed if the story above has no elevation.
- Wall.story stays 0-based (edge_story). to_wall_line keeps story+1 for WallLine/StoryLoad. Document, do not flip.
- wall_thickness is a required keyword when any :walls edge exists. No invented default thickness. concrete stays nothing.
- link_wall_stack! mirrors link_column_stack! (plan position, story+1 → wall_above).
- deserialize shatters input.edges.walls into the :walls group.
- At the end of initialize!, for each story that has walls, call story_plate_geometry(skeleton, story; walls=those walls) so assert_walls_enclosed runs at construction.

Rigor medium. Checkers: reviewer (baseline), critic (story index, height-vs-length, edges misclassified as beams), tester (focused). Skipped: bugbot (focused diff), security-review (no untrusted-input surface beyond the existing JSON edge list).
