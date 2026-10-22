---
id: plan-d9fb1410
type: plan
project: menegroth
parent_id: plan-a4de4826
title: 'Flush-bearing Bn: sqA=1 unless wider on all sides'
node_label: 'Flush-bearing Bn: sqA=1 unless wider on all sides'
tags: foundation-safety,bearing,aci-10.14.1,coordinator
status: active
open_threads: 6
success: 'null'
files: StructuralSizer/src/foundations/codes/aci/strip_footing.jl@9690969, StructuralSizer/src/foundations/codes/aci/spread_footing.jl@113262c,
  StructuralSizer/test/foundations/test_foundation_safety_9_15.jl@113262c
session_id: sess-fe4149f4
created_at: '2026-09-23T17:31:08.715189+00:00'
updated_at: '2026-09-27T17:21:48.756010+00:00'
---
Tight follow-up to run-82af63b6 leftover P1 (note-36224782).

ACI 318-11 §10.14.1 (corpus: aci-318-11, page 162): φ(0.85fc A1) except when the supporting surface is **wider on all sides** than the loaded area, then √(A2/A1) ≤ 2. High-qa Y-strip floors B at c_across (flush transverse edges) but `_bearing_check_footing` still takes √ from along-strip 4h spread → √=2 vs required 1 → Bn up to 2× high.

Fix in `_bearing_check_footing` (covers strip + spread): sqA=1 unless wider on all sides. Circular: diameter stays named c1 (do not feed c_along into the cone branch). Assert Bn on 36×12 qa=20 ksf Y-strip with B=c_across.

Scope wall: do NOT reopen mixed-band Mu_trans, NLP Inf, rule_of_thumb Inf, IS equivalent spread, Δx=Δy tie, hogging Chapter I.

Graph (medium, max 3 extensions):
[eng] engineer grok-4.7-high-fast
[test] tester grok-4.7-high-fast (after eng)
[rev] reviewer (after eng)
[crit] critic (after eng)
[memory] after all

Checkers: reviewer (baseline), critic (sqA=1 vs widen-B), tester (suite + behavior). Skip bugbot (small diff), security-review (no surface).
