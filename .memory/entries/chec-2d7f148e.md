---
id: chec-2d7f148e
type: checkpoint
project: menegroth
parent_id: plan-d0c5bff3
title: 'Phase 5d: stiffness token witnesses wall shell geometry (loads_only cannot
  go stale)'
node_label: 5d token geometry
tags: ''
status: active
open_threads: 0
success: 'null'
files: ''
session_id: sess-03d8a2aa
created_at: '2026-10-23T01:28:44.712966+00:00'
updated_at: '2026-10-23T01:28:44.712966+00:00'
has_child_rationale: Closes the 5d stiffness-token slice
---
Coordinator run run-50f0d6ff (low rigor). Engineer + grok-4.7-high-fast critic, both PASS. File: StructuralSynthesizer/src/analyze/asap/utils.jl, `_stiffness_token` only.

## Change
The shell loop previously hashed only `(:shell, thickness, E, ν)` and, worse, read `sh.section`. Wall shells are `Asap.ShellTri3`, which stores thickness/E/ν as direct fields and has no `.section` (external/Asap/src/Elements/shell/shell.jl). That loop threw FieldError on any wall shell, so wall geometry never entered the token and `loads_only` could not even see a wall. The token now hashes, in the shell's own node order, each node's stripped (x,y,z) plus thickness, E, and ν read off the element. Non-ShellTri3 folds typeof(sh). Frame loop, eccentricity map, `_loads_only_sync`, and `sync_asap!` unchanged.

## Verification
Unchanged model stable across 20 calls and across a remesh with new node objects. Moving a plan endpoint, moving a node in place, doubling thickness, and swapping two nodes (same coordinates, different order) each change the token; restoring returns the original. `_loads_only_sync` is true before an in-place node move and false after (SS_SYNC_LOADS_ONLY unset). Frame-only model stable; moving a frame end node still changes the token. Against HEAD only the shell-loop body differs.

## Residual (not fixed)
`local_K` also depends on κ, shear_stab, and drilling_scale. Those are not in the token. The wall mesher leaves them at ShellTri3 defaults, so they do not bite today. Do not expand unless a later path sets them per wall.

## Deferred to Phase 6
Batching lateral right-hand sides via `Asap.solve(model, cases)`, and keeping P-delta and accidental torsion as their own solves. There are no lateral cases to batch until wind/seismic exist. The Phase 4 stub `apply_wall_cache_class` still throws; this slice did not call it.

Not committed.
