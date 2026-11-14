---
id: plan-1e34d0a9
type: plan
project: menegroth
parent_id: plan-0802e15d
title: Edge beams, stop a failed waffle, heads as slabs
node_label: Edge beams and failed waffle
tags: waffle,edge-beam,aci-318,solid-head,joist
status: active
open_threads: 1
success: 'null'
files: ''
session_id: sess-22b4bc22
created_at: '2026-11-13T23:05:44.030926+00:00'
updated_at: '2026-11-14T15:02:03.038193+00:00'
has_child_rationale: Confirmed scope for the next implementation pass
---
Sketch, then implement. Three steps, in this order.

1. Edge beams. A concrete member with the slab on one side only stays on the T-beam path with one flange direction. ACI 318-11 §8.12.3 (aci-318-11, page 119): overhang ≤ span/12, ≤ 6·hf, and ≤ half the clear distance to the next web. §8.12.2 applies only when the slab is on both sides. A missing side is not a rectangular beam. A member on the slab boundary that currently takes the two-sided limits is sized as an edge beam. No new width formula.

2. A waffle that misses §8.13.2 or §8.13.3 (aci-318-11, page 120) does not stay a waffle. No solid-head growth and no two-way rib grillage. §8.13.4 designs that floor as slabs and beams. Head size is not a second trigger. For this grid the ribbed design is a one-way joist slab whose clear rib spacing satisfies §8.13, spanning onto girders. The other design is slabs and beams, with the slab in the scene and no solid heads.

3. Where a qualifying waffle does fill a pan, that region is a slab of the full rib depth in the analysis section. Ribs inside it do not keep a joist section, stirrups, or a T-flange.
