---
id: deci-b966dff4
type: decision
project: menegroth
parent_id: deci-fa9d3eb2
title: Analysis sections fill walls from their stored thickness
node_label: Wall section fill
tags: viewer,section,walls
status: active
open_threads: 0
success: 'null'
files: ''
session_id: sess-661403b4
created_at: '2026-11-07T21:30:41.042055+00:00'
updated_at: '2026-11-07T21:30:41.042055+00:00'
---
Analysis mode hides the sized shell solids, so the black section fill was skipping walls. A wall lying in the cut plane also drew no stroke, because a triangle coplanar with the plane is skipped.

The shell volume stays a hatch source when it is hidden. Only wall prisms (shell kind 1) are filled, using the thickness stored on each triangle. Slab cuts in analysis stay the black stroke. The wall fill sits on the kept side of the plane so the unclipped wall sheet does not cover it. Sized geometry is unchanged: it still fills every solid, on the discarded side of the plane.

No office rerun and no commit. The office scene already has wall triangles and shell thickness.
