---
id: todo-c2f2cf6e
type: todo
project: menegroth
parent_id: plan-93430266
title: 'D2: grouped size_columns in size_flat_plate!'
node_label: 'D2: grouped size_columns in size_flat_plate!'
tags: wave-3, d2, column-grouping, size-columns, todo
status: discarded
open_threads: 0
success: 'null'
files: ''
session_id: sess-4eeb9160
created_at: '2026-07-19T18:14:48.246289+00:00'
updated_at: '2026-07-23T14:46:59.834291+00:00'
---
Replace size_columns(n-vec) at pipeline.jl:1134 (Phase A) and :1387 (Phase B) with envelope(Pu,Mu,geom)→size_columns(k-vec)→fanout back to n columns. New helper analogous to _apply_column_results!. MIP still runs once with n_max_sections active on k demands, not n.
