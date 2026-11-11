---
id: deci-0f308a4b
type: decision
project: menegroth
parent_id: plan-3fd23103
title: Variant scenes are content-addressed blocks with per-design manifests
node_label: Variant storage
tags: viewer,scene-format,variants,compression
status: active
open_threads: 1
success: 'null'
files: ''
session_id: sess-3666303e
created_at: '2026-11-07T00:09:17.798918+00:00'
updated_at: '2026-11-07T00:10:35.125425+00:00'
has_child_rationale: Shared vs per-variant must change as designs are added without
  moving data
---
Measured office scene (1.63 MB): analysis mesh + results ~90% (faces 489 KB, positions 251, displacement 251, rotation 251, thickness+kind 204); components JSON 153 KB (deflates to 9 KB); member solids 14 KB. node_rotation is decoded by the viewer but never used.

Decisions (user, 2026-11-06):
- Every array is a block keyed by the hash of its uncompressed content. A design is a manifest of block hashes. Shared = referenced by more than one manifest; computed, never declared.
- Append-only: adding a design writes only missing blocks plus a new trailing index. `compact` rewrites to drop orphans after a removal.
- Mesh blocks split per component (slab, wall, story, footing set) with local node numbering so one design's extra nodes do not renumber everything. Results (displacement, stress) are expected to be per design.
- Lossless per-block deflate (browser DecompressionStream). Faces delta+byte-shuffle: 489 -> 215 KB. Floats byte-shuffled: displacement 251 -> 188 KB.
- Display-only fields (displacement, stress) quantized to int16 steps of max/32767 with the step in the header (office: 0.00056 mm, 251 -> 82 KB). Check values in component records stay exact.
- node_rotation leaves the viewer scene; stays in .mgdesign.
- Viewer reads the index, fetches only the active design's blocks.
Not started.
