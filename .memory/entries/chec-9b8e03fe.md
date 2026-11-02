---
id: chec-9b8e03fe
type: checkpoint
project: menegroth
parent_id: plan-cb717409
title: 'Row F interactive checks: 75% wall shear, 25% frame on story stiffness'
node_label: 12.2.5.8 interactive checks
tags: walls,phase-7,seismic-system,table-12.2-1,asce-7-22,interactive-system,12.2.5.8
status: active
open_threads: 0
success: 'null'
files: StructuralSizer/src/loads/_loads.jl@152ee99, StructuralSizer/src/loads/seismic.jl@152ee99,
  StructuralSizer/src/loads/seismic_systems.jl@152ee99, StructuralSynthesizer/src/StructuralSynthesizer.jl@152ee99,
  StructuralSynthesizer/src/analyze/_analyze.jl@152ee99, StructuralSynthesizer/src/analyze/lateral/approaches/_approaches.jl@152ee99,
  StructuralSynthesizer/src/analyze/lateral/approaches/types.jl@152ee99, StructuralSynthesizer/src/analyze/lateral/approaches/systems/interactive_shear_wall_frame_system.jl@152ee99,
  StructuralSynthesizer/src/analyze/lateral/interactive_checks.jl@152ee99, StructuralSynthesizer/src/analyze/lateral/ordinary_wall_inputs.jl@152ee99,
  StructuralSynthesizer/src/analyze/lateral/ordinary_wall_stage.jl@152ee99, StructuralSynthesizer/src/analyze/lateral/wall_cuts.jl@152ee99,
  StructuralSynthesizer/test/analyze/test_ordinary_wall_stage.jl@152ee99, StructuralSynthesizer/test/analyze/test_lateral_approaches.jl@152ee99,
  scripts/runners/pdelta_ratio_probe.jl@152ee99
session_id: sess-82a12f94
created_at: '2026-11-02T21:55:14.684553+00:00'
updated_at: '2026-11-02T21:55:14.684553+00:00'
has_child_rationale: 'Closes the tightening plan: the row lives on the lateral-system
  type and §12.2.5.8 is enforced.'
---
The ordinary-wall stage now takes the Table 12.2-1 row from the lateral-system type. WallsSeismicSystem is :A3 or :B6 only. InteractiveShearWallFrameSystem is row F.

Row B.6 is refused when walls carry more than 20% of a story's unfactored dead vertical force. That cutoff is a project reading of C12.2.1 ("relatively small percentage"), not an ASCE number.

For row F, design story shear is strength-level ELF Vx times the story 1/(1-θ) when θ>0.10. Walls must provide at least 75% as ΣφVn; ρt is raised on the existing grid when they fall short. The frame is solved without shell stiffness, on the story geometric stiffness already built, under 0.25 of the ELF story forces. θ from that P-delta analysis is divided by (1+θ) before θmax. Above θmax the stage throws. Flat plates are refused. Unsized beams and columns are recorded failures.

The unsized vault office on row F throws: story 1 in X has θ/(1+θ) above θmax. Ordinary-wall stage tests: 333 passed. Cd, Ω0, and rows C.7, E.8, and F still rest on the rendered Table 12.2-1 pages.

Asap solve gains exclude_shells so the frame-only displacement keeps the unified numbering. That change is committed in the Asap submodule with this checkpoint.
