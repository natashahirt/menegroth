---
id: deci-b14c408c
type: decision
project: menegroth
parent_id: plan-c8115994
title: Wall thickness jumps from one lateral analysis
node_label: Wall thickness jumps from one lateral analysis
tags: walls,thickness,efficiency,ordinary-walls
status: active
open_threads: 0
success: 'null'
files: StructuralSynthesizer/src/analyze/lateral/wall_thickness_jump.jl@709f198, StructuralSynthesizer/src/analyze/lateral/ordinary_wall_stage.jl@709f198,
  StructuralSynthesizer/src/design/parameters.jl@709f198, StructuralSynthesizer/test/analyze/test_wall_thickness_jump.jl@709f198
session_id: sess-70a4df14
created_at: '2026-11-07T01:46:15.435862+00:00'
updated_at: '2026-11-07T01:46:15.435862+00:00'
has_child_rationale: 'The wall-building loop still only records a failing pier. The
  user asked for the slab-thickness jump applied to walls, at the same computational
  cost: invert from one analysis, confirm once.'
---
Ordinary walls jump thickness from one lateral analysis, the same way the slab sizer jumps depth. All walls share one thickness (the existing `params.wall_thickness`). They step together so relative stiffness is unchanged and in-plane V and M can be frozen. Unfactored wall self-weight axial force scales with t; live, wind, and QE stay. Drift scales as t0/t because in-plane flexural and shear flexibility are both 1/t. Steel is re-picked on the existing rho grid at each candidate, starting from 0.0025. The grid is 1 in, from the next inch above t0 up to the larger of 24 in and the shear-cap or drift invert, and not past 36 in. Table 11.3.1.1 is already inside the bearing check. Mixed thicknesses, a negative implied tributary axial, and interactive-frame-only failures do not jump. A failed confirm remeshes once more from the new analysis. `jump_wall_thickness` defaults to true; a test that must record a failure at the given t sets it false.
