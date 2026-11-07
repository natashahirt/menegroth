---
id: note-621eb77e
type: note
project: menegroth
parent_id: plan-04899673
title: Saved core office design is archive version 1 and the current code cannot read
  it
node_label: v1 design unreadable
tags: foundations,core-office,archive
status: active
open_threads: 0
success: 'null'
files: ''
session_id: sess-7588812f
created_at: '2026-11-07T22:52:38.482299+00:00'
updated_at: '2026-11-07T22:52:38.482299+00:00'
has_child_rationale: The equilibrium check cannot reload the saved core office until
  a version 2 design is written
---
core_office.mgdesign (written 2026-11-07 16:28) is design-archive version 1. The current reader is version 2 because Slab carries tributary_polygons, and a version 1 file does not deserialize (MethodError: Vector{Vector{Int64}} cannot convert to Slab). A stale precompile did load it once: 16 supports, 12 spreads, one mat 9.22 x 9.22 x 0.61 m at 76% utilization with 4 supports and 13 walls, and one wall group. 12 + 4 = 16, so every support is on exactly one footing. The vertical residual was not printed; the check script then hit a soft-scope error, and the following recompile made the file unreadable. The equilibrium check has to follow a new design that writes archive version 2.
