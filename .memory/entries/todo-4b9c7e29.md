---
id: todo-4b9c7e29
type: todo
project: menegroth
parent_id: deci-89225495
title: Document SERVER_STATUS as sole serializer of non-concurrency-safe incremental
  engine
node_label: 'TODO: engine-race guard'
tags: todo,concurrency,SERVER_STATUS,incremental-engine,hardening
status: active
open_threads: 0
success: 'null'
files: ''
session_id: sess-f5bbcf39
created_at: '2026-10-21T04:03:26.839103+00:00'
updated_at: '2026-10-21T04:03:26.839103+00:00'
has_child_rationale: rev2 hardening suggestion from P0-1 re-review
---
## rev2 hardening suggestion

Add a comment/assert documenting that **`SERVER_STATUS` (RUNNING) is the ONLY serializer** of the non-concurrency-safe incremental engine.

Any future call site that invokes `_design_with_incremental!` **without holding RUNNING** would be an engine race (the incremental engine is not concurrency-safe). The invariant currently holds because both existing call sites (`_execute_design`, `run_design`) serialize designs via `SERVER_STATUS`, but this is undocumented and easy to violate when adding a third call site.
