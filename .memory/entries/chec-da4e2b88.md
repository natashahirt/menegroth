---
id: chec-da4e2b88
type: checkpoint
project: menegroth
parent_id: deci-0b378fd3
title: 'Story-shell beams settle: member span, upward-only picks, non-degenerate mesh'
node_label: 'Story-shell beams settle: member span, upward-only'
tags: story-shell,beams,convergence,mesh,aisc
status: active
open_threads: 0
success: 'null'
files: StructuralSizer/src/slabs/codes/concrete/panel_shell_beams.jl@d9c4c84, StructuralSizer/test/slabs/test_story_shell.jl@d9c4c84,
  StructuralSizer/test/runtests.jl@d9c4c84, StructuralSynthesizer/src/analyze/members/members/demands.jl@d9c4c84,
  StructuralSynthesizer/src/analyze/members/members/size_beams.jl@d9c4c84, StructuralSynthesizer/src/analyze/members/members/size_beams_story_shell.jl@d9c4c84,
  StructuralSynthesizer/src/workflow/member_iteration.jl@d9c4c84, StructuralSynthesizer/test/analyze/test_story_shell_beams.jl@d9c4c84,
  StructuralSynthesizer/test/analyze/test_section_floor.jl@d9c4c84, StructuralSynthesizer/test/runtests.jl@d9c4c84
session_id: sess-f3377fcc
created_at: '2026-11-08T00:30:59.391201+00:00'
updated_at: '2026-11-08T00:30:59.391201+00:00'
---
2026-11-07. Closes the first two items of deci-0b378fd3 (convergence diagnosis, SPD warning). The 3×3 auto-framing floor settles in two story-shell rounds.

Group length is the longest member, not the sum of the group. A seven-joist group was checked at 126 ft, which inflated Lc = K·L (AISC 360-16 §E2) and the hogging unbraced length. Joists that had locked at W8×35–W10×39 drop to W4×13–W10×12.

Steel discrete story-shell sizing then takes two free passes, then only a heavier section, then one trim. The trim is kept only when it converges lighter by the sizing objective. Equal-weight shapes do not replace a section that still passes. Section identity compares arrays element by element, so a re-built column with the same bars counts as unchanged.

The stiffness warning was zero-area shell triangles: a beam-line point one ulp off the outline became a flat triangle. Every constrained-line point that lies on an outline edge is now a mesh corner.

The same commit carries the story-shell design rounds, per-level beam passes, and concrete columns for a beamless two-way floor, which this loop calls. Next is walls as line supports (deci-0b378fd3 item 3).
