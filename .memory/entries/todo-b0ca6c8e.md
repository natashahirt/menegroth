---
id: todo-b0ca6c8e
type: todo
project: menegroth
parent_id: plan-a2a6128f
title: Phase 4 — Performance contracts, baselines, cache stubs
node_label: 'P4: performance architecture'
tags: walls,phase,performance,incremental,warm-state,todo
status: active
open_threads: 0
success: 'null'
files: ''
session_id: sess-370815c5
created_at: '2026-10-21T02:13:03.064634+00:00'
updated_at: '2026-10-21T02:13:03.064634+00:00'
---
Deliver performance CONTRACTS + BASELINE BENCHMARKS + CACHE STUBS only (implementation lands with Phase 5). Define invalidation classes (checks-only / loads-only / stiffness-only / topology) and fingerprint definitions for topology, DOF map, scatter maps, load vectors, solved states, recovery maps. Reuse existing primitives: Asap.solve(model, cases) multi-RHS reuse + sync_asap!(loads_only=true). Benchmark cold gravity, reduced, isolated FEM, and load-case counts separately.
