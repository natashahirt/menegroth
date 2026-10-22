---
id: plan-dc397b09
type: plan
project: menegroth
parent_id: plan-a4de4826
title: General-shape punching critical sections (non-orthogonal + re-entrant corners)
  via ACI 421.1R-99 App. B
node_label: General-shape punching critical sections (non-orth
tags: ''
status: active
open_threads: 0
success: 'null'
files: corpus/manifests/sources.yml@d03a3c6
session_id: sess-6c133fea
created_at: '2026-10-22T23:28:12.980925+00:00'
updated_at: '2026-10-22T23:28:12.980925+00:00'
---
GOAL: handle unusual/non-right-angle and re-entrant (L-shape inside) corners elegantly, replacing the 3-tag closed-form dispatch (:interior/:edge/:corner) with a general critical-section model.

GROUNDING (now in corpus): aci-421-1r-99 (ACI 421.1R-99, Shear Reinforcement for Slabs), registered this session. Appendix B 'Properties of critical sections of general shape' (p. 421.1R-11..13) + Ch.3:
- Eq.(3.2): vu = Vu/Ac + gamma_vx*Mux*y/Jx + gamma_vy*Muy*x/Jy
- Eq.(3.3): gamma_vx = 1 - 1/(1 + (2/3)*sqrt(ly1/lx1)); gamma_vy symmetric (lx1/ly1).
- Eq.(B-1): Ac = d*sum(l). Eq.(B-2/B-3): Ix = sum (d*l/3)(yi^2+yi*yj+yj^2); Iy = sum (d*l/3)(xi^2+xi*xj+xj^2) over straight segments with endpoints (xi,yi),(xj,yj) in CENTROIDAL coords; Jx~=Ix, Jy~=Iy.
- Eq.(3.4) rectangular interior closed form Jy = d*lx1^3/6 + d*lx1*ly1^2/2 + lx1*d^3/6 -> must be reproduced by the general summation (unit-test oracle).

PLAN (Phase 0 + Phase 1 in one pass, user approved):
Phase 1 (general method, Sizer): segment model of the d/2 critical perimeter clipped to the slab region; compute Ac, centroid (length-weighted), Jx~=Ix, Jy~=Iy via App. B; gamma_v from side projections; vu via Eq.(3.2). Reduce EXACTLY to existing polar_moment_Jc_interior/edge/corner for rectangular interior/edge/corner. Tests: rectangular reduction + 60deg wedge + re-entrant L.
Phase 0 (classifier gate): extend position classification to also compute interior angle + convex/re-entrant side; keep grounded rectangular sections for right-angle convex/edge/interior; route non-orthogonal + re-entrant corners through the general method (or gate if unsupported).

PROCESS: one Julia/Gurobi process at a time; quiet runner; cite source_id+clause+page. NOTE: corpus MCP caches manifest at startup, so aci-421-1r-99 not queryable via corpus.* until server reload; read corpus/text/code_guides/aci/ACI-421.1R-99.txt directly meanwhile.
