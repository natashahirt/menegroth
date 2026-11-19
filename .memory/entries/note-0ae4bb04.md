---
id: note-0ae4bb04
type: note
project: menegroth
parent_id: chec-ff9d586f
title: 'Merge landing deferred: live rib-floor work occupies the main checkout'
node_label: landing deferred
tags: merge,row-f-nlp,blocked,ribbed-floors,worktree
status: active
open_threads: 0
success: 'null'
files: ''
session_id: sess-2258f4af
created_at: '2026-11-19T20:52:58.761121+00:00'
updated_at: '2026-11-19T20:52:58.761121+00:00'
---
Landing merge/row-f-nlp onto main is DEFERRED by user decision (we were out of budget; wrapping up).

Reason: the main checkout (Dropbox working dir) is on branch integration/2026-11-18 and holds 54 uncommitted files from a separate, active ribbed-floor / joist-systems session (new rib_sets.jl, rib_deflection.jl, rib_story.jl, docs/sizing-map/ribbed-floors.md, joist diagnostics, T-beam checker edits; the sdf_joist_systems.jl sweeps). 22 of those files overlap files the row-f-nlp merge changed (demands.jl, size_columns.jl, member_iteration.jl, check_settle.jl, t_checker.jl, subdivision.jl, etc.). Switching/merging the live tree now would collide with that work, so we did not touch it.

State preserved: all merge work is committed on branch merge/row-f-nlp at b7e2af13 (three fixes verified: ordinary-wall 701/701, pentagon settles, Cb guarded). The ref lives in .git; safe regardless of worktrees. Branch topology unchanged: main is ancestor of integration/2026-11-18 is ancestor of merge/row-f-nlp (no independent main commits). Asap submodule target b066f93.

Cleanup done: .baseline-worktree removed. .merge-worktree kept (holds the merge/row-f-nlp checkout) until landing.

TO LAND LATER: once the rib session commits its 54 files, fast-forward main (and/or integration/2026-11-18) to merge/row-f-nlp, confirm Asap submodule at b066f93, run the two suites once more, then remove .merge-worktree and delete the row-f-nlp and merge/row-f-nlp branches.

STILL OPEN (pre-existing, not merge regressions): flat-plate-on-building-model failures that also fail on integration abe95f9e (pattern-loading tests, design-graph exact-first/incremental equivalence, visualization unverified-column) from commit 764c0ae1; and the slab-edge cladding load path for flat plates (deci-3d324e9c) is designed but not implemented.
