---
id: expe-7fba03a9
type: experiment
project: menegroth
parent_id: plan-2dcf41ac
title: 'Story-shell sections: one hogging spike, then neighbor-shape swaps'
node_label: 'Story-shell sections: one hogging spike, then neig'
tags: story-shell,convergence,oscillation,auto-framing
status: active
open_threads: 1
success: 'true'
files: scripts/runners/diag_story_shell_sections.jl@731837c, StructuralSynthesizer/src/analyze/members/members/size_beams_story_shell.jl@731837c
session_id: sess-c2530395
created_at: '2026-11-07T16:21:25.418692+00:00'
updated_at: '2026-11-07T19:03:15.419164+00:00'
---
2026-11-07. Runner scripts/runners/diag_story_shell_sections.jl on the auto-framing floor (54x42 ft, 3x3 bays, one story, steel joists at 24 in, concrete girders), SS_TRACE_SHELL_PASSES=1.

Round 1, strength only (service stays off until sections hold, so it never starts):
- Pass 0 tributary: mostly W6X8.5 / W4X13.
- Pass 1: 118/147 beams change. Several see hogging of hundreds of kip-ft on the light section and jump (one beam W6X9 to W27X84 at Mu- = 493 kip-ft; two groups of 7 to W14X132 at Mu- about 220).
- Pass 2: that hogging is gone (often 0) and those beams walk down (W27X84 to W16X26, W14X132 to W8X48 / W12X45).
- Passes 3-6: no full-vector repeat (every pass is a new section list). About 44-62 beams still change. The movers are adjacent catalog shapes with nearly steady demand, swapping both ways: W8X35 vs W8X40, W10X39 vs W8X35, W10X12 vs W6X12. regions_moving is empty.

Round 2 opens from those sections (the trace prints them as none to W because pass 0 has no previous vector). Service is on because the previous spans are seeded. The hogging spike does not return. Pass 1 changes 42/147, pass 2 changes 50/147, still neighbor swaps (W10X54 vs W12X53, W8X67 vs W10X60) at 15-40 kip-ft.

Not SPD warnings appear on the frame solves inside sizing, clustered once service is on.

Grow-only would freeze the pass-1 overshoot. A keep-heavier-when-a-group-repeats rule would stop the neighbor swaps and would not freeze the W27, because that shape is not repeated. Stopped the run after round-2 pass 2.
