---
id: plan-03b90f0a
type: plan
project: menegroth
parent_id: menegroth
title: 'Plan: component dossier in the scene and a full-height detail panel'
node_label: Component dossier panel
tags: viewer,scene,trace,detail
status: active
open_threads: 1
success: 'null'
files: StructuralSynthesizer/src/scene/components.jl@f56c933, StructuralSynthesizer/src/scene/build.jl@f56c933,
  docs/src/reference/scene_format.md@f56c933, viewer/src/main.ts@f56c933, viewer/src/detail.ts@f56c933,
  viewer/index.html@f56c933, viewer/src/style.css@f56c933
session_id: sess-50f1d342
created_at: '2026-11-05T02:24:27.729859+00:00'
updated_at: '2026-11-07T01:50:37.924624+00:00'
---
Double-click isolates one component: everything else greys, a charcoal outline follows that component's edges, and a full-height panel shows the drawing, the checks, and the solver path.

build_scene(BuildingDesign) writes header.components and header.design_trace. Each component carries the design-result fields in SI, the governing check and clauses already used by diagnose, a bind key the viewer can match (frame element, slab elevation, wall plane and story range, footing instance), and the trace events that name that element. The design_trace object is the solve's full event list, sanitized, with long vectors truncated. The viewer does not recompute a check. A scene written before this record still isolates and outlines, and the panel says the record is absent.
