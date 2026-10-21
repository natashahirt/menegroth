---
id: todo-5a5e6a94
type: todo
project: menegroth
parent_id: deci-4ef4e16f
title: 'Phase 0 eng_plumbing: run_all_gates.jl + README-gates.md + gitignore grasshopper
  + track untracked tests'
node_label: P0 eng_plumbing
tags: phase0,gates,hygiene
status: discarded
open_threads: 0
success: 'null'
files: ''
session_id: sess-2a4555ab
created_at: '2026-10-21T02:20:29.335163+00:00'
updated_at: '2026-10-21T03:19:44.505393+00:00'
---
Add scripts/runners/run_all_gates.jl (runs the four verify runners headless, aggregated exit code, by current path — no reorg); scripts/runners/README-gates.md (gate inventory, rtol, order, Gurobi need, design_signature schema). Gitignore grasshopper/Menegroth.GH/{obj,bin}/; git add the untracked StructuralSizer/test and StructuralSynthesizer/test files.
