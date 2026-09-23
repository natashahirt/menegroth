---
id: note-d0c9dc97
type: note
project: menegroth
parent_id: plan-a4de4826
title: 'Defects 6-8: AISC phi_v=1.0 default, abs(Nu) boosting Vc, foundation abs(Fz)
  and Ps=Pu/1.4'
node_label: D6-8 small defects
tags: safety,aisc,shear,aci,axial,foundations
status: active
open_threads: 0
success: 'null'
files: StructuralSizer/src/members/codes/aisc/checker.jl@d70bce4, StructuralSizer/src/members/codes/aci/beams/checker.jl@d70bce4,
  StructuralSynthesizer/src/analyze/foundations/utils.jl@d70bce4
session_id: sess-acdd572d
created_at: '2026-09-23T01:52:01.340928+00:00'
updated_at: '2026-09-23T01:52:01.340928+00:00'
---
6) AISCChecker default phi_v=1.0; AISC 360-16 G1(a) p.126: 0.90 except G2.1(a).
7) ACI beam checker abs(Nu) always increases Vc (318-11 11.2.1.2); tension (11.2.2.3) never reduces it.
8) support_demands: Pu=abs(Fz) treats uplift as compression; Ps=Pu/1.4 under-estimates D+L when dead dominates (L=0.4D gives 1.31D vs 1.4D).
