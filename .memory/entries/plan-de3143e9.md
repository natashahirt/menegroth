---
id: plan-de3143e9
type: plan
project: menegroth
parent_id: plan-5d8af001
title: Incremental Engine backlog (Phase 4/5/6 + deferred)
node_label: Incremental Engine backlog (Phase 4/5/6 + deferred
tags: ''
status: active
open_threads: 0
success: 'null'
files: ''
session_id: sess-71f1208d
created_at: '2026-07-15T01:38:20.742713+00:00'
updated_at: '2026-07-15T01:38:20.742713+00:00'
---
Queued work beyond Phase B, captured so chained runs can pick it up. Not in the active graph.

Phase 4 — Levers A+B: decision-bucketed fingerprints; bounding nodes; sweep-aware monotonicity; FEA unit-load superposition basis; content-addressed factorization reuse; adjoint predictor-corrector.
Phase 5 — Batch/persistence/solver reuse: batch scheduler dedup across sweeps; refactor building_scale_analysis.jl + studies _run_method onto the engine; content-addressed on-disk persistence (DVC/S3); persistent warm-started Gurobi / batched assignment MIP.
Phase 6 — Hardening + interactive: per-node source/version hashing + durability tiers; corpus-clause-linked invalidation; metamorphic monotonicity tests; interactive what-if API (reuse api/cache.jl session); speculative precompute; lazy BuildingDesign fields.
Deferred backlog: hash-consed / delta-encoded snapshots; approximate/surrogate tier (ML / reduced-order FEA emulators).
