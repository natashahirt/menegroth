---
id: note-a6b2a27e
type: note
project: menegroth
parent_id: plan-267f93b4
title: Core-corner columns inside the walls came back
node_label: corner columns in walls
tags: core-office,columns,walls,geometry
status: active
open_threads: 0
success: 'null'
files: ''
session_id: sess-39367573
created_at: '2026-11-14T20:46:06.652471+00:00'
updated_at: '2026-11-14T20:46:06.652471+00:00'
---
The core office again shows a column stack at each corner where the core walls meet. That is the skeleton that leaves those edges in `:columns`. The geometry in `scripts/runners/core_office_geometry.jl` on the main checkout parks the four stacks (four stories) into `:absent` with `_park_core_corner_columns!`, so the walls are the supports there and the edges can be put back later. The floor-system scenes started 2026-11-14 used the skeleton that keeps the columns, which is why the columns are inside the walls again. Do not treat that as the intended core.
