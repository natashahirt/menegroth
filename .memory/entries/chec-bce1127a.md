---
id: chec-bce1127a
type: checkpoint
project: menegroth
parent_id: plan-b45b0d7f
title: design_building runs ordinary-wall checks when lateral design is requested
node_label: walls in design_building
tags: walls,phase-7,design-pipeline,ordinary-walls
status: active
open_threads: 0
success: 'null'
files: StructuralSynthesizer/src/design_workflow.jl@78b13bc, StructuralSynthesizer/src/workflow/pipeline_spec.jl@78b13bc,
  StructuralSynthesizer/src/workflow/graph_builder.jl@78b13bc, StructuralSynthesizer/src/workflow/execute.jl@78b13bc,
  StructuralSynthesizer/src/workflow/prepare.jl@78b13bc, StructuralSynthesizer/src/workflow/summary.jl@78b13bc,
  StructuralSynthesizer/src/workflow/capture_results.jl@78b13bc, StructuralSynthesizer/src/workflow/column_reconciliation.jl@78b13bc,
  StructuralSynthesizer/src/workflow/compare.jl@78b13bc, StructuralSynthesizer/src/workflow/member_iteration.jl@78b13bc,
  StructuralSynthesizer/src/workflow/validation.jl@78b13bc, StructuralSynthesizer/src/building_types/structure.jl@78b13bc,
  StructuralSynthesizer/src/design_graph/provenance.jl@78b13bc
session_id: sess-c86634db
created_at: '2026-10-31T14:46:12.534952+00:00'
updated_at: '2026-10-31T14:46:12.534952+00:00'
has_child_rationale: The ordinary-wall stage now runs from the design pipeline
---
design_building runs design_ordinary_walls! only when DesignParameters.lateral is set. build_pipeline appends that stage with needs_sync false, after foundations when those were requested and otherwise after members. build_design_graph uses the same order. A gravity-only building stays at two stages and the graph has no :ordinary_walls node.

The stage writes BuildingStructure.ordinary_wall_result. capture_design copies checks onto BuildingDesign.walls and drift comparisons onto seismic_story_drift. _compute_design_summary! folds a failing wall check or story-drift comparison into all_checks_pass and the critical element.

design_workflow.jl is now includes of src/workflow/. The moved functions match the previous monolith; the ordinary-wall stage, the result field, and the summary entries are the behavior change. Commit 78b13bc0.

Covered by test_ordinary_wall_stage.jl: gravity pipeline length 2, lateral pipeline length 3, the graph node depends on members, and needs_sync is false. That file passed  with the ELF suite, 237 of 237, before this commit, on this same source.
