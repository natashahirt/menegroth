---
id: chec-9b2cda33
type: checkpoint
project: menegroth
parent_id: plan-a5444476
title: Analysis studs use the group's unbraced length and Cb
node_label: Group Lb and Cb for ΣQn
tags: composite,studs,Lb,Cb,I_LB
status: active
open_threads: 0
success: 'null'
files: StructuralSynthesizer/src/analyze/members/composite_context.jl@2adbd1f, StructuralSynthesizer/src/analyze/members/utils.jl@2adbd1f,
  StructuralSynthesizer/test/analyze/test_composite_context.jl@2adbd1f, StructuralSynthesizer/src/analyze/members/composite/checks.jl@2adbd1f,
  StructuralSynthesizer/src/analyze/members/composite/demands.jl@2adbd1f, StructuralSynthesizer/src/analyze/members/composite/openings.jl@2adbd1f,
  StructuralSynthesizer/src/analyze/members/composite/options.jl@2adbd1f, StructuralSynthesizer/src/analyze/members/composite/payloads.jl@2adbd1f,
  StructuralSynthesizer/src/analyze/members/composite/profiles.jl@2adbd1f, StructuralSynthesizer/src/analyze/members/composite/stiffness.jl@2adbd1f,
  StructuralSynthesizer/src/analyze/members/composite/subdivision.jl@2adbd1f, StructuralSynthesizer/src/analyze/members/members/beam_tributaries.jl@2adbd1f,
  StructuralSynthesizer/src/analyze/members/members/column_tributaries.jl@2adbd1f,
  StructuralSynthesizer/src/analyze/members/members/demands.jl@2adbd1f, StructuralSynthesizer/src/analyze/members/members/geometry_classification.jl@2adbd1f,
  StructuralSynthesizer/src/analyze/members/members/grouping.jl@2adbd1f, StructuralSynthesizer/src/analyze/members/members/initialize.jl@2adbd1f,
  StructuralSynthesizer/src/analyze/members/members/releases.jl@2adbd1f, StructuralSynthesizer/src/analyze/members/members/size_beams.jl@2adbd1f,
  StructuralSynthesizer/src/analyze/members/members/size_columns.jl@2adbd1f, StructuralSynthesizer/src/analyze/members/members/wall_stacks.jl@2adbd1f
session_id: sess-98cda459
created_at: '2026-10-31T15:38:56.773362+00:00'
updated_at: '2026-10-31T15:38:56.773362+00:00'
---
The composite inertia writer now counts studs with the same bare-steel flexural strength the strength check uses. member_group_demands stores the longest segment Lb and the smallest segment Cb on SteelMemberGeometry. _write_beam_composite_ix! passes that pair to get_ϕMn (ϕ_b = 0.90, AISC 360-16 §F1, corpus: aisc-360-16, p. 102). Commentary Eq. C-I3-1 (corpus: aisc-360-22, PDF p. 502) takes ΣQn as the anchors between the maximum positive moment and the adjacent zero; Lb and Cb only change how many anchors the search places. A beam braced only at its ends with Cb = 1 is unchanged. Hogging stays on the cracked section. The deflection target is not passed into this search, because the confirmation checks the solved deflection.

Under axial compression the checker can still place more studs through moment amplification and H1. Gravity beams carry no axial force.

Tests: test_composite_context.jl 270 passed. Log logs/test_StructuralSynthesizer_20261031_111647.log. The composite and member sources are split into their own files in this commit because the writer lives in that split.
