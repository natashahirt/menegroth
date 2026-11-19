---
id: deci-38eacad7
type: decision
project: menegroth
parent_id: plan-a7ebaacc
title: 'Ribbed floors: one rib depth per story, one web and bar size per rib line,
  depth set by strength, heads, and computed deflection on carbon'
node_label: Story rib depth, rib lines, deflection
tags: waffle,joists,rib-depth,deflection,aci-318-11,carbon
status: active
open_threads: 0
success: 'null'
files: ''
session_id: sess-5aeb210c
created_at: '2026-11-19T20:18:18.894455+00:00'
updated_at: '2026-11-19T20:18:18.894455+00:00'
has_child_rationale: User reframed ribbed floors at the system level after per-piece
  sizing produced 11 in ribs and large heads
invalidates: deci-20346596
---
User decisions 2026-11-19 (plan in docs/sizing-map/ribbed-floors.md):

- One overall rib depth per story (waffle and joist), chosen from topping + the joist stem grid (6..24 in); standard 30 in dome depths are an option only, so waffle and joist code share one grid.
- One web width per rib line (prismatic end to end); one bar size per line, bar counts per piece.
- Depth is set by rib strength, the solid heads, and computed deflection (ACI 318-11 §9.5.3.4 with Table 9.5(b), corpus aci-318-11 PDF pp. 133-135).
- Deflection: peak sag below the surface through the corner columns of the column bay (columns deflect too); l = the longer center-to-center column span. Immediate live l/360. Long-term limit is a setting, default l/480 (damageable elements), l/240 selectable.
- Objective: embodied carbon of concrete plus longitudinal rebar in ribs and heads.

Supersedes deci-20346596 item 1-2 (per-piece width and depth, depth step). Its head items (punching minimum, void closure, solid cap) stay. Retires conform_rib_lines!, rib_depth_step, raise_head_face_ribs!, and the per-piece rib MIP.
