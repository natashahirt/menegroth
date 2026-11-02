---
id: deci-7144bc3d
type: decision
project: menegroth
parent_id: plan-c7b78612
title: Two-way ln is the long span along the reinforcement axes; steel αf follows
  composite action
node_label: Two-way ln along reinforcement axes; steel αf by composite level
tags: slabs,two-way,thickness,composite,aci-318-11
status: active
open_threads: 0
success: 'null'
files: ''
session_id: sess-c02bef18
created_at: '2026-11-02T13:21:11.710315+00:00'
updated_at: '2026-11-02T13:21:11.710315+00:00'
has_child_rationale: The user set ln as the max span along the reinforcement direction
  and chose the steel αf basis.
---
Locked 2026-11-02 (user).

1. ln for the two-way minimum thickness is the longer chord along the panel's reinforcement axes: max(spans.primary, spans.secondary). These come from Asap `get_polygon_span(verts; axis)`, along global x and y or a given tributary_axis, the same axes the shell's bars use by default. β = longer/shorter. The polygon diameter (spans.isotropic) is not along a reinforcement axis and is no longer used for TwoWay. Changed in StructuralSynthesizer `_sizing_span(::TwoWay)`, the initializer (which passes l2 for TwoWay), and StructuralSizer `_size_slab!(::TwoWay)`. A 20×20 ft bay with unknown beams is now 8.5 in; the diagonal gave 11.5 in. Building test: 14/14.

Still center-to-center, not face-to-face: beam widths are not known when the slab is sized, so this is conservative. Known limitation: on a non-convex panel (U or L), the Asap chord through a vertex can jump across the notch. That makes the span too long, which is conservative. Not fixed.

2. Steel beam αf basis (ACI 318-11 §13.2.4, page 244, includes the slab only for monolithic or fully composite construction): non-composite uses bare Es·Ix; fully composite uses the transformed composite section; partially composite uses the AISC lower-bound I_LB already computed by the composite beam code (ENGINEERING JUDGMENT; ACI does not cover partial composite). Applies once the slab is re-sized after the beams, which comes after the shell work.
