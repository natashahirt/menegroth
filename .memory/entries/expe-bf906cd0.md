---
id: expe-bf906cd0
type: experiment
project: menegroth
parent_id: menegroth
title: 'e0c0 pass-0 probe: chiral seed is geometric, in beam_side_profiles (C2-invariant,
  reflection-broken)'
node_label: 'e0c0 pass-0 probe: chiral seed is geometric, in be'
tags: symmetry,chirality,e0c0,beam_side_profiles,handedness,tributary,waffle
status: active
open_threads: 0
success: 'true'
files: scripts/runners/sdf_e0c0_pass0_handedness.jl@8ea5ed6
session_id: sess-3103885d
created_at: '2026-11-25T03:04:04.140950+00:00'
updated_at: '2026-11-25T03:04:04.140950+00:00'
---
Probe `scripts/runners/sdf_e0c0_pass0_handedness.jl` on star/e0c0, uniform frame stiffness (396 floor els set to one shared section), dumping `beam_side_profiles` (geometry) + `beam_signed_moment_field` for the four hub girders NE(18,15)/NW(6,15)/SE(18,5)/SW(6,5) radiating from hub (12,10).

**[A] beam_side_profiles (pure geometry) — THE decisive result:**
- NE: LEFT ext_m=[1.921,0,0,2.5] @pos[0,0.155,0.155,1.0]; RIGHT=nothing (slab edge)
- SW: LEFT ext_m=[1.921,0,0,2.5] @pos[0,0.155,0.155,1.0]; RIGHT=nothing
- NW: LEFT ext_m=[0,1.921,2.5,0] @pos[0,0.155,0.327,1.0]; RIGHT=nothing
- SE: LEFT ext_m=[0,1.921,2.5,0] @pos[0,0.155,0.327,1.0]; RIGHT=nothing

Signature: **C2-rotation invariant (NE==SW, NW==SE) but reflection BROKEN (NE != SE, NE != NW)**. All four girders report flange on LEFT / slab-edge (nothing) on RIGHT — the CCW face-winding handedness. The chiral seed is thus PURE GEOMETRY, independent of loads/sizing, living in `_edge_perside_canonical` (left/right by CCW traversal) + the chain reorientation/stitching in `beam_side_profiles`. The underlying one-way partition VALUES were already proven covariant (trib_covariance Δ=0, expe prior), so the break is in the LABELING + chain assembly, not the partition.

**[B/C] signed moments under uniform FRAME stiffness:** mirror pairs differ ~76 kN·m (~7% of ~1100 peak): NE vs SE Δ=76.4, NW vs SW Δ=76.3. C2 pairs closer (NE vs SW ~11). NOTE: confounded — only frame elements were uniformized, slab shells were NOT, and the max_iterations=1 design did not converge; so this moment number is not a clean load-covariance test (the geometry result [A] is the clean one).

**Operational note:** max_iterations=1 BACKFIRED — took ~36 min (longer than the converging 12-iter run ~21 min) because non-convergence triggers extra repair loops. Use default iters next time.

**Conclusion:** Confirms the single-root-cause theory. Fix target = make the side assignment in `beam_side_profiles`/`_edge_perside_canonical` reflection-covariant: derive left/right (and the one-sided flange side + chain s=0 orientation) from a reflection-stable geometric reference rather than CCW winding.
