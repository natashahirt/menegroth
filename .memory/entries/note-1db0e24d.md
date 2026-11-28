---
id: note-1db0e24d
type: note
project: menegroth
parent_id: menegroth
title: C group-7 strength trap FIXED by raising COMPOSITE_RATCHET_MAX 6->24; exposed
  a 2nd ratchet-floor bug on group 1 (deflection corner)
node_label: C group-7 strength trap FIXED by raising COMPOSITE
tags: ''
status: active
open_threads: 0
success: 'null'
files: ''
session_id: sess-783cf641
created_at: '2026-11-28T06:22:35.115645+00:00'
updated_at: '2026-11-28T06:22:35.115645+00:00'
---
FIX APPLIED: size_beams.jl COMPOSITE_RATCHET_MAX 6 -> 24 (+ rationale docstring). VALIDATION (scripts/runners/diag_steel_deck_default.jl nova/e1c1, default catalog, ~42 min): the run now SIZES group 7 and proceeds far past it (multiple member/column iteration passes: 32 -> 56 beam groups, 9 columns, back to 32) where before it died immediately at group 7. So the group-7 composite STRENGTH/stud trap (the original C) is resolved.

NEW FAILURE EXPOSED (distinct from C): after group 7 resolves, e1c1 throws 'No feasible sections for group 1' on DEFLECTION: Mux=281 kN·m, L=5.0 m, Lb=1.25 m; 'Every section fails deflection_ll, deflection_total. Closest is W14X257: deflection_ll 1.75 (L/360, per-element composite inertia), deflection_total 1.55 (L/240)'. A 5 m composite beam failing L/360 that badly with the closest being a heavy SHALLOW W14 means the catalog is restricted to the W14 family.

ROOT CAUSE of the group-1 corner = ratchet flooring monotonicity: _composite_ratchet_floors (size_beams.jl:1217) floors EVERY group (not just the rejected group 7) at its installed section each ratchet step. Group 1's optimistic pass-1 composite search installed a heavy shallow W14X257 (composite inertia makes deflection look OK pre-solve). Then _floor_or_heavier (size_beams.jl:1193) returns {same-shape(floor)} ∪ {obj > obj(floor)} with obj = WEIGHT. For a deflection-governed group floored at W14X257 (257 lb/ft), all the DEEPER-but-LIGHTER sections that would satisfy deflection (e.g. W24X76 = 76 lb/ft) are EXCLUDED because they weigh less than the floor; only heavier W14s / a few very-heavy deep sections remain, so deflection can't be met. The deep-only probe (diag_steel_deck_deep.jl) finished precisely because every group was handed deep sections directly, bypassing the weight-floor.

TWO COUPLED DEFECTS: (1) ratchet floors ALL groups, cornering innocent deflection-governed groups; (2) weight-based floor excludes deeper-lighter sections (wrong monotonicity for deflection control). Note _floor_or_heavier is SHARED with user row-F 'exact' floors (_frame_floor_mask), so any change must not relax the exact-floor path.

FIX OPTIONS for group 1: (A) floor only the REJECTED group(s), not all groups, in _composite_ratchet_floors; (B) for non-exact (ratchet) floors, also admit sections at least as DEEP as the floor so deflection-governed groups can reach depth; (C) both. Each needs a ~40 min e1c1 validation. Builds on note-4fed683d.
