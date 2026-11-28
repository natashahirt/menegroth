---
id: chec-1b0ad960
type: checkpoint
project: menegroth
parent_id: plan-7318fba7
title: Rectangular beam NLP uses the ACI 318-11 beam deflection check
node_label: Rectangular NLP deflection
tags: nlp,beams,deflection,aci-318-11
status: active
open_threads: 0
success: 'null'
files: ''
session_id: sess-37be5cf1
created_at: '2026-11-13T15:05:01.717901+00:00'
updated_at: '2026-11-13T15:05:01.717901+00:00'
has_child_rationale: 'First open item: rectangular beam NLP had no deflection constraint.'
---
Worktree row-f-nlp. Rectangular beam NLP takes w_dead, w_live, and L_span and adds live (L/360) and total (L/240) constraints. The arithmetic matches design_beam_deflection: wc = 150 pcf, fr = 7.5 sqrt(f'c), Ig = bh^3/12, transformed Icr, Branson, Eq. 9-11 with no compression steel. ACI 318-11 §9.5.2, corpus aci-318-11, PDF pp. 131–133. The rounded section is checked again with design_beam_deflection. Omitting any service input leaves the old constraint count. Test concrete_beam/test_signed_demands.jl 88/88. Not committed yet.
