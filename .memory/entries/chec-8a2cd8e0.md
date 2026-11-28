---
id: chec-8a2cd8e0
type: checkpoint
project: menegroth
parent_id: deci-93f9b5ce
title: 'Dual increment (2) DONE: steel frame-member strength (AISC App.8 B1/B2) wired
  + tested'
node_label: 'Dual increment (2) DONE: steel frame-member streng'
tags: ''
status: active
open_threads: 0
success: 'null'
files: StructuralSynthesizer/src/analyze/lateral/dual_frame_checks.jl@a35e3de, StructuralSynthesizer/src/analyze/lateral/dual_system_stage.jl@a35e3de,
  StructuralSynthesizer/src/analyze/_analyze.jl@a35e3de, StructuralSizer/src/members/codes/aisc/checker/explanations.jl@a35e3de,
  StructuralSynthesizer/test/analyze/test_ordinary_wall_stage.jl@a35e3de, StructuralSizer/test/steel_member/test_b1_checker_integration.jl@a35e3de,
  scripts/runners/dual_stage_smoke.jl@a35e3de
session_id: sess-76a55c71
created_at: '2026-11-24T00:23:44.331195+00:00'
updated_at: '2026-11-24T00:23:44.331195+00:00'
---
Increment (2) of the dual-system remaining work complete and green.

WHAT LANDED:
- StructuralSizer explanations.jl: explain_feasibility(::AISCChecker,...; story=nothing) now routes through _aisc_amplified_forces (mirrors is_feasible): B1*Mnt+B2*Mlt, Pr=Pnt+B2*Plt, and feeds Pr_c (not Pu_c) into the H1 interaction. Flag-off (story=nothing) byte-identical. New testset in test_b1_checker_integration.jl (B2 flows into explain governing ratio; braced==no-op; explain.passed==is_feasible).
- NEW StructuralSynthesizer/src/analyze/lateral/dual_frame_checks.jl: dual_frame_member_checks(struc,basic,wind,elf,effects,inputs,mf). _build_first_order gives first-order full-model per-case u=[D,L,roof,wind...,qe...]; per seismic strength combo x seismic effect x element, _split_nt_lt partitions factored forces into nt (gravity+Ev) / lt (rho*Eh). Columns carry the lt split (is_feasible does B1/B2); girders (Pu_c~0 -> is_feasible skips App.8) get sway moment PRE-amplified Mnt+B2*Mlt. Shear = total nt+lt. Only designated mf.columns/mf.beams checked; non-steel skipped+counted. B2 per story from story_stability_records(pmf_fraction=1.0), max over directions.
- dual_system_stage.jl: DualSystemResult gains frame_members::Vector{FrameMemberCheck}; design_dual_system! runs the check, pending now 2 (share proxy + frame-only gate). _analyze.jl includes dual_frame_checks.jl.

VERIFICATION:
- Smoke (dual_stage_smoke.jl, W14X145 cols + W24X84 girders on _stage_office nopark): 55 members checked (27 col + 28 beam), 0 failing; governing pm_interaction_compression (cols) / pm_interaction_tension_hogging (beams) under strength_1_2D_1_0E + QE*. theta~0.0007 so B2~1 here (B2 stressed later in the 20-40 story proof, increment 4).
- StructuralSynthesizer analyze/test_ordinary_wall_stage.jl: 719/719 (added frame_members assertions to the dual backbone testset).
- StructuralSizer: test_b1_checker_integration 28/28; explain_agreement+composite+b1_b2 381/381.

NEXT: increment (1) §12.2.5.1 25% story-shear-share proxy, then (3) frame-only 25% capability gate, then (4) drift governor + graph node + tall-building proof.
