---
id: todo-5ac236c3
type: todo
project: menegroth
parent_id: plan-f933342a
title: 'P2c: harden citation registry against last-writer-wins on verbatim clause/edition'
node_label: 'todo: P2c registry'
tags: p2,citation-registry,robustness
status: discarded
open_threads: 0
success: 'null'
files: ''
session_id: sess-1bf3bf92
created_at: '2026-07-23T17:52:27.282894+00:00'
updated_at: '2026-07-23T20:23:16.131567+00:00'
---
corpus_grounding/design_state citation registry dedups by citation_id but stores verbatim clause/edition last-writer-wins; two spellings mapping to one id can cross-reference. Either include verbatim clause in the key or assert identical metadata before overwrite; add a guarding test. Mark done by discarding with reason 'completed'.
