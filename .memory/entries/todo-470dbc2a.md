---
id: todo-470dbc2a
type: todo
project: menegroth
parent_id: plan-97498959
title: E1 — Ingest NDS 2018 + Supplement (timber canon)
node_label: 'E1: Ingest NDS 2018'
tags: todo,corpus,ingest,nds,timber,phase-e
status: active
open_threads: 0
success: 'null'
files: ''
session_id: sess-9619ef1e
created_at: '2026-07-14T01:43:11.541971+00:00'
updated_at: '2026-07-14T01:43:11.541971+00:00'
has_child_rationale: Prerequisite for all timber work (D1, B6, C3) — NDS is absent
  from the corpus
---
# E1 — Ingest NDS 2018

NDS (National Design Specification for Wood Construction) 2018 + the NDS Supplement (reference design values) are **absent from the corpus manifest**. Required before any timber Julia can be written (`code-accuracy.mdc`).

**Do:** add NDS 2018 + Supplement to `corpus/manifests/sources.yml`, run `scripts/corpus/ingest.py`, verify via `corpus.search_text`/`get_clause`. Include CLT provisions (or PRG 320) for B6. **Unblocks:** D1, B6, C3, F4.
