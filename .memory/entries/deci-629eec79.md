---
id: deci-629eec79
type: decision
project: menegroth
parent_id: plan-882e912b
title: 'Displacement route: critical section at the base of a continuous line; δu
  at the center of mass of the line''s top floor'
node_label: critical section and δu
tags: walls,aci-318-19,18.10.6.2,special-wall,decision
status: active
open_threads: 0
success: 'null'
files: ''
session_id: sess-facff8fd
created_at: '2026-11-11T17:20:05.438323+00:00'
updated_at: '2026-11-11T17:20:05.438323+00:00'
---
User decision 2026-11-11.

Critical section (§18.10.6.2, corpus: aci-318-19, page 326): each wall line that reaches story 0 with no opening on any story is designed to have its single critical section at its base. Other lines state none and stay on §18.10.6.3. The route still needs hwcs/ℓw ≥ 2.0; otherwise it is the stress route.

δu: the ELF design displacement (ElfCase.design_m) at the center of mass of the floor at the top of that wall line. Not the displacement at the wall's own plan location.

Still to confirm before coding: which ELF cases feed δu (drift-purpose cases along the pier's axis, largest over the torsion cases, is the proposed reading), and that c is then computed at the factored axial of the earthquake combination consistent with that displacement (R18.10.6.2).

Correction to plan-882e912b step 3: §18.10.6.4(i)'s 12 in. limit is the vertical spacing of the transverse reinforcement (hoop corners or crossties with seismic hooks at each end) that laterally supports web vertical bars, not the spacing of the web bars. It waits with the boundary bars. Only the (k) 6 in. gap is measurable from today's placed bars.
