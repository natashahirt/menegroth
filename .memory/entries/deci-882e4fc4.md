---
id: deci-882e4fc4
type: decision
project: menegroth
parent_id: menegroth
title: One-way tributary sweep normal taken from the cell centroid, so the partition
  is reflection-covariant for any mirror
node_label: One-way tributary sweep normal taken from the cell
tags: tributary,one_way,sweep,reflection,covariance,chirality,e0c0
status: active
open_threads: 0
success: 'null'
files: external/Asap/src/Tributary/one_way.jl@ff4c58a, external/Asap/test/tributary/test_tributary_balance.jl@ff4c58a
session_id: sess-22a3ee1a
created_at: '2026-11-25T12:36:50.685919+00:00'
updated_at: '2026-11-25T12:36:50.685919+00:00'
---
## Decision
The one-way partition's sweep normal `n` is no longer the fixed left normal `(-u2, u1)`. `_sweep_normal(u, pts)` points `n` toward the cell's centroid, and falls back to a fixed world anchor (increasing world x, then world y) only when the centroid lies on the span axis. This makes the strip-to-support assignment covariant under reflection across an axis at ANY angle to the span, which is what removes the e0c0 hub chirality.

## Why the centroid, not world-x
The left normal is odd under reflection across an axis parallel to the span `u`: the mirror swaps which support catches a diagonal edge's wedge, but recomputing the left normal does not. Anchoring to world-x fixes only axis-aligned mirrors (a diagonal mirror maps world-x to world-y). The centroid reflects and rotates with the shape, so it is covariant for every mirror. The world anchor remains only as the tie-break for a cell centered on its span axis, where both sweep directions assign the same load anyway.

## Validation
`external/Asap/test/tributary/test_tributary_balance.jl`: 151/151 pass, including a new test reflecting a skewed pentagon spanning along y=x across y=0 (a diagonal mirror) and checking every edge carries the same area. All pre-existing tests (orthogonal grids, skewed parallelogram, openings, clockwise loops) are unchanged, so orthogonal grids are bit-identical.

## Correction of two wrong intermediate diagnoses
While debugging I twice misattributed a failing covariance check:
1. `expe-0ffd519d` said the only handedness was the sweep sign and world-x would fix it. World-x does NOT fix a diagonal mirror.
2. A follow-up blamed a float-tolerance collapse in `unique(t_vals)` changing the strip count. That was wrong: the failing test held the span axis FIXED when reflecting the shape. Reflecting a building reflects its span axis too (`(1,1)` -> `(1,-1)` across y=0). With the axis mirrored along with the geometry, the centroid rule is bit-exact covariant and there is no tolerance bug. The debug prints in one_way.jl were removed.

## Scope
This changes tributary areas only for one-way cells with a diagonal support whose centroid is off the span axis (the star hub). Orthogonal grids are unaffected. The exactness sweep (grid/x1y1, rhombus, star/e0c0) should be re-run to confirm e0c0 is now non-chiral and the grids are unchanged.
