---
id: todo-a8b3ef17
type: todo
project: menegroth
parent_id: plan-a2a6128f
title: Phase 1 — Audit + fail-safe the existing wall library
node_label: 'P1: audit + harden'
tags: walls,phase,audit,safety,todo
status: active
open_threads: 1
success: 'null'
files: ''
session_id: sess-aff20eff
created_at: '2026-10-21T02:12:49.711067+00:00'
updated_at: '2026-10-21T02:15:30.070961+00:00'
---
Fix known safety gaps: material-driven fy/λ in `check_wall_inplane_shear` (currently hardcoded Grade-60), true multistory interstory drift in `lateral_evaluator.jl`, accidental-eccentricity-consistent `story_drift_sensitivity`, fail-closed singular K (replace pinv fallback), reconcile reduced vs FEM result semantics in `fem_evaluator.jl` (withhold upper-story wall-force checks until validated). Inventory and resolve stale status comments + every VERIFY / engineering-judgment marker across `StructuralSizer/src/walls/`, tests, reports, docs. Self-contained; unblocks all later phases.
