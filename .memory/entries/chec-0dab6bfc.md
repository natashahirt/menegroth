---
id: chec-0dab6bfc
type: checkpoint
project: menegroth
parent_id: deci-a672f3e0
title: H1.2 tension+hogging P1 verified green (103/103) and committed
node_label: H1.2 tension+hogging P1 verified green (103/103) a
tags: ''
status: active
open_threads: 0
success: 'null'
files: StructuralSizer/src/members/codes/aisc/checker.jl@bcfe7d3, StructuralSizer/test/steel_member/test_phi_v_provision.jl@bcfe7d3
session_id: sess-70a4a7a8
created_at: '2026-10-23T02:00:50.792486+00:00'
updated_at: '2026-10-23T02:00:50.792486+00:00'
---
Finalized the pre-ribbed H1 tension-on-hogging-face P1 (deci-a672f3e0). The working-tree fix in checker.jl was complete and correctly cited: `_h1_pm_utilizations` adds `ur_t_neg = check_PMxMy_interaction(Pu_t, Mux_neg, Muy, ϕPnt, ϕMn_neg, ϕMny)` (AISC 360-16 §H1.2 p.134, Pc=ϕt·Pn from D2, Mcx=hogging ϕMn_neg, first-order Mr). Both is_feasible paths now reject `ur_t_neg>1`; both explain_feasibility paths emit `pm_interaction_tension_hogging`. Unit test oracle: Pr/Pc=0.60 & Mrx/Mcx=0.60 hogging → 0.60+8/9·0.60=1.133>1 (fails), sagging tension stays 0.60. steel_member/test_phi_v_provision.jl: 103/103 green. Committing checker.jl + test.
