---
id: chec-f16dbf7b
type: checkpoint
project: menegroth
parent_id: deci-a764434e
title: Per-station composite b_eff(s) from tributary geometry, with reduction and
  solved-frame tests
node_label: Per-station composite b_eff(s) from tributary geom
tags: ''
status: active
open_threads: 0
success: 'null'
files: StructuralSizer/src/StructuralSizer.jl@b075af9, StructuralSizer/src/members/codes/aisc/composite/_composite.jl@b075af9,
  StructuralSizer/src/members/codes/aisc/composite/effective_width.jl@b075af9, StructuralSizer/src/members/codes/aisc/composite/per_station.jl@b075af9,
  StructuralSizer/test/runtests.jl@b075af9, StructuralSizer/test/steel_member/composite/test_composite_per_station.jl@b075af9,
  StructuralSynthesizer/src/StructuralSynthesizer.jl@b075af9, StructuralSynthesizer/src/analyze/members/_members.jl@b075af9,
  StructuralSynthesizer/src/analyze/members/composite_context.jl@b075af9, StructuralSynthesizer/test/runtests.jl@b075af9,
  StructuralSynthesizer/test/analyze/test_composite_context.jl@b075af9
session_id: sess-7dc04c7f
created_at: '2026-10-23T23:12:20.012200+00:00'
updated_at: '2026-10-23T23:12:20.012200+00:00'
---
Committed the per-station AISC 360-16 §I3.1a composite effective-width path (deci-a764434e). b_eff(s) is built per side from the building tributary (face-winding split; multi-edge stitched), capped at L/8 per side. Demand M(s) reuses the exact TributaryLoad field. Governing station is a per-segment search. Positive moment uses §I3.2a; negative uses §I3.2b with caller-supplied Asr (compact/anchor/development gates not auto-checked). Deflection scale is Ix/I_LB on the FEM δ.

Tests: StructuralSizer composite per-station + existing composite beam 159/159; StructuralSynthesizer test_composite_context.jl 107/107, including T1 sagging-positive wL²/8 on a 32-element beam, T2 simple-span 5wL⁴/384EI reduction and two-span ≠ that formula, T3 check_composite_beam on a solved two-bay frame.

Not in this commit: check_composite_beam is not yet called from size_beams!. Unrelated dirty files (agents.yaml, Asap submodule, defect runners, promotions.yml, convert_pdfs_to_text.py) were left out.
