---
id: todo-7fb14fe9
type: todo
project: menegroth
parent_id: deci-e2344cc5
title: '[crit8 P1 OPEN] Enclosure guard checks wall CENTROID not body — fix before
  Phase 3/6 bridge wires the reduced tier to production'
node_label: '[crit8 P1 OPEN] Enclosure guard checks wall CENTRO'
tags: ''
status: active
open_threads: 0
success: 'null'
files: StructuralSizer/src/walls/lateral_evaluator.jl@2a0b2c4
session_id: sess-c4e1eb1f
created_at: '2026-10-22T13:27:42.010392+00:00'
updated_at: '2026-10-22T13:27:42.010392+00:00'
---
VERIFIED STILL OPEN in code (StructuralSizer/src/walls/lateral_evaluator.jl _plate_encloses_walls L543-558): the guard only tests w.x/w.y (pier centroid), not endpoints centroid±(lw/2)(cosθ,sinθ). crit8 reproducer (scripts/runners/crit8_wall_endpoint_overhang_attack.jl) shows a long X pier (lw=20, θ=0, centroid (0,0)) with ends 5m outside a (5,5) plate passes the guard → solve_wall_layout feasible=TRUE/:optimal at declared worst_util=0.980 while the TRUE drift at wall end (10,0) is 1.180·DL (18% over ASCE 7-22 §12.12.1). NON-PRODUCTION-REACHABLE TODAY (reduced ReducedDiaphragmEvaluator/solve_wall_layout has no production caller; to_wall_line only built by test fixtures per deci-e2344cc5), so not a shipping unconservative design — but it MUST be fixed before the Phase 3/6 production bridge wires the reduced tier in, and before relying on it over the Phase 10 FEM authority. FIX (cheap, per note-be7048ad): bound wall endpoints centroid±(lw/2)(cosθ,sinθ) against the plate in _plate_encloses_walls; lw/θ already carried by WallCandidate. Add a regression mirroring crit8. This belongs to the walls workstream (plan-a2a6128f); surfaced here because it was recorded only as note-be7048ad and omitted from the deferred-follow-ups list todo-6cd02f4a.
