---
id: chec-a0e1f1e8
type: checkpoint
project: menegroth
parent_id: plan-b45b0d7f
title: Wall bridge sources live in StructuralSynthesizer/src/walls
node_label: wall bridge split
tags: walls,phase-7,refactor
status: active
open_threads: 0
success: 'null'
files: StructuralSynthesizer/src/walls_bridge.jl@6500546, StructuralSynthesizer/src/walls/plate_geometry.jl@6500546,
  StructuralSynthesizer/src/walls/enclosure.jl@6500546, StructuralSynthesizer/src/walls/outline_topology.jl@6500546,
  StructuralSynthesizer/src/walls/seismic_mass.jl@6500546, StructuralSynthesizer/src/walls/bridge_validation.jl@6500546
session_id: sess-c86634db
created_at: '2026-10-31T14:45:37.902384+00:00'
updated_at: '2026-10-31T14:45:37.902384+00:00'
has_child_rationale: File split committed before wiring the stage into design_building
---
walls_bridge.jl is now five includes. The moved sources are plate_geometry.jl, enclosure.jl, outline_topology.jl, seismic_mass.jl, and bridge_validation.jl under StructuralSynthesizer/src/walls. Line count matches the removed monolith (804 lines). No function changes. Commit 65005461.

The ordinary-wall stage still has to be committed into design_building. The call is already written in the uncommitted workflow split: build_pipeline adds design_ordinary_walls! only when DesignParameters.lateral is set, the design graph places that node after members or foundations, and capture copies checks onto BuildingDesign.walls and seismic story drift.
