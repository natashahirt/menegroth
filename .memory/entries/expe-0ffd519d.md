---
id: expe-0ffd519d
type: experiment
project: menegroth
parent_id: menegroth
title: 'e0c0 chirality root cause: one-way sweep normal n=(-u2,u1) is handed, so a
  diagonal support''s wedge flips under reflection'
node_label: 'e0c0 chirality root cause: one-way sweep normal n='
tags: e0c0,chirality,tributary,one_way,sweep,normal,handedness,root-cause
status: active
open_threads: 0
success: 'true'
files: external/Asap/src/Tributary/one_way.jl@c98ac62
session_id: sess-22a3ee1a
created_at: '2026-11-25T12:01:18.382006+00:00'
updated_at: '2026-11-25T12:01:18.382006+00:00'
---
Root cause of the star/e0c0 hub chirality, pinned to one line in the one-way partition (external/Asap/src/Tributary/one_way.jl, _one_way_ccw).

## The bug
The sweep frame is built as:
  u = normalize(axis)            # load direction (axis = (0,+1) for e0c0, +y)
  n = (-u[2], u[1])              # sweep axis = LEFT normal of u
`_strip_stretches` sorts crossings by s = dot(p,u) and pairs them as (left,right) in increasing s, so the lower-s crossing is always the LEFT end. A stretch then goes to the supports at its two ends.

`n` is the LEFT normal of u, a handed choice. Reflecting the plan across an axis parallel to u (e0c0: y=10, parallel to the +y span axis) maps the left normal to the right normal, but the code recomputes the same left normal. So the sweep direction is odd under reflection.

## Why it shows only at the pinwheel hub
For a support perpendicular to the axis (the x=12 spine, u=(0,1) so edge along x, s=const), reflection maps it to a constant-s edge and the assignment is unchanged. For a DIAGONAL support (the hub girder, edge 11 / edge 44) the two ends of a strip have different s, so which end is the 'left' (lower-s) end depends on the sign of n. Reflection flips which support the near-hub wedge lands on:
- cell5 (NE, above hub): near-hub wedge -> DIAGONAL edge 11, fat-at-hub (area 7.5, pw=[1.92,0]).
- mirror cell2 (SE, below hub): near-hub wedge -> the SPINE (edges 66,67); diagonal edge 44 gets ZERO from cell2 and is loaded only by the outboard cell3, fat-at-outer (pw=[0,1.92]).
Result: edge 11 one-sided fat-at-hub, edge 44 one-sided fat-at-outer — not mirror images. The girder loads/flanges are reflection-odd. (Confirmed by the fine-cell probe, expe-622dab5d.)

## Why earlier probes missed it
find-667f5187 and the uniform-stiffness test mirrored across x=12 (perpendicular to the axis) and found the demand path bit-covariant. That reflection leaves the sweep normal's effect even, so it never exposed this. The break is specifically across the axis-parallel mirror (y=10).

## Fix
Make the sweep normal reflection-stable: choose n's sign from geometry rather than always the left normal — e.g. orient n so it points toward increasing world-x (or a fixed world half-plane), independent of winding and of the axis sign. Then the strip->support assignment is reflection-covariant and the hub wedges mirror. Must re-run the exactness sweep (grid/x1y1, rhombus, star/e0c0) since this changes tributary areas on skewed one-way cells. Orthogonal grids are unaffected (no diagonal supports), so grid results should be bit-identical.
