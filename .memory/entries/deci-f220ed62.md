---
id: deci-f220ed62
type: decision
project: menegroth
parent_id: plan-b0000001
title: SS_SKIP_SOLVER_WARMUP skips StructuralSizer's JuMP warmup in short-lived test
  processes (Gurobi license still probed)
node_label: SS_SKIP_SOLVER_WARMUP
tags: testing,startup,gurobi,jump,dev-tooling
status: active
open_threads: 0
success: 'null'
files: scripts/runners/test_quiet.jl@36a39f8, docs/agent-setup.md@36a39f8
session_id: sess-7b1f9afb
created_at: '2026-11-04T17:09:03.482049+00:00'
updated_at: '2026-11-04T17:09:03.482049+00:00'
---
## Decision
`StructuralSizer.__init__` checks `SS_SKIP_SOLVER_WARMUP` (runtime ENV, fine because __init__ runs per process). When true it skips `_warmup_jump_solvers()` (JIT-only trivial MIP solves) but still calls `_get_gurobi_env()` and sets `_HAS_GUROBI[] = false` on failure, so Gurobi-gated tests and the `:auto` -> HiGHS fallback behave exactly as before. `test_quiet.jl` sets it to true for fresh child processes (overridable); the persistent test server keeps the warmup (paid once).

## Verified
Same small test file in a fresh process: ~48 s with skip vs ~65 s without (noisy machine; ~15-20 s saved). Gurobi still detected.

StructuralSizer.jl has user WIP, so the __init__ hunk is committed separately (hunk-only).
