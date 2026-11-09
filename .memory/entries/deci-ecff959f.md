---
id: deci-ecff959f
type: decision
project: menegroth
parent_id: plan-0e3e4710
title: Rib, topping, and solid-head bar placement
node_label: Bar placement rules
tags: bars, topping, joist, solid-head, aci-318-11
status: active
open_threads: 0
success: 'null'
files: ''
session_id: sess-7d8298d5
created_at: '2026-11-09T12:52:07.967586+00:00'
updated_at: '2026-11-09T12:52:07.967586+00:00'
has_child_rationale: User chose how the three bar limits are resolved before placement
  is built.
---
Topping bars are the slab spanning rib to rib (ACI 318-11 §8.13.6.2, removable forms). Moments are §8.3.3 on that clear span when the rib-to-rib spans qualify, including wu·ln²/12 where spans are at most 10 ft; otherwise the elastic strip (§8.3.1). The §7.12 mat is always placed. The bay-length one_way_topping_bars moments are not the topping schedule; the ribs carry the bay moment.

The solid head does not reduce negative steel. The topping mat continues through the head. §13.3.7 is not used, and the result says so. A drop panel versus a shear cap does not change the bars.

Rib bottom bars and stirrups stay on detail_beam. Top bars are full length, from the grillage frame's negative moment at each rib end. No cutoff, because there is no inflection diagram. A rib sized as a beam under §8.13.4 uses the same top bars.
