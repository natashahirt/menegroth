---
id: deci-d2aeb0a8
type: decision
project: menegroth
parent_id: plan-9768ec38
title: Each pier takes its own wall's slab moment, with Ev on the dead part, from
  real D/L parts in every method
node_label: Each pier takes its own wall's slab moment, with E
tags: ''
status: active
open_threads: 0
success: 'null'
files: StructuralSizer/src/slabs/types/flat_plate_results.jl@4230ad5, StructuralSizer/src/slabs/codes/concrete/flat_plate/types.jl@4230ad5,
  StructuralSizer/src/slabs/codes/concrete/flat_plate/analysis/fea/frame.jl@4230ad5,
  StructuralSizer/src/slabs/codes/concrete/flat_plate/analysis/efm/demands.jl@4230ad5,
  StructuralSizer/src/slabs/codes/concrete/flat_plate/analysis/efm/frame_lines.jl@4230ad5,
  StructuralSizer/src/slabs/codes/concrete/flat_plate/analysis/efm/applicability.jl@4230ad5,
  StructuralSizer/src/slabs/codes/concrete/flat_plate/analysis/ddm/frameline.jl@4230ad5,
  StructuralSizer/src/slabs/codes/concrete/flat_plate/design/results.jl@4230ad5, StructuralSizer/src/slabs/codes/concrete/flat_plate/pipeline/final_design.jl@4230ad5,
  StructuralSizer/src/slabs/codes/concrete/flat_plate/pipeline/thickness_jump.jl@4230ad5,
  StructuralSizer/test/slabs/test_wall_supports.jl@4230ad5, StructuralSynthesizer/src/analyze/lateral/ordinary_wall_stage.jl@4230ad5,
  StructuralSynthesizer/src/analyze/lateral/wall_opening_checks.jl@4230ad5, StructuralSynthesizer/src/analyze/lateral/wall_ordinary_check.jl@4230ad5,
  StructuralSynthesizer/test/analyze/test_wall_face_parts.jl@4230ad5, StructuralSynthesizer/test/analyze/test_wall_ordinary.jl@4230ad5
session_id: sess-94967b01
created_at: '2026-11-18T19:31:24.155016+00:00'
updated_at: '2026-11-18T19:31:24.155016+00:00'
---
Three simplifications in the out-of-plane slab moment into walls are removed.

1. Per-wall moment. Wall-face parts are now `SlabWallFaceMoment(D, L, x1, y1, x2, y2)` (StructuralSizer, flat_plate_results.jl), on FlatPlatePanelResult.wall_face_parts[_secondary] and MomentAnalysisResult.wall_faces. A pier uses only faces whose `_segment_key` matches its wall (`_pier_directed_moment`, `_face_on_wall` in ordinary_wall_stage.jl). Parts present but none on this wall gives 0. No parts at all keeps the panel envelope and pressure pairing.

2. Vertical seismic. `_action_slab_moment` uses dead factor combo.D + combo.Ev * vertical_seismic_load_effect(SDS, 1.0), ASCE 7-22 Eq. 12.4-4a (asce-7-22, PDF p.183). The min(scale, 1) cap is gone on both the face and pressure paths; a negative pressure gives 0. SDS rides on the basis via `_with_sds`; lateral pier path and pierced segments pass inputs.SDS, gravity stage passes 0. Pier in-plane Ev stays axial-only (unchanged judgment in wall_combinations.jl).

3. D/L for EFM and DDM. EFM `_efm_wall_faces` solves at qD, qL and unfactored live patterns plus a zero-pressure solve (skipped without a drop). D = M(qD) - M(0) + M(0)/gamma, gamma = governing_dead_factor, because the frame's drop line load is already factored dead. L = max over live cases of M - M(0). Per line the governing side per wall; across lines strips are summed (`_sum_wall_faces`). FrameLine DDM splits the factored support moment by qD/qu and qL/qu (`_factored_wall_faces`). These parts are NOT checked against ACI M_wall (0.75 pattern factor stays on slab steel); the wall uses full 1.6L. FEA parts carry cut.seg and still pass `_paired_wall_face_parts`.

Tests: test_wall_supports.jl 99 pass (fake-solver EFM/DDM/sum unit tests), test_wall_ordinary.jl 64 pass (Ev numbers, uncapped scale, per-wall), test_wall_face_parts.jl 18 pass (FEA one-wall plate + EFM end-to-end with the wall-end columns parked; with a column at the wall end, EFM treats the column as the joint and stores no wall moment). Office design_building rerun and full suites not run (user doing speed work).
