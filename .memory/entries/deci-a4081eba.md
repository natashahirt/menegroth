---
id: deci-a4081eba
type: decision
project: menegroth
parent_id: plan-c431a82d
title: Pair the slab moment with each wall combination, and place half of Table 18.7.5.4
node_label: Pair Moop and place half-table hoops
tags: walls,detailing,aci-318,asce-7
status: active
open_threads: 0
success: 'null'
files: ''
session_id: sess-ce5a48d4
created_at: '2026-11-17T22:08:30.345244+00:00'
updated_at: '2026-11-17T22:08:30.345244+00:00'
has_child_rationale: The user asked to pair the wall moment with the concurrent axial
  and to address the special-wall detailing that was still only a warning.
---
The slab moment into an ordinary wall is no longer the same envelope on every strength combination. The stored moment is still the envelope of 1.4D and 1.2D+1.6L. Each action takes that envelope times its own gravity pressure divided by the larger of those two, and never more than the envelope. A floor uses the combination's L, and the wind reading of combination 3 drops floor live. A roof uses the combination's Lr. Wind and Eh do not scale it. No pressure basis leaves the envelope on every action, which is what the unit tests do.

ACI 318-19 §18.14.3.2(c) (corpus aci-318-19, PDF pages 353-354) now places half of Table 18.7.5.4 (a) and (b) over ℓo when the factored gravity axial exceeds 0.35P0. Parts (c) and (f) are not in that minimum. The §18.14.3.3 path is unchanged and still uses the full table, including (c). The trigger is the gravity axial already computed for the δDE check, 1.2D+1.6L+0.2·SDS·D, which includes vertical ground motion (§18.14.2.1) and does not include Eh. The earthquake-included Pu is not the trigger. When the cover outside the confining hoop exceeds 4 in., §18.7.5.7 (PDF page 312) adds hoops at 4 in. cover, at most 12 in. apart, over ℓo.

The sentence in deci-0209e2a8 that half of Table 18.7.5.4 is reported and not placed is no longer the behavior. The rest of that decision stands.

Tests: StructuralSizer detailing 305/305. StructuralSynthesizer wall checks, thickness jump, pier checks, openings, detailing, and the ordinary-wall stage passed (1312 plus the opening file 82/82). The opening fixture now uses the first floor of a two-story office, because story 0 has no beam grid.
