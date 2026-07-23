---
id: todo-f0c95acf
type: todo
project: menegroth
parent_id: plan-f933342a
title: 'Steel-column diagnostic: real E3-based capacity + correct §E3 citation (fix
  ''conservative'' mislabel)'
node_label: 'todo: E3 capacity+citation'
tags: aisc,e3,capacity,citation,diagnostic
status: active
open_threads: 0
success: 'null'
files: ''
session_id: sess-d721c22c
created_at: '2026-07-23T17:52:13.242381+00:00'
updated_at: '2026-07-23T17:52:13.242381+00:00'
---
Replace design_workflow.jl _populate_column_results! gross-yield estimate (0.9*Fy*Ag) with vetted E3-based capacity (reuse engine ϕPn or StructuralSizer.get_ϕPn). Cite §E3 in corpus_grounding + _column_code_clauses steel axial->E3. Mark done by discarding with reason 'completed'.
