---
id: chec-bed06526
type: checkpoint
project: menegroth
parent_id: plan-a79eb74f
title: Foundation combinations stay centered on the gravity resultant
node_label: Combination footings committed
tags: foundations,lateral,commit
status: active
open_threads: 0
success: 'null'
files: StructuralSizer/src/foundations/codes/aci/mat_footing.jl@2af5e9c, StructuralSizer/src/foundations/codes/aci/strip_footing.jl@2af5e9c,
  StructuralSizer/src/foundations/codes/aci/wall_strip_footing.jl@2af5e9c, StructuralSizer/test/foundations/test_mat_rigid_statics.jl@2af5e9c,
  StructuralSizer/test/foundations/test_strip_aci.jl@2af5e9c, StructuralSizer/test/foundations/test_wall_footing.jl@2af5e9c,
  StructuralSynthesizer/src/analyze/foundations/demands.jl@2af5e9c, StructuralSynthesizer/src/analyze/foundations/size_isolated.jl@2af5e9c,
  StructuralSynthesizer/src/analyze/foundations/wall_groups.jl@2af5e9c, StructuralSynthesizer/src/analyze/lateral/foundation_reactions.jl@2af5e9c,
  StructuralSynthesizer/test/analyze/test_wall_foundations.jl@2af5e9c
session_id: sess-278ee43a
created_at: '2026-11-26T03:55:02.630001+00:00'
updated_at: '2026-11-26T03:55:02.630001+00:00'
---
Strips, column mats, grade-wall strips, and mats that carry a wall line now check every ASCE 7 service and strength combination. The plan stays centered on the gravity resultant: a straight wall or column strip lengthens about that center or widens, a corner only widens, and a mat keeps equal overhang.

A strength combination designs its own punching, shear, flexure, and tensile steel on the linear ACI 336.2R §3.2.1 pressure. Partial contact is not applied. If an enclosed column has no stored actions, a wall-line mat keeps the gravity design rather than mixing the two.

Tests: StructuralSizer foundations/test_strip_aci.jl, test_mat_rigid_statics.jl, test_wall_footing.jl, and StructuralSynthesizer analyze/test_wall_foundations.jl.

Still open: a flexible mat (Winkler or Shukla) and the grade-wall beam-on-elastic-foundation fallback still section on the gravity demand, and the rigid mat's 20% load-variation gate still reads gravity Pu only.
