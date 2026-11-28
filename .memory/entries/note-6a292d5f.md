---
id: note-6a292d5f
type: note
project: menegroth
parent_id: expe-18356ac1
title: 30 in is the special-wall shear-stress cap, not a thickness default
node_label: '30 in is the special-wall shear-stress cap, not a '
tags: walls,thickness,18.10.4.4,Ve
status: active
open_threads: 0
success: 'null'
files: ''
session_id: sess-37c127ca
created_at: '2026-11-14T04:48:09.653827+00:00'
updated_at: '2026-11-14T04:48:09.653827+00:00'
has_child_rationale: What the 30 in thickness is, on the Category D run.
---
The 30 in on the Category D office is the first whole inch at which special-wall shear fits under ACI 318-19 §18.10.4.4, Vn ≤ 8√f(f′c) Acv (corpus: aci-318-19, page 324). At 29 in the transverse steel was on the 0.020 grid top and the pier still failed. At 30 in ρl = ρt = 0.0065, the 0.0005 step that develops that cap for αc = 2: (8−2)√4000/60000 = 0.00633. The recorded ratio 1.00 is §11.6.2 minimum longitudinal steel equal to that shear steel.

The jump ceilings are 24 in and 36 in. This building went past 24 and stopped before 36. The start is the 0.25 m parameter. Three times that length is 0.75 m, and the next inch is 30. The first frozen-shear proposal was 23 in; re-solves walked 28, 29, then 30, which is the two-jump budget letting a thicker wall pick up more story shear. Category B at SDS 0.20 on the same row stays near 10 in, so the thickness follows the SDS 1.0 shear at the Ve ≤ 3 Vu ceiling (Eq. 18.10.3.1), not a stored 30 in.

T = 0.4 s does not set Cs here: SD1/SDS = 0.60 s, so Cs = SDS/(R/Ie) = 0.20 with R = 5 for Table 12.2-1 row A1. The wind pressures are the same ones the thin Category B building uses.
