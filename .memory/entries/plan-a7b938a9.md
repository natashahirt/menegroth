---
id: plan-a7b938a9
type: plan
project: menegroth
parent_id: plan-2d4158d0
title: 'Flat-plate joint search: choose slab thickness, column sizes, and studs together
  by embodied carbon'
node_label: Joint thickness/column/stud search
tags: flat-plate,punching,search,carbon,shear-studs,iteration,ratchet
status: active
open_threads: 0
success: 'null'
files: docs/flat-plate-joint-sizing-plan.md@6fd630b
session_id: sess-304ba08b
created_at: '2026-11-11T17:43:08.386571+00:00'
updated_at: '2026-11-11T17:43:08.386571+00:00'
has_child_rationale: User asked to zoom out on the sizing pipeline after v7 showed
  path-dependent sizes (11.5/11.5/13.0/10.5 in slabs; 30/30/18/14 in corners).
invalidates: plan-159c1800
---
Design note: docs/flat-plate-joint-sizing-plan.md.

User decisions (2026-11-11): objective embodied carbon by default, switchable via opts.objective; studs are a third option, pure carbon first to see whether studs win everywhere; a switch to turn studs off (joint_studs) and a weight on the stud term (stud_weight); pick the lowest objective; floors top-down, each floor on its own with the column above as a minimum, no look-ahead; one re-scan per floor after the member stage grows columns (the existing stale-slab redesign, with a stored per-column floor); 1% tie rule preferring the floor above. User did not want slab 3 rerun with tracing.

Algorithm: Phase A as now gives h_A; reset columns to c_min = max(P-M, column above, external floor); one analysis; scan h upward with scaled demands (thickness_jump.jl); per column choose the cheapest of smallest bare-passing size and smallest stud-passing size; stop when slab term alone exceeds best; verify with a real analysis; rescan on failure with columns not below the failed sizes.

Findings: no stud layout exists for wall reactions (design_shear_studs is column-only); wall studs need code sign-off, so walls are thickness-only for now. v7's design_trace has zero events (tracing was off). v7 summary reports all_checks_pass=true with critical ratio 1.075 (Wall 35 longitudinal ratio, story 2) - unresolved inconsistency.

Supersedes plan-159c1800's lexicographic objective and the Nov 9 deferral in deci-44674e99.
