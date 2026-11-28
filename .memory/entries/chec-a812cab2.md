---
id: chec-a812cab2
type: checkpoint
project: menegroth
parent_id: plan-31b09209
title: Wall thickness groupings share one proposal and re-solve when they differ
node_label: Grouped wall thickness loop
tags: walls,thickness,grouping
status: active
open_threads: 0
success: 'null'
files: ''
session_id: sess-37bf593d
created_at: '2026-11-08T03:07:26.838165+00:00'
updated_at: '2026-11-08T03:07:26.838165+00:00'
---
All six thickness groupings are sized. `propose_wall_thicknesses` partitions the walls with `wall_thickness_groups`, then calls the existing `propose_wall_thickness` on each group.

Drift and interactive story shear are handed to every group and scaled from that group's own thickness, so relative stiffness is unchanged when those govern. A local check (minimum thickness, shear cap, bearing) moves only the groups that contain the failing wall. `:all` is that same path with one group. It still stops after the existing confirm cap (`_thickness_pass >= 2`). A finer grouping may re-solve until nothing grows, and stops after six analyses; the last result stands, failures included. The jump only increases thickness. A group that already has two thicknesses throws when it needs to grow. `:all` that is already mixed does not jump.

Parity, from one frozen analysis, on parallel, collinear, and stacked pairs: the thickest wall of every grouping matches `:all` for minimum thickness, shear over the cap, story drift, and interactive story shear. Drift on two different starting thicknesses multiplies each pier from its own thickness. On a symmetric one-story building, all six groupings finish at the same thickness and the same reinforcement, and the checks pass. A 100 mm wall beside 300 mm walls grows alone under a grouping that splits it, the other walls stay, and those checks pass. `:all` leaves the mixed set unchanged. A grouping that would have to grow a mixed group throws.

`design_building publishes ordinary-wall records` still errors: `wall_is_fully_restrained` is called from the flat-plate DDM applicability check and is not defined. That is outside this loop.
