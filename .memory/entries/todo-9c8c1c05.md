---
id: todo-9c8c1c05
type: todo
project: menegroth
parent_id: deci-592222ad
title: 'Follow-up: ground centroid-shift eccentricity e=c1/2-cAB vs spSlab e=(b1-cAB)-c1/2
  (differ by d/2)'
node_label: 'Follow-up: ground centroid-shift eccentricity e=c1'
tags: ''
status: active
open_threads: 0
success: 'null'
files: StructuralSizer/src/codes/aci/punching.jl@8484f17, StructuralSizer/src/slabs/codes/concrete/flat_plate/design/checks.jl@e1aa19a
session_id: sess-7e92aa78
created_at: '2026-10-22T17:38:48.108326+00:00'
updated_at: '2026-10-22T17:38:48.108326+00:00'
---
Critic [P1] (run-9091881e, task-840c3531): the edge/corner centroid-shift eccentricity in punching.jl (lines ~586, 611-612) and checks.jl (~144, 149) uses e=c1/2-cAB, which disagrees with the cited spSlab/StructurePoint p.42 worked example (e=(b1-cAB)-c1/2) by exactly d/2. The code value is CONSERVATIVE (spSlab e=4.89in -> vu=137.2 psi; code e=2.01in -> vu~147 psi), so it is NOT unsafe and was deliberately NOT changed in the Defect 4 fix cycle. ACTION: verify against PCA EB712 Fig.16-13 / spSlab edge example via corpus.* tools; if the standard formula genuinely differs, align ONLY with corpus grounding (it reduces conservatism, so must be well-grounded) AND fix the sign-fragility when cAB>c1/2 or under reversed-sign transfer (the max(|M|-Vu*e,0) guard). Separate grounded task, not bundled with production wiring.
