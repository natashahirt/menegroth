---
id: deci-61ec0b4b
type: decision
project: menegroth
parent_id: plan-0e3e4710
title: Solid-head mass is the projection below the topping
node_label: Head mass is the projection
tags: solid-head,dead-load,grillage
status: active
open_threads: 0
success: 'null'
files: ''
session_id: sess-0aa4c403
created_at: '2026-11-08T23:32:08.666277+00:00'
updated_at: '2026-11-08T23:32:08.666277+00:00'
has_child_rationale: The panel pressure already contains the topping over the head,
  so the frame section must not weigh that concrete again.
---
The grillage panel pressure is the CIP topping, h·ρ·g, over the whole panel, including the solid head. Rib T-beams already leave that flange to the pressure and weigh only the stem.

A solid-head analysis section keeps the gross rectangle for stiffness (ACI 318-11 §13.7.3.1). Its mass is only the concrete below the topping: each rib family stores half of ρ×(depth−topping)/depth, so the two families weigh the projection once. A head that does not project below the topping adds no mass.

The depth is the sized concrete rib's overall depth. apply_solid_head_frame_sections! writes those sections onto the frame at the start of every stiffness re-solve, and after a single-pass size_beams! that solved before the ribs existed.
