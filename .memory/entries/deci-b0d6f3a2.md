---
id: deci-b0d6f3a2
type: decision
project: menegroth
parent_id: expe-fbdb2363
title: Flat-plate scene is the shell, and wall nodes are not support arrows
node_label: plate scene, no wall arrows
tags: scene,flat-plate,support-arrows,core-office
status: active
open_threads: 0
success: 'null'
files: ''
session_id: sess-0505e00e
created_at: '2026-11-17T14:21:03.871236+00:00'
updated_at: '2026-11-17T14:21:03.871236+00:00'
has_child_rationale: The sized core office was drawn as the skeleton beam frame, so
  the beams sagged and the slab fans stayed flat.
---
A flat plate or flat slab scene keeps the shell mesh from build_analysis_model! (columns and walls). It does not replace that mesh with the skeleton frame and cell-corner fans. The generator beams are not the plate; drawing them shows their particular sag while the slab, connected only at the columns, barely moves.

A support arrow is drawn only where a column meets the ground. A node that belongs to a wall shell and is not the end of a column is held by the wall, so it is not drawn as a support. The grade restraint and the story-shell pin stay in the analysis. The footing pad is still drawn.
