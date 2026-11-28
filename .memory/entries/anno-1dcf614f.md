---
id: anno-1dcf614f
type: annotation
project: menegroth
parent_id: plan-33507d8a
title: size_beams! recursion hangs Julia inference
node_label: no recursive size_beams
tags: julia,inference,size_beams
status: active
open_threads: 0
success: 'null'
files: ''
session_id: sess-e553319d
created_at: '2026-11-05T20:17:54.390674+00:00'
updated_at: '2026-11-05T20:17:54.390674+00:00'
---
size_beams! must not call itself directly. Inferring the recursive call through the pass closure runs Julia's subtype checker until it does not finish (observed ~35 min in jl_f_issubtype / obvious_subtype). The multi-pass loop calls Base.invokelatest(size_beams!, ...), and group_filter is @nospecialize so each level's predicate does not recompile the function. A doubled docstring immediately above a function also fails precompile with "cannot document the following expression".
