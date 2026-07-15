---
id: todo-f69e605b
type: todo
project: menegroth
parent_id: todo-9160f206
title: A1.3 — Joist load-routing validation + default framing_opts policy
node_label: 'A1.3: Load routing + defaults'
tags: todo,joists,load-routing,framing,defaults,phase-a
status: active
open_threads: 0
success: 'null'
files: ''
session_id: sess-252d7a06
created_at: '2026-07-15T01:15:53.132051+00:00'
updated_at: '2026-07-15T01:15:53.132051+00:00'
has_child_rationale: Decide whether joists are on by default and validate area-load
  routing
---
# A1.3 — Load routing + default policy

Two loose ends: (1) validate the joist-aware area-load routing modes (`:auto`, `:cell_tributary`, `:shell_area` in `analyze/asap/utils.jl`) against a hand tributary calc; (2) decide the **default** — today `prepare!` uses empty `framing_opts` ⇒ no joists unless the caller opts in. Choose and document a defensible default so flat-plate and framed workflows behave predictably. **Couples to:** A1.1/A1.2.
