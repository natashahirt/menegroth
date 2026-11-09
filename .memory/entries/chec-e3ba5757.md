---
id: chec-e3ba5757
type: checkpoint
project: menegroth
parent_id: plan-0e3e4710
title: Solid-head punching checks match the waffle example without the 1.10
node_label: Head punching checks
tags: punching,solid-head,joist,spslab
status: active
open_threads: 0
success: 'null'
files: ''
session_id: sess-208d8ca5
created_at: '2026-11-09T00:07:12.520028+00:00'
updated_at: '2026-11-09T00:07:12.520028+00:00'
has_child_rationale: The three checks are in StructuralSizer and tested. The building
  solve does not call them yet.
---
check_solid_head_column_punching uses the existing column path at the full head depth, with moment transfer and no 1.10.

check_rib_web_punching uses spSlab Eq. 2-14 (sp-de-two-way-waffle-slab-aci318-14, reference text page 61): d_v = Σ(bw·h) / head width, v_u = V_u / (b0·d_v). Direct shear only. The result says eccentric shear at that section is not covered by a code clause. The example's 1.10 on v_c is not applied. The exterior drop in the example (4×17×7.32 / 150 = 3.32 in, v_u ≈ 117.94 psi) is the test.

check_rib_shear_at_head is one-way shear at d from the head face. Vc_joist supplies the 1.10 only when §8.13.2 and §8.13.3 are met. solid_head_punching.jl is in the source scan that forbids the joist factor.

grown_solid_head steps one rib module and throws when opposite heads would meet. The design loop does not yet pass the column reaction in or re-cut the frame when the check fails.
