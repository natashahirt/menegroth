---
id: deci-69d8c5a5
type: decision
project: menegroth
parent_id: plan-a7ebaacc
title: Rib hogging at the solid head is the stem's tension-controlled capacity
node_label: stem hogging capacity
tags: solid-head,hogging,aci-318
status: active
open_threads: 0
success: 'null'
files: ''
session_id: sess-d4fc172b
created_at: '2026-11-11T23:44:05.464201+00:00'
updated_at: '2026-11-11T23:44:05.464201+00:00'
---
At the face of a solid head, hogging puts the topping in tension and the rib stem in compression. The check is the tension-controlled capacity of a rectangle of width bw and depth d: ACI 318-11 §10.2.7 (Whitney block, page 140), εt = 0.005 (§10.3.4, page 142), φ = 0.90 (§9.3.2.1, page 126), via max_singly_reinforced. If a stem depth is given and a_max is deeper than the stem, the block enters the topping and this width does not govern. Sagging is not checked this way. The moment read uses the existing hogging sign (opposite of sagging on local My). A failing rib grows one bay along its outward direction when the hogging moment is positive; the moment is not stored in Vu. On the released-corner rectangle the face moment is sagging, so Mu is zero and the corner fraction stays. One-way shear at d from the face falls as that rectangle's head grows (1.01 at 1/8 of an 8×8 bay, 0.63 at 1/4, 4.5 kPa), so the next module can pass.
