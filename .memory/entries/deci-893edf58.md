---
id: deci-893edf58
type: decision
project: menegroth
parent_id: todo-a8b3ef17
title: Launch Phase 1 wall-audit coordinator run (one-graph-per-phase model)
node_label: launch P1 coordinator
tags: walls,coordinator,phase1,audit,launch,decision
status: active
open_threads: 1
success: 'null'
files: ''
session_id: sess-f764d548
created_at: '2026-10-21T02:15:30.070961+00:00'
updated_at: '2026-10-21T10:30:27.875261+00:00'
---
Approved execution model: the complete-wall-system plan (plan-a2a6128f) runs as ONE coordinator graph PER PHASE (12 runs), never a single mega-graph — safety-critical code with HARD-STOP corpus gates and mandatory equivalence/non-regression gates. Phase boundaries are human/corpus checkpoints, not auto-advanced edges. Full per-phase template + Phase 1 graph recorded in .cursor/plans/complete-wall-system_76ac3f3b.plan.md under 'Coordinator execution model'.

Phase 1 graph (rigor=high, max_extensions=5): Wave0 explore (audit walls/ for VERIFY markers, hardcoded fy=60_000 in checker.jl, pinv singular-K fallback, drift + reduced-vs-FEM semantics; carve disjoint writes). Wave1 three parallel engineers on disjoint files — checker.jl (material-driven fy/λ), lateral_evaluator.jl (multistory interstory drift + accidental-eccentricity-consistent story_drift_sensitivity), fem_evaluator.jl (fail-closed singular K + reduced-vs-FEM semantics, withhold upper-story checks). Wave2 reviewer+critic+tester. Wave3 memory. Open carve: singular-K may straddle lateral_evaluator/fem_evaluator — explore assigns both to eng-fem if so. Checkers: reviewer+critic+tester; skipped bugbot (small diff) + security-review (no untrusted-input surface).
