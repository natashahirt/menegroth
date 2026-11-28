---
id: deci-9b435a0e
type: decision
project: menegroth
parent_id: deci-2bb4ccf6
title: Sized beams share the slab top, and an SDF plan has no beams at the supports
node_label: Sized beams share the slab top, and an SDF plan ha
tags: viewer,slab,beams,support,mid-plane
status: active
open_threads: 0
success: 'null'
files: ''
session_id: sess-e3a19980
created_at: '2026-11-13T15:05:52.833860+00:00'
updated_at: '2026-11-13T15:05:52.833860+00:00'
---
The grid waffle scene is one 8 in slab at 12 ft. Its top was already flat. The uneven surface is the beam sections (about 12 to 20 in), drawn centered on that same plane, so the deeper beams stick up through the slab. The ground grid is a second copy of the plan at the column bases.

The sized drawing now puts every beam top on the slab top and hangs the extra depth below. Panels of different thickness on one plane share the highest top. Beams below every slab, on the support elevation, are not drawn. The analysis line stays on the shell mid-plane; this does not move the solved centroid.

An SDF plan draws beams only at the floor. Columns still rise from supports at grade. Warehouse floor cells are 49, and the tributary still covers the floor.
