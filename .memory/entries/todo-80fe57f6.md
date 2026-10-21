---
id: todo-80fe57f6
type: todo
project: menegroth
parent_id: deci-4ef4e16f
title: 'Phase 0 eng_shared: extract _verify_shared.jl; rewire 4 verify runners + in-suite
  twins'
node_label: P0 eng_shared
tags: phase0,gates,refactor
status: discarded
open_threads: 0
success: 'null'
files: ''
session_id: sess-2a4555ab
created_at: '2026-10-21T02:20:25.686619+00:00'
updated_at: '2026-10-21T03:19:43.380971+00:00'
---
Extract INVARIANT_COLS, design_signature, same_signature, and shared build_* building builders (duplicated across verify_design_graph.jl, verify_design_graph_incremental.jl, verify_incremental_engine.jl, verify_warm_state_incremental.jl and their test/design_graph twins) into StructuralSynthesizer/test/design_graph/_verify_shared.jl; include from runners+tests. Must NOT activate StructuralStudies (second-Asap-identity hazard).
