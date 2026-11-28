---
id: chec-972eecb5
type: checkpoint
project: menegroth
parent_id: deci-1b3809c2
title: The building casts solid heads from rib bays and grows them
node_label: building grows bay heads
tags: solid-head,grillage,building
status: active
open_threads: 0
success: 'null'
files: StructuralSynthesizer/src/building_types/framing.jl@e61b36c, StructuralSynthesizer/src/analyze/framing/solid_head_split.jl@e61b36c,
  StructuralSynthesizer/src/analyze/framing/materialize.jl@e61b36c, StructuralSynthesizer/src/analyze/slabs/slabs/arrangement_heads.jl@e61b36c,
  StructuralSynthesizer/src/analyze/slabs/slabs/solid_head_check.jl@e61b36c, StructuralSynthesizer/src/workflow/member_iteration.jl@e61b36c,
  StructuralSynthesizer/test/analyze/test_rib_grillage.jl@e61b36c, docs/sizing-map/raw/slabs.md@e61b36c
session_id: sess-917f9253
created_at: '2026-11-12T02:16:40.604645+00:00'
updated_at: '2026-11-12T02:16:40.604645+00:00'
---
The building's solid concrete is the rib bays, and the beam/column loop grows them.

- Section widths come from solid_edge_widths of those bays. On a quad the corner fraction is the starting bays, and the existing rectangle mass check is unchanged.
- grow_building_solid_heads! runs after the ribs are sized. It starts from the fraction bays plus any column the fraction does not already cover, calls resolve_arrangement_heads, and moves the beams on the new bays into the solid-head group. A second call with the same sections returns the same heads.
- resolve retries a head after another head grows, because the frame changed. A step whose outline is not one critical section is refused.
- Punching uses that report. Without it, the released-corner rectangle check remains.

On the 6 by 4 m, 4 by 4 grid with narrow ribs and a heavy live load, the four corners start at one bay and stop at 2, 4, 2 and 4 bays, still failing one-way shear at ratios 1.45 to 2.10. The irregular outlines are unchanged.
