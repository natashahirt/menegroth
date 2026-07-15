---
id: todo-d50bda2c
type: todo
project: menegroth
parent_id: plan-cecee16b
title: H4 — Integrated stability/drift + lateral-system selection
node_label: 'H4: Stability & system selection'
tags: todo,steel,stability,drift,system-selection,lfrs,phase-h
status: active
open_threads: 0
success: 'null'
files: ''
session_id: sess-92359b08
created_at: '2026-07-15T02:26:05.550462+00:00'
updated_at: '2026-07-15T02:26:05.550462+00:00'
has_child_rationale: Ties the steel LFRS into the whole-building lateral pipeline
  and picks the system
---
# H4 — Integrated stability/drift + system selection

The integration step: wire H1/H2 into the whole-building lateral pipeline (demand from A3 → distribute via A4 → design frames → check drift/stability), whole-frame P-Δ (A5), and a **lateral-system-selection** heuristic (braced vs moment vs dual, and where to place bracing bays / moment lines) analogous to the wall-layout question in the wall program (S4).

**Build:** system-selection + brace/moment-line placement (placement-as-input first, heuristic then optimized — mirror the wall program's placement policy), integrated drift/stability acceptance, and the dual-system option. **Couples to:** A3/A4/A5, wall program S2–S4 (shared distribution/layout machinery), F2 (steel office generator).
