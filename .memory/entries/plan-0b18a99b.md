---
id: plan-0b18a99b
type: plan
project: menegroth
parent_id: plan-1e34d0a9
title: One-sided flange drawing, edge cages, and the beams that do not match
node_label: Flange drawing and mismatched beams
tags: waffle,edge-beam,flange,detailing,solid-head
status: active
open_threads: 0
success: 'null'
files: ''
session_id: sess-1505a83d
created_at: '2026-11-14T22:21:16.223542+00:00'
updated_at: '2026-11-14T22:21:16.223542+00:00'
has_child_rationale: She confirmed this scope and asked to address it now
---
Confirmed, then implement. Do not change a flange width until the stored width is explained. Do not add a mirror constraint (deci-569db0d0). Do not invent an L-section or change ACI 318-11 §8.12.2 or §8.12.3.

1. Diagnose beam 4, whose stored flange equals the stem, and the x=6 versus x=18 ribs (beam 38 versus beam 30), whose moments differ on a symmetric plan. If the rectangle is what §8.12.3 produced, the width stays. If the demands differ because the solve is not symmetric, fix that cause.
2. Draw a one-sided flange on the slab side. The check keeps one centered width. For a member already marked one-sided, shift the scene polygon so the overhang lies on the slab side and the outside face is flush with the stem. An interior T-beam stays symmetric.
3. Measure solid-head bars before changing them. Pieces whose hogging does not fit one layer in the piece width stay unresolved until the clause is chosen. Do not use §13.3.7 unless it is looked up and she agrees. The beam section's effective depth stays one layer.
4. Draw the top bars that already place on the solid-head prism.
5. Place the edge-beam cages (beams 3, 4, 25, 26) whose section has bars but whose schedule is empty because a support was not found. This does not change the head mat.

Left alone: head size, topping thickness, the other two grid designs.
