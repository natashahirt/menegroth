---
id: chec-ff9d586f
type: checkpoint
project: menegroth
parent_id: deci-6f2facb5
title: row-f-nlp merge verified and fixed; ready to land on main
node_label: merge ready for main
tags: merge,row-f-nlp,main,cladding,cb,flat-plate
status: active
open_threads: 1
success: 'null'
files: ''
session_id: sess-2258f4af
created_at: '2026-11-19T20:41:12.900700+00:00'
updated_at: '2026-11-19T20:52:58.761121+00:00'
---
The three merge-only failures are fixed and verified in the .merge-worktree checkout (branch merge/row-f-nlp, on top of ab165fc3).

1. Alignment chart Fig. R10.10.1.1: the sway root search is now one bracket (1.001, 40) and nonsway one bracket (0.501, 0.999). (π/k)cot(π/k) is continuous through k=2 and k=2/3, so the old split brackets missed roots near ψAψB≈(12/π)². Regression tests added. This bug predated the merge; the merge produced the ψ=3.82 column that hit it.

2. Cladding on a unitless skeleton: _stories_bottom_up uses Asap.to_meters, the codebase convention.

3. Cb Commentary Eq. C-F1-5: a hogging end that is <=1e-8 of the largest |M| in the segment is roundoff, treated as zero, so the caller keeps Cb=1. The equation is unchanged and uncapped (worked example 5.67). Fixes the deck-floor slanted-beam InexactError (Cb≈10^17).

4. Flat-plate column floor: _raise_column_floors! is now also called after the opening and each per-round section search, not only after the slab commit. A plan size the search grew is a floor. On the pentagon (test_mesh_refinement drape path) this stops column 2 cycling 14/18/20/22 in; it settles at 20 in and every column's checked==installed.

5. Ordinary-wall P-delta fixture sets wall_SDL=0; the softened Y frame is the subject and the default 10 psf façade pushed θ to 0.129. Production default stays 10 psf.

Verification: test_ordinary_wall_stage.jl 701/701 PASS; pentagon design_building settles; Cb unit checks pass. Earlier full baseline on integration abe95f9e was 2481/28 fail/21 err — those failures are flat-plate work already on integration, not merge regressions.

Still OPEN before final sign-off: the flat-plate-on-building-model failures that fail on integration too (pattern-loading tests, exact-first/incremental design-graph equivalence, visualization unverified-column) are NOT addressed here; they belong to commit 764c0ae1. The slab-edge cladding load path for flat plates (deci-3d324e9c) is designed but NOT yet implemented — cladding still rides the zero-stiffness perimeter frame element.

Branch topology: main is an ancestor of integration/2026-11-18 is an ancestor of merge/row-f-nlp (no independent main commits). Plan: ff main to merge/row-f-nlp, Asap submodule at b066f93, then remove .merge-worktree and .baseline-worktree and delete the row-f-nlp/merge branches.
