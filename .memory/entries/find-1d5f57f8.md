---
id: find-1d5f57f8
type: finding
project: menegroth
parent_id: find-32732058
title: e0c0 chirality seed is a winding-convention, not mesh geometry
node_label: e0c0 chirality seed is a winding-convention, not m
tags: ''
status: active
open_threads: 0
success: 'null'
files: scripts/runners/sdf_e0c0_mesh_symmetry.jl@a553cd2
session_id: sess-a25c99f8
created_at: '2026-11-23T20:15:58.145106+00:00'
updated_at: '2026-11-23T20:15:58.145106+00:00'
has_child_rationale: Corrects the open question in find-32732058 (mesh vs convention)
  with a geometry-only probe
---
Corrects find-32732058's open question. Geometry-only probe (scripts/runners/sdf_e0c0_mesh_symmetry.jl, NO design run) reflected the star/e0c0 skeleton across y=10:
- vertices: 34, ALL have a mirror partner (0 unmapped)
- faces: 32, ALL map to an existing face as vertex-sets (0 unmapped)
- all 32 faces wound CCW (consistent winding)
- the only 9 'bad edges' are the vertical COLUMN edges (x in {0,12,24}, y in {0,10,20}); spurious because the probe matched vertices by xy only, so stacked ground/floor nodes scramble vertical-edge partners. All plan (horizontal) edges are symmetric.

CONCLUSION: the mesh (vertices/edges/faces) IS reflection-symmetric. The chirality is NOT a mesh asymmetry. It is an ORIENTATION CONVENTION built on the globally-consistent CCW face winding, which is rotation-covariant but NOT reflection-covariant. Under reflection a CCW face maps to a region still stored CCW (not CW), so any winding-derived 'left/right of a directed edge' (e.g. _edge_perside_canonical: 'face traversing the canonical direction has interior on the canonical LEFT') assigns sides rotation-consistently but reflection-FLIPPED.

Evidence it changes magnitudes (not just labels): mirror girders B11 vs B44 reported side-extent profiles that differ in SHAPE ([1.92,0,0,2.5] vs [0,1.92,2.5,0]) on this symmetric mesh — so the reinforcement-axis-aware tributary derivation (cell_edge_tributaries / _extract_width_profile positions, and/or the one-way span-axis choice) is itself handedness-dependent, not merely a left/right label swap. That chiral tributary seeds different first T-beam sections, which the solve amplifies into the ~65% demand gap (B11 Mu~1033 hogging vs B44 Mu~745 sagging).

FIX DIRECTION (per user: fix the mechanism, not force symmetry): derive the reinforcement-axis/span-direction and the side assignment from actual geometry (slab-bearing side, span axis) in a mirror-invariant way, rather than from CCW-winding sign. Candidates to audit: cell_edge_tributaries, _extract_width_profile, _edge_perside_canonical, beam_side_profiles rev-flip.
