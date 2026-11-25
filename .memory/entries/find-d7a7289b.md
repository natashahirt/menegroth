---
id: find-d7a7289b
type: finding
project: menegroth
parent_id: chec-14dd6253
title: e0c0 chirality carrier = reflection-asymmetric hub cell-edge adjacency (axis/partition/sign
  all covariant)
node_label: e0c0 chirality carrier = reflection-asymmetric hub
tags: symmetry,chirality,e0c0,tributary,one-way,mesh,cell-adjacency,root-cause,hub
status: active
open_threads: 0
success: 'null'
files: scripts/runners/sdf_e0c0_finecell_covariance.jl@cd4e884, scripts/runners/sdf_oneway_axis_sign.jl@cd4e884
session_id: sess-0ddbe93a
created_at: '2026-11-25T04:29:07.248455+00:00'
updated_at: '2026-11-25T04:29:07.248455+00:00'
---
Definitive localization via fast probes (prepare!+stage1 ~3min; pure-geometry ~1min). Supersedes the retracted straight-skeleton claim (expe-5620d71e/chec-14dd6253).

**Elimination (all COVARIANT, NOT the carrier):** mesh vertex/face coords (find-1d5f57f8); FEA given mirrored sections; one-way partition algorithm given cell+axis (trib_covariance Delta=0); the per-cell span axis field (ALL 32 e0c0 cells store axis=(0,1) uniform; 16/16 mirror pairs Delta=0); axis-SIGN (sdf_oneway_axis_sign: get_tributary_polygons axis=(0,1) vs (0,-1) Delta=0 on 3 asym polys); left/right label (uniform canL); coarse straight-skeleton geometry.

**THE CARRIER (fine-cell probe sdf_e0c0_finecell_covariance):** mirror hub girder edges draw tributary from NON-mirror cells.
- NE edge 11 hub->(12.93,10.77): bounded by cell 5 centroid (13.6,12.7); profile_w=[1.921,0] (peak at hub s=0, d-max at s=0.205).
- SE edge 44 hub->(12.93,9.23) = exact y=10 mirror of edge 11, hub invariant (s=0 both): bounded by cell 3 (16.4,7.7); profile_w=[0,1.921] (d-max at s=0.795).
- cell 5's TRUE y=10 mirror is cell 2 (13.6,7.3), NOT cell 3. If edge 44 were bounded by cell 2 the profile would peak at s=0.205 (covariant). Peaks 0.205 vs 0.795 sum to 1 => exact s->1-s reversal = the chirality.

**Conclusion:** the CELL DECOMPOSITION / which cell each radiating hub edge belongs to is reflection-ASYMMETRIC near the hub, even though the vertex/face SET mirrors. Refines find-1d5f57f8 (coords mirror; edge->face adjacency/cell assignment near hub does not). Carrier is upstream in skeleton/cell construction (most central geometry) — NOT beam_side_profiles, NOT the partition, NOT the axis.

**Fast harness wins:** prepare!+pipeline stage[1] gives the meshed+tributary struc in ~3min (vs ~31min full design); pure-geometry covariance probes ~1min. Use these to verify any fix.

**Next (cheap, ~3min):** dump full vertex loops of cells 2,3,5 and the hub-(12,10) neighborhood to see WHY edge 44 belongs to cell 3 not cell 2 (tie-break in face/cell construction?). Then decide fix. Do NOT modify skeleton/cell construction without understanding the hub tessellation.
