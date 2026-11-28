---
id: find-542bde3f
type: finding
project: menegroth
parent_id: find-1d5f57f8
title: e0c0 chirality is EMERGENT in solve/sizing; every geometric input is reflection-symmetric
node_label: 'e0c0 chirality is EMERGENT in solve/sizing; every '
tags: ''
status: active
open_threads: 0
success: 'null'
files: scripts/runners/sdf_e0c0_grillage_symmetry.jl@56f1395
session_id: sess-c1f759e0
created_at: '2026-11-23T21:25:52.819529+00:00'
updated_at: '2026-11-23T21:25:52.819529+00:00'
has_child_rationale: Discriminator run isolates the chirality to the solve/sizing,
  ruling out all geometric inputs
---
Discriminator run (scripts/runners/sdf_e0c0_grillage_symmetry.jl, full e0c0 waffle->one-way-joist design, ~54 min): reflected every horizontal floor analysis frame element across y=10.

RESULT:
- 396 horizontal floor frame elements; 0 whose mirror image is ABSENT => the SOLVED analysis frame (girders + all ribs/joists) is EXACTLY reflection-symmetric.
- Hub girders still split by mirror: NE Beam11 = T18x36-bf42-4#10, SW Beam55 = T18x36-bf42-4#10, NW Beam27 = T20x30-bf20-4#10, SE Beam44 = T20x30-bf20-4#10. NE==SW and NW==SE (180deg pairs) but mirror pairs differ.

CONCLUSION: VERDICT = break is EMERGENT in the solve/sizing, NOT any geometric input. This closes the chain of elimination:
- mesh geometry reflection-symmetric (find-1d5f57f8)
- one-way tributary partition reflection-covariant (sdf_e0c0_trib_covariance.jl, dmax=0)
- span-axis choice covariant (SpanInfo/_orthogonal_frame_axis sin(4a) circular mean; 90deg frame preserved)
- signed moment-field sign covariant (sag_sign=sign(ux) for horizontal beams w/ roll pi/2; invariant under y-reflection)
- flange geometry symmetric (earlier sdf_e0c0_flange_diag: both hf=0.1016m, nearest webs 7.68m)
- full solved frame reflection-symmetric (this run)

So the only remaining mechanism is reflection-odd behaviour in the ITERATIVE DISCRETE SIZING. Note the per-pass logs alternate 'Sized 64 RC T-beam groups' then 'Sized 56 RC T-beam groups' (two beam-sizing sub-phases/groupings) + 9 column groups, and the member loop runs the full 12 outer passes ('Story shell and frame agree' each pass). Leading suspects, in priority order: (1) live-load SKIP PATTERN generation producing reflection-odd sagging/hogging ENVELOPES (would be a true mechanism inconsistency and explains the LARGE section split = sagging- vs hogging-governed, not a tie); (2) member GROUPING signature that separates mirror-congruent beams into different groups sized independently; (3) MIP discrete tie-break / input ordering on demand-equal groups.

USER CONSTRAINT: fix the MECHANISM so symmetry is respected for the right reason (NOT symmetry-stable grouping that would mask a small symmetry break). => the fix should make the per-beam demand envelope / sizing path reflection-covariant, not force mirror beams into one group.

NEXT: dump Mu_pos/Mu_neg/Vu for the four hub girders to decide tie-break (demands mirror-equal) vs mechanism (demands mirror-asymmetric); and read the live-load pattern + demand-envelope code for a reflection-odd ordering/choice.
