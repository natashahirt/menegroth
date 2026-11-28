---
id: chec-b8ddfab2
type: checkpoint
project: menegroth
parent_id: menegroth
title: 'Ribbed-floor crash fixes: story-membership for deflection + degenerate-axis
  punching'
node_label: 'Ribbed-floor crash fixes: story-membership for def'
tags: ribbed-floors,deflection,punching,aci,crash-fix
status: active
open_threads: 0
success: 'null'
files: StructuralSynthesizer/src/analyze/members/members/rib_deflection.jl@88d9fb8,
  StructuralSizer/src/codes/aci/punching/general_geometry.jl@88d9fb8, StructuralSizer/test/slabs/test_general_critical_section.jl@88d9fb8
session_id: sess-1a327094
created_at: '2026-11-19T22:51:27.154857+00:00'
updated_at: '2026-11-19T22:51:27.154857+00:00'
---
Dense-waffle grid/x1y1 end-to-end now runs to completion (~20 min, 1219s) and writes the scene; no more crashes.

Two crash fixes:
1. `_story_service_elements` (rib_deflection.jl) now finds a story's rib/level beams through their framing level's slab (`_slab_story` + `level_group_ids`), with `edge_story` kept only as the girder fallback. The previous `story.edges`/`edge_story` membership returned empty at the pre-loop depth screen, because interior grillage rib edges added after the last geometry-cache rebuild have no `edge_stories` entry (default story 0), and at that screen only the ribs carry a concrete section. Threw `story 1 has no concrete beam elements`.
2. `punching_stress_general` (StructuralSizer general_geometry.jl) sets the eccentric-shear stress term to 0 for a degenerate principal axis (l2<=1e-6*lmax => J1~0, or l1<=1e-6*lmax => J2~0): the moment about a collinear/one-sided critical section transfers by flexure (gamma_f=1), not eccentric shear. ACI 318-11 §11.11.7.1 / ACI 421.1R-99. Avoids 0/0=NaN at corner-column solid heads. Unit test added in test_general_critical_section.jl.

OPEN (design-margin, not crashes): qualification still pass=false. (a) Ribbed story 1 fails service deflection at ~1.5x the l/480 sensitive limit, and NO available stem (up to 24 in stem / 30 in total, l=12 m bays) satisfies it; the Ie ratchet reports converged=false in 4 passes. (b) Beam 138 is_feasible ratio 1.51 (a girder). Need user direction: investigate deflection over-prediction / non-convergence vs accept margin, and girder sizing.
