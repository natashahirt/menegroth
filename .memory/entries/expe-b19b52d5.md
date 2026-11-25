---
id: expe-b19b52d5
type: experiment
project: menegroth
parent_id: menegroth
title: 'e0c0 still reflection-chiral after the sweep-normal fix: same C2 section split'
node_label: e0c0 still reflection-chiral after the sweep-norma
tags: e0c0,chirality,tributary,sweep,sizing,tie-break
status: active
open_threads: 0
success: 'false'
files: external/Asap/src/Tributary/one_way.jl@ff4c58a, scripts/runners/sdf_e0c0_chirality_check.jl@8447a7d,
  scripts/runners/sdf_oneway_hubcell_mirror.jl@8447a7d
session_id: sess-f69b61ca
created_at: '2026-11-25T16:17:29.168040+00:00'
updated_at: '2026-11-25T16:17:29.168040+00:00'
---
Full star/e0c0 waffle design (max_iterations=12, 1401 s) AFTER the centroid sweep-normal change. Hub girders:

- NE = SW = T20x36-bf44-5#9
- NW = SE = T20x36-bf20-5#9

mirror across x=12: false. mirror across y=10: false. Same C2 signature as before the fix (previously NE=SW=T18x36-bf42, NW=SE=T20x30-bf20). Depth is now shared; the flange width still splits.

The one-way partition of the hub cell itself IS covariant under the y=10 mirror with the new code (sdf_oneway_hubcell_mirror.jl: cell 5 vs its mirror, every edge area and profile_w matches). So the remaining design split is not the single-cell tributary seed. It matches the already-diagnosed bistable sizing tie-break (collinear bar sharing along the two hub diagonals, equal-cost mirror fixed points).

The exactness sweep (cache ON vs OFF) was still running when this was recorded.
