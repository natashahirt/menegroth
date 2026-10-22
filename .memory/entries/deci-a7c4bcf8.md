---
id: deci-a7c4bcf8
type: decision
project: menegroth
parent_id: deci-bd124c43
title: Fix cycle 4 scope adds the reviewer's two notes
node_label: Fix cycle 4 scope adds the reviewer's two notes
tags: eq-13-7,fix-cycle-4,nlp,performance
status: active
open_threads: 1
success: 'null'
files: ''
session_id: sess-112ae1b2
created_at: '2026-10-14T20:41:59.287166+00:00'
updated_at: '2026-10-21T01:51:29.649732+00:00'
---
User asked to fix both reviewer notes in the next slab fix cycle, alongside the §13.6.2.4 edge-l2 doubling bug:
(1) Finish the vertex->cell index. _eq137_sw_from_result and _eq137_neighbour_drop still vector-search struc.slabs (ci in sl.cell_indices), and _eq137_column_list / _eq137_far_column scan every column. Precompute cell->slab and vertex->column maps once.
(2) The NLP flexural moment M (col_moments in flat_plate_problem.jl) must be classified direction-aware like the transfer moment, not by column_positions.
