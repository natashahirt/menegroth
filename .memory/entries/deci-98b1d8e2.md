---
id: deci-98b1d8e2
type: decision
project: menegroth
parent_id: plan-fdfcf263
title: A rib that fails one-way shear at a solid head is resized, not filled in
node_label: Rib shear returns to the beam
tags: waffle,solid-head,shear,sizing
status: discarded
open_threads: 0
success: 'null'
files: ''
session_id: sess-bcaa7123
created_at: '2026-11-17T03:37:01.243122+00:00'
updated_at: '2026-11-17T23:02:34.758369+00:00'
---
The 30 in qualification waffle fails on Slab 15, punching ratio 6.90, clause stored as ACI 318-19 §22.6. The analysis note says the solid-head check took 0 growth steps, stopped, and the governing section was rib one-way shear. The head grows only for column punching. A rib that fails one-way shear at the head is a rib section problem.

That shear is now kept, by beam, in newtons, and the next beam sizing pass uses it when it is larger than the frame shear. The value only rises during a run, so a rib that just carried the shear is not shrunk on the following pass. The beam and column loop does not settle, and does not accept a section cycle, while the last solid-head check still fails on rib one-way shear or stem compression. Column punching still grows the head and does not hold the loop for that reason.

No new shear formula. The demand is the shear the existing head check already computed. The 1.25 m module is unchanged.
