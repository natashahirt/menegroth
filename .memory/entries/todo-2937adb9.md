---
id: todo-2937adb9
type: todo
project: menegroth
parent_id: plan-67a1e4f7
title: 'G1 — Deep foundations: piles, drilled piers/caissons, pile caps'
node_label: 'G1: Deep foundations'
tags: todo,foundations,piles,caissons,pile-cap,aci,phase-g
status: active
open_threads: 0
success: 'null'
files: ''
session_id: sess-92359b08
created_at: '2026-07-15T02:25:31.984697+00:00'
updated_at: '2026-07-15T02:25:31.984697+00:00'
has_child_rationale: Types exist in foundations/types.jl but no design; required for
  high-rise/hospital
---
# G1 — Deep foundations

Pile / drilled-pier / caisson foundations and pile caps. Types exist in `foundations/types.jl` but have **no design path**. Needed wherever bearing or settlement rules out shallow foundations (high-rise, hospital, poor soils).

**Build:** structural pile design (axial + lateral + moment per ACI 318 / concrete or AISC / steel piles), **pile-cap design** (rigid-cap reaction distribution + strut-and-tie for the cap, ACI 318-11 Appendix A / 318-19 Ch. 23), pile-group effects. **Oracle:** corpus `sp-pile-reaction-distribution` (CRSI rigid-cap method vs spMats FEA). **Canon gap:** geotechnical pile capacity (skin friction / end bearing) has no soil standard in corpus — flag for ingestion or treat geotech capacity as an input. **Couples to:** G4 (geotech), column reactions from `size_foundations!`.
