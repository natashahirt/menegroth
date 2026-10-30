---
id: chec-387f9dc9
type: checkpoint
project: menegroth
parent_id: plan-a5444476
title: Studs stay in their sagging region; per-element inertia started
node_label: region studs + element I
tags: composite, aisc, studs, stiffness, I_LB
status: active
open_threads: 0
success: 'null'
files: StructuralSizer/src/members/codes/aisc/checker.jl@4a1b084, StructuralSizer/src/members/codes/aisc/composite/per_station.jl@4a1b084,
  StructuralSizer/src/StructuralSizer.jl@4a1b084, StructuralSizer/test/steel_member/composite/test_composite_per_station.jl@4a1b084,
  StructuralSynthesizer/src/analyze/members/composite_context.jl@4a1b084, StructuralSynthesizer/src/StructuralSynthesizer.jl@4a1b084,
  StructuralSynthesizer/test/analyze/test_composite_context.jl@4a1b084
session_id: sess-24065292
created_at: '2026-10-30T02:30:05.855745+00:00'
updated_at: '2026-10-30T02:30:05.855745+00:00'
---
Step 4 of the variable-stiffness plan. A continuous member with more than one sagging region no longer designs studs for a single governing station and then credits that total to the whole member. The region of greatest positive moment still owns the service check (Commentary Eq. C-I3-1: ΣQn between the maximum positive moment and the adjacent zero; Eq. C-I3-5: I_pos is that region). Every other sagging region is strength-checked on its own shear spans (I8.2c), with its own stud count. A long bay that passes and a short bay that carries the same moment now fails the member. StructuralSizer per-station tests: 85/85, log logs/test_StructuralSizer_20261029_165830.log.

Step 5 started, not yet inside size_beams!. composite_inertia_at_station returns I_LB of the sagging region that contains the station, or the cracked section where the moment is negative. apply_composite_element_stiffness! writes that inertia onto each existing frame element at the element midpoint. refine_composite_stiffness! rebuilds K (Asap.update! values_only) and re-solves until the sagging-region boundaries move less than the tolerance. ENGINEERING JUDGMENT: Commentary Eq. C-I3-5 (aisc-360-22, PDF p. 502) permits one constant inertia; per-element I is a refinement of that constant, not a replacement of the strength check. composite_deflection_scale still assumes the solved model is bare steel, so a deflection solved with these inertias must not also be scaled. A bay that is one element gets one inertia (the midpoint's). The building-level test (T2d in test_composite_context.jl) was still compiling when this was recorded; the machine was out of free RAM.
