---
id: deci-2ce30b6f
type: decision
project: menegroth
parent_id: plan-440fc73d
title: Input lines are column centerlines; the slab edge extends to the largest column
  face on each exterior line
node_label: Columns on grid, slab grows to cover them
tags: slab,columns,structural-offset,analysis-model,edge-strip,geometry
status: active
open_threads: 0
success: 'null'
files: StructuralSynthesizer/src/analyze/members/members/geometry_classification.jl@07f913b,
  StructuralSynthesizer/src/analyze/slabs/slabs/story_shell.jl@07f913b
session_id: sess-db6f17d3
created_at: '2026-11-06T22:35:57.127487+00:00'
updated_at: '2026-11-06T22:35:57.127487+00:00'
invalidates: deci-2941c900
---
Supersedes deci-2941c900. The old model moved edge and corner columns inboard by half their size (col.structural_offset) and moved frame nodes with them, while the skeleton, tributaries, beam lengths, and story shell stayed on the input lines. The bay changed with column size and the story shell lost its support nodes (ArgumentError: no shell node at support (0.1778, 0.1778) in test_story_shell_pipeline).

Decided with the user:
- Skeleton vertices are column and beam centerlines and never move. Frame nodes, cells, tributaries, story-shell beam lines, and supports all sit on them. A column resize changes sections, not geometry.
- Each straight exterior line gets an edge strip outside the centerline, with width equal to the largest half-column dimension normal to that line. The edge stays straight, and smaller columns on that line sit back from it. Corners take the two lines' intersection.
- The strip width tracks column size. It is recomputed at the three call sites that run update_structural_offsets! today (column sizing, column reconciliation, member iteration). Reconciliation only grows columns, so strips only widen; the extra strip load is small and converges inside the existing caps.
- The strip is meshed as a fixed-count band, so a width change only moves nodes. Same sparsity, numeric re-factorization, no story-shell rebuild (width is not part of the shell signature).
- The strip load goes to the edge beam (or the edge columns of a flat plate) as a line load. Tributary cells are unchanged, and the area balance includes the strip.
- Punching uses the real column-face-to-slab-edge distance; the ACI edge-distance rule comes from the corpus before implementation.
- Flat-plate EFM/DDM spans are center-to-center (the drawn bay); clear spans subtract half a column at each end.
- Input drawn as a slab edge is still accepted, converted once at preparation by a fixed setback, and never tracks column size. Centerline becomes the default.
