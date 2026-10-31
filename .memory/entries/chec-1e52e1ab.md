---
id: chec-1e52e1ab
type: checkpoint
project: menegroth
parent_id: plan-b45b0d7f
title: Ordinary-wall checks are in the engineering report and the design JSON
node_label: walls in report and JSON
tags: walls,phase-7,report,json
status: active
open_threads: 0
success: 'null'
files: StructuralSynthesizer/src/postprocess/engineering_report.jl@1ffd46d, StructuralSynthesizer/test/report_generators/test_ordinary_wall_report.jl@1ffd46d,
  StructuralSynthesizer/src/api/schema.jl@1ffd46d, StructuralSynthesizer/src/api/schema/output_types.jl@1ffd46d,
  StructuralSynthesizer/src/api/schema/input_schema.jl@1ffd46d, StructuralSynthesizer/src/api/schema/input_types.jl@1ffd46d,
  StructuralSynthesizer/src/api/schema/params_schema.jl@1ffd46d, StructuralSynthesizer/src/api/schema/applicability_schema.jl@1ffd46d,
  StructuralSynthesizer/src/api/schema/failure_normalization.jl@1ffd46d, StructuralSynthesizer/src/api/serialize.jl@1ffd46d,
  StructuralSynthesizer/src/api/serialize/results.jl@1ffd46d, StructuralSynthesizer/src/api/serialize/sections.jl@1ffd46d,
  StructuralSynthesizer/src/api/visualization/frame.jl@1ffd46d, StructuralSynthesizer/src/api/visualization/slabs.jl@1ffd46d,
  StructuralSynthesizer/src/api/visualization/deflected_mesh.jl@1ffd46d, StructuralSynthesizer/src/api/visualization/stress.jl@1ffd46d,
  StructuralSynthesizer/src/api/visualization/foundations.jl@1ffd46d
session_id: sess-c86634db
created_at: '2026-10-31T15:25:53.612610+00:00'
updated_at: '2026-10-31T15:25:53.612610+00:00'
has_child_rationale: Wall checks are visible in the report and the design JSON
---
Ordinary-wall checks are in the engineering report and the design JSON. Commit 1ffd46d8.

engineering_report omits the section when BuildingDesign.walls and seismic_story_drift are both empty. Otherwise it prints each wall's governing check and any other failing check, with demand and capacity converted from the checker's SI units (N, N·m, reinforcement ratio, or metres). Seismic story drift is printed from the stored SeismicStoryDriftCheck, in display length units. The design JSON keeps every record: APIWallCheck and APISeismicStoryDrift, serialized by _serialize_walls and _serialize_story_drift.

The schema and serializer files are the previous monoliths split into api/schema, api/serialize, and api/visualization. The only new names are APIWallCheck, APISeismicStoryDrift, _serialize_walls, and _serialize_story_drift. The request schema did not gain lateral or wall_inputs, so a client still cannot ask for the stage.

Test: report_generators/test_ordinary_wall_report.jl, 20 passed.

Still open in this slice: one design_building run from wall geometry through to these serialized records. The stage test calls design_ordinary_walls! directly.
