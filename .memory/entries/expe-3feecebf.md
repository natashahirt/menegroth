---
id: expe-3feecebf
type: experiment
project: menegroth
parent_id: find-48ce26cc
title: 'e0c0 chirality fix attempt #1 (reflection-covariant settle tie-breaks) does
  NOT fix the symptom: hub girders still NE=SW=T18x36, NW=SE=T20x30. Carrier is upstream
  in the main member-iteration MIP/collinear-feedback, reconciled as held=true'
node_label: 'e0c0 chirality fix attempt #1 (reflection-covarian'
tags: ''
status: active
open_threads: 0
success: 'null'
files: StructuralSynthesizer/src/workflow/check_settle.jl@aa144bf
session_id: sess-aef95a15
created_at: '2026-11-24T02:20:12.339436+00:00'
updated_at: '2026-11-24T02:20:12.339436+00:00'
---
WHAT WAS CHANGED (check_settle.jl):
- _pick_group_section now breaks EQUAL-cost ties by a canonical, member-independent section key (_section_tiebreak_key = section name) instead of encounter/state order. This makes the per-group mix reflection-covariant (symmetric groups -> identical sections).
- Both settle sites (_check_settle! and _check_shell_settle!) now PREFER the per-group cheapest-passing MIX over a single _cheapest_index-chosen cycle state (the single-state pick breaks mirror-image ties by state index = x-odd). Fall back to cheapest single state only if the mix fails its coupled re-check.
- Unit tests analyze/test_check_settle.jl: 15/15 PASS (symbols :a/:b -> keys 'a'/'b', :a still wins as before).

RESULT (full e0c0 waffle design, restore=false, max_iterations=12, ~1000s):
  NE  T18x36-bf42-4#10
  NW  T20x30-bf20-4#10
  SE  T20x30-bf20-4#10
  SW  T18x36-bf42-4#10
  => STILL chiral (C2 only). Fix did not change the outcome.

WHY: confirms note-50892991 / note-ab703058. The converged run settles via _reconcile_shell_frame! ('Story shell and frame agree on the installed sections', held=true) and never relies on the cycle tie-break paths that were fixed. The asymmetry is baked in by the MAIN member-iteration size_beams! (MIP) and locked by collinear bar-sharing.

KEY GEOMETRY INSIGHT (explains the C2 signature exactly): the four hub girders lie on TWO straight diagonals through the hub (12,10): line1 = (6,5)-(12,10)-(18,15) = {SW,NE}; line2 = (6,15)-(12,10)-(18,5) = {NW,SE}. Both diagonals have direction slope +-5/6 and are collinear chains. _share_collinear_rib_bars! propagates the MAX section along each diagonal, so {NE,SW} share one section and {NW,SE} share another -> the C2 pairing is collinear-sharing, NOT a coincidence. Mirror across x=12 swaps the two diagonals; they get different sections (T18x36 vs T20x30) only because their demands differ (~9% split) via section<->stiffness feedback. The two diagonals are mirror images, cross at the hub, and under uniform stiffness carry EXACTLY equal demand (uniform-stiffness test Delta=0). So the seed is a discrete x-odd choice in the MAIN MIP/collinear path at some mid pass that first hands the two mirror diagonals different-but-equal-cost sections.

NEXT: the fix must target the main member-iteration sizing (size_beams! MIP tie-break and/or _share_collinear_rib_bars! ordering), not the settle fallback. Decide with user whether to KEEP the settle fix (run full suite first) and hunt the upstream seed, or revert.

Artifacts: scripts/runners/sdf_e0c0_chirality_check.jl (verification runner); logs/e0c0_chirality_check.out.
