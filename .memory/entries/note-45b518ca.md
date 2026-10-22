---
id: note-45b518ca
type: note
project: menegroth
parent_id: plan-7fe7fb83
title: 'Close-out baseline: StructuralSizer full suite = 7396 pass / 20 fail / 1 broken
  @ 21e23a0f — all 20 PRE-EXISTING, zero audit regressions'
node_label: 'Close-out baseline: StructuralSizer full suite = 7'
tags: ''
status: active
open_threads: 0
success: 'null'
files: StructuralSizer/test/slabs/test_corner_punching.jl@8b97d6d, StructuralSizer/test/steel_member/test_aisc_beam_examples.jl@8b97d6d,
  StructuralSizer/test/steel_member/test_handcalc_beam.jl@8b97d6d
session_id: sess-96fa171b
created_at: '2026-10-22T13:59:23.386974+00:00'
updated_at: '2026-10-22T13:59:23.386974+00:00'
---
Ran the full StructuralSizer suite as close-out step 2 at HEAD 21e23a0f (overnight gravity audit committed; only walls lateral_evaluator.jl/layout_problem.jl + scheduler.jl dirty, none steel/punching). Result: 7396 passed, 20 FAILED, 0 errored, 1 broken (Julia exit 1). ALL 20 failures classified PRE-EXISTING / known, NONE introduced by the Eq.(13-7) or col_I_factor audit work:

CLUSTER 1 (4 failures) — STEEL beam-selection brittle oracles, UNRELATED to gravity audit:
- test_aisc_beam_examples.jl:187 (selected W18X76 ∉ (W16X67,W14X74)), :391 (W27X84 ∉ (W21X55,W18X60))
- test_handcalc_beam.jl:125 (W14X43 ∉ [W16X26,W12X30,W14X26]), :129 (weight 41.97 lb/ft ≥ 35.0)
- Sizer picks a HEAVIER W-section than the AISC textbook answer. Proven pre-existing: audit commits (21e23a0f, cdcd6271) touched NO steel files; test_aisc_beam_examples.jl last modified 2026-03-12 (7 months ago). Relates to pre-ribbed 'AISC 360-16 §H1' bucket but is a flexural selection-conservatism oracle, not a safety regression.

CLUSTER 2 (16 failures) — CORNER-PUNCHING biaxial Muy = KNOWN Defect 4 (note-7de9d402, 2026-09-23):
- test_corner_punching.jl 'Corner punching — pipeline / RuleOfThumb pass Muy' (lines ~498-501, both 20×30 ROT and DDM pipeline variants × 4 corners).
- Asserts production pr.vu ≈ r_new.vu (BIAXIAL Mux+Muy) within rtol 0.08 and closer to biaxial than uniaxial r_old. FAILS: pr.vu≈155.7 psi tracks the UNIAXIAL r_old, not biaxial r_new≈242.4 psi — i.e. production punching_check drops the corner moment transfer (punching.jl vu=v_direct for :corner, violating ACI 318-11 §11.11.7.1 which applies transfer to ALL columns). This is a ~36% UNDER-estimate of corner punching demand — UNCONSERVATIVE — but it is the documented pre-existing Defect 4, red-by-design since the test was pre-staged (eee02cdb, 2026-10-21), and already scheduled on the pre-ribbed backlog as 'edge-column biaxial punching (PCA EB712 Fig 16-13)'.

CONCLUSION: close-out suite confirms NO new regression from the overnight gravity audit; the 20 reds are the known steel-selection + Defect-4 backlog. Fix Cluster 2 in the pre-ribbed run (it is a real unconservative punching path). The 1 'broken' is an existing @test_broken. Full log: /tmp/closeout_sizer.log.
