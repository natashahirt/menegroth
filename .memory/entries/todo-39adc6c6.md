---
id: todo-39adc6c6
type: todo
project: menegroth
parent_id: plan-a2a6128f
title: Phase 7 — Integrate ordinary-wall sizing end to end
node_label: 'P7: ordinary pipeline'
tags: walls,phase,pipeline,design-workflow,trace,api,todo
status: active
open_threads: 0
success: 'null'
files: ''
session_id: sess-388b4911
created_at: '2026-10-21T02:13:17.162168+00:00'
updated_at: '2026-10-21T02:13:17.162168+00:00'
---
Add a wall stage to design_workflow.jl + design graph/provenance: analyze each lateral combination, size/check each ordinary wall (in-plane shear, min reinforcement, P–M, bearing, applicable §11.8). Dependency-aware iterations (detailing->checks, stiffness->analysis, geometry->rebuild) with per-solve provenance. Capture clause-specific CheckResults + governing combos + demands + capacities + drift + model provenance in BuildingDesign; expose via API + trace.
