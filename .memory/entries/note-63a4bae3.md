---
id: note-63a4bae3
type: note
project: menegroth
parent_id: deci-c85e0d31
title: 'Building-model head checks: first grid/x1y1 dense waffle result'
node_label: 'Building-model head checks: first grid/x1y1 dense '
tags: waffle,solid-head,building-model,result
status: active
open_threads: 0
success: 'null'
files: ''
session_id: sess-6897c4bc
created_at: '2026-11-18T17:47:39.361292+00:00'
updated_at: '2026-11-18T17:47:39.361292+00:00'
---
Implemented `arrangement_heads_frame.jl`: `resolve_building_heads!` / `check_arrangement_head_on_frame` read column punching (slab members' K u + Q at the joint, girders excluded per ACI 318-11 R13.6.8 p.257), rib one-way shear at own d, and hogging at the face from `struc.asap_model`, enveloped over full + pattern cases; growth re-solves the building. Sign test: `test/analyze/test_slab_joint_demand.jl` (joint equilibrium closes).

Findings on grid/x1y1 dense waffle (16 slabs of 6x5 m, one head each): column lines carry joist-role members (sized up to 12x27.8 in) delivering 35-70 kip into columns, so the high rib shear is the real column-strip load path, not only the local-model artifact. Final run: pass=false; most heads stop at the solid cap with rib one-way 1.04-1.81; five slabs stopped at :unsized on the last member pass with heads of 1-3 bays and punching 1.13-2.0 (governing slab 11, 2.0). Two corner heads returned a NaN punching ratio; a guard now throws with diagnostics. Also fixed: head depth no longer read from girder pieces (`_level_rib` filter), split remnants keep the host section, deflection guard throws only when no element is measured.
