---
id: note-2d6becc1
type: note
project: menegroth
parent_id: deci-a00932d8
title: 'Exhaustive audit: propagated UNVERIFIED/NaN state through every consumer of
  column ratios'
node_label: Exhaustive consumer propagation audit
tags: audit,nan-propagation,serialization,api,diagnose,report,micro-experiments,narrate
status: active
open_threads: 0
success: 'null'
files: ''
session_id: sess-a071a5e6
created_at: '2026-07-23T20:21:56.540880+00:00'
updated_at: '2026-07-23T20:21:56.540880+00:00'
has_child_rationale: Documents the full set of downstream sites that had to be guarded
  so the sentinel never crashes or mislabels
---
The UNVERIFIED/NaN state was propagated through **every** consumer of column ratios (exhaustive audit driven by two failed review cycles):

- `_compute_design_summary!`
- `column_diagnostic_governing_check` (isnan-first)
- `diagnose.jl` — `_serialized_ratio` helper, finite `governing_ratio`, lever/goal sites
- `_serialize_columns` + `APIColumnResult` (nullable)
- `_serialize_visualization_frame_elements` + `APIVisualizationFrameElement` (nullable) — **this was the P0 that crashed `GET /result` on the default path**
- `report_summary` `_summary_columns` (filter `!isnan` + `n_unverified`)
- `micro_experiments` — `_column_orig_ratio`, catalog-screen `_cand_sort_key` (defeats `isless(Nothing,Float64)`)
- `narrate` `_fmt_check_ratio`

**Guard patterns used:** finite-filter; force ratio ≥ 1.0 when failing (never 0/safe); nullable API fields.
