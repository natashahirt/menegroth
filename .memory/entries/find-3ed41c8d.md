---
id: find-3ed41c8d
type: finding
project: menegroth
parent_id: menegroth
title: 'Confirmed: flat-plate member-stage non-convergence is pre-merge (78940b2a:
  8 failed), not merge/instrumentation'
node_label: 'Confirmed: flat-plate member-stage non-convergence'
tags: flat-plate,non-convergence,pre-merge,confirmed,s2-floor,s2-commit
status: active
open_threads: 0
success: 'null'
files: ''
session_id: sess-b670e7d9
created_at: '2026-11-20T15:10:16.505390+00:00'
updated_at: '2026-11-20T15:10:16.505390+00:00'
---
Ran `test_design_graph_equivalence.jl` on pre-merge commit **78940b2a** in an isolated worktree (Asap symlinked to main, since the convergence logic is entirely in StructuralSynthesizer graph_builder.jl). Result: **51 passed, 8 failed, 0 errored** (1466s). Same failures as post-merge:
- `flat-plate DDM (reconcile columns, foundations on)`: 5 failed (16m33s) — Mode 1 (uniform-off, L6 two-sided fit shrink/regrow oscillation).
- `flat-plate DDM + uniform_column_sizing=:per_story (harmonize runs)`: 3 failed (37s) — Mode 2 (harmonize promotes group to max, exact-equality staleness re-stages peers).

Combined with archaeology (settling loop + 48-round guard + these tests all introduced together in 24637749, an ancestor of 78940b2a), this **definitively confirms** the non-convergence predates the merge (78940b2a) and the sizing-probe instrumentation (e52336c7). It is the in-flight s2-floor/s2-commit work. Supersedes the caveat in find-ef39585b.

Direction shift (user): stop patching; redesign the member stage as a proper speed-optimized algorithm. Reframe = coupled fixed point (A: sizes→demands via FEA, expensive; B: demands→sizes via ACI checks, cheap). Current loop is undamped Picard with exact-equality stop. Proposed: decouple via explicit punching ownership (slab owns punching via studs/thickening at fixed columns → clean DAG analyze→size columns monotone→size slabs), converge on DEMAND tolerance not size equality, parallel per-member inner design, and attach speed.md #1 (fixed mesh)/#2 (Woodbury)/#3 (predict-confirm) to the isolated analysis map. Open fork awaiting user: punching ownership (grow shared column vs slab reinforce/thicken).
