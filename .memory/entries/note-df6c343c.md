---
id: note-df6c343c
type: note
project: menegroth
parent_id: find-cea01648
title: 'Grade-wall lateral is ALSO already wired (3rd ''already done''): _wall_combination_cases
  -> node_foundation_actions -> _grow_wall_plan/_design_wall_rigid per combination'
node_label: Grade-wall lateral is ALSO already wired (3rd 'alr
tags: ''
status: active
open_threads: 0
success: 'null'
files: docs/sizing-map/README.md@19564e1
session_id: sess-d614242d
created_at: '2026-11-26T19:26:07.135971+00:00'
updated_at: '2026-11-26T19:26:07.135971+00:00'
---
User picked 'wire lateral into grade-wall nodes' as the one open non-held item. Recon shows it is already done:

- wall_groups.jl `_wall_combination_cases(struc, pieces, samples, nodes)` calls `node_foundation_actions(struc, nd)` per base node -> builds one WallLineDemand vector per ASCE 7-22 service and strength combination (D, L, roof, each wind case, each QE), NOT just gravity.
- `design_grade_wall_foundations` threads `wall_service`/`wall_strength` into BOTH branches: grade-wall mat (design_footing(MatFoundation) with wall_service/wall_strength) and grade-wall strip (design_footing(StripFooting, legs; service_cases, strength_cases)).
- loads.jl design_footing(::StripFooting, loads) forwards service_cases=loads.wall_service, strength_cases=loads.wall_strength; wall_strip_footing.jl `_grow_wall_plan(legs, plan, service_cases, strength_cases, soil, ...)` grows to fit every combo and `_design_wall_rigid(...; service_cases, strength_cases)` designs steel per combination.
- The `GradeWallNode.pu/ps = nd.reaction[3]` gravity values (wall_groups.jl:426-431) are only the centroid seed, overridden by the per-combination cases — same pattern as columns/mat.

Conclusion: foundation-lateral sign-off item 4 is fully done for spread, column-strip, mat, grade-wall mat, and grade-wall strip. Nothing left to implement in foundations without the HELD inputs (sliding/passive/net-tension, 20% column-load-variation, Winkler per-combo envelopes, §12.13.4). Corrected README item 4 again (removed the stale grade-wall-open claim). No code written.
