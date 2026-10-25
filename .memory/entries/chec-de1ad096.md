---
id: chec-de1ad096
type: checkpoint
project: menegroth
parent_id: chec-c2096593
title: Stud objective uses the designed count; transverse cover is a hard check
node_label: Stud objective uses the designed count; transverse
tags: composite,studs,objective,edge-distance
status: active
open_threads: 0
success: 'null'
files: ''
session_id: sess-b44b1b21
created_at: '2026-10-25T22:25:30.173924+00:00'
updated_at: '2026-10-25T22:25:30.173924+00:00'
---
The objective now charges the stud count design_shear_anchors selects for the given moment, on each side of the maximum moment. A moment the steel section carries alone adds no stud weight. Takeoff, serialization, and emissions of that count remain Phase 7.

Transverse slab edges are a hard check: AISC 360-22 §I8.2d(b) (PDF p. 183), 1 in. clear lateral cover, with the stud center on the flange. Anchors in formed-deck ribs are exempt. The check applies only when the layout places studs. §I8.2d(c) (8 in. / 10 in.) is the free edge in the shear direction; edge_dist is transverse, and that longitudinal edge is not in the model, so (c) is not applied. The shank inset of d_sa/2 from each flange tip is engineering judgment.

Rp = 0.6 where e_mid-ht is unknown remains Phase 6. Composite beam and per-station tests: 231 pass. Not committed.
