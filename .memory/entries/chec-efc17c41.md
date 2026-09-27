---
id: chec-efc17c41
type: checkpoint
project: menegroth
parent_id: plan-d9fb1410
title: 'Flush-bearing Bn complete: per-face A2, inclusive SI ulp floor, leftover A2
  oracle'
node_label: flush-bearing Bn complete
tags: foundations,bearing,checkpoint,flush,complete
status: active
open_threads: 0
success: 'null'
files: StructuralSizer/src/foundations/types.jl@0f7da6c, StructuralSizer/src/foundations/codes/aci/spread_footing.jl@0f7da6c,
  StructuralSizer/src/foundations/codes/aci/strip_footing.jl@0f7da6c, StructuralSizer/test/foundations/test_foundation_safety_9_15.jl@0f7da6c
session_id: sess-b37f743e
created_at: '2026-09-27T17:21:48.756010+00:00'
updated_at: '2026-09-27T17:21:48.756010+00:00'
results: '[{"metric": "foundation_safety_9_15_tests", "value": 222, "unit": "pass",
  "criterion": "test_foundation_safety_9_15.jl after inclusive SI ulp floor", "source":
  "local julia"}, {"metric": "overhang_ulp_floor", "value": 1e-12, "unit": "in", "criterion":
  "inclusive |oh| \u2264 1e-12 in after subtract", "source": "deci-97c535b0"}]'
---
Flush-bearing Bn is complete. ACI 318-11 §10.14.1 (corpus: aci-318-11, page 162): sqA=1 unless wider on all sides; per-face A2 clip; circular named c1; SI canonicalize + inclusive |oh|≤1e-12 in floor (1.001× Unitful slack, not a construction tolerance). 24.02×12.02 leftover oracle locks A2 clip at √(24.02×12.02/288)≈1.00125.

Coordinator run-9c2a139b landed the gate; deci-97c535b0 closed the two critic7 P2s. Foundation safety 9–15 tests: 222 pass.

This subplan is done. Remaining foundation-safety leftovers (hogging Chapter I H1 on CompositeContext, NLP interior Mub=0, rule_of_thumb Inf swallow, kern q_min<0, As_tensile design, IS V_punch, Δx=Δy tie) stay on parent plan-a4de4826 — not reopened here. Ribbed-floor work stays gated until that parent concludes.
