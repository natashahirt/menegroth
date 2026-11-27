---
id: todo-8ccd78cf
type: todo
project: menegroth
parent_id: plan-a79eb74f
title: 'Next: apply cladding weight, then bring wind and seismic into the footings'
node_label: 'Next: apply cladding weight, then bring wind and s'
tags: sizing,cladding,foundations,wind,seismic,todo,next
status: discarded
open_threads: 3
success: 'null'
files: ''
session_id: sess-df7afd0f
created_at: '2026-11-25T16:32:39.243830+00:00'
updated_at: '2026-11-27T21:21:58.061736+00:00'
---
Do these two unconservative gaps next, before any further column cleanup.

1. Cladding dead load is accepted and never applied. `GravityLoads.wall_SDL` (default 10 psf) has no consumer, so façade weight is missing from perimeter-member gravity design, foundations, seismic weight W, and Px. Sizing-map sign-off item 1.

2. Wind and seismic never reach foundation design. Sizing-map sign-off item 4.

The column gaps are already on the same round as the beam-and-column loop: a story-shell column gets one trim after the shell settles, and a floor with no beams gets free passes, then a floor, then one trim. Both keep a lighter design only when it converges. The story-shell trim also requires the shell of the new columns to pass.
