---
id: expe-622dab5d
type: experiment
project: menegroth
parent_id: menegroth
title: e0c0 chirality seed FOUND in one-way tributary partition across y=10 (not a
  pure bistable tie-break)
node_label: e0c0 chirality seed FOUND in one-way tributary par
tags: e0c0,chirality,tributary,partition,reflection,one_way,hub,girder
status: active
open_threads: 0
success: 'true'
files: scripts/runners/sdf_e0c0_finecell_covariance.jl@49a1132
session_id: sess-fa42a4c1
created_at: '2026-11-25T05:19:51.926291+00:00'
updated_at: '2026-11-25T05:19:51.926291+00:00'
---
Fresh fine-cell probe (prepare!+stage1 only, ~4min) on star/e0c0 pins the chirality seed to the **one-way weighted partition** (`get_tributary_polygons`), contradicting the earlier conclusion that it was purely a downstream bistable tie-break.

## Decisive evidence (per-cell edge tributary dump at the pinwheel hub (12,10))

Hub girder first segments: **edge 11** = NE girder (hub->(12.927,10.773)), **edge 44** = SE girder (hub->(12.927,9.227)). Edge 11 and edge 44 are **y=10 mirror** edges. Adjacent cells: edge 11 -> cells [4,5]; edge 44 -> cells [2,3]. Mirror cell pairs across y=10: cell5(NE inboard)<->cell2(SE inboard); cell4(NE outboard)<->cell3(SE outboard) (centroids mirror, |Δrefl axis|=0 for all 16 pairs; mesh IS reflection-symmetric).

Partition result:
- cell5 assigns its near-hub wedge to the **DIAGONAL** edge 11 (area 7.5, pw=[1.92,0] fat-at-hub) + edge 101.
- mirror cell2 assigns ITS near-hub wedge to the **x=12 SPINE** edges 66,67 (pw=[2.5,0],[0,1.92]) and gives its diagonal edge 44 **ZERO**.
- edge 44's tributary instead comes from the OUTBOARD cell3 (pw=[0,1.92] fat-at-outer).

So edge 11 ends one-sided fat-at-hub; edge 44 ends one-sided fat-at-outer. These are NOT mirror images => **reflection-odd seed in the partition**.

## Mechanism
The one-way partition's slab-strip -> support-edge assignment is handed w.r.t. the +y sweep (globally CCW winding is rotation- but not reflection-covariant). On an orthogonal grid supports are symmetric so it never shows. At the pinwheel hub a DIAGONAL support competes with the x=12 SPINE: for the +y cell5 the diagonal is the strip's lower support and wins the near-hub wedge; for mirror -y cell2 the diagonal is the strip's upper support and LOSES to the spine. Opposite choice => chiral girder loads/flanges.

## Reconciliation with prior findings
`find-667f5187` ('bistable tie-break, demand path covariant to the bit') and the PART-1 uniform-stiffness test both mirrored across **x=12** (NE<->NW) and found it clean. Neither isolated the **y=10** load symmetry (NE vs SE) — exactly where the partition breaks. No real contradiction: the x=12 path is covariant; the y=10 seed in the partition was simply never probed. The design is rotation-symmetric (NE=SW, NW=SE) but both reflections broken.

## Implication for the fix
The planned option 'A' (two-sided flange aggregation in profiles.jl `_edge_perside_canonical`) does NOT fix this: aggregating both adjacent cells per edge still leaves edge 11 fat-at-hub and edge 44 fat-at-outer (the other cell contributes nothing to each). The principled fix must make the one-way partition's strip->support assignment reflection-covariant in StructuralSizer/Asap `get_tributary_polygons` (or derive girder demand from a reflection-stable quantity). This is a deeper, corpus/validation-touching change than 'A'.

NOTE: the probe's girder_edges stitch section is buggy (wrong collinear edge pick, never selected edges 11/44) — disregard its printed TOTAL-extent verdict; the per-cell dump above is the authoritative evidence.
