---
id: deci-a672f3e0
type: decision
project: menegroth
parent_id: plan-ba7625fb
title: H1 tension is checked on the hogging face
node_label: H1 tension is checked on the hogging face
tags: ''
status: active
open_threads: 0
success: 'null'
files: ''
session_id: sess-6d5378e3
created_at: '2026-10-22T21:05:19.557186+00:00'
updated_at: '2026-10-22T21:05:19.557186+00:00'
---
AISC 360-16 §H1.2 (page 134) tension is now checked with the hogging face as well as the sagging face. `_h1_pm_utilizations` returns `ur_t_neg` from Eqs. H1-1a/H1-1b with Pc = φt Pn (Section D2), first-order Mux_neg, and hogging Mcx = φMn_neg. Both is_feasible paths reject it, and explain_feasibility reports `pm_interaction_tension_hogging`. The case Pu/φPn = 0.60 with Mu/φMn = 0.60 hogging is 1.133 and fails; sagging tension stays 0.60. steel_member/test_phi_v_provision.jl: 103/103.
